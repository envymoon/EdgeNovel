// Kokoro 1.1-zh on ggml: phonemes in, 24 kHz mono samples out.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kokoro kokoro;

// gpu: run the big parts on the GPU when one is there. threads: CPU threads.
// NULL when the file cannot be read; the reason goes to stderr.
kokoro * kokoro_load(const char * gguf_path, int gpu, int threads);
void kokoro_free(kokoro * k);

int kokoro_voice_count(const kokoro * k);
const char * kokoro_voice_name(const kokoro * k, int i);

// phonemes: the model's own alphabet (UTF-8), at most 510 of them.
// speed: 1 is the voice's own pace. seed: the source noise.
// Returns malloc'd samples (free with kokoro_free_audio) and their count in
// *n, or NULL with the reason in kokoro_error.
float * kokoro_speak(kokoro * k, const char * phonemes, const char * voice, float speed,
                     unsigned seed, int * n);
void kokoro_free_audio(float * samples);
const char * kokoro_error(const kokoro * k);

// Checking against the original: every intermediate is written to dir as raw
// float32, and the source noise is left out when quiet.
void kokoro_debug(kokoro * k, const char * dir, int quiet);

#ifdef __cplusplus
}
#endif
