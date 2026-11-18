// 共享候选窗：排版、整形、栅格、图片与命中区域只有这一份实现。
// 平台只提供字体文件/face、帧、主题、缩放；不访问窗口或输入宿主。
#include "../panel_render.h"
#include "../../third_party/json.hpp"
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MULTIPLE_MASTERS_H
#include <hb.h>
#include <hb-ft.h>
#include <png.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

namespace {
using Json = nlohmann::json;
constexpr size_t maxJson = 24 * 1024 * 1024, maxPixels = 4 * 1024 * 1024;
struct Invalid {};
struct FontError {};
double number(const Json &j, const char *key, double fallback, double lo, double hi) {
    auto it = j.find(key);
    if (it == j.end()) return fallback;
    if (!it->is_number()) throw Invalid{};
    double n = it->get<double>();
    if (!std::isfinite(n) || n < lo || n > hi) throw Invalid{};
    return n;
}
std::string string(const Json &j, const char *key, size_t limit = 16384) {
    auto it = j.find(key);
    if (it == j.end() || it->is_null()) return {};
    if (!it->is_string()) throw Invalid{};
    auto s = it->get<std::string>();
    if (s.size() > limit || s.find('\0') != std::string::npos) throw Invalid{};
    return s;
}
struct Scalar { uint32_t cp; size_t byte, end; int utf16; };
std::vector<Scalar> scalars(const std::string &s) {
    std::vector<Scalar> out;
    int utf16 = 0;
    for (size_t i = 0; i < s.size();) {
        size_t start = i; unsigned c = (unsigned char)s[i++], n = 0; uint32_t cp;
        if (c < 0x80) cp = c;
        else if (c >= 0xc2 && c <= 0xdf) { cp = c & 31; n = 1; }
        else if (c >= 0xe0 && c <= 0xef) { cp = c & 15; n = 2; }
        else if (c >= 0xf0 && c <= 0xf4) { cp = c & 7; n = 3; }
        else throw Invalid{};
        if (n > s.size() - i) throw Invalid{};
        for (unsigned k = 0; k < n; ++k) {
            unsigned b = (unsigned char)s[i++];
            if ((b & 0xc0) != 0x80) throw Invalid{};
            cp = (cp << 6) | (b & 63);
        }
        if ((n == 1 && cp < 0x80) || (n == 2 && cp < 0x800) || (n == 3 && cp < 0x10000)
            || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) throw Invalid{};
        out.push_back({cp, start, i, utf16}); utf16 += cp > 0xffff ? 2 : 1;
    }
    return out;
}
bool latin(uint32_t c) { return c <= 0x024f || (c >= 0x1e00 && c <= 0x1eff); }
bool emoji(uint32_t c) { return (c >= 0x1f000 && c <= 0x1faff) || (c >= 0x2600 && c <= 0x27ff); }
bool extender(uint32_t c) {
    return hb_unicode_combining_class(hb_unicode_funcs_get_default(), c) != 0
        || c == 0xfe0e || c == 0xfe0f || c == 0x20e3 || (c >= 0x1f3fb && c <= 0x1f3ff)
        || (c >= 0xe0020 && c <= 0xe007f);
}
struct Glyph { size_t face; uint32_t id; double advance, dx, dy; int cluster; };
struct Run { std::vector<Glyph> glyphs; double width = 0, pt = 14; };
struct Raster { int w = 0, h = 0, left = 0, top = 0; bool color = false; double ratio = 1; std::vector<uint8_t> bytes; };

class Fonts {
    struct Face {
        FT_Face ft = nullptr; hb_font_t *hb = nullptr; bool emoji = false, latin = false;
        std::vector<FT_Fixed> coordinates; int optical = -1;
        double opticalPt = -1, pixelSize = -1;
#ifdef _WIN32
        std::vector<uint8_t> file;
#endif
        ~Face() { if (hb) hb_font_destroy(hb); if (ft) FT_Done_Face(ft); }
    };
    FT_Library ft_ = nullptr;
    std::vector<std::unique_ptr<Face>> faces_;
    using Key = std::tuple<size_t, uint32_t, int, int>;
    std::map<Key, Raster> cache_;
    size_t cacheBytes_ = 0;
    double lastPt_ = -1;
    void setSize(Face &f, double pt, double pixels) {
        double optical = std::max(17.0, pt);
        if (f.optical >= 0 && f.opticalPt != optical) {
            auto coords = f.coordinates;
            coords[size_t(f.optical)] = FT_Fixed(optical * 65536);
            FT_Set_Var_Design_Coordinates(f.ft, FT_UInt(coords.size()), coords.data());
            f.opticalPt = optical; f.pixelSize = -1;
        }
        if (f.pixelSize != pixels) {
            if (FT_Set_Char_Size(f.ft, 0, FT_F26Dot6(std::round(pixels * 64)), 72, 72)
                && f.ft->num_fixed_sizes) FT_Select_Size(f.ft, 0);
            f.pixelSize = pixels;
        }
    }
    void setPt(double pt) {
        if (lastPt_ == pt) return;
        for (auto &f : faces_) { setSize(*f, pt, pt); hb_ft_font_changed(f->hb); hb_font_set_ptem(f->hb, float(pt)); }
        lastPt_ = pt;
    }
public:
    explicit Fonts(const Json &fonts) {
        if (!fonts.is_array() || fonts.size() > 16) throw Invalid{};
        if (FT_Init_FreeType(&ft_)) throw FontError{};
        try {
            for (const auto &spec : fonts) {
                if (!spec.is_object()) throw Invalid{};
                auto path = string(spec, "path", 8192), name = string(spec, "postscriptName", 512);
                if (path.empty()) continue;
                int index = int(number(spec, "index", 0, -1, 65535));
                auto f = std::make_unique<Face>();
#ifdef _WIN32
                std::ifstream input(std::filesystem::u8path(path), std::ios::binary | std::ios::ate);
                if (!input) continue;
                auto size = input.tellg();
                if (size <= 0 || size > 256 * 1024 * 1024) continue;
                f->file.resize(size_t(size)); input.seekg(0);
                if (!input.read(reinterpret_cast<char *>(f->file.data()), size)) continue;
                auto open = [&](int face) { return FT_New_Memory_Face(ft_, f->file.data(), FT_Long(f->file.size()), face, &f->ft); };
#else
                auto open = [&](int face) { return FT_New_Face(ft_, path.c_str(), face, &f->ft); };
#endif
                if (open(std::max(0, index))) continue;
                if (index == -1 && !name.empty()) {
                    int count = int(std::min(FT_Long(128), f->ft->num_faces)); bool found = false;
                    for (int i = 0; i < count; ++i) {
                        if (i) { FT_Done_Face(f->ft); f->ft = nullptr; if (open(i)) continue; }
                        const char *postscript = FT_Get_Postscript_Name(f->ft);
                        if (postscript && name == postscript) { found = true; break; }
                    }
                    if (!found) continue;
                }
                FT_Select_Charmap(f->ft, FT_ENCODING_UNICODE);
                f->emoji = spec.value("emoji", false); f->latin = string(spec, "role", 32) == "latin";
                FT_MM_Var *mm = nullptr;
                if (!FT_Get_MM_Var(f->ft, &mm)) {
                    f->coordinates.resize(mm->num_axis);
                    FT_Get_Var_Design_Coordinates(f->ft, mm->num_axis, f->coordinates.data());
                    for (unsigned a = 0; a < mm->num_axis; ++a)
                        if (mm->axis[a].tag == FT_MAKE_TAG('o','p','s','z')) f->optical = int(a);
                    FT_Done_MM_Var(ft_, mm);
                }
                f->hb = hb_ft_font_create_referenced(f->ft);
                hb_ft_font_set_load_flags(f->hb, FT_LOAD_NO_HINTING | (FT_IS_SCALABLE(f->ft) ? FT_LOAD_NO_BITMAP : FT_LOAD_COLOR));
                faces_.push_back(std::move(f));
            }
            if (faces_.empty()) throw FontError{};
        } catch (...) { faces_.clear(); FT_Done_FreeType(ft_); ft_ = nullptr; throw; }
    }
    ~Fonts() { faces_.clear(); if (ft_) FT_Done_FreeType(ft_); }
    Run shape(const std::string &text, double pt) {
        setPt(pt); Run run; run.pt = pt;
        auto chars = scalars(text);
        struct Span { size_t start, end, face; hb_script_t script; };
        std::vector<Span> spans;
        for (size_t i = 0; i < chars.size();) {
            size_t end = i + 1;
            while (end < chars.size() && (extender(chars[end].cp) || chars[end].cp == 0x200d || chars[end - 1].cp == 0x200d
                || (end == i + 1 && chars[i].cp >= 0x1f1e6 && chars[i].cp <= 0x1f1ff && chars[end].cp >= 0x1f1e6 && chars[end].cp <= 0x1f1ff))) ++end;
            bool isEmoji = emoji(chars[i].cp);
            for (size_t k = i; k < end; ++k) {
                if (chars[k].cp == 0xfe0f || chars[k].cp == 0x20e3) isEmoji = true;
                if (chars[k].cp == 0xfe0e) isEmoji = false;
            }
            size_t chosen = 0; int best = -1;
            for (size_t fi = 0; fi < faces_.size(); ++fi) {
                auto &f = *faces_[fi]; bool covers = true;
                for (size_t k = i; k < end; ++k) {
                    uint32_t cp = chars[k].cp;
                    if (cp == 0x200d || cp == 0xfe0e || cp == 0xfe0f || (cp >= 0xe0020 && cp <= 0xe007f)) continue;
                    if (!FT_Get_Char_Index(f.ft, cp)) { covers = false; break; }
                }
                if (!covers) continue;
                int priority = (isEmoji && f.emoji ? 4 : 0) + (latin(chars[i].cp) && f.latin ? 2 : 0) + (!f.emoji ? 1 : 0);
                if (priority > best) { best = priority; chosen = fi; }
            }
            auto script = hb_unicode_script(hb_unicode_funcs_get_default(), chars[i].cp);
            if (!spans.empty() && script == HB_SCRIPT_COMMON) script = spans.back().script;
            if (!spans.empty() && spans.back().face == chosen && spans.back().script == script) spans.back().end = end;
            else spans.push_back({i, end, chosen, script});
            i = end;
        }
        std::unique_ptr<hb_buffer_t, decltype(&hb_buffer_destroy)> buffer(hb_buffer_create(), hb_buffer_destroy);
        for (auto span : spans) {
            size_t start = chars[span.start].byte, end = chars[span.end - 1].end;
            hb_buffer_reset(buffer.get());
            hb_buffer_add_utf8(buffer.get(), text.data(), int(text.size()), unsigned(start), int(end - start));
            hb_buffer_guess_segment_properties(buffer.get());
            hb_buffer_set_language(buffer.get(), hb_language_from_string("zh-CN", -1));
            hb_shape(faces_[span.face]->hb, buffer.get(), nullptr, 0);
            unsigned count = 0;
            auto info = hb_buffer_get_glyph_infos(buffer.get(), &count);
            auto pos = hb_buffer_get_glyph_positions(buffer.get(), &count);
            const auto &face=*faces_[span.face];
            // 固定 strike 字体可能将24pt请求落到20px；布局与位图必须用同一比例。
            double metricScale=face.emoji && face.ft->num_fixed_sizes && face.ft->size->metrics.x_ppem
                ? pt/face.ft->size->metrics.x_ppem : 1;
            for (unsigned n = 0; n < count; ++n) {
                auto ch = std::lower_bound(chars.begin(), chars.end(), info[n].cluster, [](const Scalar &a, uint32_t b) { return a.byte < b; });
                double advance = pos[n].x_advance / 64.0 * metricScale;
                run.glyphs.push_back({span.face, info[n].codepoint, advance, pos[n].x_offset / 64.0 * metricScale, pos[n].y_offset / 64.0 * metricScale,
                                      ch == chars.end() ? 0 : ch->utf16});
                run.width += advance;
            }
        }
        return run;
    }
    const Raster &raster(const Glyph &g, double pt, double scale) {
        Key key{g.face, g.id, int(std::round(pt * 64)), int(std::round(scale * 1024))};
        auto found = cache_.find(key); if (found != cache_.end()) return found->second;
        if (cacheBytes_ > 8 * 1024 * 1024) { cache_.clear(); cacheBytes_ = 0; }
        auto &f = *faces_.at(g.face); Raster out;
        setSize(f, pt, pt * scale); lastPt_ = -1;
        if (f.emoji && f.ft->num_fixed_sizes) {
            int best = 0; double distance = 1e9;
            for (int i = 0; i < f.ft->num_fixed_sizes; ++i) {
                double d = std::abs(f.ft->available_sizes[i].size / 64.0 - pt * scale);
                if (d < distance) { best = i; distance = d; }
            }
            FT_Select_Size(f.ft, best);
            FT_Set_Char_Size(f.ft, 0, f.ft->available_sizes[best].size, 72, 72);
            f.pixelSize = -1;
            out.ratio = pt * scale / std::max(1.0, f.ft->available_sizes[best].size / 64.0);
        }
        FT_Int32 flags = FT_LOAD_NO_HINTING | FT_LOAD_COLOR;
        if (!f.emoji) flags |= FT_LOAD_NO_BITMAP;
        if (!FT_Load_Glyph(f.ft, g.id, flags)) {
            auto slot = f.ft->glyph;
            if (slot->format == FT_GLYPH_FORMAT_BITMAP || !FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL)) {
                auto &b = slot->bitmap;
                if ((b.pixel_mode == FT_PIXEL_MODE_GRAY || b.pixel_mode == FT_PIXEL_MODE_BGRA) && b.width <= 4096 && b.rows <= 4096) {
                    out.w = int(b.width); out.h = int(b.rows); out.left = slot->bitmap_left; out.top = slot->bitmap_top;
                    out.color = b.pixel_mode == FT_PIXEL_MODE_BGRA;
                    size_t stride = size_t(out.w) * (out.color ? 4 : 1);
                    out.bytes.resize(stride * out.h);
                    for (int y = 0; y < out.h; ++y) {
                        const auto *row = b.buffer + (b.pitch >= 0 ? y : out.h - 1 - y) * std::abs(b.pitch);
                        std::memcpy(out.bytes.data() + y * stride, row, stride);
                    }
                }
            }
        }
        cacheBytes_ += out.bytes.size();
        return cache_.emplace(key, std::move(out)).first->second;
    }
};
// 字体/字形缓存只保存字库数据；不缓存帧文本。每线程独立，设置预览可并发。
Fonts &fontsFor(const Json &spec) {
    thread_local std::string key;
    thread_local std::unique_ptr<Fonts> fonts;
    auto next = spec.dump();
    if (!fonts || next != key) { auto fresh = std::make_unique<Fonts>(spec); fonts = std::move(fresh); key = std::move(next); }
    return *fonts;
}

