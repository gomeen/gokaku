// Gogaku S1 渲染器 spike：回答「文字观感与性能是否可行」。
//
// 用 HarfBuzz 整形 + FreeType 栅格 + 自写极简合成，渲染一行
// 「中文 hello 🙂 日本語 nihao」到 RGBA 位图并存 PNG，再量：
//   1) 单帧渲染耗时（含整形与栅格）
//   2) 冷启动字体库加载耗时
//   3) 宽度与 CoreText 基准（由外部 swift 脚本对拍）
//
// 只验证可行性，不进产品代码。用法：
//   clang++ -std=c++17 -O2 probes/bitmap-renderer-spike/hello_text.cpp \
//     $(pkg-config --cflags --libs freetype2 harfbuzz libpng) -o /tmp/gc-spike
//   /tmp/gc-spike --text "中文 hello 🙂 日本語" --font "PingFang SC" --out /tmp/spike.png
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_GLYPH_H
#include <harfbuzz/hb.h>
#include <harfbuzz/hb-ft.h>
#include <png.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace {

struct Rgba {
    uint8_t r, g, b, a;
};

class Bitmap {
public:
    Bitmap(int w, int h) : w_(w), h_(h), data_(w * h * 4, 0) {}
    int width() const { return w_; }
    int height() const { return h_; }
    uint8_t *row(int y) { return data_.data() + y * w_ * 4; }
    const uint8_t *row(int y) const { return data_.data() + y * w_ * 4; }

    void fillRounded(Rgba color, double radius) {
        for (int y = 0; y < h_; ++y) {
            for (int x = 0; x < w_; ++x) {
                double dx = std::max(radius - x, x - (w_ - 1 - radius));
                double dy = std::max(radius - y, y - (h_ - 1 - radius));
                double dist = std::hypot(std::max(dx, 0.0), std::max(dy, 0.0));
                double alpha = dist <= radius - 0.5 ? 1.0
                             : dist >= radius + 0.5 ? 0.0
                                                     : radius + 0.5 - dist;
                set(x, y, color, alpha);
            }
        }
    }

    // 覆盖率合成：glyph 8bit mask 前景画到 (x,y)。gamma 校正按青简经验。
    void blendMask(const uint8_t *mask, int mw, int mh, int stride, Rgba color,
                   int x, int y, double gamma) {
        for (int row = 0; row < mh; ++row) {
            int py = y + row;
            if (py < 0 || py >= h_) continue;
            for (int col = 0; col < mw; ++col) {
                int px = x + col;
                if (px < 0 || px >= w_) continue;
                double cov = mask[row * stride + col] / 255.0;
                cov = std::pow(cov, gamma);
                set(px, py, color, cov);
            }
        }
    }

private:
    void set(int x, int y, Rgba color, double alpha) {
        uint8_t *p = row(y) + x * 4;
        double a = color.a / 255.0 * alpha;
        if (a <= 0) return;
        p[3] = static_cast<uint8_t>(p[3] * (1 - a) + 255 * a);
        for (int i = 0; i < 3; ++i)
            p[i] = static_cast<uint8_t>(p[i] * (1 - a) + (&color.r)[i] * a);
    }

    int w_, h_;
    std::vector<uint8_t> data_;
};

