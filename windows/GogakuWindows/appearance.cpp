#include "appearance.h"
#include <d2d1.h>
#include <dwrite.h>
#include <wincodec.h>
#include "../../shared/GogakuCore/panel_render.h"
#include <algorithm>
#include <cmath>
#include <cwctype>
#include <map>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace gw {
namespace {
template<class T> struct Com {
    T *p = nullptr;
    ~Com() { reset(); }
    void reset() { if (p) p->Release(); p = nullptr; }
    T **out() { reset(); return &p; }
    T *operator->() const { return p; }
};
void check(HRESULT hr, const char *message) { if (FAILED(hr)) throw std::runtime_error(message); }
std::wstring text(const Json &j, const char *key) {
    return j.contains(key) && j[key].is_string() ? wide(j[key].get<std::string>()) : L"";
}
D2D1_COLOR_F color(const Json &palette, const char *key, float alpha = 1) {
    uint32_t c = palette.value(key, 0u);
    return D2D1::ColorF(float((c >> 16) & 255) / 255, float((c >> 8) & 255) / 255, float(c & 255) / 255, alpha);
}
struct Target { RECT rect{}; CandidateRenderer::Hit hit; };
RECT pixels(D2D1_RECT_F r, float scale) { return {LONG(std::floor(r.left * scale)), LONG(std::floor(r.top * scale)), LONG(std::ceil(r.right * scale)), LONG(std::ceil(r.bottom * scale))}; }
struct FontFile {
    std::string path;
    int index = -1;
    explicit operator bool() const { return !path.empty() && index >= 0; }
};
std::mutex fontCacheMutex;
std::map<std::wstring, FontFile> fontCache;
std::wstring cacheKey(std::wstring name) {
    std::transform(name.begin(), name.end(), name.begin(), [](wchar_t c) { return (wchar_t)towlower(c); });
    return name;
}
FontFile localFile(IDWriteFontFace *face) {
    UINT32 count = 0;
    face->GetFiles(&count, nullptr);
    if (!count || count > 16) return {};
    std::vector<IDWriteFontFile *> files(count, nullptr);
    if (FAILED(face->GetFiles(&count, files.data()))) return {};
    FontFile result;
    for (auto *file : files) {
        if (!file) continue;
        Com<IDWriteFontFileLoader> loader; file->GetLoader(loader.out());
        Com<IDWriteLocalFontFileLoader> local;
        if (loader.p && SUCCEEDED(loader->QueryInterface(__uuidof(IDWriteLocalFontFileLoader), reinterpret_cast<void **>(local.out())))) {
            const void *key = nullptr; UINT32 keySize = 0, length = 0;
            if (SUCCEEDED(file->GetReferenceKey(&key, &keySize)) &&
                SUCCEEDED(local->GetFilePathLengthFromKey(key, keySize, &length)) && length < 32768) {
                std::wstring path(size_t(length) + 1, L'\0');
                if (SUCCEEDED(local->GetFilePathFromKey(key, keySize, path.data(), length + 1))) {
                    path.resize(length);
                    result.path = utf8(path);
                    result.index = static_cast<int>(face->GetIndex());
                }
            }
        }
        file->Release();
    }
    return result;
}
FontFile familyFile(IDWriteFactory *factory, const std::wstring &familyName) {
    const auto key = cacheKey(L"family:" + familyName);
    { std::lock_guard<std::mutex> lock(fontCacheMutex); auto it = fontCache.find(key); if (it != fontCache.end()) return it->second; }
    Com<IDWriteFontCollection> collection;
    if (FAILED(factory->GetSystemFontCollection(collection.out()))) return {};
    UINT32 position = 0; BOOL exists = FALSE;
    if (FAILED(collection->FindFamilyName(familyName.c_str(), &position, &exists)) || !exists) {
        std::lock_guard<std::mutex> lock(fontCacheMutex); fontCache[key] = {}; return {};
    }
    Com<IDWriteFontFamily> family; Com<IDWriteFont> font; Com<IDWriteFontFace> face;
    if (FAILED(collection->GetFontFamily(position, family.out())) ||
        FAILED(family->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                            DWRITE_FONT_STYLE_NORMAL, font.out())) ||
        FAILED(font->CreateFontFace(face.out()))) return {};
    auto found = localFile(face.p);
    if (found) { std::lock_guard<std::mutex> lock(fontCacheMutex); fontCache[key] = found; }
    return found;
}
std::wstring normalizedFamily(const std::string &family, bool latin) {
    if (family.empty() || family == "system-ui") return latin ? L"Segoe UI" : L"Microsoft YaHei UI";
    return wide(family);
}
}

