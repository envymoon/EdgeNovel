// Kokoro 1.1-zh (StyleTTS 2 with an iSTFTNet vocoder) on ggml.
//
// The heavy parts, the text's BERT, the prosody's convolutions and the
// decoder, are ggml graphs on the GPU when there is one. The recurrent layers
// (six small bidirectional LSTMs), the durations, the harmonic source and the
// STFTs are a few milliseconds of plain C++ in between.
//
// Sequences in the graphs are laid out [T, C]: time is the fast axis, like
// the original's [C, T] in memory, which is what ggml's convolutions take.
#include "kokoro.h"

#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml.h"
#include "gguf.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <condition_variable>
#include <map>
#include <mutex>
#include <random>
#include <set>
#include <string>
#include <thread>
#include <vector>

#ifdef __APPLE__
#include <sys/sysctl.h>
#endif
#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace {

constexpr int SR = 24000;
constexpr int NFFT = 20;
constexpr int HOP = 5;
constexpr int BINS = NFFT / 2 + 1;
constexpr int UPS = 300;  // samples per decoder frame: 10 * 6 * HOP
constexpr int HARMONICS = 9;
constexpr int GRAPH = 16384;
// Phonemes spoken at once at most (about 30 s of speech, 500 MB), unless
// one sentence alone is longer; and the memory a lane keeps between them.
constexpr int BUDGET = 500;
constexpr size_t KEEP = 128u << 20;

struct Lstm {
    int in = 0, hid = 0;
    std::vector<float> wih[2], whh[2], b[2];
};

}  // namespace

// Where a sentence runs: a backend (a queue of its own on the GPU) and the
// memory for what it computes. Sentences on different lanes run at once over
// the one copy of the weights.
struct Lane {
    ggml_backend_t backend = nullptr;
    ggml_gallocr_t alloc = nullptr;
};

struct kokoro {
    bool gpu = false;
    ggml_context * wctx = nullptr;
    ggml_backend_buffer_t wbuf = nullptr;
    std::vector<Lane *> lanes, idle;
    int most = 1;  // sentences at once
    int inflight = 0;  // phonemes being spoken
    std::mutex m;
    std::condition_variable freed;
    std::map<std::string, ggml_tensor *> w;
    std::set<std::string> taps;  // convolution weights, laid [Cin, K, Cout] at load
    std::map<std::string, int> vocab;
    std::vector<std::string> voice_names;
    std::map<std::string, std::vector<float>> voices;  // [510][256]
    int threads = 4;
    int bert_heads = 12;
    Lstm te_lstm, dur_lstm[3], pred_lstm, shared;
    std::vector<float> ada_w[3], ada_b[3];  // duration encoder AdaLayerNorm fc
    std::vector<float> dur_w, dur_b;        // duration_proj [50][512]
    float src_w[HARMONICS] = {}, src_b = 0;
    std::string debug_dir;
    bool quiet = false;
    // Sentences still to time op by op (EDGE_KOKORO_PROFILE at load), into
    // the log: each op on its own, so slower, and only for those.
    std::atomic<int> profile{0};
};

