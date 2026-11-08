#pragma once
#include "platform.h"
#include <memory>

namespace gw {
bool darkAppearance();
// The same Direct2D/DirectWrite renderer backs the real non-activating panel and
// settings previews. Coordinates/hit targets are physical pixels; page indices
// are strictly page-local. No renderer operation inserts into a host.
class CandidateRenderer {
public:
    enum class Action { None, Choose, Original, Restore, Explain };
    struct Hit { Action action = Action::None; size_t index = 0; std::wstring explanation; };
    CandidateRenderer();
    ~CandidateRenderer();
    CandidateRenderer(const CandidateRenderer &) = delete;
    CandidateRenderer &operator=(const CandidateRenderer &) = delete;
    void render(const Json &view, const Json &theme, bool dark, int legacyFontSize = 14, UINT dpi = 96);
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