struct Color { uint8_t r, g, b; };
Color rgb(uint32_t c) { return {uint8_t(c >> 16), uint8_t(c >> 8), uint8_t(c)}; }
struct Palette {
    Color background, border, text, comment, index, highlight, selected, selectedComment, cursor, page, typed, rest;
    double radius, padding, rowHeight, opacity, bgOpacity, imageOpacity, font, small, indexFont, preeditFont;
    bool legacy;
    const std::string *image = nullptr;
};
Palette palette(const Json &theme, const Json &frame, bool dark) {
    const Json &pal = theme.contains("light")
        ? (dark && theme.contains("dark") && !theme.at("dark").is_null() ? theme.at("dark") : theme.at("light"))
        : theme;
    if (!pal.is_object()) throw Invalid{};
    auto color = [&](const char *key, uint32_t fallback) { return rgb(uint32_t(number(pal, key, fallback, 0, 0xffffff))); };
    Palette p{}; p.legacy = string(theme, "id", 256) == "rime-macos-like";
    p.background = color("background", 0xffffff); p.border = color("border", 0xd7dfd9);
    p.text = color("text", 0x202925); p.comment = color("comment", 0x7d5800);
    p.index = color("index", 0x78837d); p.highlight = color("highlight", 0x12996a);
    p.selected = color("highlightText", 0xffffff); p.selectedComment = color("highlightComment", 0xffffff);
    p.cursor = color("cursor", 0x53655a); p.page = color("page", 0x7b8880);
    auto visual = pal.value("visual", Json::object()), typography = theme.value("typography", Json::object());
    if (!visual.is_object() || !typography.is_object()) throw Invalid{};
    p.radius = number(visual, "radius", 8, 0, 24); p.padding = number(visual, "padding", 8, 0, 24);
    p.rowHeight = number(visual, "rowHeight", 100, 50, 200);
    p.opacity = number(visual, "opacity", 100, 0, 100) / 100;
    p.bgOpacity = number(visual, "bgOpacity", 100, 0, 100) / 100;
    p.imageOpacity = number(visual, "imageOpacity", 25, 0, 100) / 100;
    p.font = p.legacy ? number(frame, "fontSize", 14, 12, 16) : number(typography, "fontSize", 14, 12, 24);
    p.small = p.font - (p.legacy ? 1 : 2);
    p.indexFont = p.legacy ? p.font - 3 : number(typography, "indexSize", 11, 8, 20);
    p.preeditFont = p.legacy ? p.small : 13;
    if (auto it = pal.find("imageData"); it != pal.end() && !it->is_null()) {
        if (!it->is_string()) throw Invalid{};
        p.image = &it->get_ref<const std::string &>();
        if (p.image->size() > maxJson) throw Invalid{};
    }
    if (p.legacy) {
        p.background = rgb(dark ? 0x2d1e1f : 0xffffff); p.text = rgb(dark ? 0xeae9e9 : 0x3c3c3c);
        p.cursor = rgb(dark ? 0xa3a09d : 0x6b6b6b); p.index = p.page = rgb(dark ? 0x999999 : 0x757575);
        p.comment = rgb(dark ? 0xe3a82e : 0x7d5800); p.highlight = rgb(0x12996a);
        p.selected = rgb(0xffffff); p.selectedComment = rgb(dark ? 0xeefaf5 : 0xffffff);
    }
    p.typed = p.cursor;
    p.rest = p.legacy ? rgb(dark ? 0x999999 : 0x757575) : p.cursor;
    return p;
}
struct Image { unsigned w = 0, h = 0; std::vector<uint8_t> rgba; };
Image decodeImage(const std::string &encoded) {
    Image image;
    if (!encoded.empty()) {
        std::vector<uint8_t> png;
        png.reserve(encoded.size() / 4 * 3);
        unsigned accum = 0, bits = 0;
        for (unsigned char c : encoded) {
            if (c == '=') break;
            int digit = c >= 'A' && c <= 'Z' ? c - 'A' : c >= 'a' && c <= 'z' ? c - 'a' + 26
                : c >= '0' && c <= '9' ? c - '0' + 52 : c == '+' ? 62 : c == '/' ? 63 : -1;
            if (digit < 0) throw Invalid{};
            accum = (accum << 6) | unsigned(digit); bits += 6;
            if (bits >= 8) { bits -= 8; png.push_back(uint8_t(accum >> bits)); }
        }
        if (png.size() > 16 * 1024 * 1024) throw Invalid{};
        png_image read{}; read.version = PNG_IMAGE_VERSION;
        if (!png_image_begin_read_from_memory(&read, png.data(), png.size())) throw Invalid{};
        struct Free { png_image *p; ~Free() { png_image_free(p); } } cleanup{&read};
        if (!read.width || !read.height || read.width > 4096 || read.height > 4096) throw Invalid{};
        read.format = PNG_FORMAT_RGBA; image.w = read.width; image.h = read.height;
        image.rgba.resize(PNG_IMAGE_SIZE(read));
        if (!png_image_finish_read(&read, nullptr, image.rgba.data(), 0, nullptr)) throw Invalid{};
    }
    return image;
}
// 主题不可变；只缓存当前外观的一张解码图，释放句柄即释放 JSON 和图像。
// 键为本对象内不可变字符串的地址，不依赖调用者地址、长度或哈希。
struct PreparedTheme {
    const Json json;
    mutable std::mutex mutex;
    mutable const std::string *imageKey = nullptr;
    mutable std::shared_ptr<const Image> image;
    mutable std::vector<const std::string *> validatedImages;
    explicit PreparedTheme(Json value): json(std::move(value)) {}
    std::shared_ptr<const Image> imageFor(const std::string *encoded, bool pixels) const {
        std::lock_guard<std::mutex> lock(mutex);
        if (encoded && std::find(validatedImages.begin(),validatedImages.end(),encoded)==validatedImages.end()) {
            if (encoded->find('\0')!=std::string::npos) throw Invalid{};
            validatedImages.push_back(encoded);
        }
        if (!pixels) return {};
        if (imageKey != encoded) { image.reset(); imageKey = encoded; }
        if (!encoded || encoded->empty()) return {};
        if (!image) image = std::make_shared<Image>(decodeImage(*encoded));
        return image; // 并发另一外观替换缓存时，当前帧仍持有自己的图像。
    }
};
Json parseTheme(const char *theme,size_t length) {
    Json json=theme?Json::parse(theme,theme+length):Json::object();
    if(!json.is_object()) throw Json::type_error::create(302,"theme must be object",&json);
    return json;
}
const PreparedTheme &themeFor(const char *theme,size_t length) {
    thread_local std::string key;
    thread_local std::unique_ptr<PreparedTheme> cached;
    thread_local bool keyPresent = false;
    // 旧 ABI 的输入可在相同地址被修改：完整字节比较是兼容调用者所必需的。
    if (!cached || keyPresent != bool(theme) || key.size()!=length || (length && std::memcmp(key.data(),theme,length))) {
        cached.reset(); std::string().swap(key); // 先释放旧主题/图像，限制替换峰值。
        auto fresh=std::make_unique<PreparedTheme>(parseTheme(theme,length));
        key.assign(theme?theme:"",length); keyPresent=bool(theme);
        cached=std::move(fresh);
    }
    return *cached;
}
struct Box { double x = 0, y = 0, w = 0, h = 0; };
class Canvas {
    int w_, h_; double radius_; std::vector<uint8_t> pixels_;
    static double coverage(double x, double y, double w, double h, double radius) {
        radius = std::min({radius, w / 2, h / 2});
        double dx = std::max({radius - x - .5, x + .5 - (w - radius), 0.0});
        double dy = std::max({radius - y - .5, y + .5 - (h - radius), 0.0});
        if (!dx || !dy) return 1;
        return std::clamp(radius + .5 - std::hypot(dx, dy), 0.0, 1.0);
    }
    void blend(int x, int y, Color c, double a, bool premultiplied = false) {
        if (x < 0 || y < 0 || x >= w_ || y >= h_ || a <= 0) return;
        auto *p = pixels_.data() + (size_t(y) * w_ + x) * 4;
        if (a >= 1) { p[0]=c.r; p[1]=c.g; p[2]=c.b; p[3]=255; return; }
        double m = premultiplied ? 1 : a;
        p[0] = uint8_t(std::min(255.0, p[0] * (1 - a) + c.r * m));
        p[1] = uint8_t(std::min(255.0, p[1] * (1 - a) + c.g * m));
        p[2] = uint8_t(std::min(255.0, p[2] * (1 - a) + c.b * m));
        p[3] = uint8_t(std::min(255.0, p[3] * (1 - a) + 255 * a));
    }
public:
    Canvas(int w, int h, double radius): w_(w), h_(h), radius_(std::min({radius,w/2.0,h/2.0})), pixels_(size_t(w)*h*4) {}
    void background(Color c, double alpha) {
        const uint8_t pixel[4]={uint8_t(std::round(c.r*alpha)),uint8_t(std::round(c.g*alpha)),uint8_t(std::round(c.b*alpha)),uint8_t(std::round(255*alpha))};
        for(size_t i=0;i<pixels_.size();i+=4)std::memcpy(pixels_.data()+i,pixel,4);
    }
    void rect(Box b, Color c, double alpha = 1, double radius = 0) {
        int x0 = std::max(0, int(std::floor(b.x))), y0 = std::max(0, int(std::floor(b.y)));
        int x1 = std::min(w_, int(std::ceil(b.x+b.w))), y1 = std::min(h_, int(std::ceil(b.y+b.h)));
        for (int y = y0; y < y1; ++y) for (int x = x0; x < x1; ++x)
            blend(x, y, c, alpha * coverage(x-b.x,y-b.y,b.w,b.h,radius));
    }
    void image(const Image &im, double opacity) {
        if (im.rgba.empty() || opacity <= 0) return;
        double scale = std::max(double(w_)/im.w, double(h_)/im.h);
        double ox = (im.w*scale-w_)/2, oy = (im.h*scale-h_)/2;
        // 横向采样位置与alpha系数在整张图中重复；每行只求一次源行。
        std::vector<size_t> columns(w_);
        for (int x=0;x<w_;++x) columns[x]=size_t(std::min(im.w-1,unsigned((x+ox)/scale)))*4;
        std::array<double,256> alpha{};
        for (int i=0;i<256;++i) alpha[i]=i/255.0*opacity;
        for (int y = 0; y < h_; ++y) {
            unsigned sy=std::min(im.h-1,unsigned((y+oy)/scale));
            const auto *row=&im.rgba[size_t(sy)*im.w*4];
            auto *dst=pixels_.data()+size_t(y)*w_*4;
            for (int x=0;x<w_;++x,dst+=4) {
                const auto *src=row+columns[x];double a=alpha[src[3]],inverse=1-a;
                // 都在画布内，alpha∈[0,1]；结果仍用旧blend的截断语义。
                dst[0]=uint8_t(dst[0]*inverse+src[0]*a);
                dst[1]=uint8_t(dst[1]*inverse+src[1]*a);
                dst[2]=uint8_t(dst[2]*inverse+src[2]*a);
                dst[3]=uint8_t(dst[3]*inverse+255*a);
            }
        }
    }
    void border(Color c, double radius, double width) {
        auto edge=[&](int x,int y) {
            double inner = (x < width || y < width || x >= w_-width || y >= h_-width) ? 0
                : coverage(x-width,y-width,w_-width*2,h_-width*2,std::max(0.0,radius-width));
            blend(x,y,c,1-inner);
        };
        int side=std::min(w_/2,int(std::ceil(radius+width+1)));
        for(int y=0;y<h_;++y) {
            if(y<width || y>=h_-width) { for(int x=0;x<w_;++x)edge(x,y); }
            else { for(int x=0;x<side;++x){edge(x,y);edge(w_-1-x,y);} }
        }
    }
    void text(Fonts &fonts, const Run &run, Color color, double x, double baseline, double scale, const std::array<uint8_t,256> &gamma) {
        for (const auto &g : run.glyphs) {
            const auto &r = fonts.raster(g, run.pt, scale);
            double ratio = r.ratio;
            int left = int(std::round((x+g.dx)*scale + r.left*ratio));
            int top = int(std::round((baseline-g.dy)*scale - r.top*ratio));
            int width = int(std::ceil(r.w*ratio)), height = int(std::ceil(r.h*ratio));
            for (int row = 0; row < height; ++row) for (int col = 0; col < width; ++col) {
                size_t offset = size_t(std::min(r.h-1,int(row/ratio)))*r.w + std::min(r.w-1,int(col/ratio));
                if (r.color) { auto p = &r.bytes[offset*4]; blend(left+col,top+row,{p[2],p[1],p[0]},p[3]/255.0,true); }
                else blend(left+col,top+row,color,gamma[r.bytes[offset]]/255.0);
            }
            x += g.advance;
        }
    }
    const std::vector<uint8_t> &finish(double opacity) {
        if (opacity < 1) for (auto &value : pixels_) value = uint8_t(std::round(value*opacity));
        // 圆角只触及四角；整窗不再逐像素重复计算距离与透明度。
        int corner = int(std::ceil(radius_+1));
        for (int y=0;y<corner;++y) for(int x=0;x<corner;++x) {
            double alpha=coverage(x,y,w_,h_,radius_);
            if(alpha>=1)continue;
            for(auto row:{y,h_-1-y})for(auto col:{x,w_-1-x}) {
                auto *p=pixels_.data()+(size_t(row)*w_+col)*4;
                for(int k=0;k<4;++k)p[k]=uint8_t(std::round(p[k]*alpha));
            }
        }
        return pixels_;
    }
};

