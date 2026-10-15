@echo off
rem Build tts-server.exe (and qwen-tts.exe) with Vulkan from a qwentts.cpp
rem checkout. See README.md.
rem
rem usage: build_engine.bat <qwentts.cpp source dir> <build dir>
rem
rem Keep the build dir short (e.g. C:\qtb): the Vulkan shader generator's CMake
rem try_compile breaks past Windows' 260-character path limit.
setlocal
if "%~2"=="" (echo usage: build_engine.bat ^<qwentts.cpp source dir^> ^<build dir^> & exit /b 2)
set "SRC=%~1"
set "OUT=%~2"
rem A PATH entry with a stray quote breaks vcvars; start from a clean one.
set "PATH=C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files (x86)\Microsoft Visual Studio\Installer;C:\Program Files\Git\cmd"
set "VS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not defined VULKAN_SDK set "VULKAN_SDK=C:\VulkanSDK\1.4.363.0"
set "PATH=%VULKAN_SDK%\Bin;%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;%VS%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"
rem One exe: the C++ runtime is linked in (same reasons as the image engine) and
rem OpenMP is off, since its runtime (vcomp140.dll) only comes as a DLL. The
rem CPU path is only the fallback, so it targets AVX2 rather than this machine.
if not exist "%OUT%\build.ninja" cmake -S "%SRC%" -B "%OUT%" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_DEFAULT_CMP0091=NEW -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DBUILD_SHARED_LIBS=OFF -DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_OPENMP=OFF || exit /b 1
cmake --build "%OUT%" --target tts-server qwen-tts -j 16 || exit /b 1
echo built %OUT%\tts-server.exe