int writePng(const Bitmap &bm, const char *path) {
    // PNG via libpng：spike 直接用，产品侧自写或换 stb。写非预乘 RGBA。
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop info = png_create_info_struct(png);
    if (setjmp(png_jmpbuf(png))) { fclose(f); return -1; }
    png_init_io(png, f);
    png_set_IHDR(png, info, bm.width(), bm.height(), 8, PNG_COLOR_TYPE_RGBA,
                 PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_write_info(png, info);
    std::vector<uint8_t> row(bm.width() * 4);
    for (int y = 0; y < bm.height(); ++y) {
        std::memcpy(row.data(), &bm.row(y)[0], row.size());
        png_write_row(png, row.data());
    }
    png_write_end(png, info);
    png_destroy_write_struct(&png, &info);
    fclose(f);
    return 0;
}

struct SpikeResult {
    double fontLoadMs;
    double shapeMs;
    double rasterMs;
    double compositeMs;
    double totalMs;
    double widthPt;
    int glyphCount;
};

const char *faceIndexEnv = nullptr;

SpikeResult renderLine(const std::string &textUtf8, const std::string &fontPath,
                       double fontSizePt, Rgba fg, Rgba bg, const char *outPath,
                       double gamma, int repeat) {
    using clock = std::chrono::steady_clock;
    SpikeResult result{};

    auto t0 = clock::now();
    FT_Library ft;
    FT_Init_FreeType(&ft);
    FT_Face face;
    FT_Long faceIndex = 0;
    if (faceIndexEnv) faceIndex = strtol(faceIndexEnv, nullptr, 10);
    FT_Error openError = FT_New_Face(ft, fontPath.c_str(), faceIndex, &face);
    if (openError) { fprintf(stderr, "FT_New_Face 失败 %d\n", openError); exit(3); }
    // 64x64 固定点：1pt = 64 单位；72dpi 下 px == pt。
    FT_Set_Char_Size(face, 0, static_cast<FT_F26Dot6>(fontSizePt * 64), 0, 72);
    hb_font_t *hbFont = hb_ft_font_create(face, nullptr);
    // NO_HINTING：advance 取设计宽度，与 CoreText 一致（nihc 26.844 vs CT 26.85）。
    hb_ft_font_set_load_flags(hbFont, FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP);
    auto t1 = clock::now();
    result.fontLoadMs = std::chrono::duration<double, std::milli>(t1 - t0).count();

    hb_buffer_t *buf = hb_buffer_create();
    hb_buffer_add_utf8(buf, textUtf8.c_str(), -1, 0, -1);
    hb_buffer_guess_segment_properties(buf);
    hb_buffer_set_language(buf, hb_language_from_string("zh-CN", 5));
    hb_shape(hbFont, buf, nullptr, 0);
    unsigned glyphCount = 0;
    hb_glyph_info_t *glyphs = hb_buffer_get_glyph_infos(buf, &glyphCount);
    hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buf, &glyphCount);
    auto t2 = clock::now();
    result.shapeMs = std::chrono::duration<double, std::milli>(t2 - t1).count();
    result.glyphCount = static_cast<int>(glyphCount);

    // 先量宽（首个 pass），再重复渲染计时。
    double widthPt = 0;
    int ascender = 0, descender = 0;
    for (unsigned i = 0; i < glyphCount; ++i)
        widthPt += (positions[i].x_advance / 64.0);
    ascender = face->size->metrics.ascender;
    descender = face->size->metrics.descender;
    result.widthPt = widthPt;

    int pad = static_cast<int>(fontSizePt * 0.6);
    int w = static_cast<int>(std::ceil(widthPt)) + pad * 2;
    int h = static_cast<int>(std::ceil((ascender - descender) / 64.0)) + pad * 2;

    double rasterMs = 0, compositeMs = 0;
    Bitmap bm(w, h);
    for (int iter = 0; iter < repeat; ++iter) {
        bm = Bitmap(w, h);
        auto ta = clock::now();
        bm.fillRounded(bg, 8);
        auto tb = clock::now();
        double penX = pad;
        double penY = pad + ascender / 64.0;
        for (unsigned i = 0; i < glyphCount; ++i) {
            FT_Load_Glyph(face, glyphs[i].codepoint, FT_LOAD_RENDER | FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP);
            FT_GlyphSlot slot = face->glyph;
            int gx = static_cast<int>(penX + slot->bitmap_left);
            int gy = static_cast<int>(penY - slot->bitmap_top);
            if (slot->bitmap.pixel_mode == FT_PIXEL_MODE_GRAY)
                bm.blendMask(slot->bitmap.buffer, slot->bitmap.width, slot->bitmap.rows,
                             slot->bitmap.pitch, fg, gx, gy, gamma);
            penX += positions[i].x_advance / 64.0;
        }
        auto tc = clock::now();
        rasterMs = std::chrono::duration<double, std::milli>(tb - ta).count();
        compositeMs = std::chrono::duration<double, std::milli>(tc - tb).count();
    }
    result.rasterMs = rasterMs;
    result.compositeMs = compositeMs;
    result.totalMs = result.fontLoadMs + result.shapeMs + rasterMs + compositeMs;
    if (outPath) writePng(bm, outPath);

    hb_buffer_destroy(buf);
    hb_font_destroy(hbFont);
    FT_Done_Face(face);
    FT_Done_FreeType(ft);
    return result;
}

}  // namespace

int main(int argc, char **argv) {
    std::string text = "中文 hello 🙂 日本語 nihao";
    std::string fontPath;
    const char *outPath = nullptr;
    double sizePt = 14;
    double gamma = 0.85;
    int repeat = 200;
    bool nameOnly = false;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--text") && i + 1 < argc) text = argv[++i];
        else if (!strcmp(argv[i], "--font") && i + 1 < argc) fontPath = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) outPath = argv[++i];
        else if (!strcmp(argv[i], "--size") && i + 1 < argc) sizePt = atof(argv[++i]);
        else if (!strcmp(argv[i], "--gamma") && i + 1 < argc) gamma = atof(argv[++i]);
        else if (!strcmp(argv[i], "--repeat") && i + 1 < argc) repeat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--name")) nameOnly = true;
    }
    if (fontPath.empty()) {
        fprintf(stderr, "需要 --font <ttf/otf 路径>\n");
        return 2;
    }
    if (nameOnly) {
        FT_Library ft;
        FT_Init_FreeType(&ft);
        for (FT_Long i = 0;; ++i) {
            FT_Face f;
            if (FT_New_Face(ft, fontPath.c_str(), i, &f)) break;
            printf("%ld\t%s / %s\n", i, f->family_name ? f->family_name : "?",
                   f->style_name ? f->style_name : "?");
            FT_Done_Face(f);
        }
        FT_Done_FreeType(ft);
        return 0;
    }
    faceIndexEnv = getenv("GC_FACE_INDEX");
    auto r = renderLine(text, fontPath, sizePt, {29, 29, 31, 255}, {245, 245, 241, 255},
                        outPath, gamma, repeat);
    printf("fontLoad=%.2fms shape=%.2fms rasterWarmup=%.2fms composite=%.2fms total=%.2fms\n",
           r.fontLoadMs, r.shapeMs, r.rasterMs, r.compositeMs, r.totalMs);
    printf("width=%.2fpt glyphs=%d\n", r.widthPt, r.glyphCount);
    return 0;
}
