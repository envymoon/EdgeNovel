// qwentts.cpp for the app (src/api/tts.rs) as a few C functions: load a voice
// on the GPU or the CPU, speak one sentence, stop the one being spoken. iOS
// lets an app start no process of its own, so the tts-server the Windows app
// runs is not used; this does what its /v1/audio/speech does with a pcm
// response, without the HTTP.
#include "qwen.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <atomic>
#include <cstdlib>
#include <mutex>
#include <shared_mutex>
#include <string>

// One voice. Sentences share it: the engine takes as many at once as it was
// loaded for (EDGE_TTS_BATCH, 1 unless set) and queues the rest.
static std::shared_mutex     g_mutex;
static qt_context *          g_ctx = nullptr;
static bool                  g_gpu = false;
static std::atomic<bool>     g_cancel{false};
static std::atomic<bool>     g_background{false};
static thread_local std::string g_error;

// Behind the screen (1) or back (0). iOS refuses GPU work from an app behind
// the screen, and listening goes on with the screen locked: the sentence on
// the GPU stops, and the voice belongs on the CPU (edge_tts_background).
extern "C" void edge_tts_set_background(int on) {
    g_background = on != 0;
    if (on) {
        g_cancel = true;
    }
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
// `on_pcm`.
extern "C" int edge_tts_speak(const char * text, const char * speaker, int max_frames, edge_tts_pcm_cb on_pcm,
                              void * user) {
    std::shared_lock<std::shared_mutex> lock(g_mutex);
    if (!g_ctx) {
        g_error = "voice not loaded";
        return QT_STATUS_INVALID_PARAMS;
    }
    g_cancel = g_gpu && g_background;
    pcm_sink sink{ on_pcm, user };

    qt_tts_params p;
    qt_tts_default_params(&p);
    p.text           = text;
    p.lang           = "chinese";
    p.speaker        = speaker;
    p.max_new_tokens = max_frames;
    p.cancel         = [](void *) -> bool { return g_cancel.load(); };
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
