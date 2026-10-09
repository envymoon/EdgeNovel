// Android packages native executables under lib/<ABI>/lib*.so. This is a PIE
// executable, not a JNI library: Rust launches it from the installed directory.
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <thread>
#include <unistd.h>

int llama_server(int argc, char ** argv);
extern const char * LICENSES[];

int main(int argc, char ** argv) {
    if (argc == 2 && std::strcmp(argv[1], "--edge-licenses") == 0) {
        for (const char ** license = LICENSES; *license; ++license) std::puts(*license);
        return 0;
    }
    // This path never initializes a model; useful for device packaging checks.
    if (argc == 2 && std::strcmp(argv[1], "--edge-self-check") == 0) {
        return 0;
    }
    const char * value = std::getenv("EDGE_PARENT_PID");
    char * end = nullptr;
    errno = 0;
    const long expected = value ? std::strtol(value, &end, 10) : 0;
    if (errno || !end || *end || expected <= 1 || getppid() != expected) {
        return 78;
    }
    // PDEATHSIG follows the spawning Linux thread, which can be a short-lived
    // Rust worker. Watch the parent process instead so worker exit is harmless.
    std::thread([expected] {
        while (getppid() == expected) sleep(1);
        _exit(0);
    }).detach();
    return llama_server(argc, argv);
}
