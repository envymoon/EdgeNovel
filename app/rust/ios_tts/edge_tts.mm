// qwentts.cpp for the app (src/api/tts.rs) as a few C functions: load a voice
// on the GPU or the CPU, speak one sentence, stop the one being spoken. iOS
// lets an app start no process of its own, so the tts-server the Windows app
// runs is not used; this does what its /v1/audio/speech does with a pcm
// response, without the HTTP.
#include "qwen.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <thread>

// One voice. Sentences share it: the engine takes as many at once as it was
// loaded for (EDGE_TTS_BATCH, 1 unless set) and queues the rest.
static std::shared_mutex     g_mutex;
static qt_context *          g_ctx = nullptr;
static std::atomic<bool>     g_gpu{false};
// Bumped to stop every sentence then being spoken; each one keeps the value
// it started with. One flag reset by every new sentence let a sentence started
// a moment later, in another lane, undo a stop meant for the rest.
static std::atomic<int64_t>  g_moved{0};
static std::atomic<bool>     g_background{false};
static std::mutex            g_bg_mu;
static std::condition_variable g_bg_cv;
static std::atomic<int64_t>  g_bg_epoch{0};
static thread_local std::string g_error;

extern "C" int edge_tts_gpu(void);

// Behind the screen (1) or back (0). iOS refuses GPU work from an app behind
// the screen, and listening goes on with the screen locked: the sentences on
// the GPU stop, and the voice belongs on the CPU (edge_tts_background). Back
// on screen, those on the CPU stop too, to be said again on the GPU at once.
// A voice already where it belongs goes on.
extern "C" void edge_tts_set_background(int on) {
    const bool behind = on != 0;
    const bool prev   = g_background.exchange(behind);
    if (behind ? g_gpu.load() : (!g_gpu && edge_tts_gpu())) {
        g_moved++;
    }
    if (prev != behind) {
        {
            std::lock_guard<std::mutex> lk(g_bg_mu);
            g_bg_epoch++;
        }
        g_bg_cv.notify_all();
    }
}

extern "C" int64_t edge_tts_bg_epoch(void) {
    return g_bg_epoch.load();
}

// Sleep up to `ns` nanoseconds, waking at once if the app moves between
// screen and background (`g_bg_epoch` changes from `epoch`).
extern "C" void edge_tts_bg_sleep(int64_t epoch, int64_t ns) {
    if (ns <= 0) {
        return;
    }
    std::unique_lock<std::mutex> lk(g_bg_mu);
    g_bg_cv.wait_for(lk, std::chrono::nanoseconds(ns), [epoch] {
        return g_bg_epoch.load() != epoch;
    });
}

// When the engine last worked or was given a sentence, in steady-clock ns.
static std::atomic<int64_t> g_last{0};

static int64_t now_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// Asked at every step of a sentence. Behind the screen, on the CPU, the
// engine rests three times as long as it last worked: iOS ends an app there
// that keeps more than 80% of a core busy over a minute, and it works on
// every performance core.
static bool stop_or_rest(void * started) {
    if (!g_gpu && g_background) {
        const int64_t now  = now_ns();
        const int64_t busy = now - g_last.load();
        if (busy > 0 && busy < 3'000'000'000) {
            std::this_thread::sleep_for(std::chrono::nanoseconds(busy * 3));
        }
    }
    g_last = now_ns();
    return *static_cast<const int64_t *>(started) != g_moved.load() || (g_gpu && g_background);
}

// UIKit's notification names (the app's and its scene's), so that nothing here
// links UIKit; a Mac never posts them.
static void watch_app() {
    static std::once_flag once;
    std::call_once(once, [] {
        NSNotificationCenter * center = [NSNotificationCenter defaultCenter];
        for (NSString * name in @[ @"UIApplicationDidEnterBackgroundNotification",
                                   @"UISceneDidEnterBackgroundNotification" ]) {
            [center addObserverForName:name
                                object:nil
                                 queue:nil
                            usingBlock:^(NSNotification *) {
                                edge_tts_set_background(1);
                            }];
        }
        for (NSString * name in @[ @"UIApplicationWillEnterForegroundNotification",
                                   @"UISceneWillEnterForegroundNotification" ]) {
            [center addObserverForName:name
                                object:nil
                                 queue:nil
                            usingBlock:^(NSNotification *) {
                                edge_tts_set_background(0);
                            }];
        }
    });
}

