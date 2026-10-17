// stable-diffusion.cpp for the app (src/api/image.rs) as a few C functions:
// draw one picture, on the GPU or the CPU, into a PNG, and stop the one being
// drawn. iOS lets an app start no process of its own, so the sd-cli the
// Windows app runs is not used; this asks the library for what sd-cli is
// asked for there, with the same settings.
#include "stable-diffusion.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STB_IMAGE_WRITE_STATIC
#include "stb_image_write.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <sys/sysctl.h>

#include <atomic>
#include <cstdlib>
#include <mutex>
#include <string>

// One picture at a time: the cover and 章间立绘 share the phone's memory.
static std::mutex        g_one;
static std::mutex        g_ctx_mutex;
static sd_ctx_t *        g_ctx = nullptr;
static std::atomic<bool> g_cancel{false};
static std::atomic<bool> g_background{false};

// Where the picture being drawn is: 0 none, 1 the GPU, 2 the CPU only for
// being behind the screen, 3 the CPU.
static std::atomic<int>         g_where{0};
static thread_local std::string g_error;

static void stop_now() {
    std::lock_guard<std::mutex> lock(g_ctx_mutex);
    if (g_ctx) {
        sd_cancel_generation(g_ctx, SD_CANCEL_ALL);
    }
}

// iOS refuses GPU work from an app behind the screen: a picture on the GPU
// stops when the app goes there, and one moved to the CPU for it stops when
// the app is back, so that src/api/image.rs draws it again where it belongs.
static void moved(bool background) {
    g_background = background;
    const int where = g_where.load();
    if ((background && where == 1) || (!background && where == 2)) {
        g_cancel = true;
        stop_now();
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
                                moved(true);
                            }];
        }
        for (NSString * name in @[ @"UIApplicationWillEnterForegroundNotification",
                                   @"UISceneWillEnterForegroundNotification" ]) {
            [center addObserverForName:name
                                object:nil
                                 queue:nil
                            usingBlock:^(NSNotification *) {
                                moved(false);
                            }];
        }
    });
}

// Whether the GPU can draw: ggml's Metal backend needs SIMD-group reductions,
// which is A13 and later (Metal 3) or A14 (Apple 7), as for the 听书 engine.
extern "C" int edge_sd_gpu(void) {
    static const bool usable = [] {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        return d && ([d supportsFamily:MTLGPUFamilyApple7] || [d supportsFamily:(MTLGPUFamily) 5001]);
    }();
    return usable ? 1 : 0;
}

// 1 while the app is behind the screen: no GPU.
extern "C" int edge_sd_background(void) {
    watch_app();
    return g_background ? 1 : 0;
}

extern "C" const char * edge_sd_error(void) {
    return g_error.c_str();
}

extern "C" void edge_sd_cancel(void) {
    g_cancel = true;
    stop_now();
}

// One thread per performance core, as the other engines count them.
static int cpu_threads() {
    for (const char * key : { "hw.perflevel0.physicalcpu", "hw.physicalcpu" }) {
        int    cores = 0;
        size_t len   = sizeof(cores);
        if (sysctlbyname(key, &cores, &len, nullptr, 0) == 0 && cores > 0) {
            return cores;
        }
    }
    return 2;
}

typedef void (*edge_sd_log_cb)(int level, const char * text, void * user);
typedef void (*edge_sd_step_cb)(int step, int steps, void * user);

struct sink {
    edge_sd_log_cb  log;
    edge_sd_step_cb step;
    void *          user;
    std::mutex      mutex;  // the loader logs from threads of its own
};