Run truncate(Fonts &fonts, Run run, double width) {
    if (run.width <= width) return run;
    Run ellipsis = fonts.shape("…", run.pt);
    for(auto &g:ellipsis.glyphs)g.cluster=-1;
    if (ellipsis.width > width) return Run{{}, 0, run.pt};
    Run out; out.pt = run.pt;
    for (size_t i = 0; i < run.glyphs.size();) {
        size_t end = i+1; double w = run.glyphs[i].advance;
        while (end < run.glyphs.size() && run.glyphs[end].cluster == run.glyphs[i].cluster) w += run.glyphs[end++].advance;
        if (out.width+w+ellipsis.width > width) break;
        out.glyphs.insert(out.glyphs.end(),run.glyphs.begin()+i,run.glyphs.begin()+end); out.width += w; i=end;
    }
    out.glyphs.insert(out.glyphs.end(),ellipsis.glyphs.begin(),ellipsis.glyphs.end()); out.width += ellipsis.width; return out;
}
std::vector<Run> wrap(Fonts &fonts, const Run &run, double width, size_t limit, bool keepTail) {
    std::vector<Run> lines; Run line; line.pt=run.pt;
    for (size_t i=0; i<run.glyphs.size();) {
        size_t end=i+1; double w=run.glyphs[i].advance;
        while (end<run.glyphs.size() && run.glyphs[end].cluster==run.glyphs[i].cluster) w+=run.glyphs[end++].advance;
        if (!line.glyphs.empty() && line.width+w>width) { lines.push_back(std::move(line)); line=Run{{},0,run.pt}; }
        line.glyphs.insert(line.glyphs.end(),run.glyphs.begin()+i,run.glyphs.begin()+end); line.width+=w; i=end;
    }
    if (!line.glyphs.empty()) lines.push_back(std::move(line));
    if (lines.size()>limit) {
        if (keepTail) {
            lines.erase(lines.begin(),lines.end()-limit);
            auto e=fonts.shape("…",run.pt);for(auto &g:e.glyphs)g.cluster=-1;
            auto &first=lines.front();
            // 从首保留行的开头让出省略号空间，保持后面内容连续，不截出中间缺口。
            while(!first.glyphs.empty() && first.width+e.width>width) {
                int cluster=first.glyphs.front().cluster;
                do {first.width-=first.glyphs.front().advance;first.glyphs.erase(first.glyphs.begin());}
                while(!first.glyphs.empty()&&first.glyphs.front().cluster==cluster);
            }
            first.glyphs.insert(first.glyphs.begin(),e.glyphs.begin(),e.glyphs.end());first.width+=e.width;
        } else {
            auto &last=lines[limit-1];auto e=fonts.shape("…",run.pt);for(auto &g:e.glyphs)g.cluster=-1;
            last.glyphs.insert(last.glyphs.end(),e.glyphs.begin(),e.glyphs.end());last.width+=e.width;
            lines.resize(limit);lines.back()=truncate(fonts,std::move(lines.back()),width);
        }
    }
    return lines;
}
struct Text { Run run; Color color; double x, baseline; };
struct Fill { Box box; Color color; double radius; };
struct Hit { Box box; int action, arg; };
struct Panel { double w=0,h=0; std::vector<Text> texts; std::vector<Fill> fills; std::vector<Hit> hits; };
Panel layout(Fonts &fonts, const Json &frame, const Palette &p) {
    Panel panel;
    bool learning=frame.value("learning",false), horizontal=!learning && string(frame,"layout",32)=="horizontal";
    bool glossOn=frame.value("glossRow",true), original=frame.value("hasOriginal",false), restore=frame.value("hasRestore",false);
    int page=int(number(frame,"page",0,0,1000000)), pages=int(number(frame,"pageCount",1,1,1000001));
    int pageSize=int(number(frame,"pageSize",9,1,9)), selected=int(number(frame,"selected",0,0,10000000));
    auto candidates=frame.value("candidates",Json::array());
    if (!candidates.is_array() || candidates.size()>size_t(pageSize)) throw Invalid{};
    auto preedit=string(frame,"preedit"), status=string(frame,"status"), toast=string(frame,"toast");
    if (candidates.empty() && preedit.empty() && status.empty() && toast.empty() && !restore && !original) throw Invalid{};
    auto issues=frame.value("issues",Json::array());
    if (!issues.is_array() || issues.size()>256) throw Invalid{};
    double pad=p.padding, minW=horizontal?320:180, maxW=horizontal?860:440;
    double innerMax=maxW-2*pad, smallH=std::ceil(p.small*1.4), preeditH=std::ceil(p.preeditFont*1.5);
    double rowH=std::max({(p.legacy?46*p.font/21:30)*p.rowHeight/100,p.font*1.5,p.indexFont*1.5});
    Run source=fonts.shape(preedit,p.preeditFont), statusRun=fonts.shape(status,p.small), pageRun;
    if (pages>1) pageRun=fonts.shape(std::to_string(page+1)+"/"+std::to_string(pages),p.indexFont);
    struct Row { Run index,word,gloss; bool selected; double width=0; };
    std::vector<Row> rows; double widest=0;
    for (size_t i=0;i<candidates.size();++i) {
        const auto &c=candidates[i]; if(!c.is_object()) throw Invalid{};
        auto explanation=string(c,"gloss");
        Row r{fonts.shape(std::to_string(i+1),p.indexFont), fonts.shape(string(c,"text"),p.font),
              fonts.shape(explanation,p.small),selected==page*pageSize+int(i)};
        r.width=r.index.width+8+r.word.width+(r.gloss.width>0?8+r.gloss.width:0)+10;
        widest=std::max(widest,r.width); rows.push_back(std::move(r));
    }
    double desired=std::max({widest,source.width,statusRun.width,original||restore?240.0:0.0});
    double pageReserve=pages>1?pageRun.width+16:0;
    if(horizontal) {
        desired=pageReserve;
        for(auto &r:rows) desired+=r.index.width+5+r.word.width+16;
        if(!rows.empty()) desired+=4*(rows.size()-1);
    }
    panel.w=std::clamp(desired+2*pad,minW,maxW); double inner=panel.w-2*pad,y=pad;
    auto put=[&](Run run,Color color,double x,double baseline){panel.texts.push_back({std::move(run),color,x,baseline});};
    auto hit=[&](Box b,int action,int arg=0){if(b.w>0&&b.h>0)panel.hits.push_back({b,action,arg});};
    if(!toast.empty() && candidates.empty() && preedit.empty() && status.empty() && !original && !restore) {
        auto r=fonts.shape(toast,p.font); panel.w=std::clamp(r.width+32,64.0,440.0); panel.h=std::max(40.0,p.font*2+16);
        put(truncate(fonts,std::move(r),panel.w-32),p.text,16,(panel.h+p.font*.7)/2);return panel;
    }
    if(!preedit.empty()) {
        auto lines=wrap(fonts,source,inner,4,true);
        int caret=int(number(frame,"preeditCaretUTF16",-1,-1,16384));
        int totalUTF16=0; auto chars=scalars(preedit);
        if(!chars.empty())totalUTF16=chars.back().utf16+(chars.back().cp>0xffff?2:1);
        caret=std::min(caret,totalUTF16);
        int typed = learning && string(frame,"direction",16)=="enToZh" ? totalUTF16
            : int(std::min(double(totalUTF16),number(frame,"typedPrefixUTF16",0,0,std::numeric_limits<double>::max())));
        for(size_t i=0;i<lines.size();++i) {
            const auto &line=lines[i]; double x=pad;
            bool caretDrawn=false;
            for(const auto &g:line.glyphs) {
                if(!caretDrawn && caret>=0 && g.cluster>=caret && (i==0 || caret>=line.glyphs.front().cluster)) {
                    panel.fills.push_back({{x,y+2,1,preeditH-4},p.cursor,0}); caretDrawn=true;
                }
                if(learning)for(size_t n=0;n<issues.size();++n) {
                    const auto &issue=issues[n];
                    int loc=int(number(issue,"location",0,0,16384)),len=int(number(issue,"length",0,0,16384));
                    if(loc+len>totalUTF16 || !len || g.cluster<loc || g.cluster>=loc+len)continue;
                    hit({x,y,std::max(2.0,g.advance),preeditH},GC_PANEL_HIT_EXPLAIN,int(n));
                    for(double dx=0;dx<g.advance;dx+=4)panel.fills.push_back({{x+dx,y+preeditH-2,2,1},rgb(0xcc433f),0});
                }
                x+=g.advance;
            }
            if(!caretDrawn && caret>=0 && i+1==lines.size() && caret==totalUTF16)panel.fills.push_back({{std::min(x,panel.w-pad-1),y+2,1,preeditH-4},p.cursor,0});
            double textX=pad;
            Run segment; segment.pt=line.pt;
            bool typedSegment=false;
            for(const auto &g:line.glyphs) {
                bool isTyped=g.cluster>=0 && g.cluster<typed;
                if(!segment.glyphs.empty() && isTyped!=typedSegment) {
                    double advance=segment.width;
                    put(std::move(segment),typedSegment?p.typed:p.rest,textX,y+preeditH*.76);
                    textX+=advance;segment=Run{{},0,line.pt};
                }
                typedSegment=isTyped;segment.glyphs.push_back(g);segment.width+=g.advance;
            }
            if(!segment.glyphs.empty())put(std::move(segment),typedSegment?p.typed:p.rest,textX,y+preeditH*.76);
            y+=preeditH;
        }
        y+=4;
    }
    if(horizontal && !rows.empty()) {
        double available=inner-pageReserve-4*(rows.size()-1),used=0;
        std::vector<double> widths(rows.size());
        // 水位分配：短候选取所需宽度，长候选平分剩余空间；页内候选永不丢弃。
        double remaining=available;size_t pending=rows.size();
        for(size_t pass=0;pass<rows.size();++pass) {
            double share=remaining/std::max(size_t(1),pending);bool changed=false;
            for(size_t i=0;i<rows.size();++i)if(!widths[i]) {
                double natural=rows[i].index.width+5+rows[i].word.width+16;
                if(natural<=share){widths[i]=natural;remaining-=natural;--pending;changed=true;}
            }
            if(!changed)break;
        }
        for(size_t i=0;i<rows.size();++i)if(!widths[i])widths[i]=remaining/std::max(size_t(1),pending);
        for(size_t i=0;i<rows.size();++i) {
            auto &r=rows[i];double x=pad+used,w=widths[i];Box box{x,y,w,rowH};
            if(r.selected)panel.fills.push_back({box,p.highlight,4});
            put(r.index,r.selected?p.selected:p.index,x+8,y+(rowH+p.indexFont*.7)/2);
            put(truncate(fonts,std::move(r.word),std::max(0.0,w-r.index.width-21)),r.selected?p.selected:p.text,x+13+r.index.width,y+(rowH+p.font*.7)/2);
            hit(box,GC_PANEL_HIT_CHOOSE,page*pageSize+int(i));used+=w+4;
        }
        if(pages>1){double x=panel.w-pad-pageRun.width;put(pageRun,p.page,x,y+(rowH+p.indexFont*.7)/2);
            if(page>0)hit({x-4,y,pageRun.width/2+4,rowH},GC_PANEL_HIT_PAGE_PREV);
            if(page+1<pages)hit({x+pageRun.width/2,y,pageRun.width/2+4,rowH},GC_PANEL_HIT_PAGE_NEXT);}
        y+=rowH;
        for(auto &r:rows)if(r.selected && glossOn && r.gloss.width>0){put(truncate(fonts,std::move(r.gloss),inner-8),p.comment,pad+4,y+p.small);y+=smallH+2;break;}
    } else {
        for(size_t i=0;i<rows.size();++i) {
            auto &r=rows[i];double wordX=pad+6+r.index.width+8;
            double room=panel.w-pad-wordX-5,glossReserve=r.gloss.width>0?std::min(40.0,room*.4)+8:0;
            r.word=truncate(fonts,std::move(r.word),room-glossReserve);
            double glossX=wordX+r.word.width+8,glossWidth=std::max(0.0,panel.w-pad-glossX-5);
            bool wrapGloss=learning && string(frame,"direction",16)=="zhToEn" && r.selected;
            auto lines=wrapGloss?wrap(fonts,r.gloss,glossWidth,6,false):std::vector<Run>{truncate(fonts,std::move(r.gloss),glossWidth)};
            double height=rowH+std::max(0,int(lines.size())-1)*smallH;Box box{pad,y,inner,height};
            if(r.selected)panel.fills.push_back({{pad,y,inner+(p.legacy?std::min(4.0,pad):0),height},p.highlight,4});
            put(r.index,r.selected?p.selected:p.index,pad+6,y+(rowH+p.indexFont*.7)/2);
            put(r.word,r.selected?p.selected:p.text,wordX,y+(rowH+p.font*.7)/2);
            for(size_t n=0;n<lines.size();++n)put(lines[n],r.selected?p.selectedComment:p.comment,glossX,y+(rowH+p.small*.7)/2+n*smallH);
            hit(box,GC_PANEL_HIT_CHOOSE,page*pageSize+int(i));y+=height;
        }
        if(pages>1){double x=panel.w-pad-pageRun.width;put(pageRun,p.page,x,y+p.indexFont+2);
            if(page>0)hit({x-4,y,pageRun.width/2+4,smallH},GC_PANEL_HIT_PAGE_PREV);
            if(page+1<pages)hit({x+pageRun.width/2,y,pageRun.width/2+4,smallH},GC_PANEL_HIT_PAGE_NEXT);y+=smallH+2;}
    }
    if(!status.empty()){auto lines=wrap(fonts,statusRun,inner,3,false);for(auto &line:lines){put(line,p.cursor,pad,y+p.small);y+=smallH;}y+=2;}
    if(!toast.empty()){put(truncate(fonts,fonts.shape(toast,p.small),inner),p.cursor,pad,y+p.small);y+=smallH+2;}
    if(original||restore){double x=pad;for(auto action:{GC_PANEL_HIT_ORIGINAL,GC_PANEL_HIT_RESTORE}){
        if((action==GC_PANEL_HIT_ORIGINAL&&!original)||(action==GC_PANEL_HIT_RESTORE&&!restore))continue;
        auto title=fonts.shape(action==GC_PANEL_HIT_ORIGINAL?"原文上屏":"恢复草稿",p.small);double width=title.width+16;
        if(x+width>panel.w-pad){y+=smallH+8;x=pad;}
        put(title,p.cursor,x+8,y+p.small+4);hit({x,y,width,smallH+8},action);x+=width+8;
    }y+=smallH+8;}
    panel.h=std::max(24.0,y+pad);return panel;
}

