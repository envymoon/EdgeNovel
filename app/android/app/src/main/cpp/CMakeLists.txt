cmake_minimum_required(VERSION 3.22.1)
project(edge_android_engine LANGUAGES C CXX)

if(NOT ANDROID)
    message(FATAL_ERROR "This launcher must be cross-compiled with the Android NDK")
endif()
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set_property(GLOBAL PROPERTY JOB_POOLS edge_compile=2 edge_link=1)
set(CMAKE_JOB_POOL_COMPILE edge_compile)
set(CMAKE_JOB_POOL_LINK edge_link)
# NDK r28 supports 16 KB pages; explicitly preserve alignment for our executable.
add_link_options("-Wl,-z,max-page-size=16384")

# Same upstream revision as the validated Windows b9957 engine. No floating tag.
set(EDGE_LLAMA_COMMIT c4ae9a88f8884ee5a155c8349ace9ea31a58007f)
set(EDGE_LLAMA_URL "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/${EDGE_LLAMA_COMMIT}")
if(EDGE_LLAMA_ARCHIVE AND EXISTS "${EDGE_LLAMA_ARCHIVE}")
    file(TO_CMAKE_PATH "${EDGE_LLAMA_ARCHIVE}" EDGE_LLAMA_URL)
endif()
include(FetchContent)
FetchContent_Declare(edge_llama
    URL "${EDGE_LLAMA_URL}"
    URL_HASH SHA256=0943e7f2201ea6b300ce4125dabd6569c848a7ac8f7b703f02b41f84f4c74315
    TLS_VERIFY TRUE)

# Static linkage gives the launcher no private shared-library dependencies.
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
set(GGML_LLAMAFILE OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_CPU_ARM_ARCH armv8-a CACHE STRING "" FORCE)
# Do not copy the build PC's instruction set into an emulator executable.
foreach(feature AVX AVX2 AVX512 AVX_VNNI FMA F16C BMI2)
    set(GGML_${feature} OFF CACHE BOOL "" FORCE)
endforeach()
FetchContent_MakeAvailable(edge_llama)

add_library(llama-ui INTERFACE)
target_include_directories(llama-ui INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
add_subdirectory("${edge_llama_SOURCE_DIR}/tools/server" "server")
set_property(SOURCE "${edge_llama_SOURCE_DIR}/tools/server/server-models.cpp"
    "${edge_llama_SOURCE_DIR}/tools/server/server-tools.cpp"
    DIRECTORY "${edge_llama_SOURCE_DIR}/tools/server"
    APPEND PROPERTY COMPILE_OPTIONS
    "-include" "${CMAKE_CURRENT_SOURCE_DIR}/android24_spawn_compat.h")
target_include_directories(server-context PRIVATE "${edge_llama_SOURCE_DIR}")
target_include_directories(llama-server-impl PRIVATE "${edge_llama_SOURCE_DIR}")

add_executable(edge_llama_server engine_main.cpp)
license_add_file("Android NDK toolchain / static C++ runtime" "${ANDROID_NDK}/NOTICE.toolchain")
license_generate(edge_llama_server)
target_link_libraries(edge_llama_server PRIVATE llama-server-impl)
file(TO_CMAKE_PATH "${EDGE_ENGINE_OUTPUT_DIR}" EDGE_ENGINE_OUTPUT_DIR)
string(TOLOWER "${CMAKE_BUILD_TYPE}" EDGE_BUILD_TYPE)
set_target_properties(edge_llama_server PROPERTIES
    OUTPUT_NAME libedge_llama_server.so
    RUNTIME_OUTPUT_DIRECTORY "${EDGE_ENGINE_OUTPUT_DIR}/${EDGE_BUILD_TYPE}/${ANDROID_ABI}")
