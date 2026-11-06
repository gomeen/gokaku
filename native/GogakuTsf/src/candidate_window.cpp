#include "candidate_window.h"
#include <algorithm>
#include <windowsx.h>

namespace { constexpr wchar_t WindowClass[] = L"GogakuCandidateWindowV2"; }

bool CandidateWindow::create(HINSTANCE instance) {
    if (m_hwnd) return true;
    WNDCLASSW wc{}; wc.lpfnWndProc=s_wndProc; wc.hInstance=instance;
    wc.hIcon=LoadIconW(instance,MAKEINTRESOURCEW(101));
    wc.lpszClassName=WindowClass; wc.hCursor=LoadCursorW(nullptr,IDC_ARROW);
    if (!RegisterClassW(&wc) && GetLastError()!=ERROR_CLASS_ALREADY_EXISTS) return false;
    m_instance=instance;
    m_hwnd=CreateWindowExW(WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE|WS_EX_LAYERED,
        WindowClass,L"Gogaku 候选",WS_POPUP,0,0,1,1,nullptr,nullptr,instance,this);
    if (!m_hwnd) return false;
    m_renderer=std::make_unique<gw::CandidateRenderer>();
    return true;
}
void CandidateWindow::destroy() {
    if (m_hwnd) { KillTimer(m_hwnd,1); DestroyWindow(m_hwnd); m_hwnd=nullptr; }
    m_renderer.reset(); m_haveCaret=false;
}
void CandidateWindow::hide() {
    if (m_hwnd) { KillTimer(m_hwnd,1); ShowWindow(m_hwnd,SW_HIDE); }
    m_view=gw::Json::object();
}
void CandidateWindow::showView(const gw::Json &view,const RECT &caret,const gw::Json &settings) {
    if (!m_hwnd || !view.is_object()) return;
    KillTimer(m_hwnd,1);
    m_view=view; m_settings=settings; m_caret=caret; m_haveCaret=true;
    // Core normal snapshots use integer toast/english enums; public views may
    // already contain the display string. Normalize before entering the renderer.
    if (m_view.contains("toast") && m_view["toast"].is_number_integer()) {
        int code=m_view["toast"].get<int>();
        m_view["toast"]=code==1?"中":code==2?"英":"";
    }
    const bool visible=m_view.value("composing",false) || m_view.value("draftAvailable",false) ||
        !m_view.value("toast",std::string()).empty() ||
        (m_view.contains("candidates") && m_view["candidates"].is_array() && !m_view["candidates"].empty());
    if (!visible) { hide(); return; }
    redraw();
    if (!m_view.value("composing",false) && !m_view.value("draftAvailable",false) && !m_view.value("toast",std::string()).empty()) SetTimer(m_hwnd,1,800,nullptr);
}
void CandidateWindow::showCandidates(const GcSnapshot &snapshot,const RECT &caret) {
    gw::Json candidates=gw::Json::array();
    for (size_t i=0;i<snapshot.count && i<9;++i) candidates.push_back({
        {"text",snapshot.candidates[i].text?snapshot.candidates[i].text:""},
        {"gloss",snapshot.candidates[i].gloss?snapshot.candidates[i].gloss:""}});
    showView({{"composing",snapshot.count || (snapshot.preedit && *snapshot.preedit)},
        {"preedit",snapshot.preedit?snapshot.preedit:""},{"candidates",candidates},
        {"selected",snapshot.selected},{"page",snapshot.page},{"pageCount",snapshot.page_count}},caret,m_settings);
}
void CandidateWindow::showToast(const wchar_t *value) {
    // Never use mouse position or an unrelated window as a synthetic anchor.
    // The modern caller can show a first-use toast with showView + its caret.
    if (!m_hwnd || !m_haveCaret || !value) return;
    KillTimer(m_hwnd,1);
    m_view={{"toast",gw::utf8(value)},{"candidates",gw::Json::array()}};
    redraw(); SetTimer(m_hwnd,1,800,nullptr);
}
void CandidateWindow::redraw() {
    if (!m_renderer || !m_haveCaret) return;
    try {
        UINT dpi=GetDpiForWindow(m_hwnd); if (!dpi) dpi=96;
        m_renderer->render(m_view,gw::resolvedTheme(m_settings),gw::darkAppearance(),m_settings.value("candidateFontSize",14),dpi);
        auto size=m_renderer->size();
        MONITORINFO info{}; info.cbSize=sizeof(info);
        if (!GetMonitorInfoW(MonitorFromRect(&m_caret,MONITOR_DEFAULTTONEAREST),&info)) return;
        const auto work=info.rcWork;
        LONG x=m_caret.right+4,y=m_caret.bottom+2;
        if (x+size.cx>work.right) x=m_caret.left-size.cx;
        if (y+size.cy>work.bottom) y=m_caret.top-size.cy-2;
        x=std::max(work.left,std::min(x,work.right-size.cx));
        y=std::max(work.top,std::min(y,work.bottom-size.cy));
        POINT destination{x,y},source{};
        BLENDFUNCTION blend{AC_SRC_OVER,0,m_renderer->opacity(),AC_SRC_ALPHA};
        if (!UpdateLayeredWindow(m_hwnd,nullptr,&destination,&size,m_renderer->dc(),&source,0,&blend,ULW_ALPHA)) { ShowWindow(m_hwnd,SW_HIDE); return; }
        SetWindowPos(m_hwnd,HWND_TOPMOST,x,y,size.cx,size.cy,SWP_NOACTIVATE|SWP_SHOWWINDOW);
    } catch (...) {
        // Rendering failure cannot cross TSF COM boundaries or alter composition.
        ShowWindow(m_hwnd,SW_HIDE);
    }
}
LRESULT CALLBACK CandidateWindow::s_wndProc(HWND hwnd,UINT message,WPARAM wp,LPARAM lp) {
    if (message==WM_NCCREATE) {
        auto create=reinterpret_cast<CREATESTRUCTW *>(lp);
        SetWindowLongPtrW(hwnd,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto self=reinterpret_cast<CandidateWindow *>(GetWindowLongPtrW(hwnd,GWLP_USERDATA));
    if (message==WM_MOUSEACTIVATE) return MA_NOACTIVATE;
    if (message==WM_ERASEBKGND) return 1;
    if (message==WM_PAINT) { PAINTSTRUCT ps{}; BeginPaint(hwnd,&ps); EndPaint(hwnd,&ps); return 0; }
    if (!self) return DefWindowProcW(hwnd,message,wp,lp);
    switch (message) {
    case WM_TIMER: if (wp==1) self->hide(); return 0;
    case WM_LBUTTONUP:
        if (self->m_renderer) {
            const auto hit=self->m_renderer->hitTest({GET_X_LPARAM(lp),GET_Y_LPARAM(lp)});
            // Callbacks perform their own fresh focus/revision checks in TextService.
            // Do not SetFocus, SendInput, or directly mutate host text here.
            switch (hit.action) {
            case gw::CandidateRenderer::Action::Choose: { auto fn=self->onChoose; if (fn) fn(hit.index); break; }
            case gw::CandidateRenderer::Action::Original: { auto fn=self->onOriginal; if (fn) fn(); break; }
            case gw::CandidateRenderer::Action::Restore: { auto fn=self->onRestore; if (fn) fn(); break; }
            case gw::CandidateRenderer::Action::Explain:
                self->m_view["status"]=gw::utf8(hit.explanation.empty()?L"疑似拼写问题，不代表一定错误。":hit.explanation);
                self->redraw(); break;
            default: break;
            }
        }
        return 0;
    case WM_SETTINGCHANGE: case WM_THEMECHANGED: if (IsWindowVisible(hwnd)) self->redraw(); return 0;
    case WM_DPICHANGED: if (IsWindowVisible(hwnd)) self->redraw(); return 0;
    default: return DefWindowProcW(hwnd,message,wp,lp);
    }
}