// 0 drawn into `out`, 1 stopped (edge_sd_cancel, or the app moving between
// screen and background), -1 failed (edge_sd_error). `prefer_gpu` with `gpu`
// 0: on the CPU only because the app is behind the screen.
extern "C" int edge_sd_draw(const char * model, const char * taesd, int gpu, int prefer_gpu, const char * prompt,
                            const char * negative, int width, int height, int steps, int64_t seed, const char * out,
                            edge_sd_log_cb on_log, edge_sd_step_cb on_step, void * user) {
    watch_app();
    std::lock_guard<std::mutex> one(g_one);
    g_cancel = false;
    gpu      = gpu && edge_sd_gpu() && !g_background;
    g_where  = gpu ? 1 : (prefer_gpu && edge_sd_gpu() ? 2 : 3);

    sink s{ on_log, on_step, user };
    sd_set_log_callback(
        [](enum sd_log_level_t level, const char * text, void * data) {
            auto * k = static_cast<sink *>(data);
            std::lock_guard<std::mutex> lock(k->mutex);
            k->log((int) level, text, k->user);
        },
        &s);
    sd_set_progress_callback(
        [](int step, int steps, float, void * data) {
            auto * k = static_cast<sink *>(data);
            std::lock_guard<std::mutex> lock(k->mutex);
            k->step(step, steps, k->user);
        },
        &s);

    // sd-cli's -m, --taesd and --fa; without a backend the library takes the
    // GPU, and `--backend cpu` is the CPU.
    sd_ctx_params_t p;
    sd_ctx_params_init(&p);
    p.model_path = model;
    p.taesd_path = taesd;
    p.flash_attn = true;
    p.n_threads  = cpu_threads();
    p.backend    = gpu ? nullptr : "cpu";

    int        rc  = 0;
    sd_ctx_t * ctx = new_sd_ctx(&p);
    if (!ctx) {
        g_error = "生图引擎启动失败";
        rc      = -1;
    } else {
        {
            std::lock_guard<std::mutex> lock(g_ctx_mutex);
            g_ctx = ctx;
        }
        if (g_cancel) {
            rc = 1;
        } else {
            // --clip-skip 2, -W/-H, --steps, --cfg-scale 1, --sampling-method
            // tcd, -s, -p, -n, and the decoder in strips: --vae-tiling
            // --vae-relative-tile-size 1x0.375 --vae-tile-overlap 0.5.
            sd_img_gen_params_t g;
            sd_img_gen_params_init(&g);
            g.prompt                            = prompt;
            g.negative_prompt                   = negative;
            g.clip_skip                         = 2;
            g.width                             = width;
            g.height                            = height;
            g.seed                              = seed;
            g.batch_count                       = 1;
            g.sample_params.sample_method       = TCD_SAMPLE_METHOD;
            g.sample_params.scheduler           = sd_get_default_scheduler(ctx, TCD_SAMPLE_METHOD);
            g.sample_params.sample_steps        = steps;
            g.sample_params.guidance.txt_cfg    = 1.0f;
            g.vae_tiling_params.enabled         = true;
            g.vae_tiling_params.rel_size_w      = 1.0f;
            g.vae_tiling_params.rel_size_h      = 0.375f;
            g.vae_tiling_params.target_overlap  = 0.5f;

            sd_image_t * images = nullptr;
            int          n      = 0;
            const bool   ok     = generate_image(ctx, &g, &images, &n);
            if (g_cancel) {
                rc = 1;
            } else if (!ok || n < 1 || !images || !images[0].data) {
                g_error = "生图失败";
                rc      = -1;
            } else {
                const sd_image_t & im = images[0];
                if (!stbi_write_png(out, (int) im.width, (int) im.height, (int) im.channel, im.data,
                                    (int) (im.width * im.channel))) {
                    g_error = "保存图片失败";
                    rc      = -1;
                }
            }
            for (int i = 0; images && i < n; i++) {
                free(images[i].data);
            }
            free(images);
        }
        {
            std::lock_guard<std::mutex> lock(g_ctx_mutex);
            g_ctx = nullptr;
        }
        free_sd_ctx(ctx);
    }
    g_where = 0;
    sd_set_log_callback(nullptr, nullptr);
    sd_set_progress_callback(nullptr, nullptr);
    return rc;
}
