#pragma once
#include <windows.h>

// A missing InputScope is not permission to handle an arbitrary window. Only
// known native edit controls attached to this TSF document may use this fallback.
inline bool nativeEditFallbackSafe(HWND focus, HWND document) {
    if (!focus || !document || !IsWindowEnabled(focus)) return false;
    DWORD process = 0;
    DWORD thread = GetWindowThreadProcessId(focus, &process);
    if (process != GetCurrentProcessId() || thread != GetCurrentThreadId()) return false;
    if (focus != document && !IsChild(document, focus)) return false;
    wchar_t name[64]{};
    if (!GetClassNameW(focus, name, 64)) return false;
    if (_wcsicmp(name, L"Edit") && _wcsicmp(name, L"RichEdit20W") &&
        _wcsicmp(name, L"RICHEDIT50W") && _wcsicmp(name, L"RichEditD2DPT")) return false;
    if (GetWindowLongPtrW(focus, GWL_STYLE) & (ES_PASSWORD | ES_READONLY)) return false;
    // RichEdit supports password masking without relying on the creation style.
    DWORD_PTR password = 0;
    return SendMessageTimeoutW(focus, EM_GETPASSWORDCHAR, 0, 0,
                              SMTO_ABORTIFHUNG | SMTO_BLOCK, 50, &password) && !password;
}
