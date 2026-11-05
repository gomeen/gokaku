/* Gogaku TSF 前端——公共头。
 *
 * 计划约束（docs/implementation-plan.md）：TSF 用 MSVC/Windows SDK 实现，
 * 通过版本化 C ABI 加载共享核心 DLL（Clang64 构建）；不跨编译器传递 C++
 * 类型；核心加载路径仅限安装目录，不依赖系统 PATH 或 MSYS 环境。
 */
#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <msctf.h>

#include <functional>
#include <string>
#include <vector>

#include "../../GogakuCore/include/gogaku_core.h"

/* {A3C5D7E9-1B2F-4A6C-8E0D-2F4B6A8C0E12} */
__declspec(selectany) const GUID CLSID_GogakuTsf = {
    0xA3C5D7E9, 0x1B2F, 0x4A6C, {0x8E, 0x0D, 0x2F, 0x4B, 0x6A, 0x8C, 0x0E, 0x12}};
/* {C9E1F3A5-7B8D-4E2F-6A0C-1D3E5F7A9B11}（zh-CN 语言档案） */
__declspec(selectany) const GUID GUID_GOGAKU_PROFILE = {
    0xC9E1F3A5, 0x7B8D, 0x4E2F, {0x6A, 0x0C, 0x1D, 0x3E, 0x5F, 0x7A, 0x9B, 0x11}};

std::string Utf16ToUtf8(const std::wstring &w);
std::wstring Utf8ToUtf16(const std::string &s);

extern HINSTANCE g_hInst;
