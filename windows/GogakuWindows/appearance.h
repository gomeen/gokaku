#pragma once
#include "platform.h"
#include <memory>

namespace gw {
bool darkAppearance();
// Coordinates/hit targets are physical pixels; page indices are strictly page-local.
// The shared renderer is preferred; Direct2D remains the explicit system renderer
// and automatic fallback when a shared bitmap cannot be produced.
class CandidateRenderer {
public:
    enum class Action { None, Choose, Original, Restore, Explain, PagePrev, PageNext };
    struct Hit { Action action = Action::None; size_t index = 0; std::wstring explanation; };
    CandidateRenderer();
    ~CandidateRenderer();
    CandidateRenderer(const CandidateRenderer &) = delete;
    CandidateRenderer &operator=(const CandidateRenderer &) = delete;
    // 在设置/草稿更新时调用；逐帧使用不带 theme 的 render 重载。
    void setTheme(const Json &theme);
    void render(const Json &view, bool dark, int legacyFontSize = 14, UINT dpi = 96,
                const Json &settings = Json::object());
    void render(const Json &view, const Json &theme, bool dark, int legacyFontSize = 14, UINT dpi = 96,
                const Json &settings = Json::object());
    HDC dc() const;
    SIZE size() const;
    BYTE opacity() const;
    Hit hitTest(POINT point) const;
    void paint(HDC destination, int x, int y) const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
Json candidatePreview(); // explicitly nine layout samples, never model results
} // namespace gw