namespace {

// ---- loading ---------------------------------------------------------------

std::vector<float> host(kokoro * k, const std::string & name, gguf_context * g, FILE * f) {
    const int64_t id = gguf_find_tensor(g, name.c_str());
    if (id < 0) throw std::string("missing tensor " + name);
    ggml_tensor * t = k->w.at(name);
    const size_t off = gguf_get_data_offset(g) + gguf_get_tensor_offset(g, id);
    std::vector<uint8_t> raw(ggml_nbytes(t));
    if (fseek(f, (long) off, SEEK_SET) != 0 || fread(raw.data(), 1, raw.size(), f) != raw.size())
        throw std::string("cannot read " + name);
    std::vector<float> out(ggml_nelements(t));
    if (t->type == GGML_TYPE_F32) {
        memcpy(out.data(), raw.data(), raw.size());
    } else if (t->type == GGML_TYPE_F16) {
        ggml_fp16_to_fp32_row((const ggml_fp16_t *) raw.data(), out.data(), (int64_t) out.size());
    } else {
        throw std::string("unexpected type for " + name);
    }
    return out;
}

void load_lstm(kokoro * k, Lstm & l, const std::string & p, gguf_context * g, FILE * f) {
    const char * sfx[2] = {"_l0", "_l0_reverse"};
    for (int d = 0; d < 2; d++) {
        l.wih[d] = host(k, p + ".weight_ih" + sfx[d], g, f);
        l.whh[d] = host(k, p + ".weight_hh" + sfx[d], g, f);
        auto bi = host(k, p + ".bias_ih" + sfx[d], g, f);
        auto bh = host(k, p + ".bias_hh" + sfx[d], g, f);
        l.b[d].resize(bi.size());
        for (size_t i = 0; i < bi.size(); i++) l.b[d][i] = bi[i] + bh[i];
    }
    l.hid = (int) l.b[0].size() / 4;
    l.in = (int) (l.wih[0].size() / l.b[0].size());
}

// ---- CPU parts -------------------------------------------------------------

inline float sigm(float x) { return 1.0f / (1.0f + std::exp(-x)); }

float dot(const float * a, const float * b, int n) {
    float s = 0;
    for (int i = 0; i < n; i++) s += a[i] * b[i];
    return s;
}

// x: [T][in] -> out: [T][2*hid], forward then backward halves.
void run_lstm(const Lstm & l, const float * x, int T, float * out) {
    auto one = [&](int d) {
        const int H = l.hid;
        std::vector<float> pre((size_t) T * 4 * H);
        for (int t = 0; t < T; t++)
            for (int r = 0; r < 4 * H; r++)
                pre[(size_t) t * 4 * H + r] =
                    l.b[d][r] + dot(&l.wih[d][(size_t) r * l.in], x + (size_t) t * l.in, l.in);
        std::vector<float> h(H, 0.0f), c(H, 0.0f), g(4 * H);
        for (int s = 0; s < T; s++) {
            const int t = d ? T - 1 - s : s;
            for (int r = 0; r < 4 * H; r++)
                g[r] = pre[(size_t) t * 4 * H + r] + dot(&l.whh[d][(size_t) r * H], h.data(), H);
            for (int j = 0; j < H; j++) {
                const float i = sigm(g[j]), fg = sigm(g[H + j]), gg = std::tanh(g[2 * H + j]),
                            o = sigm(g[3 * H + j]);
                c[j] = fg * c[j] + i * gg;
                h[j] = o * std::tanh(c[j]);
                out[(size_t) t * 2 * H + d * H + j] = h[j];
            }
        }
    };
    std::thread back(one, 1);
    one(0);
    back.join();
}

// Layer norm over each row of [T][C], then (1 + gamma) x + beta.
void ada_layer_norm(float * x, int T, int C, const float * gamma, const float * beta) {
    for (int t = 0; t < T; t++) {
        float * r = x + (size_t) t * C;
        double m = 0, v = 0;
        for (int i = 0; i < C; i++) m += r[i];
        m /= C;
        for (int i = 0; i < C; i++) v += (r[i] - m) * (r[i] - m);
        v /= C;
        const float inv = 1.0f / std::sqrt((float) v + 1e-5f);
        for (int i = 0; i < C; i++) r[i] = (1.0f + gamma[i]) * ((r[i] - (float) m) * inv) + beta[i];
    }
}

void linear(const float * w, const float * b, const float * x, int in, int out, float * y) {
    for (int o = 0; o < out; o++) y[o] = b[o] + dot(w + (size_t) o * in, x, in);
}

const float PI = 3.14159265358979323846f;

// The harmonic source of the original's SourceModuleHnNSF, sample for sample.
std::vector<float> harmonic_source(const kokoro * k, const std::vector<float> & f0, unsigned seed) {
    const int L = (int) f0.size();  // decoder frames
    const int N = L * UPS;
    std::vector<float> out(N);
    std::mt19937 rng(seed);
    std::normal_distribution<float> gauss(0.0f, 1.0f);
    std::vector<float> phase(L);
    std::vector<float> merged(N, k->src_b);
    for (int h = 0; h < HARMONICS; h++) {
        // Phase per frame: the per-sample step of the frame, summed over
        // frames, then spread over the samples by linear interpolation.
        // Summed in double, as torch's cumsum does on the CPU.
        double acc = 0;
        for (int i = 0; i < L; i++) {
            float r = f0[i] * (float) (h + 1) / (float) SR;
            r = r - std::floor(r);
            acc += r;
            phase[i] = (float) acc * 2.0f * PI * (float) UPS;
        }
        for (int j = 0; j < N; j++) {
            float src = ((float) j + 0.5f) / (float) UPS - 0.5f;
            if (src < 0) src = 0;
            int i0 = (int) src;
            if (i0 > L - 1) i0 = L - 1;
            const int i1 = std::min(i0 + 1, L - 1);
            const float lam = src - (float) i0;
            const float p = (1.0f - lam) * phase[i0] + lam * phase[i1];
            const float f = f0[j / UPS];
            const bool voiced = f > 10.0f;
            float v = voiced ? std::sin(p) * 0.1f : 0.0f;
            if (!k->quiet) v += (voiced ? 0.003f : 0.1f / 3.0f) * gauss(rng);
            merged[j] += k->src_w[h] * v;
        }
    }
    for (int j = 0; j < N; j++) out[j] = std::tanh(merged[j]);
    return out;
}

std::vector<float> hann() {
    std::vector<float> w(NFFT);
    for (int n = 0; n < NFFT; n++) w[n] = 0.5f - 0.5f * std::cos(2.0f * PI * (float) n / (float) NFFT);
    return w;
}

struct DftTable {
    double cos_t[BINS][NFFT];
    double sin_t[BINS][NFFT];
    DftTable() {
        for (int kb = 0; kb < BINS; kb++) {
            for (int n = 0; n < NFFT; n++) {
                const double a = 2.0 * M_PI * kb * n / NFFT;
                cos_t[kb][n] = std::cos(a);
                sin_t[kb][n] = std::sin(a);
            }
        }
    }
};

static const DftTable & dft_table() {
    static const DftTable tbl;
    return tbl;
}

// torch.stft(center, reflect, hann) -> [22][frames]: magnitudes, then phases.
std::vector<float> stft(const std::vector<float> & x, int & frames) {
    const int N = (int) x.size();
    const int pad = NFFT / 2;
    std::vector<float> p(N + 2 * pad);
    for (int i = 0; i < N + 2 * pad; i++) {
        int j = i - pad;
        if (j < 0) j = -j;
        if (j >= N) j = 2 * (N - 1) - j;
        p[i] = x[j];
    }
    frames = N / HOP + 1;
    const auto w = hann();
    const auto & tbl = dft_table();
    std::vector<float> out((size_t) 2 * BINS * frames);
    double vw[NFFT];
    for (int f = 0; f < frames; f++) {
        const float * pf = &p[f * HOP];
        for (int n = 0; n < NFFT; n++) {
            vw[n] = (double) pf[n] * w[n];
        }
        for (int kb = 0; kb < BINS; kb++) {
            double re = 0, im = 0;
            const double * ct = tbl.cos_t[kb];
            const double * st = tbl.sin_t[kb];
            for (int n = 0; n < NFFT; n++) {
                re += vw[n] * ct[n];
                im -= vw[n] * st[n];
            }
            if (kb == 0 || kb == BINS - 1) im = 0;
            out[(size_t) kb * frames + f] = (float) std::sqrt(re * re + im * im);
            out[(size_t) (BINS + kb) * frames + f] = (float) std::atan2(im, re);
        }
    }
    return out;
}

// torch.istft of exp(x[:11]) * e^(i sin(x[11:])), x: [22][frames].
std::vector<float> istft(const std::vector<float> & x, int frames) {
    const auto w = hann();
    const auto & tbl = dft_table();
    const int full = (frames - 1) * HOP + NFFT;
    std::vector<double> acc(full, 0.0), env(full, 0.0);
    double re_k[BINS], im_k[BINS];
    for (int f = 0; f < frames; f++) {
        for (int kb = 0; kb < BINS; kb++) {
            const double m = std::exp((double) x[(size_t) kb * frames + f]);
            const double ph = std::sin((double) x[(size_t) (BINS + kb) * frames + f]);
            const double scale = (kb == 0 || kb == BINS - 1) ? m : 2.0 * m;
            re_k[kb] = scale * std::cos(ph);
            im_k[kb] = scale * std::sin(ph);
        }
        const double dc = re_k[0];
        const double nyq = re_k[BINS - 1];
        for (int n = 0; n < NFFT; n++) {
            double s = dc + ((n & 1) ? -nyq : nyq);
            for (int kb = 1; kb < BINS - 1; kb++) {
                // cos(2*pi*kb*n/NFFT + ph[kb]) = cos_t*cos(ph) - sin_t*sin(ph)
                s += re_k[kb] * tbl.cos_t[kb][n] - im_k[kb] * tbl.sin_t[kb][n];
            }
            s /= NFFT;
            acc[f * HOP + n] += s * w[n];
            env[f * HOP + n] += (double) w[n] * w[n];
        }
    }
    const int pad = NFFT / 2;
    const int len = (frames - 1) * HOP;
    std::vector<float> out(len);
    for (int i = 0; i < len; i++) {
        const double e = env[i + pad];
        out[i] = (float) (e > 1e-11 ? acc[i + pad] / e : acc[i + pad]);
    }
    return out;
}

// ---- graph pieces ----------------------------------------------------------

struct G {
    kokoro * k;
    ggml_context * ctx;
    // Intermediates written out when checking.
    std::vector<std::pair<std::string, ggml_tensor *>> * probes = nullptr;
    void probe(const char * name, ggml_tensor * t) const {
        if (probes && !k->debug_dir.empty()) probes->push_back({name, t});
    }
    ggml_tensor * W(const std::string & n) const {
        auto it = k->w.find(n);
        if (it == k->w.end()) throw std::string("missing tensor " + n);
        return it->second;
    }
    bool has(const std::string & n) const { return k->w.count(n) != 0; }

