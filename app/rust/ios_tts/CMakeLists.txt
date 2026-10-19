cmake_minimum_required(VERSION 3.22)
project(edge_ios_tts LANGUAGES C CXX OBJC OBJCXX)

# 听书 on iOS: qwentts.cpp, the engine the Windows app runs as tts-server, built
# as a library to run inside the app (edge_tts.mm). build.rs drives this and
# then hides everything but edge_tts_* in one object: this ggml is a fork, newer
# than the one llama.cpp brings, and the two must not meet at link time.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_MACOSX_BUNDLE OFF)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

# The revisions of the Windows engine (experiments/qwen-tts), with its patch,
# and one of its own: as many CPU threads as performance cores, not half the
# cores, which assumes SMT.
set(EDGE_QWENTTS_COMMIT 177925ecc54fed51c868985efd7dd01a8ae4fa29)
set(EDGE_QWENTTS_GGML_COMMIT 2be5947ac234d277714e824a5c7eb23880557543)
include(FetchContent)
FetchContent_Declare(edge_qwentts
    URL "https://codeload.github.com/ServeurpersoCom/qwentts.cpp/tar.gz/${EDGE_QWENTTS_COMMIT}"
    URL_HASH SHA256=b86898c2e74bf4edea8cc875e8708bf13b1a4edf0ae52a4e76cd68d26edf473c
    TLS_VERIFY TRUE
    PATCH_COMMAND patch -p1 -i "${CMAKE_CURRENT_SOURCE_DIR}/../../../experiments/qwen-tts/qwentts.patch"
          COMMAND patch -p1 -i "${CMAKE_CURRENT_SOURCE_DIR}/qwentts-threads.patch"
    # Sources only: its own CMakeLists builds the tools and the server.
    SOURCE_SUBDIR no-cmake)
# The ggml it is pinned to. The patch lets the app say where the compiled Metal
# library is, compiles it for the oldest iOS that runs the engine, reads its
# fusion switch at every load, and moves the codec's data by faster kernels
# (GGML_METAL_FAST_MOVE, the same values).
FetchContent_Declare(edge_qwentts_ggml
    URL "https://codeload.github.com/ServeurpersoCom/ggml/tar.gz/${EDGE_QWENTTS_GGML_COMMIT}"
    URL_HASH SHA256=aa59ede8471d7d6c679e697c83c5a9392b3f8fc8cbc16d5b11dfab21865c1139
    TLS_VERIFY TRUE
    PATCH_COMMAND patch -p1 -i "${CMAKE_CURRENT_SOURCE_DIR}/ggml-metal-library.patch")

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_METAL ON CACHE BOOL "" FORCE)
# A compiled default.metallib (bin/), which build.rs hands to the app, rather
# than kernel sources compiled on the device.
set(GGML_METAL_EMBED_LIBRARY OFF CACHE BOOL "" FORCE)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set(GGML_METAL_TARGET_OS ios CACHE STRING "" FORCE)
    set(GGML_METAL_DEPLOYMENT_TARGET 16.4)
else()
    set(GGML_METAL_MACOSX_VERSION_MIN 13.0 CACHE STRING "" FORCE)
endif()
# Tensor names in the codec are longer than ggml's default.
add_compile_definitions(GGML_MAX_NAME=128)
FetchContent_MakeAvailable(edge_qwentts edge_qwentts_ggml)
# llama.cpp's ggml has a class of this name too, and the runtime has one
# namespace for classes.
target_compile_definitions(ggml-metal PRIVATE GGMLMetalClass=EdgeTtsGGMLMetalClass)

set(QT "${edge_qwentts_SOURCE_DIR}")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/version.h"
    "#pragma once\n#define QWEN_VERSION \"177925e\"\n")
add_library(edge_tts STATIC
    edge_tts.mm
    "${QT}/src/qwen.cpp"
    "${QT}/src/pipeline-tts.cpp"
    "${QT}/src/pipeline-codec.cpp")
target_compile_definitions(edge_tts PRIVATE QWEN_STATIC)
target_include_directories(edge_tts PRIVATE "${QT}/src" "${QT}" "${CMAKE_CURRENT_BINARY_DIR}")
target_link_libraries(edge_tts PRIVATE ggml ggml-base ggml-cpu ggml-metal)
add_dependencies(edge_tts ggml-metal-lib)
