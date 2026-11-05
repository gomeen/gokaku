/* 非激活候选窗（Win32，计划约束：不位于按键性能链、永不夺焦点）。
 * WS_EX_NOACTIVATE + WM_MOUSEACTIVATE 返回 MA_NOACTIVATE。
 * 显示：预编辑行＋本页候选（序号＋词＋释义），高亮选中项；Shift 提示模式
 * 显示单个大字气泡（「中」/「英」）。 */
#pragma once

#include "stdafx.h"

class CandidateWindow {
public:
    bool create(HINSTANCE hInst);  /* 每线程一次 */
    void destroy();
    bool valid() const { return m_hwnd != nullptr; }

    void showCandidates(const GcSnapshot &snap, const RECT &caretRect);
    void showToast(const wchar_t *text);
    void hide();

private:
    static LRESULT CALLBACK s_wndProc(HWND, UINT, WPARAM, LPARAM);
    LRESULT onPaint();
    void layout(const RECT &caretRect);

    HWND m_hwnd = nullptr;
    HFONT m_font = nullptr, m_smallFont = nullptr;
    std::vector<std::wstring> m_words, m_glosses;
    std::wstring m_preedit;
    size_t m_selected = 0;
    size_t m_page = 0, m_pageCount = 0;
    bool m_toast = false;
};