    // ConvTranspose1d of x [IL, IC] by w [K, OC, IC] with K = 2 * stride, as
    // one matrix product and an overlap-add: each output step takes the
    // first half of the kernel from one input step and the second half from
    // the one before. ggml's own runs a single thread per output on Metal,
    // which kept an iPhone GPU busy for most of a sentence. -> [(IL+1)*s, OC]
    ggml_tensor * up(ggml_tensor * w, ggml_tensor * x, int s) const {
        const int64_t K = w->ne[0], OC = w->ne[1], IC = w->ne[2], IL = x->ne[0];
        if (K != 2 * s || x->ne[1] != IC) throw std::string("unexpected upsampling shape");
        ggml_tensor * a = ggml_cont(ctx, ggml_transpose(ctx, ggml_reshape_2d(ctx, w, K * OC, IC)));  // [IC, K*OC]
        ggml_tensor * y = ggml_mul_mat(ctx, a, ggml_cont(ctx, ggml_transpose(ctx, x)));             // [K*OC, IL]
        y = ggml_reshape_3d(ctx, y, K, OC, IL);
        auto half = [&](int64_t off) {
            ggml_tensor * h = ggml_view_3d(ctx, y, s, OC, IL, y->nb[1], y->nb[2], off * y->nb[0]);
            h = ggml_cont(ctx, ggml_permute(ctx, h, 0, 2, 1, 3));  // [s, IL, OC]
            return ggml_reshape_2d(ctx, h, s * IL, OC);
        };
        return ggml_add(ctx, ggml_pad_ext(ctx, half(0), 0, s, 0, 0, 0, 0, 0, 0),
                        ggml_pad_ext(ctx, half(s), s, 0, 0, 0, 0, 0, 0, 0));
    }

    // y = x * w^T + b over the last axis; x: [in, T] (row per step).
    ggml_tensor * lin(const std::string & p, ggml_tensor * x) const {
        ggml_tensor * y = ggml_mul_mat(ctx, W(p + ".weight"), x);
        if (has(p + ".bias")) y = ggml_add(ctx, y, W(p + ".bias"));
        return y;
    }
    ggml_tensor * ln(ggml_tensor * x, const std::string & p, float eps) const {
        x = ggml_norm(ctx, x, eps);
        return ggml_add(ctx, ggml_mul(ctx, x, W(p + ".weight")), W(p + ".bias"));
    }
    // Conv1d on x: [T, Cin] -> [T', Cout], weight [K, Cin, Cout]. As matrix
    // products over x laid [Cin, T], where the window of an output step is
    // a run in memory: ggml's im2col runs a few threads per group on Metal,
    // which kept an iPhone GPU busy for most of a sentence. Undilated, the
    // windows overlap in one view and it is one product; dilated, one per tap.
    ggml_tensor * conv(const std::string & p, ggml_tensor * x, int s, int pad, int d) const {
        ggml_tensor * wt = W(p + ".weight");  // [IC, K, OC]
        // [K, Cin, Cout] with one tap or one channel in is that order already.
        if (!k->taps.count(p + ".weight")) {
            if (wt->ne[0] != 1 && wt->ne[1] != 1) throw std::string("convolution weight not laid out: " + p);
            wt = ggml_reshape_3d(ctx, wt, wt->ne[1], wt->ne[0], wt->ne[2]);
        }
        const int64_t IC = wt->ne[0], K = wt->ne[1], OC = wt->ne[2];
        if (x->ne[1] != IC || (d > 1 && s > 1)) throw std::string("unexpected convolution shape");
        if (pad) x = ggml_pad_ext(ctx, x, pad, pad, 0, 0, 0, 0, 0, 0);
        const int64_t OL = (x->ne[0] - d * (K - 1) - 1) / s + 1;
        ggml_tensor * xt = ggml_cont(ctx, ggml_transpose(ctx, x));                // [IC, L]
        ggml_tensor * y;
        if (d == 1) {
            // Rows that overlap, which ggml_view_2d refuses: made a row, then
            // given the rest.
            ggml_tensor * col = ggml_view_2d(ctx, xt, K * IC, 1, s * xt->nb[1], 0);
            col->ne[1] = OL;
            col->nb[2] = col->nb[3] = col->nb[1] * OL;
            y = ggml_mul_mat(ctx, ggml_reshape_2d(ctx, wt, K * IC, OC), col);       // [OC, OL]
        } else {
            y = nullptr;
            for (int64_t i = 0; i < K; i++) {
                ggml_tensor * wi = ggml_view_2d(ctx, wt, IC, OC, wt->nb[2], i * wt->nb[1]);
                ggml_tensor * xi = ggml_view_2d(ctx, xt, IC, OL, xt->nb[1], i * d * xt->nb[1]);
                ggml_tensor * yi = ggml_mul_mat(ctx, wi, xi);
                y = y ? ggml_add(ctx, y, yi) : yi;
            }
        }
        y = ggml_cont(ctx, ggml_transpose(ctx, y));  // [OL, OC]
        if (has(p + ".bias")) y = ggml_add(ctx, y, row(W(p + ".bias")));
        return y;
    }
    // A per-channel vector [C] as [1, C], to broadcast over time.
    ggml_tensor * row(ggml_tensor * v) const { return ggml_reshape_2d(ctx, v, 1, ggml_nelements(v)); }

    // (1 + gamma) * instance_norm(x) + beta, gamma and beta from the style.
    ggml_tensor * adain(const std::string & p, ggml_tensor * x, ggml_tensor * s) const {
        const int64_t C = x->ne[1];
        ggml_tensor * h = lin(p + ".fc", s);  // [2C, 1]
        ggml_tensor * gamma = ggml_view_2d(ctx, h, 1, C, sizeof(float), 0);
        ggml_tensor * beta = ggml_view_2d(ctx, h, 1, C, sizeof(float), C * sizeof(float));
        ggml_tensor * n = ggml_norm(ctx, x, 1e-5f);
        return ggml_add(ctx, ggml_add(ctx, ggml_mul(ctx, n, gamma), n), beta);
    }
    ggml_tensor * snake(ggml_tensor * x, ggml_tensor * a) const {
        a = ggml_reshape_2d(ctx, a, 1, ggml_nelements(a));
        ggml_tensor * s = ggml_sqr(ctx, ggml_sin(ctx, ggml_mul(ctx, x, a)));
        return ggml_add(ctx, x, ggml_div(ctx, s, a));
    }

    // The original's depthwise ConvTranspose1d(k=3, s=2, p=1, output_padding=1):
    // even outputs x * w1, odd ones x * w2 + next(x) * w0.
    ggml_tensor * pool(const std::string & p, ggml_tensor * x) const {
        const int64_t L = x->ne[0], C = x->ne[1];
        ggml_tensor * w = W(p + ".weight");  // [C, 3]
        auto tap = [&](int i) { return ggml_view_2d(ctx, w, 1, C, sizeof(float), i * C * sizeof(float)); };
        ggml_tensor * padded = ggml_pad(ctx, x, 1, 0, 0, 0);
        ggml_tensor * next = ggml_cont(ctx, ggml_view_2d(ctx, padded, L, C, padded->nb[1], sizeof(float)));
        ggml_tensor * b = row(W(p + ".bias"));
        ggml_tensor * even = ggml_add(ctx, ggml_mul(ctx, x, tap(1)), b);
        ggml_tensor * odd = ggml_add(ctx, ggml_add(ctx, ggml_mul(ctx, x, tap(2)), ggml_mul(ctx, next, tap(0))), b);
        ggml_tensor * both = ggml_concat(ctx, ggml_reshape_3d(ctx, even, 1, L, C), ggml_reshape_3d(ctx, odd, 1, L, C), 0);
        return ggml_reshape_2d(ctx, both, 2 * L, C);
    }
    ggml_tensor * twice(ggml_tensor * x) const {
        const int64_t L = x->ne[0], C = x->ne[1];
        ggml_tensor * x3 = ggml_reshape_3d(ctx, x, 1, L, C);
        return ggml_reshape_2d(ctx, ggml_concat(ctx, x3, x3, 0), 2 * L, C);
    }

