# TSF 按宿主架构构建；输入核心在 x64 代理中，渲染器静态编入本 DLL。
# cmake -S windows/GogakuTsf -B .build/win-tsf -G "Visual Studio 17 2022" -A x64
cmake_minimum_required(VERSION 3.25)
project(GogakuTsf LANGUAGES C CXX RC)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
option(GOGAKU_DEV "Use the development channel identity" OFF)
option(GOGAKU_LITE "Build Lite" OFF)
set(GOGAKU_PANEL_EXPORTS OFF)
add_subdirectory(../../shared/GogakuCore/panel_render panel_render)

add_library(GogakuTsf SHARED
    src/dllmain.cpp src/text_service.cpp src/candidate_window.cpp src/core_bridge.cpp
    ../GogakuWindows/platform.cpp ../GogakuWindows/appearance.cpp ../GogakuWindows/themes.cpp
    ../../shared/GogakuCore/settings_contract.cpp ../../shared/GogakuCore/theme_contract.cpp
    ../GogakuWindows/app.rc gogaku_tsf.def)
target_include_directories(GogakuTsf PRIVATE src ../GogakuWindows ../../shared/GogakuCore/include)
target_link_libraries(GogakuTsf PRIVATE GogakuPanelRender
    user32 gdi32 advapi32 ole32 oleaut32 uuid shell32 bcrypt crypt32 d2d1 dwrite windowscodecs msimg32)
target_compile_definitions(GogakuTsf PRIVATE UNICODE _UNICODE NOMINMAX
    WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00 GOGAKU_SETTINGS_CONTRACT_STATIC)
if(GOGAKU_DEV)
    target_compile_definitions(GogakuTsf PRIVATE GOGAKU_DEV GOGAKU_CHANNEL="dev")
else()
    target_compile_definitions(GogakuTsf PRIVATE GOGAKU_CHANNEL="stable")
endif()
if(GOGAKU_LITE)
    target_compile_definitions(GogakuTsf PRIVATE GOGAKU_LITE)
endif()
if(MSVC)
    target_compile_options(GogakuTsf PRIVATE /W3 /utf-8 /Zc:__cplusplus)
elseif(MINGW)
    target_link_options(GogakuTsf PRIVATE -static -Wl,--kill-at)
endif()
