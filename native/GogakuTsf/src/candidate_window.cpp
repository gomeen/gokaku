#include "candidate_window.h"

#include <algorithm>

namespace {
const wchar_t *KWndClass = L"GogakuCandidateWindow";
const int KLineH = 30;
const int KPreeditH = 26;
const int KPadX = 12;
const int KGlossMax = 24; /* 释义最多显示的 UTF-16 单元数 */
}

bool CandidateWindow::create(HINSTANCE hInst) {
    if (m_hwnd) return true;
    WNDCLASSW wc{};
    wc.lpfnWndProc = s_wndProc;
    wc.hInstance = hInst;
    wc.lpszClassName = KWndClass;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = nullptr;
    if (!RegisterClassW(&wc)) return false;
    m_hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                             KWndClass, L"", WS_POPUP, 0, 0, 10, 10,
                             nullptr, nullptr, hInst, nullptr);
    if (!m_hwnd) return false;
    SetWindowLongPtrW(m_hwnd, GWLP_USERDATA, (LONG_PTR)this);
    m_font = CreateFontW(-16, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                         OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                         DEFAULT_PITCH, L"Microsoft YaHei UI");
    m_smallFont = CreateFontW(-12, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                              OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                              DEFAULT_PITCH, L"Microsoft YaHei UI");
    return true;
}

void CandidateWindow::destroy() {
    if (m_hwnd) {
        DestroyWindow(m_hwnd);
        m_hwnd = nullptr;
    }
    if (m_font) { DeleteObject(m_font); m_font = nullptr; }
    if (m_smallFont) { DeleteObject(m_smallFont); m_smallFont = nullptr; }
}

void CandidateWindow::showCandidates(const GcSnapshot &snap, const RECT &caretRect) {
    if (!m_hwnd) return;
    m_toast = false;
    m_preedit = Utf8ToUtf16(snap.preedit ? snap.preedit : "");
    m_words.clear();
    m_glosses.clear();
    /* snap.selected 为全局下标；面板高亮需页内下标（整页满时换算精确）。 */
    const size_t pageStart = snap.page * snap.count;
    m_selected = (snap.selected >= pageStart && snap.selected < pageStart + snap.count)
                     ? snap.selected - pageStart : 0;
    m_page = snap.page;
    m_pageCount = snap.page_count;
    for (size_t i = 0; i < snap.count && i < 100; ++i) {
        m_words.push_back(Utf8ToUtf16(snap.candidates[i].text ? snap.candidates[i].text : ""));
        std::wstring g = Utf8ToUtf16(snap.candidates[i].gloss ? snap.candidates[i].gloss : "");
        if ((int)g.size() > KGlossMax) g = g.substr(0, KGlossMax) + L"…";
        m_glosses.push_back(g);
    }
    layout(caretRect);
    InvalidateRect(m_hwnd, nullptr, TRUE);
    if (!m_words.empty() || !m_preedit.empty()) ShowWindow(m_hwnd, SW_SHOWNOACTIVATE);
    else ShowWindow(m_hwnd, SW_HIDE);
}

void CandidateWindow::showToast(const wchar_t *text) {
    if (!m_hwnd) return;
    m_toast = true;
    m_words.clear();
    m_glosses.clear();
    m_preedit = text;
    RECT r = {0, 0, 64, 64};
    layout(r);
    InvalidateRect(m_hwnd, nullptr, TRUE);
    ShowWindow(m_hwnd, SW_SHOWNOACTIVATE);
    SetTimer(m_hwnd, 1, 800, nullptr); /* WM_TIMER → 隐藏（见 wndProc） */
}

void CandidateWindow::hide() {
    if (m_hwnd) {
        KillTimer(m_hwnd, 1);
        ShowWindow(m_hwnd, SW_HIDE);
    }
}