    // AdainResBlk1d.
    ggml_tensor * res_blk(const std::string & p, ggml_tensor * x, ggml_tensor * s, bool up) const {
        ggml_tensor * r = ggml_leaky_relu(ctx, adain(p + ".norm1", x, s), 0.2f, false);
        if (up) r = pool(p + ".pool", r);
        r = conv(p + ".conv1", r, 1, 1, 1);
        r = ggml_leaky_relu(ctx, adain(p + ".norm2", r, s), 0.2f, false);
        r = conv(p + ".conv2", r, 1, 1, 1);
        ggml_tensor * sc = up ? twice(x) : x;
        if (has(p + ".conv1x1.weight")) sc = conv(p + ".conv1x1", sc, 1, 0, 1);
        return ggml_scale(ctx, ggml_add(ctx, r, sc), 0.70710677f);
    }

    // AdaINResBlock1 of the vocoder.
    ggml_tensor * res_blk1(const std::string & p, ggml_tensor * x, ggml_tensor * s, int kernel) const {
        const int dil[3] = {1, 3, 5};
        for (int j = 0; j < 3; j++) {
            const std::string i = std::to_string(j);
            ggml_tensor * t = adain(p + ".adain1." + i, x, s);
            t = snake(t, W(p + ".alpha1." + i));
            t = conv(p + ".convs1." + i, t, 1, dil[j] * (kernel - 1) / 2, dil[j]);
            t = adain(p + ".adain2." + i, t, s);
            t = snake(t, W(p + ".alpha2." + i));
            t = conv(p + ".convs2." + i, t, 1, (kernel - 1) / 2, 1);
            x = ggml_add(ctx, t, x);
        }
        return x;
    }
};

struct Graph {
    ggml_context * ctx = nullptr;
    ggml_cgraph * gf = nullptr;
    explicit Graph(kokoro * k) {
        ggml_init_params p = {ggml_tensor_overhead() * GRAPH + ggml_graph_overhead_custom(GRAPH, false), nullptr, true};
        ctx = ggml_init(p);
        gf = ggml_new_graph_custom(ctx, GRAPH, false);
        (void) k;
    }
    ~Graph() { ggml_free(ctx); }
    ggml_tensor * input(ggml_type t, int64_t a, int64_t b = 1) {
        ggml_tensor * x = b == 1 ? ggml_new_tensor_1d(ctx, t, a) : ggml_new_tensor_2d(ctx, t, a, b);
        ggml_set_input(x);
        return x;
    }
    void output(ggml_tensor * t) {
        ggml_set_output(t);
        ggml_build_forward_expand(gf, t);
    }
};

std::vector<float> fetch(ggml_tensor * t) {
    std::vector<float> v(ggml_nelements(t));
    ggml_backend_tensor_get(t, v.data(), 0, v.size() * sizeof(float));
    return v;
}

void dump(const kokoro * k, const char * name, const std::vector<float> & v) {
    if (k->debug_dir.empty()) return;
    const std::string path = k->debug_dir + "/" + name + ".f32";
    if (FILE * f = fopen(path.c_str(), "wb")) {
        fwrite(v.data(), sizeof(float), v.size(), f);
        fclose(f);
    }
}

void compute(const kokoro * k, Lane * l, Graph & g) {
    // A GPU that lacks an operation says so here, and the caller loads the
    // model on the CPU instead.
    if (k->gpu)
        for (int i = 0; i < ggml_graph_n_nodes(g.gf); i++) {
            ggml_tensor * n = ggml_graph_node(g.gf, i);
            if (!ggml_backend_supports_op(l->backend, n))
                throw std::string("GPU cannot run ") + ggml_op_desc(n) + " (" + ggml_get_name(n) + ")";
        }
    if (!ggml_gallocr_alloc_graph(l->alloc, g.gf)) throw std::string("out of memory");
}

// Time by op and shape, when profiling: "<graph> <op> <out shape> [<weight
// shape>]" -> (count, seconds).
using Prof = std::map<std::string, std::pair<int, double>>;

void run(Lane * l, Graph & g, Prof * prof = nullptr, const char * what = "",
         bool chunked = false, edge_tts_kokoro_check_cb check = nullptr, void * check_user = nullptr) {
    if (!prof) {
        if (chunked && check) {
            // On the CPU behind the screen, run a few ops at a time so the
            // caller can pace CPU use and stop promptly on return to screen.
            const int n_nodes = ggml_graph_n_nodes(g.gf);
            constexpr int CHUNK = 8;
            ggml_init_params p = {ggml_graph_overhead_custom(CHUNK, false), nullptr, true};
            ggml_context * c = ggml_init(p);
            ggml_cgraph * sub = ggml_new_graph_custom(c, CHUNK, false);
            for (int i = 0; i < n_nodes;) {
                ggml_graph_clear(sub);
                int added = 0;
                while (i < n_nodes && added < CHUNK) {
                    ggml_tensor * n = ggml_graph_node(g.gf, i++);
                    if (ggml_is_empty(n) || n->op == GGML_OP_NONE || n->op == GGML_OP_VIEW ||
                        n->op == GGML_OP_RESHAPE || n->op == GGML_OP_PERMUTE || n->op == GGML_OP_TRANSPOSE)
                        continue;
                    ggml_graph_add_node(sub, n);
                    added++;
                }
                if (added == 0) break;
                if (check(0, check_user)) {
                    ggml_free(c);
                    throw std::string("cancelled");
                }
                if (ggml_backend_graph_compute(l->backend, sub) != GGML_STATUS_SUCCESS) {
                    ggml_free(c);
                    throw std::string("compute failed");
                }
                if (check(1, check_user)) {
                    ggml_free(c);
                    throw std::string("cancelled");
                }
            }
            ggml_free(c);
            return;
        }
        if (ggml_backend_graph_compute(l->backend, g.gf) != GGML_STATUS_SUCCESS) throw std::string("compute failed");
        if (check && check(0, check_user)) throw std::string("cancelled");
        return;
    }
    // One op a graph, each waited for.
    ggml_init_params p = {ggml_graph_overhead_custom(1, false), nullptr, true};
    ggml_context * c = ggml_init(p);
    ggml_cgraph * one = ggml_new_graph_custom(c, 1, false);
    for (int i = 0; i < ggml_graph_n_nodes(g.gf); i++) {
        ggml_tensor * n = ggml_graph_node(g.gf, i);
        if (ggml_is_empty(n) || n->op == GGML_OP_NONE || n->op == GGML_OP_VIEW || n->op == GGML_OP_RESHAPE ||
            n->op == GGML_OP_PERMUTE || n->op == GGML_OP_TRANSPOSE)
            continue;
        ggml_graph_clear(one);
        ggml_graph_add_node(one, n);
        const auto a = std::chrono::steady_clock::now();
        const bool ok = ggml_backend_graph_compute(l->backend, one) == GGML_STATUS_SUCCESS;
        const double dt = std::chrono::duration<double>(std::chrono::steady_clock::now() - a).count();
        if (!ok) {
            ggml_free(c);
            throw std::string("compute failed");
        }
        char key[160];
        int len = snprintf(key, sizeof key, "%s %s %lldx%lld", what, ggml_op_desc(n), (long long) n->ne[0], (long long) n->ne[1]);
        if (n->op == GGML_OP_MUL_MAT || n->op == GGML_OP_CPY || n->op == GGML_OP_CONT)
            snprintf(key + len, sizeof key - len, " %s%lldx%lld nb0=%zu", n->op == GGML_OP_MUL_MAT ? "w=" : "src=",
                     (long long) n->src[0]->ne[0], (long long) n->src[0]->ne[1], n->src[n->op == GGML_OP_MUL_MAT]->nb[0]);
        auto & e = (*prof)[key];
        e.first++;
        e.second += dt;
    }
    ggml_free(c);
}

std::vector<int> to_ids(const kokoro * k, const std::string & ps, int & chars) {
    std::vector<int> ids = {0};
    chars = 0;
    for (size_t i = 0; i < ps.size();) {
        const unsigned char c = (unsigned char) ps[i];
        const size_t n = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        auto it = k->vocab.find(ps.substr(i, n));
        if (it != k->vocab.end()) ids.push_back(it->second);
        chars++;
        i += n;
    }
    ids.push_back(0);
    return ids;
}

std::vector<float> speak(kokoro * k, Lane * l, const std::string & ps, const std::string & voice, float speed,
                         unsigned seed, edge_tts_kokoro_check_cb check = nullptr, void * check_user = nullptr) {
    auto checkpoint = [&](int mode) {
        if (check && check(mode, check_user)) throw std::string("cancelled");
    };
    const int rest_mode = k->gpu ? 0 : 1;
    checkpoint(-1);
    // How long each stage took, a line per sentence in EDGE_KOKORO_LOG when
    // set: where the time goes on a phone's GPU.
    auto t0 = std::chrono::steady_clock::now();
    std::string took;
    auto lap = [&](const char * n) {
        const auto t = std::chrono::steady_clock::now();
        char buf[48];
        snprintf(buf, sizeof buf, " %s=%.3f", n, std::chrono::duration<double>(t - t0).count());
        took += buf;
        t0 = t;
    };
    int chars = 0;
    const std::vector<int> ids = to_ids(k, ps, chars);
    const int T = (int) ids.size();
    if (chars == 0) return {};
    if (T > 512) throw std::string("too many phonemes");
    auto vit = k->voices.find(voice);
    if (vit == k->voices.end()) throw std::string("no voice " + voice);
    const float * ref = vit->second.data() + (size_t) std::min(chars - 1, 509) * 256;
    std::vector<float> s_dec(ref, ref + 128), s_pred(ref + 128, ref + 256);
    G b{k, nullptr};
    Prof profiled;
    Prof * prof = nullptr;
    for (int left = k->profile.load(); left > 0;)
        if (k->profile.compare_exchange_weak(left, left - 1)) {
            prof = &profiled;
            break;
        }

    // 1. Text: BERT -> d_en [T][512]; text encoder convolutions -> [T][512].
    std::vector<float> d_en, te;
    {
        Graph g(k);
        b.ctx = g.ctx;
        ggml_tensor * in_ids = g.input(GGML_TYPE_I32, T);
        ggml_tensor * in_pos = g.input(GGML_TYPE_I32, T);
        ggml_tensor * x = ggml_get_rows(g.ctx, b.W("bert.embeddings.word_embeddings.weight"), in_ids);
        x = ggml_add(g.ctx, x, ggml_get_rows(g.ctx, b.W("bert.embeddings.position_embeddings.weight"), in_pos));
        ggml_tensor * tt = b.W("bert.embeddings.token_type_embeddings.weight");
        x = ggml_add(g.ctx, x, ggml_view_1d(g.ctx, tt, tt->ne[0], 0));
        x = b.ln(x, "bert.embeddings.LayerNorm", 1e-12f);
        x = b.lin("bert.encoder.embedding_hidden_mapping_in", x);  // [768, T]
        const int64_t H = x->ne[0], nh = k->bert_heads, hd = H / nh;
        for (int l = 0; l < 12; l++) {
            const std::string p = "bert.layer.";
            ggml_tensor * q = ggml_reshape_3d(g.ctx, b.lin(p + "attention.query", x), hd, nh, T);
            ggml_tensor * kk = ggml_reshape_3d(g.ctx, b.lin(p + "attention.key", x), hd, nh, T);
            ggml_tensor * v = ggml_reshape_3d(g.ctx, b.lin(p + "attention.value", x), hd, nh, T);
            q = ggml_permute(g.ctx, q, 0, 2, 1, 3);   // [hd, T, nh]
            kk = ggml_permute(g.ctx, kk, 0, 2, 1, 3);
            ggml_tensor * kq = ggml_mul_mat(g.ctx, kk, q);  // [T, T, nh]
            kq = ggml_soft_max_ext(g.ctx, kq, nullptr, 1.0f / std::sqrt((float) hd), 0.0f);
            ggml_tensor * vt = ggml_cont(g.ctx, ggml_permute(g.ctx, v, 1, 2, 0, 3));  // [T, hd, nh]
            ggml_tensor * o = ggml_mul_mat(g.ctx, vt, kq);  // [hd, T, nh]
            o = ggml_cont(g.ctx, ggml_permute(g.ctx, o, 0, 2, 1, 3));  // [hd, nh, T]
            o = ggml_reshape_2d(g.ctx, o, H, T);
            ggml_tensor * a = b.ln(ggml_add(g.ctx, x, b.lin(p + "attention.dense", o)), p + "attention.LayerNorm", 1e-12f);
            ggml_tensor * f = ggml_gelu(g.ctx, b.lin(p + "ffn", a));
            x = b.ln(ggml_add(g.ctx, b.lin(p + "ffn_output", f), a), p + "full_layer_layer_norm", 1e-12f);
        }
        ggml_tensor * bert = x;
        ggml_tensor * den = b.lin("bert_encoder", x);  // [512, T]

        ggml_tensor * e = ggml_get_rows(g.ctx, b.W("text_encoder.embedding.weight"), in_ids);  // [512, T]
        e = ggml_cont(g.ctx, ggml_transpose(g.ctx, e));  // [T, 512]
        for (int i = 0; i < 3; i++) {
            const std::string p = "text_encoder.cnn." + std::to_string(i);
            e = b.conv(p + ".0", e, 1, 2, 1);
            e = ggml_cont(g.ctx, ggml_transpose(g.ctx, e));  // [512, T]
            e = ggml_norm(g.ctx, e, 1e-5f);
            e = ggml_add(g.ctx, ggml_mul(g.ctx, e, b.W(p + ".1.gamma")), b.W(p + ".1.beta"));
            e = ggml_leaky_relu(g.ctx, e, 0.2f, false);
            if (i < 2) e = ggml_cont(g.ctx, ggml_transpose(g.ctx, e));
        }
        g.output(den);
        g.output(e);
        if (!k->debug_dir.empty()) g.output(bert);
        compute(k, l, g);
        std::vector<int> pos(T);
        for (int i = 0; i < T; i++) pos[i] = i;
        ggml_backend_tensor_set(in_ids, ids.data(), 0, T * sizeof(int));
        ggml_backend_tensor_set(in_pos, pos.data(), 0, T * sizeof(int));
        run(l, g, prof, "bert", !k->gpu, check, check_user);
        d_en = fetch(den);
        te = fetch(e);
        if (!k->debug_dir.empty()) dump(k, "bert", fetch(bert));
    }

    lap("bert");
    checkpoint(0);
    // 2. Durations, on the CPU.
    const int S = 128, D = 512, DS = D + S;
    std::vector<float> d((size_t) T * DS), y((size_t) T * D), h(2 * D);
    for (int t = 0; t < T; t++) {
        memcpy(&d[(size_t) t * DS], &d_en[(size_t) t * D], D * sizeof(float));
        memcpy(&d[(size_t) t * DS + D], s_pred.data(), S * sizeof(float));
    }
    for (int l = 0; l < 3; l++) {
        run_lstm(k->dur_lstm[l], d.data(), T, y.data());
        linear(k->ada_w[l].data(), k->ada_b[l].data(), s_pred.data(), S, 2 * D, h.data());
        ada_layer_norm(y.data(), T, D, h.data(), h.data() + D);
        for (int t = 0; t < T; t++) memcpy(&d[(size_t) t * DS], &y[(size_t) t * D], D * sizeof(float));
    }
    dump(k, "dur_enc", d);
    run_lstm(k->pred_lstm, d.data(), T, y.data());
    std::vector<int> dur(T);
    int F = 0;
    for (int t = 0; t < T; t++) {
        float z[64];
        linear(k->dur_w.data(), k->dur_b.data(), &y[(size_t) t * D], D, 50, z);
        float sum = 0;
        for (int i = 0; i < 50; i++) sum += sigm(z[i]);
        dur[t] = std::max(1, (int) std::nearbyint(sum / speed));
        F += dur[t];
    }
    if (!k->debug_dir.empty()) dump(k, "dur", std::vector<float>(dur.begin(), dur.end()));

    lap("dur");
    checkpoint(rest_mode);
    // Text features stretched to the frames; the shared LSTM over them.
    std::vector<float> te_l((size_t) T * D);
    run_lstm(k->te_lstm, te.data(), T, te_l.data());
    dump(k, "t_en", te_l);
    std::vector<float> en((size_t) F * DS), shared((size_t) F * D), asr((size_t) D * F), sh_t((size_t) D * F);
    for (int t = 0, f = 0; t < T; t++)
        for (int r = 0; r < dur[t]; r++, f++) {
            memcpy(&en[(size_t) f * DS], &d[(size_t) t * DS], DS * sizeof(float));
            for (int c = 0; c < D; c++) asr[(size_t) c * F + f] = te_l[(size_t) t * D + c];
        }
    run_lstm(k->shared, en.data(), F, shared.data());
    for (int f = 0; f < F; f++)
        for (int c = 0; c < D; c++) sh_t[(size_t) c * F + f] = shared[(size_t) f * D + c];

    lap("shared_lstm");
    checkpoint(rest_mode);
    // 3. Pitch and energy curves, [2F] each.
    std::vector<float> f0, nn;
    {
        Graph g(k);
        b.ctx = g.ctx;
        ggml_tensor * x = g.input(GGML_TYPE_F32, F, D);
        ggml_tensor * s = g.input(GGML_TYPE_F32, S);
        ggml_tensor * outs[2];
        const char * names[2] = {"F0", "N"};
        for (int i = 0; i < 2; i++) {
            const std::string p = std::string("predictor.") + names[i];
            ggml_tensor * c = b.res_blk(p + ".0", x, s, false);
            c = b.res_blk(p + ".1", c, s, true);
            c = b.res_blk(p + ".2", c, s, false);
            outs[i] = b.conv(p + "_proj", c, 1, 0, 1);
            g.output(outs[i]);
        }
        compute(k, l, g);
        ggml_backend_tensor_set(x, sh_t.data(), 0, sh_t.size() * sizeof(float));
        ggml_backend_tensor_set(s, s_pred.data(), 0, S * sizeof(float));
        run(l, g, prof, "f0n", !k->gpu, check, check_user);
        f0 = fetch(outs[0]);
        nn = fetch(outs[1]);
    }
    dump(k, "F0", f0);
    dump(k, "N", nn);
    // Checking the decoder alone: the original's curves and source, when given.
    auto given = [&](const char * name, std::vector<float> & v) {
        if (k->debug_dir.empty()) return;
        FILE * in = fopen((k->debug_dir + "/" + name + ".in.f32").c_str(), "rb");
        if (!in) return;
        std::vector<float> got(v.size());
        if (fread(got.data(), sizeof(float), got.size(), in) == got.size()) v = got;
        fclose(in);
    };
    given("F0", f0);
    given("N", nn);

    lap("f0n");
    // 4. The harmonic source and its spectrum.
    std::vector<float> source = harmonic_source(k, f0, seed);
    given("har_source", source);
    dump(k, "har_source", source);
    int frames = 0;
    std::vector<float> har = stft(source, frames);
    given("har", har);

    lap("source_stft");
    checkpoint(rest_mode);
    // 5. Decoder and vocoder -> [22][frames].
    std::vector<float> post;
    {
        Graph g(k);
        b.ctx = g.ctx;
        ggml_context * c = g.ctx;
        std::vector<std::pair<std::string, ggml_tensor *>> probes;
        b.probes = &probes;
        ggml_tensor * in_asr = g.input(GGML_TYPE_F32, F, D);
        ggml_tensor * in_f0 = g.input(GGML_TYPE_F32, 2 * F, 1);
        ggml_tensor * in_n = g.input(GGML_TYPE_F32, 2 * F, 1);
        ggml_tensor * in_har = g.input(GGML_TYPE_F32, frames, 2 * BINS);
        ggml_tensor * s = g.input(GGML_TYPE_F32, S);
        ggml_tensor * F0 = b.conv("decoder.F0_conv", in_f0, 2, 1, 1);  // [F, 1]
        ggml_tensor * N = b.conv("decoder.N_conv", in_n, 2, 1, 1);
        ggml_tensor * x = ggml_concat(c, ggml_concat(c, in_asr, F0, 1), N, 1);
        x = b.res_blk("decoder.encode", x, s, false);
        b.probe("dec_encode", x);
        ggml_tensor * asr_res = b.conv("decoder.asr_res.0", in_asr, 1, 0, 1);
        for (int i = 0; i < 4; i++) {
            x = ggml_concat(c, ggml_concat(c, ggml_concat(c, x, asr_res, 1), F0, 1), N, 1);
            x = b.res_blk("decoder.decode." + std::to_string(i), x, s, i == 3);
        }
        b.probe("gen_x", x);
        const int rates[2] = {10, 6}, kernels[2] = {20, 12}, noise_k[2] = {7, 11};
        for (int i = 0; i < 2; i++) {
            const std::string si = std::to_string(i);
            x = ggml_leaky_relu(c, x, 0.1f, false);
            ggml_tensor * xs = i == 0 ? b.conv("decoder.generator.noise_convs.0", in_har, 6, 3, 1)
                                      : b.conv("decoder.generator.noise_convs.1", in_har, 1, 0, 1);
            b.probe(i ? "noise_conv1" : "noise_conv0", xs);
            xs = b.res_blk1("decoder.generator.noise_res." + si, xs, s, noise_k[i]);
            b.probe(i ? "noise_res1" : "noise_res0", xs);
            ggml_tensor * up = b.up(b.W("decoder.generator.ups." + si + ".weight"), x, rates[i]);
            const int crop = (kernels[i] - rates[i]) / 2;
            up = ggml_cont(c, ggml_view_2d(c, up, up->ne[0] - 2 * crop, up->ne[1], up->nb[1], crop * sizeof(float)));
            x = ggml_add(c, up, b.row(b.W("decoder.generator.ups." + si + ".bias")));
            b.probe(i ? "ups1" : "ups0", x);
            if (i == 1) x = ggml_pad_reflect_1d(c, x, 1, 0);
            x = ggml_add(c, x, xs);
            ggml_tensor * sum = nullptr;
            const int ks[3] = {3, 7, 11};
            for (int j = 0; j < 3; j++) {
                ggml_tensor * r = b.res_blk1("decoder.generator.resblocks." + std::to_string(i * 3 + j), x, s, ks[j]);
                sum = sum ? ggml_add(c, sum, r) : r;
            }
            x = ggml_scale(c, sum, 1.0f / 3.0f);
            b.probe(i ? "stage1" : "stage0", x);
        }
        x = ggml_leaky_relu(c, x, 0.01f, false);
        x = b.conv("decoder.generator.conv_post", x, 1, 3, 1);  // [frames, 22]
        g.output(x);
        for (auto & pr : probes) g.output(pr.second);
        compute(k, l, g);
        ggml_backend_tensor_set(in_asr, asr.data(), 0, asr.size() * sizeof(float));
        ggml_backend_tensor_set(in_f0, f0.data(), 0, f0.size() * sizeof(float));
        ggml_backend_tensor_set(in_n, nn.data(), 0, nn.size() * sizeof(float));
        ggml_backend_tensor_set(in_har, har.data(), 0, har.size() * sizeof(float));
        ggml_backend_tensor_set(s, s_dec.data(), 0, S * sizeof(float));
        run(l, g, prof, "dec", !k->gpu, check, check_user);
        post = fetch(x);
        for (auto & pr : probes) dump(k, pr.first.c_str(), fetch(pr.second));
        if ((int) x->ne[0] != frames) throw std::string("frame count mismatch");
    }
    dump(k, "post", post);
    lap("decoder");
    std::vector<float> audio = istft(post, frames);
    lap("istft");
    checkpoint(rest_mode);
    if (const char * log = getenv("EDGE_KOKORO_LOG")) {
        if (FILE * f = fopen(log, "a")) {
            // When it finished, to tell from the lines how fast sentences
            // came out together.
            const double now = std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
            std::string out(512, '\0');
            out.resize(snprintf(&out[0], out.size(), "%s audio=%.2f phonemes=%d%s lanes=%d mem=%zuMB at=%.3f%s\n",
                                k->gpu ? "gpu" : "cpu", audio.size() / 24000.0, chars, took.c_str(), k->most,
                                ggml_gallocr_get_buffer_size(l->alloc, 0) >> 20, now, prof ? " profiled" : ""));
            if (prof) {
                std::vector<std::pair<double, std::string>> by;
                double all = 0;
                for (auto & [key, e] : *prof) {
                    char buf[256];
                    snprintf(buf, sizeof buf, "prof %s n=%d ms=%.2f\n", key.c_str(), e.first, e.second * 1000);
                    by.push_back({e.second, buf});
                    all += e.second;
                }
                std::sort(by.rbegin(), by.rend());
                if (by.size() > 40) by.resize(40);
                char buf[64];
                snprintf(buf, sizeof buf, "prof total ms=%.1f\n", all * 1000);
                out += buf;
                for (auto & e : by) out += e.second;
            }
            fwrite(out.data(), 1, out.size(), f);
            fclose(f);
        }
    }
    dump(k, "audio", audio);
    return audio;
}

}  // namespace

