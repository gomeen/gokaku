/* Gogaku 的 Windows 输入法身份常量——只有这一份定义。
 *
 * TSF 的 DllRegisterServer（机器级注册，HKLM）与用户级启用（HKCU 输入法列表）
 * 必须拼出完全相同的条目串 `<LangID 四位十六进制>:<CLSID><档案 GUID>`；两者
 * 各写一份 GUID 曾是这里唯一的两处维护点，任何一处漂移都会让「已注册但启用
 * 指向不存在的档案」这种沉默故障重现。
 *
 * CLSID 由 dev 与 stable 共用（历史如此，改动等于让已安装的版本失联）；只有
 * 语言档案 GUID 区分通道，因此同一个用户可以在系统里同时看到 Gogaku 与
 * Gogaku Dev 两个输入源。
 */
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
/* StringFromGUID2：windows.h 在 WIN32_LEAN_AND_MEAN 下不包含它。 */
#include <objbase.h>

#include <string>
#include <string_view>

namespace gogaku {

inline constexpr GUID kTsfClsid = {0xA3C5D7E9, 0x1B2F, 0x4A6C,
                                   {0x8E, 0x0D, 0x2F, 0x4B, 0x6A, 0x8C, 0x0E, 0x13}};
inline constexpr GUID kProfileStable = {0xC9E1F3A5, 0x7B8D, 0x4E2F,
                                        {0x6A, 0x0C, 0x1D, 0x3E, 0x5F, 0x7A, 0x9B, 0x11}};
inline constexpr GUID kProfileDev = {0xC9E1F3A5, 0x7B8D, 0x4E2F,
                                     {0x6A, 0x0C, 0x1D, 0x3E, 0x5F, 0x7A, 0x9B, 0x12}};
/* zh-CN：与 DllRegisterServer 的 MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_SIMPLIFIED) 同一值。 */
inline constexpr LANGID kLangId = 0x0804;

/* 本次编译的通道。GOGAKU_DEV 与 GOGAKU_CHANNEL 由构包脚本成对给出，
 * 因此这里的编译期选择必然等于运行时 gw::channel()。 */
inline constexpr bool kDevChannel =
#ifdef GOGAKU_DEV
    true;
#else
    false;
#endif

/* GOGAKU_DEV 与 GOGAKU_CHANNEL 必须成对（构包脚本与 CMake 都成对给出）。只改一半
 * 会让「注册的身份」与「启用的条目」指向不同档案，且不会有任何运行时错误——
 * 用户只是看不到输入法。这里把它变成编译错误。 */
constexpr bool channelStringIsDev() {
#ifdef GOGAKU_CHANNEL
    constexpr std::string_view channel = GOGAKU_CHANNEL;
    return channel == "dev";
#else
    return true; /* platform.cpp 未定义 GOGAKU_CHANNEL 时的缺省通道 */
#endif
}
static_assert(channelStringIsDev() == kDevChannel, "GOGAKU_DEV 与 GOGAKU_CHANNEL 不一致");

inline constexpr const GUID &profileGuid(bool dev) { return dev ? kProfileDev : kProfileStable; }
/* 与 DllRegisterServer 同源的选择：启用侧不能另算一次通道。 */
inline constexpr const GUID &profileGuid() { return profileGuid(kDevChannel); }

/* 用户输入法列表条目。StringFromGUID2 输出 `{XXXX-...}`（大写十六进制），
 * 与系统 InputMethodTips 里的写法一致；LangID 固定四位大写十六进制。 */
inline std::wstring profileTipString(const GUID &clsid, const GUID &profile) {
    wchar_t clsidText[40]{}, profileText[40]{};
    if (!StringFromGUID2(clsid, clsidText, 40) || !StringFromGUID2(profile, profileText, 40))
        return {};
    static const wchar_t hex[] = L"0123456789ABCDEF";
    wchar_t lang[5]{};
    for (int i = 0; i < 4; ++i) lang[i] = hex[(unsigned(kLangId) >> (12 - i * 4)) & 0xF];
    lang[4] = L':';
    return std::wstring(lang) + clsidText + profileText;
}

inline std::wstring profileTipString() { return profileTipString(kTsfClsid, profileGuid()); }

/* 面向用户的输入法名称。与 DllRegisterServer 写入的 description 同一口径，
 * 避免设置页让用户在 stable 安装里去找「Gogaku Dev」。 */
inline constexpr const wchar_t *profileName() { return kDevChannel ? L"Gogaku Dev" : L"Gogaku"; }

} // namespace gogaku
