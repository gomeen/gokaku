# Gogaku TSF 前端（Windows 输入法接入层）。
# 计划约束：MSVC/Windows SDK 构建；通过 C ABI 加载 Clang64 构建的
# gogaku_core.dll（不跨编译器传递 C++ 类型）；核心加载路径仅限安装目录。
#
# VM 构建（VS Build Tools 就绪后）：
#   cmake -S native/GogakuTsf -B .build/win-tsf -G "Visual Studio 17 2022" -A x64
#   cmake --build .build/win-tsf --config Release
# CI 上同一套 CMake（windows-latest 自带 MSVC）。
cmake_minimum_required(VERSION 3.20)
project(GogakuTsf CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(GogakuTsf SHARED
    src/dllmain.cpp
    src/text_service.cpp
    src/candidate_window.cpp
    src/core_bridge.cpp
    gogaku_tsf.def
)

target_include_directories(GogakuTsf PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../GogakuCore/include
)

target_link_libraries(GogakuTsf PRIVATE
    user32 gdi32 advapi32 ole32 uuid shcore
)

target_compile_definitions(GogakuTsf PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN)

if(MSVC)
    # /utf-8：源码含中文注释与字符串；/W3 基线告警。
    target_compile_options(GogakuTsf PRIVATE /W3 /utf-8 /Zc:__cplusplus)
endif()
