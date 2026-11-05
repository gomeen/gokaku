/* Gogaku TSF 前端——公共头。
 *
 * 计划约束（docs/implementation-plan.md）：TSF 用 MSVC/Windows SDK 实现，
 * 通过版本化 C ABI 加载共享核心 DLL（Clang64 构建）；不跨编译器传递 C++
 * 类型；核心加载路径仅限安装目录，不依赖系统 PATH 或 MSYS 环境。
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

#include "../../GogakuCore/include/gogaku_core.h"

/* GUID 定义在 dllmain.cpp（头文件只声明，避免 selectany/内部链接问题）。 */
extern const GUID CLSID_GogakuTsf;
extern const GUID GUID_GOGAKU_PROFILE;

std::string Utf16ToUtf8(const std::wstring &w);
std::wstring Utf8ToUtf16(const std::string &s);

extern HINSTANCE g_hInst;
