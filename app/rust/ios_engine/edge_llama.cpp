// llama-server as two C functions for the app (src/ios_engine.rs): run one on
// a thread until it is stopped, and stop one by its port.
#include <clocale>

#include "arg.h"
#include "common.h"
#include "llama.h"
#include "server-stream.h"

// tools/server/server.cpp; the second one comes from server-stop-by-port.patch.
int llama_server(common_params & params, int argc, char ** argv);
bool llama_server_stop_port(int port);

// What llama_server(argc, argv) does, except that the server is started the way
// llama.cpp's own CLI starts it, without argv: then it installs no signal
// handlers, which in an app would belong to the whole process.
extern "C" int edge_llama_run(int argc, char ** argv) {
    std::setlocale(LC_NUMERIC, "C");
    common_params params;
    common_init();
    server_stream_session_manager_start();
    if (!common_params_parse(argc, argv, params, LLAMA_EXAMPLE_SERVER)) {
        return 1;
    }
    llama_backend_init();
    llama_numa_init(params.numa);
    return llama_server(params, 0, nullptr);
}

// 0 while the server on `port` is still loading its model (or not running):
// it can only be stopped once it is serving.
extern "C" int edge_llama_stop(int port) {
    return llama_server_stop_port(port) ? 1 : 0;
}