// Whether the GPU can run the voice: ggml's Metal backend has some of the ops
// it needs (RMS_NORM among them) only with SIMD-group reductions, which is
// A13 and later (Metal 3) or A14 (Apple 7). The voice runs on one backend with
// nothing to fall back on, so an older GPU leaves it on the CPU.
extern "C" int edge_tts_gpu(void) {
    static const bool usable = [] {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        // MTLGPUFamilyMetal3 by number, as ggml has it: it is newer than the
        // oldest iOS this is built for.
        return d && ([d supportsFamily:MTLGPUFamilyApple7] || [d supportsFamily:(MTLGPUFamily) 5001]);
    }();
    return usable ? 1 : 0;
}

extern "C" const char * edge_tts_error(void) {
    return g_error.c_str();
}

// 1 while the app is behind the screen: no GPU.
extern "C" int edge_tts_background(void) {
    return g_background ? 1 : 0;
}

// Starts following the app behind the screen and back, for the light voice,
// which may run before this voice ever loads.
extern "C" void edge_tts_watch(void) {
    watch_app();
}

// 1 when loaded. `gpu` 0, or a GPU that cannot run it, runs on the CPU.
extern "C" int edge_tts_load(const char * talker, const char * codec, int gpu) {
    watch_app();
    gpu = gpu && edge_tts_gpu();
    std::unique_lock<std::shared_mutex> lock(g_mutex);
    if (g_ctx) {
        qt_free(g_ctx);
        g_ctx = nullptr;
    }
    qt_init_params p;
    qt_init_default_params(&p);
    p.talker_path = talker;
    p.codec_path  = codec;
    p.device      = gpu ? nullptr : "CPU";
    if (const char * batch = getenv("EDGE_TTS_BATCH")) {
        p.max_batch = atoi(batch) > 1 ? atoi(batch) : 1;
    }
    g_ctx         = qt_init(&p);
    g_gpu         = gpu != 0;
    if (!g_ctx) {
        g_error = qt_last_error();
        return 0;
    }
    return 1;
}

extern "C" void edge_tts_unload(void) {
    std::unique_lock<std::shared_mutex> lock(g_mutex);
    if (g_ctx) {
        qt_free(g_ctx);
        g_ctx = nullptr;
    }
}

typedef void (*edge_tts_pcm_cb)(const float * samples, int n_samples, void * user);

struct pcm_sink {
    edge_tts_pcm_cb cb;
    void *          user;
};

// 0 when spoken, the qt_status otherwise (-5: stopped because the app went
// behind the screen). The audio comes as it is decoded, 24 kHz mono, through
// `on_pcm`. How freely the talker draws each sound is the caller's
// (tts.rs, `STEADY`); a seed of -1 draws a new one.
extern "C" int edge_tts_speak(const char * text, const char * speaker, int max_frames, float temperature, int top_k,
                              long long seed, edge_tts_pcm_cb on_pcm, void * user) {
    std::shared_lock<std::shared_mutex> lock(g_mutex);
    if (!g_ctx) {
        g_error = "voice not loaded";
        return QT_STATUS_INVALID_PARAMS;
    }
    int64_t started = g_moved.load();
    g_last          = now_ns();
    pcm_sink sink{ on_pcm, user };

    qt_tts_params p;
    qt_tts_default_params(&p);
    p.text           = text;
    p.lang           = "chinese";
    p.speaker        = speaker;
    p.max_new_tokens = max_frames;
    p.temperature    = temperature;
    p.top_k          = top_k;
    p.seed           = seed;
    p.cancel         = stop_or_rest;
    p.cancel_user_data = &started;
    p.on_chunk       = [](const float * s, int n, void * u) -> bool {
        auto * k = static_cast<pcm_sink *>(u);
        k->cb(s, n, k->user);
        return true;
    };
    p.on_chunk_user_data = &sink;

    qt_audio       out = {};
    enum qt_status rc  = qt_synthesize(g_ctx, &p, &out);
    qt_audio_free(&out);
    if (rc != QT_STATUS_OK) {
        g_error = qt_last_error();
    }
    return (int) rc;
}
