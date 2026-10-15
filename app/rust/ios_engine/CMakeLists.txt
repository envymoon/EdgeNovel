cmake_minimum_required(VERSION 3.22)
project(edge_ios_engine LANGUAGES C CXX OBJC)

# iOS lets an app start no process of its own, so the llama-server that runs as
# an executable on Windows and Android is built here as a library, to be run on
# a thread inside the app (edge_llama.cpp). build.rs drives this for iOS only.

set(CMAKE_CXX_STANDARD 17)
# On iOS CMake makes every executable an app bundle, and llama-server's install
# rule has no place for one. Nothing here is installed or run as a program.
set(CMAKE_MACOSX_BUNDLE OFF)

# Same upstream revision as the validated Windows b9957 engine and the Android
# one. The patch lets several servers share the process, each stopped by port,
# answers a request still waiting when its server stops (or the stop never
# ends), and makes a model that gets no context fail its load instead of
# crashing.
set(EDGE_LLAMA_COMMIT c4ae9a88f8884ee5a155c8349ace9ea31a58007f)
include(FetchContent)
FetchContent_Declare(edge_llama
    URL "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/${EDGE_LLAMA_COMMIT}"
    URL_HASH SHA256=0943e7f2201ea6b300ce4125dabd6569c848a7ac8f7b703f02b41f84f4c74315
    TLS_VERIFY TRUE
    PATCH_COMMAND patch -p1 -i "${CMAKE_CURRENT_SOURCE_DIR}/server-stop-by-port.patch")

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_NUMBER 9957 CACHE STRING "" FORCE)
set(LLAMA_BUILD_COMMIT "${EDGE_LLAMA_COMMIT}" CACHE STRING "" FORCE)
set(MTMD_VIDEO OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
# The GPU is Metal. Its shaders are embedded as source and compiled on the
# device, so no metallib has to ship next to the app.
set(GGML_METAL ON CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(edge_llama)

# The no-assets web UI stub the Android engine uses: Flutter is the UI.
add_library(llama-ui INTERFACE)
target_include_directories(llama-ui INTERFACE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../android/app/src/main/cpp")
add_subdirectory("${edge_llama_SOURCE_DIR}/tools/server" "server" EXCLUDE_FROM_ALL)
target_include_directories(server-context PRIVATE "${edge_llama_SOURCE_DIR}")
target_include_directories(llama-server-impl PRIVATE "${edge_llama_SOURCE_DIR}")

add_library(edge_llama STATIC edge_llama.cpp)
target_link_libraries(edge_llama PRIVATE llama-server-impl)