void CandidateWindow::layout(const RECT &caretRect) {
    if (!m_hwnd) return;
    HDC dc = GetDC(m_hwnd);
    HFONT old = (HFONT)SelectObject(dc, m_font);
    int maxW = 120;
    wchar_t tmp[64];
    if (!m_toast) {
        for (size_t i = 0; i < m_words.size(); ++i) {
            std::wstring line = std::to_wstring(i + 1) + L" " + m_words[i];
            if (!m_glosses[i].empty()) line += L"  " + m_glosses[i];
            SIZE sz{};
            GetTextExtentPoint32W(dc, line.c_str(), (int)line.size(), &sz);
            maxW = std::max(maxW, (int)sz.cx);
        }
        swprintf_s(tmp, L"%zu/%zu", m_page + 1, m_pageCount ? m_pageCount : 1);
        SIZE sz{};
        SelectObject(dc, m_smallFont);
        GetTextExtentPoint32W(dc, tmp, (int)wcslen(tmp), &sz);
        maxW = std::max(maxW, (int)sz.cx + 2 * KPadX);
        SelectObject(dc, m_font);
    } else {
        maxW = 64;
    }
    SelectObject(dc, old);
    ReleaseDC(m_hwnd, dc);

    int w = maxW + 2 * KPadX + 8;
    int h = m_toast ? 56
                    : KPadX + (m_preedit.empty() ? 0 : KPreeditH) +
                          KLineH * (int)m_words.size() + KPadX + 20;
    RECT work{};
    HMONITOR mon = MonitorFromRect(&caretRect, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi{sizeof(mi)};
    GetMonitorInfoW(mon, &mi);
    work = mi.rcWork;
    int x = caretRect.right + 4, y = caretRect.bottom + 2;
    if (x + w > work.right) x = caretRect.left - w;
    if (x < work.left) x = work.left;
    if (y + h > work.bottom) y = caretRect.top - h - 2;
    if (y < work.top) y = work.top;
    SetWindowPos(m_hwnd, HWND_TOPMOST, x, y, w, h,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

LRESULT CALLBACK CandidateWindow::s_wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_TIMER) {
        KillTimer(hwnd, 1);
        ShowWindow(hwnd, SW_HIDE);
        return 0;
    }
    if (msg == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    CandidateWindow *self = (CandidateWindow *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    switch (msg) {
    case WM_PAINT:
        return self ? self->onPaint() : DefWindowProcW(hwnd, msg, wp, lp);
    case WM_ERASEBKGND:
        return 1;
    default:
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
}

LRESULT CandidateWindow::onPaint() {
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(m_hwnd, &ps);
    RECT rc;
    GetClientRect(m_hwnd, &rc);
    FillRect(dc, &rc, (HBRUSH)GetStockObject(WHITE_BRUSH));
    SetBkMode(dc, TRANSPARENT);
    SelectObject(dc, m_font);

    if (m_toast) {
        SetTextColor(dc, RGB(40, 40, 40));
        HFONT big = CreateFontW(-32, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
                                OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                                DEFAULT_PITCH, L"Microsoft YaHei UI");
        HFONT old = (HFONT)SelectObject(dc, big);
        RECT rr = rc;
        DrawTextW(dc, m_preedit.c_str(), -1, &rr,
                  DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        SelectObject(dc, old);
        DeleteObject(big);
        EndPaint(m_hwnd, &ps);
        return 0;
    }

    int y = KPadX / 2;
    if (!m_preedit.empty()) {
        SelectObject(dc, m_smallFont);
        SetTextColor(dc, RGB(120, 120, 120));
        TextOutW(dc, KPadX, y, m_preedit.c_str(), (int)m_preedit.size());
        y += KPreeditH;
        SelectObject(dc, m_font);
    }
    for (size_t i = 0; i < m_words.size(); ++i) {
        bool sel = (i == m_selected);
        std::wstring line = std::to_wstring(i + 1) + L"  " + m_words[i];
        if (!m_glosses[i].empty()) line += L"  " + m_glosses[i];
        int lineW = rc.right - 2 * KPadX;
        if (sel) {
            RECT hl = {KPadX - 4, y, rc.right - KPadX + 2, y + KLineH};
            HBRUSH b = CreateSolidBrush(RGB(0, 122, 255));
            FillRect(dc, &hl, b);
            DeleteObject(b);
            SetTextColor(dc, RGB(255, 255, 255));
        } else {
            SetTextColor(dc, RGB(30, 30, 30));
        }
        TextOutW(dc, KPadX, y + (KLineH - 20) / 2, line.c_str(), (int)line.size());
        y += KLineH;
    }
    /* 页码 */
    wchar_t tmp[64];
    swprintf_s(tmp, L"%zu/%zu", m_page + 1, m_pageCount ? m_pageCount : 1);
    SelectObject(dc, m_smallFont);
    SetTextColor(dc, RGB(160, 160, 160));
    TextOutW(dc, KPadX, rc.bottom - 18, tmp, (int)wcslen(tmp));
    EndPaint(m_hwnd, &ps);
    return 0;
}
