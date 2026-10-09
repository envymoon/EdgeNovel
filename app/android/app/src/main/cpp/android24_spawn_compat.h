// llama.cpp's optional model router uses posix_spawn (Android API 28+).
// EdgeNovel supplies -m and runs one model per managed process, never the
// router. On API 24 builds, fail any attempted nested spawn with ENOSYS rather
// than importing symbols that would prevent the entire engine from loading.
#pragma once
#include <cerrno>
#include <spawn.h>
#if defined(__ANDROID__) && __ANDROID_API__ < 28
inline int edge_spawn_init(posix_spawn_file_actions_t *) { return ENOSYS; }
inline int edge_spawn_destroy(posix_spawn_file_actions_t *) { return ENOSYS; }
inline int edge_spawn_close(posix_spawn_file_actions_t *, int) { return ENOSYS; }
inline int edge_spawn_dup2(posix_spawn_file_actions_t *, int, int) { return ENOSYS; }
inline int edge_spawn(pid_t *, const char *, const posix_spawn_file_actions_t *,
                      const posix_spawnattr_t *, char * const *, char * const *) {
    return ENOSYS;
}
#define posix_spawn_file_actions_init edge_spawn_init
#define posix_spawn_file_actions_destroy edge_spawn_destroy
#define posix_spawn_file_actions_addclose edge_spawn_close
#define posix_spawn_file_actions_adddup2 edge_spawn_dup2
#define posix_spawn edge_spawn
#define posix_spawnp edge_spawn
#endif
