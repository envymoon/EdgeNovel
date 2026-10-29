cmake_minimum_required(VERSION 3.22)
project(edge_android_tts LANGUAGES C CXX)

# 听书 on Android: qwentts.cpp's tts-server, the engine the Windows app runs,
# built for the phone with the GPU (Vulkan) and shipped in the APK as
# libedge_tts_server.so. A project of its own, built by ../CMakeLists.txt as
# an external project: its ggml is a fork, and must not meet llama.cpp's.

if(NOT ANDROID)
    message(FATAL_ERROR "This engine must be cross-compiled with the Android NDK")
endif()
set(CMAKE_CXX_STANDARD 17)
add_link_options("-Wl,-z,max-page-size=16384")

# The revisions of the Windows and iOS engines, with the Windows patch.
set(EDGE_QWENTTS_COMMIT 177925ecc54fed51c868985efd7dd01a8ae4fa29)
set(EDGE_QWENTTS_GGML_COMMIT 2be5947ac234d277714e824a5c7eb23880557543)
include(FetchContent)
FetchContent_Declare(edge_qwentts
    URL "https://codeload.github.com/ServeurpersoCom/qwentts.cpp/tar.gz/${EDGE_QWENTTS_COMMIT}"
    URL_HASH SHA256=b86898c2e74bf4edea8cc875e8708bf13b1a4edf0ae52a4e76cd68d26edf473c
    TLS_VERIFY TRUE
    PATCH_COMMAND "${EDGE_PATCH}" -p1 -i "${EDGE_REPO}/experiments/qwen-tts/qwentts.patch"
    # Sources only: its own CMakeLists builds every tool.
    SOURCE_SUBDIR no-cmake)
FetchContent_Declare(qg
    URL "https://codeload.github.com/ServeurpersoCom/ggml/tar.gz/${EDGE_QWENTTS_GGML_COMMIT}"
    URL_HASH SHA256=aa59ede8471d7d6c679e697c83c5a9392b3f8fc8cbc16d5b11dfab21865c1139
    TLS_VERIFY TRUE)

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
# Tensor names in the codec are longer than ggml's default.
add_compile_definitions(GGML_MAX_NAME=128)
FetchContent_MakeAvailable(edge_qwentts qg)

set(QT "${edge_qwentts_SOURCE_DIR}")
find_package(Threads REQUIRED)
add_subdirectory("${QT}/vendor/cpp-httplib" httplib)
add_library(yyjson STATIC "${QT}/vendor/yyjson/yyjson.c")
target_include_directories(yyjson PUBLIC "${QT}/vendor/yyjson")
target_compile_options(yyjson PRIVATE -w)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/version.h"
    "#pragma once\n#define QWEN_VERSION \"177925e\"\n")

# Its main becomes edge_engine_main, under one that ends it with the app.
add_executable(edge_tts
    "${EDGE_CPP}/parent_main.cpp"
    "${EDGE_CPP}/vulkan11_shim.cpp"
    "${QT}/tools/tts-server.cpp"
    "${QT}/src/qwen.cpp"
    "${QT}/src/pipeline-tts.cpp"
    "${QT}/src/pipeline-codec.cpp")
set_source_files_properties("${QT}/tools/tts-server.cpp"
    PROPERTIES COMPILE_DEFINITIONS main=edge_engine_main)
target_compile_definitions(edge_tts PRIVATE QWEN_STATIC)
target_include_directories(edge_tts PRIVATE
    "${QT}/src" "${QT}" "${QT}/tools" "${CMAKE_CURRENT_BINARY_DIR}" "${Vulkan_INCLUDE_DIR}")
target_link_libraries(edge_tts PRIVATE ggml ggml-base ggml-cpu ggml-vulkan httplib yyjson Threads::Threads)
set_target_properties(edge_tts PROPERTIES
    OUTPUT_NAME libedge_tts_server.so
    RUNTIME_OUTPUT_DIRECTORY "${EDGE_OUTPUT_DIR}")
