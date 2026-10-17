cmake_minimum_required(VERSION 3.22)
project(edge_ios_sd LANGUAGES C CXX OBJC OBJCXX)

# AI 封面 and 章间立绘 on iOS: stable-diffusion.cpp, the engine the Windows app
# runs as sd-cli, built as a library to run inside the app (edge_sd.mm).
# build.rs drives this and then hides everything but edge_sd_* in one object:
# its ggml is a third copy, beside llama.cpp's and the 听书 engine's, and they
# must not meet at link time.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_MACOSX_BUNDLE OFF)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")

# The revisions of the Windows engine (experiments/anime-cover-model), with its
# patch: the model's UNet convolutions are quantized, which stock sd.cpp
# cannot load.
set(EDGE_SD_COMMIT 1b0ba10893f4e2e0656103011fc1c4645a02a734)
set(EDGE_SD_GGML_COMMIT d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93)
include(FetchContent)
# The ggml it is pinned to. The patch lets the app say where the compiled Metal
# library is, under a name of its own, and compiles it for the oldest iOS that
# runs the engine.
FetchContent_Declare(edge_sd_ggml
    URL "https://codeload.github.com/leejet/ggml/tar.gz/${EDGE_SD_GGML_COMMIT}"
    URL_HASH SHA256=bbfaebbfe2564a796f1a9309ff87cd6c6a5acdfffe7b779f96b847f57945403b
    TLS_VERIFY TRUE
    PATCH_COMMAND patch -p1 -i "${CMAKE_CURRENT_SOURCE_DIR}/ggml-metal-library.patch"
    # Sources only: sd.cpp adds it itself.
    SOURCE_SUBDIR no-cmake)
# Upstream keeps src/convert.cpp with CRLF line ends and the patch has LF.
FetchContent_Declare(edge_sd
    URL "https://codeload.github.com/leejet/stable-diffusion.cpp/tar.gz/${EDGE_SD_COMMIT}"
    URL_HASH SHA256=af0d33ffe265503ece89526b283015a4c987cfdf54479559e7ce08fc32327216
    TLS_VERIFY TRUE
    PATCH_COMMAND perl -pi -e "s/\\r$//" src/convert.cpp
          COMMAND patch -p1 -i "${CMAKE_CURRENT_SOURCE_DIR}/../../../experiments/anime-cover-model/sdcpp-quantized-conv.patch")
FetchContent_MakeAvailable(edge_sd_ggml)

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
set(SD_METAL ON CACHE BOOL "" FORCE)
set(SD_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SD_WEBP OFF CACHE BOOL "" FORCE)
set(SD_WEBM OFF CACHE BOOL "" FORCE)
set(SD_GGML_SOURCE_DIR "${edge_sd_ggml_SOURCE_DIR}" CACHE PATH "" FORCE)
FetchContent_MakeAvailable(edge_sd)
# llama.cpp's ggml and the 听书 engine's have a class of this name too, and
# the runtime has one namespace for classes.
target_compile_definitions(ggml-metal PRIVATE GGMLMetalClass=EdgeSdGGMLMetalClass)

add_library(edge_sd STATIC edge_sd.mm)
target_include_directories(edge_sd PRIVATE
    "${edge_sd_SOURCE_DIR}/include"
    "${edge_sd_SOURCE_DIR}/thirdparty")
target_link_libraries(edge_sd PRIVATE stable-diffusion)
add_dependencies(edge_sd ggml-metal-lib)