int render(const char *frame,size_t frameLen,const char *theme,size_t themeLen,double scale,int dark,GcPanelResult **out,bool pixels,const PreparedTheme *prepared=nullptr) {
    if(!out)return 1;*out=nullptr;
    if((!frame&&frameLen)||(!theme&&themeLen)||frameLen>maxJson||themeLen>maxJson||!std::isfinite(scale)||scale<.5||scale>4)return 1;
    try {
        Json f=frame?Json::parse(frame,frame+frameLen):Json::object();
        if(!f.is_object())return 2;
        const auto &t=prepared?*prepared:themeFor(theme,themeLen);
        Palette p=palette(t.json,f,dark!=0);
        auto background=t.imageFor(p.image,pixels);
        Fonts &fonts=fontsFor(f.value("fonts",Json::array()));
        Panel panel=layout(fonts,f,p);
        int w=int(std::ceil(panel.w*scale)),h=int(std::ceil(panel.h*scale));
        if(w<=0||h<=0||size_t(w)*h>maxPixels)return 1;
        std::unique_ptr<GcPanelResult,decltype(&gc_panel_result_free)> result(static_cast<GcPanelResult *>(std::calloc(1,sizeof(GcPanelResult))),gc_panel_result_free);
        if(!result)throw std::bad_alloc{};
        result->width=w;result->height=h;result->hit_count=panel.hits.size();
        if(!panel.hits.empty()){
            result->hits=static_cast<GcPanelHitRegion *>(std::malloc(panel.hits.size()*sizeof(GcPanelHitRegion)));
            if(!result->hits)throw std::bad_alloc{};
            for(size_t i=0;i<panel.hits.size();++i){auto &hit=panel.hits[i];
                int x=std::max(0,int(std::floor(hit.box.x*scale))),y=std::max(0,int(std::floor(hit.box.y*scale)));
                int right=std::min(w,int(std::ceil((hit.box.x+hit.box.w)*scale))),bottom=std::min(h,int(std::ceil((hit.box.y+hit.box.h)*scale)));
                result->hits[i]={hit.action,hit.arg,x,y,std::max(0,right-x),std::max(0,bottom-y)};
            }
        }
        if(pixels){
            Canvas canvas(w,h,p.radius*scale);canvas.background(p.background,p.bgOpacity);
            if(background)canvas.image(*background,p.imageOpacity);
            if(!p.legacy)canvas.border(p.border,p.radius*scale,scale);
            for(auto &fill:panel.fills)canvas.rect({fill.box.x*scale,fill.box.y*scale,fill.box.w*scale,fill.box.h*scale},fill.color,1,fill.radius*scale);
            static const auto lightGamma=[] {std::array<uint8_t,256> a{};for(int i=0;i<256;++i)a[i]=uint8_t(std::round(255*std::pow(i/255.0,.85)));return a;}();
            static const auto darkGamma=[] {std::array<uint8_t,256> a{};for(int i=0;i<256;++i)a[i]=uint8_t(std::round(255*std::pow(i/255.0,.75)));return a;}();
            for(auto &text:panel.texts)canvas.text(fonts,text.run,text.color,text.x,text.baseline,scale,dark?darkGamma:lightGamma);
            const auto &data=canvas.finish(p.opacity);
            result->pixels=static_cast<uint8_t *>(std::malloc(data.size()));if(!result->pixels)throw std::bad_alloc{};
            std::memcpy(result->pixels,data.data(),data.size());
        }
        *out=result.release();return 0;
    }catch(const FontError &){return 3;}catch(const Invalid &){return 1;}catch(const Json::exception &){return 2;}
    catch(const std::bad_alloc &){return 4;}catch(...){return 5;}
}
} // namespace
struct GcPanelTheme : PreparedTheme { using PreparedTheme::PreparedTheme; };
extern "C" int32_t gc_panel_theme_create(const char *theme,size_t length,GcPanelTheme **out) {
    if(!out)return 1;*out=nullptr;
    if((!theme&&length)||length>maxJson)return 1;
    try { *out=new GcPanelTheme(parseTheme(theme,length));return 0; }
    catch(const Json::exception &){return 2;}catch(const std::bad_alloc &){return 4;}catch(...){return 5;}
}
extern "C" void gc_panel_theme_free(GcPanelTheme *theme){delete theme;}
extern "C" int32_t gc_panel_render_prepared(const char *f,size_t fl,const GcPanelTheme *t,double s,int32_t d,GcPanelResult **out){
    if(!t){if(out)*out=nullptr;return 1;}return render(f,fl,nullptr,0,s,d,out,true,t);
}
extern "C" int32_t gc_panel_layout_prepared(const char *f,size_t fl,const GcPanelTheme *t,double s,int32_t d,GcPanelResult **out){
    if(!t){if(out)*out=nullptr;return 1;}return render(f,fl,nullptr,0,s,d,out,false,t);
}
extern "C" int32_t gc_panel_render(const char *f,size_t fl,const char *t,size_t tl,double s,int32_t d,GcPanelResult **out){return render(f,fl,t,tl,s,d,out,true);}
extern "C" int32_t gc_panel_layout(const char *f,size_t fl,const char *t,size_t tl,double s,int32_t d,GcPanelResult **out){return render(f,fl,t,tl,s,d,out,false);}
extern "C" void gc_panel_result_free(GcPanelResult *result){if(!result)return;std::free(result->pixels);std::free(result->hits);std::free(result);}
