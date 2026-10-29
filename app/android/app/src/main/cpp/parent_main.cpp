// The 听书 engine's entry on Android (tts/CMakeLists.txt compiles its own
// main as edge_engine_main). Like the chat engine's (engine_main.cpp), it
// goes when the app does: a server left listening would hold the voice's
// memory for nobody.
#include <cerrno>
#include <cstdlib>
#include <thread>
#include <unistd.h>

int edge_engine_main(int argc, char ** argv);

int main(int argc, char ** argv) {
    const char * value = std::getenv("EDGE_PARENT_PID");
    char * end = nullptr;
    errno = 0;
    const long parent = value ? std::strtol(value, &end, 10) : 0;
    if (!errno && end && !*end && parent > 1) {
        // PDEATHSIG follows the spawning Linux thread, which can be a
        // short-lived Rust worker. Watch the parent process instead.
        std::thread([parent] {
            while (getppid() == parent) sleep(1);
            _exit(0);
        }).detach();
    }
    return edge_engine_main(argc, argv);
}