extern "C" {

// As many threads as performance cores where the system says (an iPhone's
// efficiency cores only slow the rest down), else four.
static int default_threads() {
#ifdef __APPLE__
    for (const char * key : {"hw.perflevel0.physicalcpu", "hw.physicalcpu"}) {
        int n = 0;
        size_t len = sizeof(n);
        if (sysctlbyname(key, &n, &len, nullptr, 0) == 0 && n > 0) return std::min(n, 8);
    }
#endif
    return 4;
}

// A new lane; with k->m held, or at load.
static Lane * add_lane(kokoro * k) {
    auto * l = new Lane();
    l->backend = k->gpu ? ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_GPU, nullptr) : ggml_backend_cpu_init();
    if (!l->backend) {
        delete l;
        throw std::string("cannot start the backend");
    }
    // On the CPU the lanes share the cores.
    if (!k->gpu) ggml_backend_cpu_set_n_threads(l->backend, std::max(1, k->threads / k->most));
    l->alloc = ggml_gallocr_new(ggml_backend_get_default_buffer_type(l->backend));
    k->lanes.push_back(l);
    return l;
}

static thread_local std::string error;

kokoro * edge_tts_kokoro_load(const char * path, int gpu, int threads) {
    auto * k = new kokoro();
    k->threads = threads > 0 ? threads : default_threads();
    if (const char * p = getenv("EDGE_KOKORO_PROFILE")) k->profile = atoi(p);
    gguf_context * g = nullptr;
    FILE * f = nullptr;
    try {
        gguf_init_params ip = {true, &k->wctx};
        g = gguf_init_from_file(path, ip);
        if (!g) throw std::string("cannot open ") + path;
        k->gpu = gpu != 0;
        if (k->gpu) {
            try {
                add_lane(k);
            } catch (const std::string &) {
                k->gpu = false;
            }
        }
        if (!k->gpu) add_lane(k);
        k->idle.push_back(k->lanes[0]);
        for (ggml_tensor * t = ggml_get_first_tensor(k->wctx); t; t = ggml_get_next_tensor(k->wctx, t))
            k->w[ggml_get_name(t)] = t;
        k->wbuf = ggml_backend_alloc_ctx_tensors(k->wctx, k->lanes[0]->backend);
        if (!k->wbuf) throw std::string("out of memory for weights");
#ifdef _WIN32
        {
            const int wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
            if (wlen > 0) {
                std::vector<wchar_t> wpath(wlen);
                MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath.data(), wlen);
                f = _wfopen(wpath.data(), L"rb");
            }
            if (!f) f = fopen(path, "rb");
        }
#else
        f = fopen(path, "rb");
#endif
        if (!f) throw std::string("cannot open ") + path;
        std::vector<uint8_t> buf;
        for (int64_t i = 0; i < gguf_get_n_tensors(g); i++) {
            ggml_tensor * t = k->w.at(gguf_get_tensor_name(g, i));
            buf.resize(ggml_nbytes(t));
            const size_t off = gguf_get_data_offset(g) + gguf_get_tensor_offset(g, i);
            if (fseek(f, (long) off, SEEK_SET) != 0 || fread(buf.data(), 1, buf.size(), f) != buf.size())
                throw std::string("cannot read ") + ggml_get_name(t);
            // A convolution's weight [K, Cin, Cout] laid [Cin, K, Cout], the
            // order its windows are in (G::conv), once here.
            const std::string name = ggml_get_name(t);
            if (ggml_n_dims(t) == 3 && name.find(".ups.") == std::string::npos && name.find(".pool.") == std::string::npos &&
                (t->type == GGML_TYPE_F16 || t->type == GGML_TYPE_F32)) {
                const int64_t K = t->ne[0], IC = t->ne[1], OC = t->ne[2];
                const size_t es = ggml_type_size(t->type);
                std::vector<uint8_t> laid(buf.size());
                for (int64_t o = 0; o < OC; o++)
                    for (int64_t c = 0; c < IC; c++)
                        for (int64_t j = 0; j < K; j++)
                            memcpy(&laid[((o * K + j) * IC + c) * es], &buf[((o * IC + c) * K + j) * es], es);
                buf.swap(laid);
                t->ne[0] = IC;
                t->ne[1] = K;
                t->nb[1] = es * IC;
                t->nb[2] = t->nb[1] * K;
                t->nb[3] = t->nb[2] * OC;
                k->taps.insert(name);
            }
            ggml_backend_tensor_set(t, buf.data(), 0, buf.size());
        }

        const int64_t sym = gguf_find_key(g, "kokoro.vocab.symbols");
        const int64_t idk = gguf_find_key(g, "kokoro.vocab.ids");
        if (sym < 0 || idk < 0) throw std::string("no vocabulary");
        const int32_t * idv = (const int32_t *) gguf_get_arr_data(g, idk);
        for (size_t i = 0; i < gguf_get_arr_n(g, sym); i++) k->vocab[gguf_get_arr_str(g, sym, i)] = idv[i];
        const int64_t vk = gguf_find_key(g, "kokoro.voices");
        if (vk >= 0)
            for (size_t i = 0; i < gguf_get_arr_n(g, vk); i++) {
                const std::string name = gguf_get_arr_str(g, vk, i);
                k->voice_names.push_back(name);
                k->voices[name] = host(k, "voice." + name, g, f);
            }
        const int64_t hk = gguf_find_key(g, "kokoro.bert.heads");
        if (hk >= 0) k->bert_heads = (int) gguf_get_val_u32(g, hk);

        load_lstm(k, k->te_lstm, "text_encoder.lstm", g, f);
        for (int l = 0; l < 3; l++) {
            load_lstm(k, k->dur_lstm[l], "predictor.text_encoder.lstms." + std::to_string(2 * l), g, f);
            k->ada_w[l] = host(k, "predictor.text_encoder.lstms." + std::to_string(2 * l + 1) + ".fc.weight", g, f);
            k->ada_b[l] = host(k, "predictor.text_encoder.lstms." + std::to_string(2 * l + 1) + ".fc.bias", g, f);
        }
        load_lstm(k, k->pred_lstm, "predictor.lstm", g, f);
        load_lstm(k, k->shared, "predictor.shared", g, f);
        k->dur_w = host(k, "predictor.duration_proj.linear_layer.weight", g, f);
        k->dur_b = host(k, "predictor.duration_proj.linear_layer.bias", g, f);
        auto sw = host(k, "decoder.generator.m_source.l_linear.weight", g, f);
        auto sb = host(k, "decoder.generator.m_source.l_linear.bias", g, f);
        for (int i = 0; i < HARMONICS; i++) k->src_w[i] = sw[i];
        k->src_b = sb[0];

        fclose(f);
        gguf_free(g);
        return k;
    } catch (const std::string & e) {
        fprintf(stderr, "kokoro: %s\n", e.c_str());
        if (f) fclose(f);
        if (g) gguf_free(g);
        edge_tts_kokoro_free(k);
        return nullptr;
    } catch (const std::exception & e) {
        fprintf(stderr, "kokoro: %s\n", e.what());
        if (f) fclose(f);
        if (g) gguf_free(g);
        edge_tts_kokoro_free(k);
        return nullptr;
    }
}

