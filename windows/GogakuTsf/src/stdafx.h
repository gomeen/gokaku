/* Gogaku TSF 前端——公共头。
 *
 * TSF 是 Windows SDK COM 薄前端（MSVC／MinGW-w64 均可编译）。
 * x86 与 x64 通过同一有界、当前用户专用的管道协议连接 x64 代理。
 * 只有代理加载共享核心；TSF 不联网、不加载模型、不写调频文件。
 */
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX /* windows.h 的 min/max 宏与 std::max 冲突 */
#endif
#include <windows.h>
#include <msctf.h>

#include <functional>
#include <string>
#include <vector>

#include "../../../shared/GogakuCore/include/gogaku_core.h"

/* GUID 定义在 dllmain.cpp（头文件只声明，避免 selectany/内部链接问题）。 */
extern const GUID CLSID_GogakuTsf;
extern const GUID GUID_GOGAKU_PROFILE;

std::string Utf16ToUtf8(const std::wstring &w);
std::wstring Utf8ToUtf16(const std::string &s);

extern HINSTANCE g_hInst;
