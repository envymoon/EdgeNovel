# The GPU for the Android engines: ggml's Vulkan backend, as the Windows
# engines have it. The loader is the phone's own (the NDK's libvulkan.so;
# ggml finds every entry point through it at run time, so API 24 links). The
# C++ headers and the shader compiler come from the Vulkan SDK on the build
# machine: VULKAN_SDK, or the version the Windows engines are built with.
#
# ggml compiles its shaders with a generator it builds for the build machine,
# not the phone; edge_vulkan_host_toolchain() writes the toolchain for that.
# Included by this directory's CMakeLists.txt (the chat engine) and by tts/
# and sd/.

set(EDGE_VULKAN_SDK "$ENV{VULKAN_SDK}")
if(NOT EDGE_VULKAN_SDK AND CMAKE_HOST_WIN32)
    set(EDGE_VULKAN_SDK "C:/VulkanSDK/1.4.363.0")
endif()
file(TO_CMAKE_PATH "${EDGE_VULKAN_SDK}" EDGE_VULKAN_SDK)
if(NOT IS_DIRECTORY "${EDGE_VULKAN_SDK}")
    message(FATAL_ERROR "Vulkan SDK not found: set VULKAN_SDK")
endif()
if(CMAKE_HOST_WIN32)
    set(_edge_vk_include "${EDGE_VULKAN_SDK}/Include")
    set(_edge_vk_glslc "${EDGE_VULKAN_SDK}/Bin/glslc.exe")
    set(_edge_vk_cmake "${EDGE_VULKAN_SDK}/Lib/cmake")
else()
    set(_edge_vk_include "${EDGE_VULKAN_SDK}/include")
    set(_edge_vk_glslc "${EDGE_VULKAN_SDK}/bin/glslc")
    set(_edge_vk_cmake "${EDGE_VULKAN_SDK}/lib/cmake")
endif()
if(NOT EXISTS "${_edge_vk_include}/vulkan/vulkan.hpp" OR NOT EXISTS "${_edge_vk_glslc}")
    message(FATAL_ERROR "Vulkan SDK at ${EDGE_VULKAN_SDK} has no vulkan.hpp or glslc")
endif()
set(Vulkan_INCLUDE_DIR "${_edge_vk_include}" CACHE PATH "" FORCE)
set(Vulkan_GLSLC_EXECUTABLE "${_edge_vk_glslc}" CACHE FILEPATH "" FORCE)
if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(_edge_triple aarch64-linux-android)
else()
    set(_edge_triple x86_64-linux-android)
endif()
set(_edge_api "${ANDROID_PLATFORM_LEVEL}")
if(NOT _edge_api)
    set(_edge_api "${CMAKE_SYSTEM_VERSION}")
endif()
set(Vulkan_LIBRARY "${CMAKE_SYSROOT}/usr/lib/${_edge_triple}/${_edge_api}/libvulkan.so"
    CACHE FILEPATH "" FORCE)
if(NOT EXISTS "${Vulkan_LIBRARY}")
    message(FATAL_ERROR "The NDK has no libvulkan.so at ${Vulkan_LIBRARY}")
endif()
set(SPIRV-Headers_DIR "${_edge_vk_cmake}/SPIRV-Headers" CACHE PATH "" FORCE)

# The toolchain vulkan-shaders-gen is built with. On Windows that is MSVC,
# found by vswhere, with its and the Windows SDK's paths spelled out, so no
# vcvars environment is needed; Gradle runs CMake without one. Ninja is the
# one this build runs on: nested projects are not told it, and it is not on
# Gradle's PATH.
function(edge_vulkan_host_toolchain out)
    set(file "${CMAKE_BINARY_DIR}/edge-host-toolchain.cmake")
    # Gradle hands it over with backslashes, which a CMake string would read
    # as escapes.
    file(TO_CMAKE_PATH "${CMAKE_MAKE_PROGRAM}" make)
    set(text "set(CMAKE_MAKE_PROGRAM \"${make}\" CACHE FILEPATH \"\" FORCE)\n")
    string(APPEND text "set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)\n")
    string(APPEND text "set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY NEVER)\n")
    string(APPEND text "set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE NEVER)\n")
    if(CMAKE_HOST_WIN32)
        set(vswhere "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe")
        execute_process(
            COMMAND "${vswhere}" -latest -products * -requires
                    Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
            OUTPUT_VARIABLE vs OUTPUT_STRIP_TRAILING_WHITESPACE)
        file(TO_CMAKE_PATH "${vs}" vs)
        file(GLOB msvc LIST_DIRECTORIES true "${vs}/VC/Tools/MSVC/*")
        set(kits "C:/Program Files (x86)/Windows Kits/10")
        file(GLOB sdk LIST_DIRECTORIES true "${kits}/Include/10.*")
        if(NOT msvc OR NOT sdk)
            message(FATAL_ERROR "Building the Vulkan shaders needs Visual Studio's C++ tools and a Windows SDK")
        endif()
        list(SORT msvc)
        list(GET msvc -1 msvc)
        list(SORT sdk)
        list(GET sdk -1 sdk)
        get_filename_component(sdk "${sdk}" NAME)
        set(bin "${msvc}/bin/Hostx64/x64")
        set(flags "/I\\\"${msvc}/include\\\"")
        foreach(part ucrt um shared)
            string(APPEND flags " /I\\\"${kits}/Include/${sdk}/${part}\\\"")
        endforeach()
        set(links "/MANIFEST:NO /LIBPATH:\\\"${msvc}/lib/x64\\\"")
        foreach(part ucrt um)
            string(APPEND links " /LIBPATH:\\\"${kits}/Lib/${sdk}/${part}/x64\\\"")
        endforeach()
        string(APPEND text "set(CMAKE_C_COMPILER \"${bin}/cl.exe\")\n")
        string(APPEND text "set(CMAKE_CXX_COMPILER \"${bin}/cl.exe\")\n")
        string(APPEND text "set(CMAKE_LINKER \"${bin}/link.exe\" CACHE FILEPATH \"\" FORCE)\n")
        string(APPEND text "set(CMAKE_AR \"${bin}/lib.exe\" CACHE FILEPATH \"\" FORCE)\n")
        string(APPEND text "set(CMAKE_RC_COMPILER \"${kits}/bin/${sdk}/x64/rc.exe\" CACHE FILEPATH \"\" FORCE)\n")
        string(APPEND text "set(CMAKE_MT \"${kits}/bin/${sdk}/x64/mt.exe\" CACHE FILEPATH \"\" FORCE)\n")
        string(APPEND text "set(CMAKE_C_FLAGS_INIT \"${flags}\")\n")
        string(APPEND text "set(CMAKE_CXX_FLAGS_INIT \"${flags}\")\n")
        string(APPEND text "set(CMAKE_EXE_LINKER_FLAGS_INIT \"${links}\")\n")
    else()
        string(APPEND text "set(CMAKE_C_COMPILER cc)\nset(CMAKE_CXX_COMPILER c++)\n")
    endif()
    file(WRITE "${file}" "${text}")
    set(${out} "${file}" PARENT_SCOPE)
endfunction()

# Everything ggml needs to build its Vulkan backend for the phone.
macro(edge_enable_vulkan)
    edge_vulkan_host_toolchain(_edge_host_toolchain)
    set(GGML_VULKAN ON CACHE BOOL "" FORCE)
    set(GGML_VULKAN_SHADERS_GEN_TOOLCHAIN "${_edge_host_toolchain}" CACHE FILEPATH "" FORCE)
endmacro()
