cmake_minimum_required(VERSION 3.22)
project(edge_windows_kokoro LANGUAGES C CXX)

# Kokoro 1.1-zh light voice DLL for Windows, built on the same ggml fork as
# Android and iOS, and placed beside novel.exe.
set(CMAKE_CXX_STANDARD 17)

get_filename_component(EDGE_APP "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(EDGE_QWENTTS_GGML_COMMIT 2be5947ac234d277714e824a5c7eb23880557543)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)

# Enable Vulkan GPU acceleration automatically when the Vulkan SDK is present.
find_package(Vulkan QUIET)
if(Vulkan_FOUND)
    set(GGML_VULKAN ON CACHE BOOL "" FORCE)
else()
    set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
endif()

add_compile_definitions(GGML_MAX_NAME=128)

include(FetchContent)
# Keep the FetchContent path short so MSBuild's vulkan-shaders-gen stays
# under Windows' 260-character MAX_PATH limit.
set(FETCHCONTENT_BASE_DIR "${CMAKE_BINARY_DIR}/k")
FetchContent_Declare(g
    URL "https://codeload.github.com/ServeurpersoCom/ggml/tar.gz/${EDGE_QWENTTS_GGML_COMMIT}"
    URL_HASH SHA256=aa59ede8471d7d6c679e697c83c5a9392b3f8fc8cbc16d5b11dfab21865c1139
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    TLS_VERIFY TRUE
    EXCLUDE_FROM_ALL)
FetchContent_MakeAvailable(g)

set(KOKORO_SRC "${EDGE_APP}/rust/ios_tts/kokoro")
add_library(edge_kokoro SHARED "${KOKORO_SRC}/kokoro.cpp")
target_compile_definitions(edge_kokoro PRIVATE
    EDGE_KOKORO_SHARED
    _USE_MATH_DEFINES
    _CRT_SECURE_NO_WARNINGS)
target_include_directories(edge_kokoro PRIVATE "${KOKORO_SRC}")
target_link_libraries(edge_kokoro PRIVATE ggml ggml-base ggml-cpu)
if(Vulkan_FOUND)
    target_link_libraries(edge_kokoro PRIVATE ggml-vulkan)
endif()
if(MSVC)
    target_compile_options(edge_kokoro PRIVATE /EHsc /W2)
endif()
