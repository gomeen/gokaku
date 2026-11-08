// Thread-local non-activating candidate panel. It never inserts host content.
#pragma once
#include "stdafx.h"
#include "../../GogakuWindows/appearance.h"
#include <memory>

class CandidateWindow {
public:
    bool create(HINSTANCE instance);
    void destroy();
    bool valid() const { return m_hwnd != nullptr; }
    void hide();
    void showToast(const wchar_t *text);
    void showToast(const std::wstring &text) { showToast(text.c_str()); }
    void showView(const gw::Json &view, const RECT &caret, const gw::Json &settings);
    // Compatibility only. The agent-backed TextService should use showView.
    void showCandidates(const GcSnapshot &snapshot, const RECT &caret);
    std::function<void(size_t)> onChoose; // page-local index 0...8
    std::function<void()> onOriginal;
    std::function<void()> onRestore;      // explicit draft restore only
private:
    static LRESULT CALLBACK s_wndProc(HWND, UINT, WPARAM, LPARAM);
    void redraw();
    HWND m_hwnd = nullptr;
    HINSTANCE m_instance = nullptr;
    std::unique_ptr<gw::CandidateRenderer> m_renderer;
    gw::Json m_view = gw::Json::object(), m_settings = gw::Json::object();
    RECT m_caret{};
    bool m_haveCaret = false;
};
