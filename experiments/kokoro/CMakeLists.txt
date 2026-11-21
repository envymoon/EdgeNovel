cmake_minimum_required(VERSION 3.22)
project(kokoro_pc LANGUAGES C CXX)

# The PC check of the Kokoro engine (app/rust/ios_tts/kokoro) against the
# original: ggml from GGML_DIR, the same fork the phone's 听书 engine pins.
set(CMAKE_CXX_STANDARD 17)
set(GGML_DIR "" CACHE PATH "ggml source")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
add_subdirectory(${GGML_DIR} ggml)

set(K "${CMAKE_CURRENT_SOURCE_DIR}/../../app/rust/ios_tts/kokoro")
add_executable(kokoro-cli kokoro_cli.cpp "${K}/kokoro.cpp")
target_include_directories(kokoro-cli PRIVATE "${K}")
target_link_libraries(kokoro-cli PRIVATE ggml ggml-base ggml-cpu)
if(MSVC)
    target_compile_definitions(kokoro-cli PRIVATE _USE_MATH_DEFINES _CRT_SECURE_NO_WARNINGS)
endif()
