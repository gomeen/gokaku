#include "appearance.h"
#include <d2d1.h>
#include <dwrite.h>
#include <wincodec.h>
#include <algorithm>
#include <cmath>
#include <stdexcept>

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
    void render(const Json &view, const Json &theme, bool dark, int legacy, UINT dpi) {
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
        size_t pages=view.value("pageCount",size_t(0)), page=view.value("page",size_t(0));
        size_t selected=view.value("selected",size_t(0)); size_t local=selected>=page*9?selected-page*9:9;
        float width=180;
        for (size_t i=0;i<count;++i) width=std::max(width,2*pad+32+measure(text(candidates[i],"text"),cn.p)+12+measure(text(candidates[i],"gloss"),en.p));
        if (!preedit.empty()) width=std::max(width,measure(preedit,small.p)+2*pad);
        if (!status.empty()) width=std::max(width,measure(status,index.p)+2*pad);
        width=std::clamp(width,180.0f,440.0f);
        float sourceHeight=0;
        Com<IDWriteTextLayout> source;
        if (!preedit.empty()) {
            source.p=layout(preedit,small.p,width-2*pad,180,true); source->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
            DWRITE_TEXT_METRICS metrics{}; source->GetMetrics(&metrics); sourceHeight=std::min(180.0f,std::max(24.0f,metrics.height+8));
        }
        float footer=(!status.empty() || pages>1)?24.0f:0, actions=(learning && (!preedit.empty() || count)) || draft ? 30.0f : 0;
        float height=2*pad+sourceHeight+row*count+footer+actions;
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
            for (size_t i=0;i<count;++i) {
                bool chosen=i==local; auto rect=D2D1::RectF(pad,y,width-pad+std::min(4.0f,pad),y+row);
                if (chosen) target->FillRoundedRectangle(D2D1::RoundedRect(rect,4,4),ink("highlight"));
                draw(std::to_wstring(i+1),index.p,D2D1::RectF(pad+4,y,pad+25,y+row),chosen?"highlightText":"index");
                auto word=text(candidates[i],"text"),gloss=text(candidates[i],"gloss");
                float wordWidth=gloss.empty()?width-2*pad-32:std::min(measure(word,cn.p)+4,(width-2*pad-32)*.62f);
                draw(word,cn.p,D2D1::RectF(pad+28,y,pad+28+wordWidth,y+row),chosen?"highlightText":"text");
                draw(gloss,en.p,D2D1::RectF(pad+28+wordWidth+8,y,width-pad-3,y+row),chosen?"highlightComment":"comment");
                Hit hit; hit.action=Action::Choose; hit.index=i;
                targets.push_back({pixels(rect,scale),hit}); y+=row;
            }
            if (footer) {
                float pageWidth=0;
                if (pages>1) { auto value=std::to_wstring(page+1)+L"/"+std::to_wstring(pages); pageWidth=measure(value,index.p)+8;
                    draw(value,index.p,D2D1::RectF(width-pad-pageWidth,y,width-pad,y+24),"page"); }
                draw(status,index.p,D2D1::RectF(pad,y,width-pad-pageWidth,y+24),"page"); y+=24;
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
void CandidateRenderer::render(const Json &view,const Json &theme,bool dark,int font,UINT dpi) { impl_->render(view,theme,dark,font,dpi); }
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
