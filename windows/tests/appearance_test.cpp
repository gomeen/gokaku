// Windows 接缝自检：离屏 DIB、回退、页内命中和 UTF-16；不注入宿主按键。
#include "../GogakuWindows/appearance.h"
#include "../GogakuWindows/panel_frame.h"
#include <algorithm>
#include <cstdio>
#include <set>
#include <stdexcept>

namespace {
int failures = 0;
void expect(bool ok, const char *message) {
    if (!ok) { ++failures; std::fprintf(stderr, "FAIL: %s\n", message); }
}
using Renderer = gw::CandidateRenderer;
std::set<size_t> choices(const Renderer &renderer) {
    std::set<size_t> result;
    auto size = renderer.size();
    for (LONG y = 0; y < size.cy; ++y) for (LONG x = 0; x < size.cx; ++x) {
        auto hit = renderer.hitTest({x,y});
        if (hit.action == Renderer::Action::Choose) result.insert(hit.index);
    }
    return result;
}
bool has(const Renderer &renderer, Renderer::Action action, const std::wstring &explanation = {}) {
    auto size = renderer.size();
    for (LONG y = 0; y < size.cy; ++y) for (LONG x = 0; x < size.cx; ++x) {
        auto hit = renderer.hitTest({x,y});
        if (hit.action == action && (explanation.empty() || hit.explanation == explanation)) return true;
    }
    return false;
}
std::vector<BYTE> pixels(const Renderer &renderer) {
    DIBSECTION dib{};
    if (!GetObjectW(GetCurrentObject(renderer.dc(), OBJ_BITMAP), sizeof(dib), &dib) || !dib.dsBm.bmBits) return {};
    auto *bytes=static_cast<const BYTE *>(dib.dsBm.bmBits);
    return {bytes,bytes+size_t(renderer.size().cx)*renderer.size().cy*4};
}
void bitmap(const Renderer &renderer) {
    DIBSECTION dib{};
    expect(GetObjectW(GetCurrentObject(renderer.dc(), OBJ_BITMAP), sizeof(dib), &dib) != 0, "DIB accessible");
    if (!dib.dsBm.bmBits) return;
    const auto *p = static_cast<const BYTE *>(dib.dsBm.bmBits);
    bool green = false;
    for (size_t i = 0; i < size_t(renderer.size().cx) * renderer.size().cy; ++i, p += 4) {
        if (p[0] > p[3] || p[1] > p[3] || p[2] > p[3]) { expect(false, "BGRA premultiplied"); break; }
        if (p[0] == 53 && p[1] == 77 && p[2] == 9 && p[3] == 128) green = true;
    }
    expect(green, "RGBA swaps red/blue; shared whole opacity applied once");
}
}
int main() {
    try {
        auto offsets = gw::panelPreeditOffsets("你🙂hao", 8, 2);
        expect(offsets["preeditCaretUTF16"] == 4 && offsets["typedPrefixUTF16"] == 3, "UTF8 byte/scalar to UTF16");
        expect(gw::panelPreeditOffsets("你🙂hao", 4, 0)["preeditCaretUTF16"] == -1, "interior UTF8 byte is not a caret");
        auto theme = gw::builtinThemes().at(0);
        theme["light"]["visual"]["opacity"] = 50;
        theme["light"]["highlight"] = 0x12996a;
        Renderer renderer;
        auto view = gw::candidatePreview();
        view["page"] = 2; view["selected"] = 19;
        renderer.render(view, theme, false);
        expect(renderer.opacity() == 255, "default selects shared bitmap, no shell opacity");
        expect(choices(renderer) == std::set<size_t>({0,1,2,3,4,5,6,7,8}), "global page 2 chooses map to local 0..8");
        expect(!has(renderer, Renderer::Action::PagePrev) && !has(renderer, Renderer::Action::PageNext),
               "页码去掉后系统渲染路径不再产生翻页命中区（2026-11-20 裁决）");
        bitmap(renderer);
        const auto originalPixels=pixels(renderer);
        const auto originalTheme=theme;
        renderer.setTheme(theme);
        theme["light"]["highlight"]=0x22996a;
        expect(theme.dump().size()==originalTheme.dump().size(),"same-length theme mutation fixture");
        renderer.render(view,false);
        expect(pixels(renderer)==originalPixels,"prepared snapshot owns theme independently of caller mutation");
        renderer.setTheme(theme);renderer.render(view,false);
        expect(pixels(renderer)!=originalPixels&&renderer.opacity()==255,"same ID/length theme update invalidates bitmap theme");
        theme=originalTheme;renderer.setTheme(theme);renderer.render(view,false);
        expect(pixels(renderer)==originalPixels,"A/B/A update restores exact pixels");
        for (int size = 4; size <= 9; ++size) {
            auto horizontal = view; horizontal["selected"] = 2 * size + size - 1;
            for (auto &candidate : horizontal["candidates"]) candidate["text"] = std::string(100, 'W');
            renderer.render(horizontal, theme, false, 14, 144, {{"candidateLayout","horizontal"},{"horizontalPageSize",size}});
            expect(renderer.opacity() == 255, "horizontal stays on shared renderer");
            auto hits = choices(renderer);
            expect(hits.size() == size_t(size) && *hits.begin() == 0 && *hits.rbegin() == size_t(size-1), "horizontal clipped text retains every local hit");
            expect(renderer.size().cx <= 1290, "horizontal max width follows DPI");
        }
        auto learning = view; learning["learning"] = true; learning["composing"] = true;
        learning["preedit"] = "🙂 metting"; learning["direction"] = "enToZh";
        learning["draftAvailable"] = true;
        learning["issues"] = gw::Json::array({{{"location",3},{"length",7},{"explanation","疑似拼写"}}});
        renderer.render(learning, theme, false);
        expect(has(renderer, Renderer::Action::Original) && has(renderer, Renderer::Action::Restore), "original and restore");
        expect(has(renderer, Renderer::Action::Explain, L"疑似拼写"), "UTF16 explain maps issue index");
        renderer.render({{"toast","中"},{"pageCount",0}}, theme, false);
        expect(renderer.opacity() == 255 && choices(renderer).empty(), "empty-page toast normalizes to valid shared frame");
        renderer.render(view, theme, false, 14, 96, {{"candidateRenderer","system"}});
        expect(renderer.opacity() == 128 && choices(renderer).size() == 9, "explicit D2D fallback");
        auto invalid = view; invalid["pageCount"] = 1000002;
        renderer.render(invalid, theme, false);
        expect(renderer.opacity() == 128 && choices(renderer).size() == 9, "shared range failure automatically uses D2D");
    } catch (const std::exception &e) { std::fprintf(stderr,"FAIL: %s\n",e.what()); return 1; }
    std::printf("windows appearance: %s\n", failures ? "FAILED" : "passed");
    return failures ? 1 : 0;
}