void edge_tts_kokoro_free(kokoro * k) {
    if (!k) return;
    for (Lane * l : k->lanes)
        if (l->alloc) ggml_gallocr_free(l->alloc);
    if (k->wbuf) ggml_backend_buffer_free(k->wbuf);
    if (k->wctx) ggml_free(k->wctx);
    for (Lane * l : k->lanes) {
        ggml_backend_free(l->backend);
        delete l;
    }
    delete k;
}

int edge_tts_kokoro_voice_count(const kokoro * k) { return (int) k->voice_names.size(); }

const char * edge_tts_kokoro_voice_name(const kokoro * k, int i) {
    return i >= 0 && i < (int) k->voice_names.size() ? k->voice_names[i].c_str() : nullptr;
}

void edge_tts_kokoro_lanes(kokoro * k, int n) {
    {
        std::lock_guard<std::mutex> g(k->m);
        k->most = std::clamp(n, 1, 4);
    }
    k->freed.notify_all();
}

float * edge_tts_kokoro_speak(kokoro * k, const char * phonemes, const char * voice, float speed, unsigned seed, int * n) {
    return edge_tts_kokoro_speak_checked(k, phonemes, voice, speed, seed, n, nullptr, nullptr);
}

float * edge_tts_kokoro_speak_checked(kokoro * k, const char * phonemes, const char * voice, float speed, unsigned seed,
                                      int * n, edge_tts_kokoro_check_cb check, void * user) {
    *n = 0;
    // What a sentence computes takes memory by its length, about 17 MB a
    // second of speech: long ones wait until the others leave room.
    int cost = 0;
    for (const char * c = phonemes; *c; c++) cost += ((unsigned char) *c & 0xC0) != 0x80;
    Lane * l = nullptr;
    {
        std::unique_lock<std::mutex> g(k->m);
        auto ready = [&] {
            return (int) (k->lanes.size() - k->idle.size()) < k->most &&
                   (k->inflight == 0 || k->inflight + cost <= BUDGET);
        };
        while (!ready()) {
            if (check && check(0, user)) {
                error = "cancelled";
                return nullptr;
            }
            if (check) {
                k->freed.wait_for(g, std::chrono::milliseconds(100), [&] {
                    return ready() || check(0, user) != 0;
                });
            } else {
                k->freed.wait(g, ready);
            }
        }
        if (check && check(0, user)) {
            error = "cancelled";
            return nullptr;
        }
        k->inflight += cost;
        if (!k->idle.empty()) {
            l = k->idle.back();
            k->idle.pop_back();
        } else {
            try {
                l = add_lane(k);
            } catch (const std::string & e) {
                k->inflight -= cost;
                error = e;
                return nullptr;
            }
        }
    }
    struct Back {
        kokoro * k;
        Lane * l;
        int cost;
        ~Back() {
            // A lane keeps no more than a usual sentence's memory between
            // sentences.
            if (ggml_gallocr_get_buffer_size(l->alloc, 0) > KEEP) {
                ggml_gallocr_free(l->alloc);
                l->alloc = ggml_gallocr_new(ggml_backend_get_default_buffer_type(l->backend));
            }
            {
                std::lock_guard<std::mutex> g(k->m);
                k->idle.push_back(l);
                k->inflight -= cost;
            }
            k->freed.notify_all();
        }
    } back{k, l, cost};
    try {
        std::vector<float> a = speak(k, l, phonemes, voice, speed > 0 ? speed : 1.0f, seed, check, user);
        float * out = (float *) malloc(std::max<size_t>(1, a.size()) * sizeof(float));
        if (!a.empty()) memcpy(out, a.data(), a.size() * sizeof(float));
        *n = (int) a.size();
        error.clear();
        return out;
    } catch (const std::string & e) {
        error = e;
    } catch (const std::exception & e) {
        error = e.what();
    }
    return nullptr;
}

void edge_tts_kokoro_free_audio(float * samples) { free(samples); }

const char * edge_tts_kokoro_error(const kokoro *) { return error.c_str(); }

void edge_tts_kokoro_debug(kokoro * k, const char * dir, int quiet) {
    k->debug_dir = dir ? dir : "";
    k->quiet = quiet != 0;
}

}  // extern "C"
