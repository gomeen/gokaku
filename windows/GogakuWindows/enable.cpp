/* 用户级启用：把本通道的 Gogaku 登记进当前用户的输入法列表。
 *
 * 机器级注册（DllRegisterServer，HKLM）与用户级启用（HKCU）是两层，前者再成功
 * 也不会让输入法出现在键盘列表里。这里只做第二层，并且刻意保持最小：
 *
 * - 只写当前用户；调用方必须已以「原用户身份」运行（安装器的 [Run] 用
 *   runasoriginaluser，设置应用本身就是原用户）。提权进程写 HKCU 写的是管理员
 *   hive，用户看不到自己的条目。
 * - 幂等：已包含就什么都不写、直接成功。系统的 InputMethodTips 是整表回写语义，
 *   「未包含才执行一次、失败不重试」把整表重写的竞态窗口压到最小
 *   （见 docs/research-ime-windows11-pruning.md §7）。
 * - 不设默认输入法、不写 Set-WinDefaultInputMethodOverride、不增删其它语言条目、
 *   不做后台循环重试。失败就把原因交回去，由安装器记日志、由设置页引导用户。
 */
#include "enable.h"
#include "platform.h"
#include "../gogaku-ids.h"

#include <algorithm>
#include <cwctype>
#include <string>
#include <vector>

namespace gw {
namespace {

constexpr wchar_t kUserProfile[] = L"Control Panel\\International\\User Profile";

/* InstallLayoutOrTip 是 input.dll 的导出，没有导入库；标志常量也不在公开头文件
 * （Learn: installlayoutortip）。这里只需要「启用」= 0。 */
using InstallLayoutOrTipFn = BOOL(WINAPI *)(LPCWSTR, DWORD);

struct Library {
    HMODULE handle = nullptr;
    InstallLayoutOrTipFn install = nullptr;
    Library() {
        handle = LoadLibraryExW(L"input.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (handle) install = reinterpret_cast<InstallLayoutOrTipFn>(GetProcAddress(handle, "InstallLayoutOrTip"));
    }
    ~Library() { if (handle) FreeLibrary(handle); }
    Library(const Library &) = delete;
    Library &operator=(const Library &) = delete;
};

std::wstring lowered(std::wstring value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](wchar_t c) { return wchar_t(std::towlower(c)); });
    return value;
}

/* 该语言标签下的 InputMethodTips 是否已含本通道条目。读失败按「未包含」处理：
 * 后续启用仍会被系统的幂等写入兜住，不因为读不到就阻止启用。 */
bool containsTip(const std::wstring &languageKey, const std::wstring &tip) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, languageKey.c_str(), 0, KEY_QUERY_VALUE, &key) != ERROR_SUCCESS)
        return false;
    DWORD type = 0, size = 0;
    LONG status = RegQueryValueExW(key, L"InputMethodTips", nullptr, &type, nullptr, &size);
    if (status != ERROR_SUCCESS || type != REG_MULTI_SZ || size < sizeof(wchar_t) || size > 1u << 20) {
        RegCloseKey(key);
        return false;
    }
    std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 1, L'\0');
    status = RegQueryValueExW(key, L"InputMethodTips", nullptr, &type,
                              reinterpret_cast<BYTE *>(buffer.data()), &size);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS) return false;
    const std::wstring wanted = lowered(tip);
    for (const wchar_t *entry = buffer.data(); *entry; entry += wcslen(entry) + 1)
        if (lowered(entry) == wanted) return true;
    return false;
}

} // namespace

bool profileEnabled(const std::wstring &tip) {
    if (tip.empty()) return false;
    /* 键名是 BCP-47 语言标签（zh-Hans-CN 等），随系统语言包变化，不硬编码：
     * 枚举每个语言子键，逐个查 InputMethodTips。 */
    HKEY root = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kUserProfile, 0, KEY_ENUMERATE_SUB_KEYS, &root) != ERROR_SUCCESS)
        return false;
    bool found = false;
    for (DWORD index = 0; !found; ++index) {
        wchar_t name[256]{};
        DWORD length = DWORD(sizeof(name) / sizeof(wchar_t));
        if (RegEnumKeyExW(root, index, name, &length, nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS)
            break;
        found = containsTip(std::wstring(kUserProfile) + L"\\" + name, tip);
    }
    RegCloseKey(root);
    return found;
}

long enableProfile(const std::wstring &tip) {
    if (tip.empty()) return kEnableInvalidIdentity;
    if (profileEnabled(tip)) return 0;
    Library library;
    if (!library.install) return kEnableUnavailable;
    /* 单次调用；不做后台重试。返回 0 表示系统已接受这次启用请求。 */
    return library.install(tip.c_str(), 0) ? 0 : kEnableRejected;
}

long enableProfile() { return enableProfile(gogaku::profileTipString()); }

} // namespace gw
