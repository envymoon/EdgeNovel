cmake_minimum_required(VERSION 3.22)
project(edge_android_sd LANGUAGES C CXX)

# AI 封面 and 章间立绘 on Android: stable-diffusion.cpp's sd-cli, the engine
# the Windows app runs, built for the phone with the GPU (Vulkan) and shipped
# in the APK as libedge_sd_cli.so. A project of its own, built by
# ../CMakeLists.txt as an external project: its ggml is a third copy, beside
# llama.cpp's and the 听书 engine's.

if(NOT ANDROID)
    message(FATAL_ERROR "This engine must be cross-compiled with the Android NDK")
endif()
set(CMAKE_CXX_STANDARD 17)
add_link_options("-Wl,-z,max-page-size=16384")

# The revisions of the Windows and iOS engines, with the Windows patch (the
# model's UNet convolutions are quantized, which stock sd.cpp cannot load) and
# iOS's (every tokenizer table but CLIP's, the one the model reads, left out:
# 28 MB less in the APK).
set(EDGE_SD_COMMIT 1b0ba10893f4e2e0656103011fc1c4645a02a734)
set(EDGE_SD_GGML_COMMIT d25b121ce1d6ae0c7e62ad080460d9fc1e46dd93)
include(FetchContent)
FetchContent_Declare(edge_sd_ggml
    URL "https://codeload.github.com/leejet/ggml/tar.gz/${EDGE_SD_GGML_COMMIT}"
    URL_HASH SHA256=bbfaebbfe2564a796f1a9309ff87cd6c6a5acdfffe7b779f96b847f57945403b
    TLS_VERIFY TRUE
    # Sources only: sd.cpp adds it itself.
    SOURCE_SUBDIR no-cmake)
# Upstream keeps src/convert.cpp with CRLF line ends, and a Windows checkout
# gives part of the patch CRLF too: both go to LF (Git's perl, beside its
# patch) before it applies.
get_filename_component(_edge_git_bin "${EDGE_PATCH}" DIRECTORY)
find_program(EDGE_PERL perl HINTS "${_edge_git_bin}" REQUIRED)
set(_edge_conv_patch "${CMAKE_BINARY_DIR}/sdcpp-quantized-conv.patch")
FetchContent_Declare(sd
    URL "https://codeload.github.com/leejet/stable-diffusion.cpp/tar.gz/${EDGE_SD_COMMIT}"
    URL_HASH SHA256=af0d33ffe265503ece89526b283015a4c987cfdf54479559e7ce08fc32327216
    TLS_VERIFY TRUE
    PATCH_COMMAND "${CMAKE_COMMAND}" -E copy
              "${EDGE_REPO}/experiments/anime-cover-model/sdcpp-quantized-conv.patch" "${_edge_conv_patch}"
          COMMAND "${EDGE_PERL}" -pi "${EDGE_CPP}/crlf_to_lf.pl" src/convert.cpp "${_edge_conv_patch}"
          COMMAND "${EDGE_PATCH}" -p1 -i "${_edge_conv_patch}"
          COMMAND "${EDGE_PATCH}" -p1 -i "${EDGE_REPO}/app/rust/ios_sd/sdcpp-clip-vocab-only.patch")
FetchContent_MakeAvailable(edge_sd_ggml)

include("${EDGE_CPP}/edge_vulkan.cmake")
edge_enable_vulkan()
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ARM_ARCH armv8-a CACHE STRING "" FORCE)
foreach(feature AVX AVX2 AVX512 AVX_VNNI FMA F16C BMI2)
    set(GGML_${feature} OFF CACHE BOOL "" FORCE)
endforeach()
set(SD_VULKAN ON CACHE BOOL "" FORCE)
set(SD_BUILD_EXAMPLES ON CACHE BOOL "" FORCE)
set(SD_WEBP OFF CACHE BOOL "" FORCE)
set(SD_WEBM OFF CACHE BOOL "" FORCE)
set(SD_SERVER_BUILD_FRONTEND OFF CACHE BOOL "" FORCE)
set(SD_GGML_SOURCE_DIR "${edge_sd_ggml_SOURCE_DIR}" CACHE PATH "" FORCE)
FetchContent_MakeAvailable(sd)

target_sources(sd-cli PRIVATE "${EDGE_CPP}/vulkan11_shim.cpp")
target_include_directories(sd-cli PRIVATE "${Vulkan_INCLUDE_DIR}")
set_target_properties(sd-cli PROPERTIES
    OUTPUT_NAME libedge_sd_cli.so
    RUNTIME_OUTPUT_DIRECTORY "${EDGE_OUTPUT_DIR}")
# ../CMakeLists.txt builds this target.
add_custom_target(edge_sd DEPENDS sd-cli)