bool darkAppearance() {
    DWORD light = 1, size = sizeof(light);
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size);
    return light == 0;
}

struct CandidateRenderer::Impl {
    Com<ID2D1Factory> d2d;
    Com<IDWriteFactory> write;
    Com<IWICImagingFactory> wic;
    Com<IDWriteTextFormat> cn, en, small, index;
    Com<IWICBitmap> backgroundImage;
    std::string imageKey, fontKey;
    Json theme = Json::object();
    std::unique_ptr<GcPanelTheme, decltype(&gc_panel_theme_free)> preparedTheme{nullptr,gc_panel_theme_free};
    void setTheme(const Json &value) {
        if (theme == value) return; // 完整内容比较，只发生在设置/预览更新。
        preparedTheme.reset(); backgroundImage.reset(); std::string().swap(imageKey);
        theme = value;
    }
    HDC memory = nullptr;
    HBITMAP bitmap = nullptr, previous = nullptr;
    SIZE extent{};
    BYTE alpha = 255;
    float scale = 1;
    std::vector<Target> targets;
    HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ~Impl() {
        if (memory) { if (previous) SelectObject(memory, previous); DeleteDC(memory); }
        if (bitmap) DeleteObject(bitmap);
        backgroundImage.reset(); cn.reset(); en.reset(); small.reset(); index.reset();
        wic.reset(); write.reset(); d2d.reset();
        if (SUCCEEDED(apartment)) CoUninitialize();
    }
    void factories() {
        if (!d2d.p) check(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d.out()), "Direct2D 初始化失败。");
        if (!write.p) check(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown **>(write.out())), "DirectWrite 初始化失败。");
        if (!wic.p) check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(wic.out())), "WIC 初始化失败。");
    }
    std::wstring font(std::string family, bool latin) {
        auto fallback = latin ? L"Segoe UI" : L"Microsoft YaHei UI";
        if (family.empty() || family == "system-ui") return fallback;
        Com<IDWriteFontCollection> collection;
        check(write->GetSystemFontCollection(collection.out()), "无法读取系统字体。");
        auto name = wide(family); UINT32 position = 0; BOOL exists = FALSE;
        if (SUCCEEDED(collection->FindFamilyName(name.c_str(), &position, &exists)) && exists) return name;
        // Unknown names use a deterministic local fallback, never download fonts.
        return fallback;
    }
    void format(Com<IDWriteTextFormat> &out, const std::wstring &family, float size) {
        check(write->CreateTextFormat(family.c_str(), nullptr, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL, size, L"zh-CN", out.out()), "无法建立候选字体。");
        out->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        out->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    }
    void fonts(const Json &theme, int legacy) {
        const auto type = theme.value("typography", Json::object());
        const bool old = theme.value("id", std::string()) == "rime-macos-like";
        float fs = old ? float(std::clamp(legacy, 12, 16)) : type.value("fontSize", 14.0f);
        float is = old ? fs - 3 : type.value("indexSize", 11.0f);
        auto key = type.dump() + std::to_string(old ? legacy : 0);
        if (key == fontKey && cn.p) return;
        auto chinese = font(type.value("fontCN", std::string("system-ui")), false);
        auto english = font(type.value("fontEN", std::string("system-ui")), true);
        format(cn, chinese, fs * 4 / 3); format(en, english, std::max(8.0f, fs - (old ? 1.0f : 2.0f)) * 4 / 3);
        format(small, chinese, std::max(8.0f, fs - 1) * 4 / 3); format(index, english, is * 4 / 3);
        fontKey = key;
    }
    IDWriteTextLayout *layout(const std::wstring &value, IDWriteTextFormat *format, float width, float height, bool wrap = false) {
        IDWriteTextLayout *result = nullptr;
        check(write->CreateTextLayout(value.c_str(), UINT32(value.size()), format, width, height, &result), "无法排版候选文字。");
        result->SetWordWrapping(wrap ? DWRITE_WORD_WRAPPING_WRAP : DWRITE_WORD_WRAPPING_NO_WRAP);
        return result;
    }
    float measure(const std::wstring &s, IDWriteTextFormat *format) {
        Com<IDWriteTextLayout> line; line.p = layout(s, format, 4096, 80);
        DWRITE_TEXT_METRICS metrics{}; line->GetMetrics(&metrics); return metrics.widthIncludingTrailingWhitespace;
    }
    void image(const Json &palette) {
        std::string key = palette.contains("imageData") && palette["imageData"].is_string() ? palette["imageData"].get<std::string>() : "";
        if (key == imageKey) return;
        backgroundImage.reset(); imageKey = key;
        if (key.empty()) return;
        // Decode once per theme update; ordinary keystroke layout reuses pixels.
        const auto data = base64Decode(key);
        if (data.empty() || data.size() > 8 * 1024 * 1024) throw std::runtime_error("背景图片无效。");
        Com<IWICStream> input; check(wic->CreateStream(input.out()), "无法读取背景图片。");
        check(input->InitializeFromMemory(reinterpret_cast<BYTE *>(const_cast<char *>(data.data())), DWORD(data.size())), "背景图片流无效。");
        Com<IWICBitmapDecoder> decoder;
        check(wic->CreateDecoderFromStream(input.p, nullptr, WICDecodeMetadataCacheOnLoad, decoder.out()), "背景图片无法实际解码。");
        UINT count = 0; check(decoder->GetFrameCount(&count), "无法读取背景帧数。");
        if (count != 1) throw std::runtime_error("背景图片必须是单帧。");
        Com<IWICBitmapFrameDecode> frame; check(decoder->GetFrame(0, frame.out()), "背景图片损坏。");
        UINT w=0,h=0; check(frame->GetSize(&w,&h), "背景尺寸无效。");
        if (!w || !h || w>4096 || h>4096) throw std::runtime_error("背景图片超过尺寸限制。");
        Com<IWICFormatConverter> converted; check(wic->CreateFormatConverter(converted.out()), "无法转换背景图片。");
        check(converted->Initialize(frame.p, GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom), "背景像素格式无效。");
        check(wic->CreateBitmapFromSource(converted.p, WICBitmapCacheOnLoad, backgroundImage.out()), "背景像素解码失败。");
    }
    void surface(int w, int h) {
        if (extent.cx == w && extent.cy == h && bitmap) return;
        if (!memory) memory = CreateCompatibleDC(nullptr);
        if (!memory) throw std::runtime_error("无法创建候选绘图设备。");
        if (bitmap) { SelectObject(memory, previous); DeleteObject(bitmap); bitmap = nullptr; }
        BITMAPINFO info{}; info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER); info.bmiHeader.biWidth=w;
        info.bmiHeader.biHeight=-h; info.bmiHeader.biPlanes=1; info.bmiHeader.biBitCount=32; info.bmiHeader.biCompression=BI_RGB;
        void *bits=nullptr; bitmap=CreateDIBSection(memory,&info,DIB_RGB_COLORS,&bits,nullptr,0);
        if (!bitmap) throw std::runtime_error("无法创建候选像素缓冲。");
        previous=static_cast<HBITMAP>(SelectObject(memory,bitmap)); extent={w,h};
    }
    void addFont(Json &fonts, const std::wstring &name, bool emoji, const char *role = nullptr) {
        auto face = familyFile(write.p, name);
        if (!face) return;
        for (auto &existing : fonts) {
            if (existing.value("path", std::string()) == face.path && existing.value("index", -2) == face.index &&
                existing.value("emoji", false) == emoji) {
                if (role) existing["role"] = role;
                return;
            }
        }
        Json entry{{"path", face.path}, {"index", face.index}, {"emoji", emoji}};
        if (role) entry["role"] = role;
        fonts.push_back(std::move(entry));
    }
    void renderBitmap(const Json &view, const Json &theme, bool dark, int legacy, UINT dpi, const Json &settings) {
        if (!write.p) check(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory), reinterpret_cast<IUnknown **>(write.out())), "DirectWrite 初始化失败。");
        Json type = theme.value("typography", Json::object());
        Json fontList = Json::array();
        addFont(fontList, normalizedFamily(type.value("fontCN", std::string("system-ui")), false), false);
        addFont(fontList, normalizedFamily(type.value("fontEN", std::string("system-ui")), true), false, "latin");
        for (const auto *name : {L"Microsoft YaHei UI", L"Segoe UI", L"Arial"}) addFont(fontList, name, false);
        addFont(fontList, L"Segoe UI Emoji", true);
        if (fontList.empty()) throw std::runtime_error("无法定位可用的本地字体。");

        const bool learning = view.value("learning", false);
        const bool horizontal = !learning && settings.value("candidateLayout", std::string()) == "horizontal";
        // 竖排每页数量可配置（4–9，默认 9；2026-11-19 裁决）。
        const int pageSize = horizontal
            ? std::clamp(settings.value("horizontalPageSize", 7), 4, 9)
            : std::clamp(settings.value("verticalPageSize", 9), 4, 9);
        Json candidates = view.value("candidates", Json::array());
        if (!candidates.is_array()) candidates = Json::array();
        if (candidates.size() > size_t(pageSize)) candidates.erase(candidates.begin() + pageSize, candidates.end());
        if (!learning && !settings.value("glossEnabled", true))
            for (auto &candidate : candidates) candidate["gloss"] = "";
