// PC check of the engine: one WAV per line of phonemes, and with --debug the
// intermediates of each for compare.py.
//
// usage: kokoro-cli <model.gguf> <voice> <phonemes.txt> <out dir> [--gpu] [--debug] [--threads N]
#include "kokoro.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

static void wav(const std::string & path, const float * x, int n) {
    std::vector<int16_t> s(n);
    for (int i = 0; i < n; i++) {
        float v = x[i] * 32767.0f;
        s[i] = (int16_t) (v > 32767 ? 32767 : v < -32768 ? -32768 : v);
    }
    FILE * f = fopen(path.c_str(), "wb");
    const uint32_t data = (uint32_t) n * 2, rate = 24000, byte_rate = rate * 2, riff = 36 + data, fmt = 16;
    const uint16_t pcm = 1, ch = 1, align = 2, bits = 16;
    fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    fwrite(&fmt, 4, 1, f); fwrite(&pcm, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f);
    fwrite(&byte_rate, 4, 1, f); fwrite(&align, 2, 1, f); fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&data, 4, 1, f); fwrite(s.data(), 2, n, f);
    fclose(f);
}

int main(int argc, char ** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: kokoro-cli <model.gguf> <voice> <phonemes.txt> <out dir> [--gpu] [--debug] [--threads N]\n");
        return 2;
    }
    bool gpu = false, debug = false;
    int threads = 8;
    for (int i = 5; i < argc; i++) {
        if (!strcmp(argv[i], "--gpu")) gpu = true;
        else if (!strcmp(argv[i], "--debug")) debug = true;
        else if (!strcmp(argv[i], "--threads") && i + 1 < argc) threads = atoi(argv[++i]);
    }
    auto t0 = std::chrono::steady_clock::now();
    kokoro * k = edge_tts_kokoro_load(argv[1], gpu ? 1 : 0, threads);
    if (!k) return 1;
    auto t1 = std::chrono::steady_clock::now();
    printf("load %.2f s\n", std::chrono::duration<double>(t1 - t0).count());
    std::ifstream in(argv[3]);
    std::string line;
    int i = 0;
    double total = 0, audio = 0;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        const std::string dir = std::string(argv[4]) + "/" + std::to_string(i);
        std::filesystem::create_directories(dir);
        edge_tts_kokoro_debug(k, debug ? dir.c_str() : nullptr, debug ? 1 : 0);
        int n = 0;
        auto a = std::chrono::steady_clock::now();
        float * x = edge_tts_kokoro_speak(k, line.c_str(), argv[2], 1.0f, 1234 + i, &n);
        double dt = std::chrono::duration<double>(std::chrono::steady_clock::now() - a).count();
        if (!x) {
            fprintf(stderr, "%d: %s\n", i, edge_tts_kokoro_error(k));
            i++;
            continue;
        }
        wav(std::string(argv[4]) + "/" + std::to_string(i) + ".wav", x, n);
        printf("%d: %.2f s audio in %.2f s (RTF %.3f)\n", i, n / 24000.0, dt, dt / (n / 24000.0));
        if (i > 0) { total += dt; audio += n / 24000.0; }
        edge_tts_kokoro_free_audio(x);
        i++;
    }
    if (audio > 0) printf("after the first: RTF %.3f\n", total / audio);
    edge_tts_kokoro_free(k);
    return 0;
}