#ifdef GOGAKU_LITE
        for (auto &candidate : candidates) candidate["gloss"] = "";
#endif
        const size_t visibleCandidates = candidates.size();
        std::string direction = settings.value("preferredDirection", std::string("zhToEn"));
        if (view.contains("direction")) {
            if (view["direction"].is_string()) direction = view["direction"].get<std::string>();
            else if (view["direction"].is_number_integer()) direction = view["direction"].get<int>() == 1 ? "enToZh" : "zhToEn";
        }
        Json frame = {{"fonts", std::move(fontList)}, {"candidates", std::move(candidates)},
                      {"selected", view.value("selected", size_t(0))},
                      {"page", view.value("page", size_t(0))},
                      {"pageCount", std::max(size_t(1), view.value("pageCount", size_t(1)))},
                      {"pageSize", pageSize}, {"layout", horizontal ? "horizontal" : "vertical"},
                      {"glossRow", horizontal && settings.value("glossEnabled", true)},
                      {"fontSize", std::clamp(legacy, 12, 16)},
                      {"preedit", view.value("preedit", std::string())},
                      {"preeditCaretUTF16", view.value("preeditCaretUTF16", -1)},
                      {"typedPrefixUTF16", view.value("typedPrefixUTF16", 0)},
                      {"learning", learning}, {"direction", direction},
                      {"status", view.value("status", std::string())}, {"toast", view.value("toast", std::string())},
                      {"hasOriginal", view.value("hasOriginal", learning && (visibleCandidates || !text(view,"preedit").empty() || !text(view,"raw").empty()))},
                      {"hasRestore", view.value("hasRestore", view.value("draftAvailable", false))},
                      {"issues", view.value("issues", Json::array())}};
        if (frame["preedit"].get<std::string>().empty()) frame["preedit"] = view.value("raw", std::string());
        if (view.value("pending", false) && frame["status"].get<std::string>().empty()) frame["status"] = "翻译处理中…";
        const auto frameText = frame.dump();
        if (!preparedTheme) {
            const auto themeText = theme.dump(); // 仅主题更新后的第一次渲染序列化。
            GcPanelTheme *rawTheme = nullptr;
            const auto code = gc_panel_theme_create(themeText.data(),themeText.size(),&rawTheme);
            preparedTheme.reset(rawTheme);
            if (code || !preparedTheme) throw std::runtime_error("共享候选主题准备失败。");
        }
        GcPanelResult *raw = nullptr;
        const int32_t code = gc_panel_render_prepared(frameText.data(), frameText.size(), preparedTheme.get(),
                                                       double(dpi ? dpi : 96) / 96.0, dark ? 1 : 0, &raw);
        std::unique_ptr<GcPanelResult, decltype(&gc_panel_result_free)> result(raw, gc_panel_result_free);
        if (code || !result || !result->pixels || result->width <= 0 || result->height <= 0)
            throw std::runtime_error("共享候选位图渲染失败。");
        surface(result->width, result->height);
        DIBSECTION section{};
        if (!GetObjectW(bitmap, sizeof(section), &section)) throw std::runtime_error("无法访问候选像素缓冲。");
        auto *dst = static_cast<uint8_t *>(section.dsBm.bmBits);
        const size_t count = size_t(result->width) * size_t(result->height);
        for (size_t i = 0; i < count; ++i) {
            const auto *src = result->pixels + i * 4;
            dst[i * 4] = src[2]; dst[i * 4 + 1] = src[1]; dst[i * 4 + 2] = src[0]; dst[i * 4 + 3] = src[3];
        }
        targets.clear();
        const int64_t pageBase = int64_t(view.value("page", size_t(0))) * pageSize;
        for (size_t i = 0; i < result->hit_count; ++i) {
            const auto &source = result->hits[i];
            Hit hit;
            if (source.action == GC_PANEL_HIT_CHOOSE) {
                const int64_t local = int64_t(source.arg) - pageBase;
                if (local < 0 || size_t(local) >= visibleCandidates) continue;
                hit.action = Action::Choose;
                hit.index = size_t(local);
            } else if (source.action == GC_PANEL_HIT_ORIGINAL) hit.action = Action::Original;
            else if (source.action == GC_PANEL_HIT_RESTORE) hit.action = Action::Restore;
            else if (source.action == GC_PANEL_HIT_PAGE_PREV) hit.action = Action::PagePrev;
            else if (source.action == GC_PANEL_HIT_PAGE_NEXT) hit.action = Action::PageNext;
            else if (source.action == GC_PANEL_HIT_EXPLAIN) {
                if (!view.contains("issues") || !view["issues"].is_array() || source.arg < 0 || size_t(source.arg) >= view["issues"].size()) continue;
                hit.action = Action::Explain;
                hit.index = size_t(source.arg);
                hit.explanation = text(view["issues"][hit.index], "explanation");
            } else continue;
            RECT rect{source.x, source.y, source.x + source.w, source.y + source.h};
            targets.push_back({rect, std::move(hit)});
        }
        alpha = 255;
    }
    void render(const Json &view, const Json &theme, bool dark, int legacy, UINT dpi, const Json &settings) {
        if (settings.value("candidateRenderer", std::string()) == "system") {
            renderSystem(view, theme, dark, legacy, dpi, settings);
            return;
        }
        try {
            renderBitmap(view, theme, dark, legacy, dpi, settings);
        } catch (...) {
            renderSystem(view, theme, dark, legacy, dpi, settings);
        }
    }
    void renderSystem(const Json &view, const Json &theme, bool dark, int legacy, UINT dpi, const Json &settings) {
        factories(); fonts(theme, legacy); targets.clear();
        const auto &palette = dark && theme.contains("dark") && theme["dark"].is_object() ? theme["dark"] : theme.at("light");
        auto visual=palette.value("visual",Json::object());
        const bool old=theme.value("id",std::string())=="rime-macos-like";
        float pad=old?8.0f:visual.value("padding",8.0f), radius=old?8.0f:visual.value("radius",8.0f);
        float row=old?46.0f*std::clamp(legacy,12,16)/21.0f:30.0f*visual.value("rowHeight",100.0f)/100;
        scale=float(dpi?dpi:96)/96; alpha=BYTE(std::lround(visual.value("opacity",100.0)*255/100));
        auto candidates=view.value("candidates",Json::array()); if (!candidates.is_array()) candidates=Json::array();
        const size_t count=std::min<size_t>(9,candidates.size());
        auto preedit=text(view,"preedit"); if (preedit.empty()) preedit=text(view,"raw");
        auto toast=text(view,"toast"); bool toastOnly=!toast.empty() && preedit.empty() && !count && !view.value("draftAvailable",false);
        auto status=text(view,"status");
        if (view.value("pending",false) && status.empty()) status=L"翻译处理中…";
        if (!toast.empty() && !toastOnly) status=toast;
        bool learning=view.value("learning",false), draft=view.value("draftAvailable",false);
        // 页码自 2026-11-20 起不绘制；page 仍参与页内下标换算。
        size_t page=view.value("page",size_t(0));
        size_t selected=view.value("selected",size_t(0));
        const bool horizontal=!learning && settings.value("candidateLayout",std::string())=="horizontal";
        const size_t psz=horizontal
            ?size_t(std::clamp(settings.value("horizontalPageSize",7),4,9))
            :size_t(std::clamp(settings.value("verticalPageSize",9),4,9));
        size_t local=selected>=page*psz?selected-page*psz:0;
        if (count && local>=count) local=count-1;
        const bool glossOn=settings.value("glossEnabled",true);
        float width=horizontal?320.0f:180.0f;
        if (!horizontal) {
            for (size_t i=0;i<count;++i) width=std::max(width,2*pad+32+measure(text(candidates[i],"text"),cn.p)+12+(glossOn?measure(text(candidates[i],"gloss"),en.p):0));
            width=std::clamp(width,180.0f,440.0f);
        }
        if (!preedit.empty()) width=std::max(width,measure(preedit,small.p)+2*pad);
        if (!status.empty()) width=std::max(width,measure(status,index.p)+2*pad);
        float sourceHeight=0;
        Com<IDWriteTextLayout> source;
        if (!preedit.empty()) {
            source.p=layout(preedit,small.p,width-2*pad,180,true); source->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
            DWRITE_TEXT_METRICS metrics{}; source->GetMetrics(&metrics); sourceHeight=std::min(180.0f,std::max(24.0f,metrics.height+8));
        }
        // 页码自 2026-11-20 起不绘制（与共享位图渲染同一裁决）：页脚高度只看
        // 状态行，单页与多页等高，不再有 PagePrev／PageNext 命中区。
        float footer=!status.empty()?24.0f:0, actions=(learning && (!preedit.empty() || count)) || draft ? 30.0f : 0;
        float height=2*pad+sourceHeight+row*count+footer+actions;
        if (horizontal && !toastOnly && count) {
            const float minW=320.0f, maxW=860.0f;
            float chipX=pad+4, chipH=std::max(28.0f,row*0.65f), rowY=pad+sourceHeight+(sourceHeight?4.0f:0);
            std::wstring glossLine;
            for (size_t i=0;i<count;++i) {
                bool chosen=i==local;
                auto word=text(candidates[i],"text");
                float iw=measure(std::to_wstring(i+1),index.p), ww=measure(word,cn.p);
                float chipW=iw+6+ww+16;
                if (chosen && glossOn) {
                    auto gloss=text(candidates[i],"gloss");
                    if (!gloss.empty()) glossLine=gloss;
                }
                width=std::max(width,chipX+chipW+pad);
                chipX+=chipW+4;
            }
            float glossH=(!glossLine.empty())?20.0f:0;
            width=std::clamp(width,minW,maxW);
            height=pad+sourceHeight+(sourceHeight>0?4.0f:0)+chipH+glossH+footer+pad;
        }
        if (toastOnly) { width=std::clamp(measure(toast,cn.p)+32,64.0f,440.0f); height=56; }
        height=std::max(height,32.0f);
        int w=int(std::ceil(width*scale)),h=int(std::ceil(height*scale)); surface(w,h);
        Com<IWICBitmap> buffer; check(wic->CreateBitmap(w,h,GUID_WICPixelFormat32bppPBGRA,WICBitmapCacheOnLoad,buffer.out()), "无法创建候选离屏画布。");
        Com<ID2D1RenderTarget> target;
        auto props=D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_SOFTWARE,D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,D2D1_ALPHA_MODE_PREMULTIPLIED),96,96);
        check(d2d->CreateWicBitmapRenderTarget(buffer.p,props,target.out()), "无法创建 Direct2D 候选画布。");
        target->SetTransform(D2D1::Matrix3x2F::Scale(scale,scale));
        target->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        Com<ID2D1SolidColorBrush> brush; check(target->CreateSolidColorBrush(D2D1::ColorF(0u),brush.out()), "无法创建候选画笔。");
        auto ink=[&](const char *key,float opacity=1) { brush->SetColor(color(palette,key,opacity)); return brush.p; };
        target->BeginDraw(); target->Clear(D2D1::ColorF(0,0.0f));
        auto bounds=D2D1::RectF(0,0,width,height); auto round=D2D1::RoundedRect(bounds,radius,radius);
        target->FillRoundedRectangle(round,ink("background",visual.value("bgOpacity",100.0f)/100));
        image(palette);
        if (backgroundImage.p) {
            Com<ID2D1Bitmap> picture; check(target->CreateBitmapFromWicBitmap(backgroundImage.p,nullptr,picture.out()), "无法绘制背景图片。");
            Com<ID2D1RoundedRectangleGeometry> shape; check(d2d->CreateRoundedRectangleGeometry(round,shape.out()), "无法创建背景圆角。");
            Com<ID2D1Layer> layer; check(target->CreateLayer(nullptr,layer.out()), "无法创建背景裁剪层。");
            target->PushLayer(D2D1::LayerParameters(bounds,shape.p),layer.p);
            const auto sz=picture->GetSize(); const float ratio=std::max(width/sz.width,height/sz.height);
            auto destination=D2D1::RectF((width-sz.width*ratio)/2,(height-sz.height*ratio)/2,(width+sz.width*ratio)/2,(height+sz.height*ratio)/2);
            target->DrawBitmap(picture.p,destination,visual.value("imageOpacity",25.0f)/100,D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
            target->PopLayer();
        }
        if (!old) target->DrawRoundedRectangle(D2D1::RoundedRect(D2D1::RectF(.5f,.5f,width-.5f,height-.5f),radius,radius),ink("border"),1);
        auto draw=[&](const std::wstring &s, IDWriteTextFormat *format, D2D1_RECT_F rect, const char *key) {
            if (s.empty() || rect.right<=rect.left) return;
            Com<IDWriteTextLayout> line; line.p=layout(s,format,rect.right-rect.left,rect.bottom-rect.top);
            Com<IDWriteInlineObject> ellipsis; check(write->CreateEllipsisTrimmingSign(format,ellipsis.out()), "无法建立文字省略标记。");
            DWRITE_TRIMMING trimming{DWRITE_TRIMMING_GRANULARITY_CHARACTER,0,0}; line->SetTrimming(&trimming,ellipsis.p);
            target->PushAxisAlignedClip(rect,D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
            target->DrawTextLayout(D2D1::Point2F(rect.left,rect.top),line.p,ink(key)); target->PopAxisAlignedClip();
        };
        if (toastOnly) draw(toast,cn.p,D2D1::RectF(16,0,width-8,height),"text");
        else {
            float y=pad;
            if (source.p) {
                auto rect=D2D1::RectF(pad,y,width-pad,y+sourceHeight);
                target->PushAxisAlignedClip(rect,D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
                target->DrawTextLayout(D2D1::Point2F(pad,y),source.p,ink("cursor"));
                // Issues are UTF-16 ranges in this exact source revision. Clicking
                // a wave opens explanation only; it never chooses a translation.
                if (learning && view.contains("issues") && view["issues"].is_array()) for (const auto &issue:view["issues"]) {
                    auto location=issue.value("location",size_t(0)),length=issue.value("length",size_t(0));
                    if (!length || location>preedit.size() || length>preedit.size()-location) continue;
                    UINT32 needed=0; source->HitTestTextRange(UINT32(location),UINT32(length),pad,y,nullptr,0,&needed);
                    std::vector<DWRITE_HIT_TEST_METRICS> metrics(needed);
                    if (!needed || FAILED(source->HitTestTextRange(UINT32(location),UINT32(length),pad,y,metrics.data(),needed,&needed))) continue;
                    for (const auto &m:metrics) {
                        if (m.top+m.height>y+sourceHeight) continue;
                        float baseline=m.top+m.height-1;
                        brush->SetColor(D2D1::ColorF(0xcc433f));
                        for (float x=m.left;x<m.left+m.width;x+=4) {
                            target->DrawLine(D2D1::Point2F(x,baseline),D2D1::Point2F(std::min(x+2,m.left+m.width),baseline-2),brush.p,1);
                            target->DrawLine(D2D1::Point2F(std::min(x+2,m.left+m.width),baseline-2),D2D1::Point2F(std::min(x+4,m.left+m.width),baseline),brush.p,1);
                        }
                        Hit hit; hit.action=Action::Explain; hit.explanation=text(issue,"explanation");
                        targets.push_back({pixels(D2D1::RectF(m.left,m.top,m.left+m.width,m.top+m.height+3),scale),hit});
                    }
                }
                target->PopAxisAlignedClip(); y+=sourceHeight;
            }
            if (horizontal) {
                float chipY=y, chipH=std::max(28.0f,row*0.65f), x=pad+4;
                std::wstring glossLine;
                for (size_t i=0;i<count;++i) {
                    bool chosen=i==local;
                    auto word=text(candidates[i],"text");
                    float iw=measure(std::to_wstring(i+1),index.p), ww=measure(word,cn.p);
                    float chipW=iw+6+ww+16;
                    auto rect=D2D1::RectF(x,chipY,x+chipW,chipY+chipH);
                    if (chosen) target->FillRoundedRectangle(D2D1::RoundedRect(rect,4,4),ink("highlight"));
                    draw(std::to_wstring(i+1),index.p,D2D1::RectF(x+4,chipY,x+4+iw,chipY+chipH),chosen?"highlightText":"index");
                    draw(word,cn.p,D2D1::RectF(x+4+iw+6,chipY,x+chipW-4,chipY+chipH),chosen?"highlightText":"text");
                    Hit hit; hit.action=Action::Choose; hit.index=i;
                    targets.push_back({pixels(rect,scale),hit});
                    if (chosen && glossOn) { auto g=text(candidates[i],"gloss"); if (!g.empty()) glossLine=g; }
                    x+=chipW+4;
                }
                y=chipY+chipH;
                if (!glossLine.empty()) { draw(glossLine,en.p,D2D1::RectF(pad+4,y,width-pad-8,y+20),"comment"); y+=22; }
            } else for (size_t i=0;i<count;++i) {
                bool chosen=i==local; auto rect=D2D1::RectF(pad,y,width-pad+std::min(4.0f,pad),y+row);
                if (chosen) target->FillRoundedRectangle(D2D1::RoundedRect(rect,4,4),ink("highlight"));
                draw(std::to_wstring(i+1),index.p,D2D1::RectF(pad+4,y,pad+25,y+row),chosen?"highlightText":"index");
                auto word=text(candidates[i],"text"),gloss=glossOn?text(candidates[i],"gloss"):L"";
                float wordWidth=gloss.empty()?width-2*pad-32:std::min(measure(word,cn.p)+4,(width-2*pad-32)*.62f);
                draw(word,cn.p,D2D1::RectF(pad+28,y,pad+28+wordWidth,y+row),chosen?"highlightText":"text");
                draw(gloss,en.p,D2D1::RectF(pad+28+wordWidth+8,y,width-pad-3,y+row),chosen?"highlightComment":"comment");
                Hit hit; hit.action=Action::Choose; hit.index=i;
                targets.push_back({pixels(rect,scale),hit}); y+=row;
            }
            if (footer) {
                draw(status,index.p,D2D1::RectF(pad,y,width-pad,y+24),"page"); y+=24;
            }
            if (actions) {
                float x=pad;
                if (learning && (!preedit.empty() || count)) {
                    auto rect=D2D1::RectF(x,y,x+112,y+30); draw(L"原文上屏",small.p,rect,"cursor");
                    Hit hit; hit.action=Action::Original; targets.push_back({pixels(rect,scale),hit}); x+=120;
                }
                if (draft) { auto rect=D2D1::RectF(x,y,std::min(width-pad,x+120),y+30); draw(L"恢复草稿",small.p,rect,"cursor");
                    Hit hit; hit.action=Action::Restore; targets.push_back({pixels(rect,scale),hit}); }
            }
        }
        check(target->EndDraw(), "候选窗绘制失败。");
        DIBSECTION section{};
        if (!GetObjectW(bitmap,sizeof(section),&section)) throw std::runtime_error("无法访问候选像素缓冲。");
        check(buffer->CopyPixels(nullptr,w*4,w*h*4,static_cast<BYTE *>(section.dsBm.bmBits)), "无法复制候选像素。");
    }
};
CandidateRenderer::CandidateRenderer():impl_(new Impl) {}
CandidateRenderer::~CandidateRenderer()=default;
void CandidateRenderer::setTheme(const Json &theme) { impl_->setTheme(theme); }
void CandidateRenderer::render(const Json &view,bool dark,int font,UINT dpi,const Json &settings) { impl_->render(view,impl_->theme,dark,font,dpi,settings); }
void CandidateRenderer::render(const Json &view,const Json &theme,bool dark,int font,UINT dpi,const Json &settings) { setTheme(theme); render(view,dark,font,dpi,settings); }
HDC CandidateRenderer::dc() const { return impl_->memory; }
SIZE CandidateRenderer::size() const { return impl_->extent; }
BYTE CandidateRenderer::opacity() const { return impl_->alpha; }
CandidateRenderer::Hit CandidateRenderer::hitTest(POINT point) const {
    for (const auto &target:impl_->targets) if (PtInRect(&target.rect,point)) return target.hit;
    return {};
}
void CandidateRenderer::paint(HDC destination,int x,int y) const {
    if (impl_->memory) { BLENDFUNCTION blend{AC_SRC_OVER,0,impl_->alpha,AC_SRC_ALPHA};
        AlphaBlend(destination,x,y,impl_->extent.cx,impl_->extent.cy,impl_->memory,0,0,impl_->extent.cx,impl_->extent.cy,blend); }
}
Json candidatePreview() {
    Json candidates=Json::array();
    const char *words[]={"你好","学习","语言","输入","世界","今天","朋友","工作","谢谢"};
    const char *glosses[]={"hello","v. learn · study","n. language","v. input","n. world","today","n. friend","n. work","thank you"};
    for (int i=0;i<9;++i) candidates.push_back({{"text",words[i]},{"gloss",glosses[i]}});
    return {{"preedit","ni'hao"},{"raw","nihc"},{"candidates",candidates},{"selected",0},{"page",0},{"pageCount",4},{"status","布局样例（不是翻译结果）"}};
}
} // namespace gw
