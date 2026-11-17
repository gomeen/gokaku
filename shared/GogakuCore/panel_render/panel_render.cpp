// 候选窗位图渲染器：一处实现，两端贴图（S2）。
//
// 输入帧 JSON＋有效主题 JSON → 预乘 RGBA 位图＋命中区域表。
// 布局规格与 macos/Sources/GogakuInput/CandidatePanel.swift 的竖排／横排
// 实现一致（行高 46×字号/21、内边距 8、圆角 8、高亮扩 4 圆角 4、横排
// [320,860]、竖排 [180,440]、页码仅多页显示、横排高亮释义行）。
// 文字：vendored HarfBuzz 整形＋FreeType 栅格（FT_LOAD_NO_HINTING，
// advance 与 CoreText 一致——见 docs/validation/bitmap-renderer-spike.md）。
// emoji：SBIX/CBDT strike 位图直接 blit（FT_LOAD_COLOR）。
//
// 无状态；线程不安全（单候选窗串行）。异常不跨 ABI。
#include "../panel_render.h"

#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MODULE_H
#include <harfbuzz/hb.h>
#include <harfbuzz/hb-ft.h>

#include "../../third_party/json.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

using Json = nlohmann::json;

constexpr int kErrParam = 1, kErrJson = 2, kErrFont = 3, kErrMemory = 4, kErrInternal = 5;

// ── 调色板：主题 JSON 的语义色位（与 theme_contract.cpp 的 keys 一致） ──
struct Rgb {
    double r, g, b;
};
struct Palette {
    Rgb background{1, 1, 1}, border{0.84, 0.87, 0.85}, text{0.13, 0.16, 0.15};
    Rgb comment{0.49, 0.35, 0}, index{0.47, 0.51, 0.49};
    Rgb highlight{0.07, 0.6, 0.42}, highlightText{1, 1, 1}, highlightComment{1, 1, 1};
    Rgb cursor{0.32, 0.4, 0.35}, page{0.48, 0.53, 0.5};
    double radius = 8, padding = 8, rowHeight = 100;
    double opacity = 100, bgOpacity = 100;
    double fontSize = 14, indexSize = 11;
};

Rgb rgbOf(const Json &v, Rgb fallback) {
    if (!v.is_number_unsigned()) return fallback;
    uint32_t raw = v.get<uint32_t>();
    return {(raw >> 16 & 255) / 255.0, (raw >> 8 & 255) / 255.0, (raw & 255) / 255.0};
}

Palette parseTheme(const Json &theme, bool dark) {
    Palette p;
    Json pal = theme;
    if (theme.contains("light"))
        pal = (dark && theme.contains("dark")) ? theme["dark"] : theme["light"];
    auto color = [&](const char *key, Rgb fb) { return rgbOf(pal.value(key, Json()), fb); };
    p.background = color("background", p.background);
    p.border = color("border", p.border);
    p.text = color("text", p.text);
    p.comment = color("comment", p.comment);
    p.index = color("index", p.index);
    p.highlight = color("highlight", p.highlight);
    p.highlightText = color("highlightText", p.highlightText);
    p.highlightComment = color("highlightComment", p.highlightComment);
    p.cursor = color("cursor", p.cursor);
    p.page = color("page", p.page);
    if (pal.contains("visual")) {
        const Json &v = pal["visual"];
        p.radius = v.value("radius", 8.0);
        p.padding = v.value("padding", 8.0);
        p.rowHeight = v.value("rowHeight", 100.0);
        p.opacity = v.value("opacity", 100.0);
        p.bgOpacity = v.value("bgOpacity", 100.0);
    }
    if (theme.contains("typography")) {
        const Json &t = theme["typography"];
        p.fontSize = t.value("fontSize", 14.0);
        p.indexSize = t.value("indexSize", 11.0);
    }
    return p;
}

// ── 字体集：帧 fonts 数组按序打开，候选字体在前、emoji 兜底在后 ──
struct GlyphRender {
    int w = 0, h = 0, left = 0, top = 0;
    std::vector<uint8_t> gray; // 8bit 覆盖率
    std::vector<uint8_t> bgra; // BGRA 彩色（emoji）
    bool color = false;
};

class Shaper {
public:
    Shaper() { FT_Init_FreeType(&ft_); }
    ~Shaper() {
        for (auto &f : faces_) {
            hb_font_destroy(f.hb);
            FT_Done_Face(f.ft);
        }
        if (ft_) FT_Done_FreeType(ft_);
    }

    int addFace(const std::string &path, int index, bool emoji) {
        FT_Face ft;
        if (FT_New_Face(ft_, path.c_str(), index, &ft)) return 1;
        FT_Select_Charmap(ft, FT_ENCODING_UNICODE);
        hb_font_t *hb = hb_ft_font_create_referenced(ft);
        hb_ft_font_set_load_flags(hb, FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP);
        faces_.push_back({ft, hb, emoji});
        return 0;
    }
    bool empty() const { return faces_.empty(); }

    // 每次整形前同步字号：hb-ft 的缩放在创建时固定，FT_Set_Char_Size 后
    // 必须 hb_ft_font_changed 通知，否则 advance 全为 0（S2 调试发现）。
    void setPt(double pt) {
        if (pt == lastPt_) return;
        for (auto &f : faces_) {
            FT_Set_Char_Size(f.ft, 0, static_cast<FT_F26Dot6>(pt * 64), 72, 72);
            hb_ft_font_changed(f.hb);
        }
        lastPt_ = pt;
    }

    struct ShapedGlyph {
        size_t face;
        uint32_t gid;
        double advance, offsetX, offsetY;
        uint32_t cluster;
    };

    // 逐字形回退：每个 cluster 取第一个有非 notdef gid 的 face（emoji 字形
    // 自然落到 emoji face，汉字落在文本 face；整段回退会让 emoji 行全 notdef）。
    std::vector<ShapedGlyph> shape(const std::string &utf8, double pt) {
        setPt(pt);
        std::vector<ShapedGlyph> out;
        struct Piece {
            std::string text;
            size_t face;
            uint32_t cluster;
        };
        // 先按 codepoint 切段（每段试 face；emoji 段独立）。
        hb_buffer_t *buf = hb_buffer_create();
        auto fill_with = [&](hb_buffer_t *b, const std::string &text) {
            hb_buffer_reset(b);
            hb_buffer_add_utf8(b, text.c_str(), -1, 0, -1);
            hb_buffer_guess_segment_properties(b);
            hb_buffer_set_language(b, hb_language_from_string("zh-CN", 5));
        };
        size_t pos = 0;
        while (pos < utf8.size()) {
            // 取一个 UTF-8 标量。
            unsigned char lead = utf8[pos];
            size_t len = lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4;
            std::string ch = utf8.substr(pos, len);
            uint32_t cluster = (uint32_t)pos;
            size_t chosen = 0;
            bool mapped = false;
            for (size_t fi = 0; fi < faces_.size(); ++fi) {
                fill_with(buf, ch);
                hb_shape(faces_[fi].hb, buf, nullptr, 0);
                unsigned n = 0;
                hb_glyph_info_t *gi = hb_buffer_get_glyph_infos(buf, &n);
                if (n >= 1 && gi[0].codepoint != 0) {
                    hb_glyph_position_t *gp = hb_buffer_get_glyph_positions(buf, &n);
                    out.push_back({fi, gi[0].codepoint, gp[0].x_advance / 64.0,
                                   gp[0].x_offset / 64.0, gp[0].y_offset / 64.0, cluster});
                    chosen = fi;
                    mapped = true;
                    break;
                }
            }
            if (!mapped) {
                // 全部 face 缺字：用首 face 的 notdef 占位（保持宽度）。
                fill_with(buf, ch);
                hb_shape(faces_[0].hb, buf, nullptr, 0);
                unsigned n = 0;
                hb_glyph_info_t *gi = hb_buffer_get_glyph_infos(buf, &n);
                hb_glyph_position_t *gp = hb_buffer_get_glyph_positions(buf, &n);
                if (n >= 1)
                    out.push_back({0, gi[0].codepoint, gp[0].x_advance / 64.0,
                                   gp[0].x_offset / 64.0, gp[0].y_offset / 64.0, cluster});
            }
            pos += len;
        }
        hb_buffer_destroy(buf);
        return out;
    }

    // 光栅：文本 face 按字号矢量栅格；emoji face 选最近 strike 的固定位图，
    // blit 时缩放到目标行高（sbix 只在请求恰等 strike 时出位图，S2 实测）。
    // 返回的 GlyphRender 带源尺寸，drawRun 用 scale 参数缩放。
    GlyphRender raster(size_t faceIndex, uint32_t gid, double pt, double scale) {
        GlyphRender g;
        Face &f = faces_[faceIndex];
        if (f.emoji) {
            // sbix 只在请求字号恰等于 strike 名义 size 时出位图（20/26/32/…）；
            // 选最近名义 size 设字号，位图按 pt×scale/strike高 缩放贴图。
            int best = 0;
            double bestDist = 1e9;
            for (long i = 0; i < f.ft->num_fixed_sizes; ++i) {
                double dist = std::abs(f.ft->available_sizes[i].size / 64.0 - pt * scale);
                if (dist < bestDist) { bestDist = dist; best = (int)i; }
            }
            FT_Set_Char_Size(f.ft, 0, f.ft->available_sizes[best].size, 72, 72);
            if (FT_Load_Glyph(f.ft, gid, FT_LOAD_NO_HINTING | FT_LOAD_COLOR)) return g;
            FT_GlyphSlot slot = f.ft->glyph;
            if (slot->bitmap.pixel_mode != FT_PIXEL_MODE_BGRA) return g;
            g.color = true;
            g.w = slot->bitmap.width; g.h = slot->bitmap.rows;
            g.left = slot->bitmap_left; g.top = slot->bitmap_top;
            g.bgra.assign(slot->bitmap.buffer, slot->bitmap.buffer + (size_t)g.w * g.h * 4);
            return g;
        }
        FT_Set_Char_Size(f.ft, 0, static_cast<FT_F26Dot6>(pt * 64), 72, 72);
        if (FT_Load_Glyph(f.ft, gid, FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP | FT_LOAD_COLOR))
            return g;
        FT_GlyphSlot slot = f.ft->glyph;
        if (FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL)) return g;
        if (slot->bitmap.pixel_mode != FT_PIXEL_MODE_GRAY) return g;
        g.w = slot->bitmap.width; g.h = slot->bitmap.rows;
        g.left = slot->bitmap_left; g.top = slot->bitmap_top;
        g.gray.assign(slot->bitmap.buffer,
                      slot->bitmap.buffer + (size_t)std::abs(slot->bitmap.pitch) * g.h);
        return g;
    }

private:
    struct Face {
        FT_Face ft;
        hb_font_t *hb;
        bool emoji;
    };
    FT_Library ft_ = nullptr;
    std::vector<Face> faces_;
    double lastPt_ = 0;
};

// ── 位图与合成（预乘 RGBA） ──
class Canvas {
public:
    Canvas(int w, int h)
        : w_(std::max(1, w)), h_(std::max(1, h)), data_((size_t)w_ * h_ * 4, 0) {}
    int width() const { return w_; }
    int height() const { return h_; }
    uint8_t *pixels() { return data_.data(); }
    size_t size() const { return data_.size(); }

    void fillRounded(Rgb color, double radius, double alpha) {
        for (int y = 0; y < h_; ++y)
            for (int x = 0; x < w_; ++x) {
                double cov = roundedCov(x, y, w_, h_, radius);
                if (cov > 0) blend(x, y, color.r * 255, color.g * 255, color.b * 255, cov * alpha);
            }
    }

    void rect(double x, double y, double w, double h, Rgb color, double alpha, double radius) {
        int x0 = std::max(0, (int)std::floor(x)), x1 = std::min(w_ - 1, (int)std::ceil(x + w));
        int y0 = std::max(0, (int)std::floor(y)), y1 = std::min(h_ - 1, (int)std::ceil(y + h));
        for (int row = y0; row <= y1; ++row)
            for (int col = x0; col <= x1; ++col) {
                double lx = col - x, ly = row - y;
                double cov = roundedCov(lx, ly, w, h, radius);
                if (cov > 0) blend(col, row, color.r * 255, color.g * 255, color.b * 255, cov * alpha);
            }
    }

    void glyphGray(const GlyphRender &g, Rgb color, double x, double y, double gamma) {
        for (int row = 0; row < g.h; ++row)
            for (int col = 0; col < g.w; ++col) {
                double cov = g.gray[(size_t)row * g.w + col] / 255.0;
                cov = std::pow(cov, gamma);
                blend(int(x + col), int(y + row), color.r * 255, color.g * 255, color.b * 255, cov);
            }
    }

    void glyphBgra(const GlyphRender &g, double x, double y) {
        for (int row = 0; row < g.h; ++row)
            for (int col = 0; col < g.w; ++col) {
                const uint8_t *p = &g.bgra[((size_t)row * g.w + col) * 4];
                blend(int(x + col), int(y + row), p[2], p[1], p[0], p[3] / 255.0);
            }
    }

    // emoji strike 缩放贴图（最近邻；候选窗 emoji 尺寸小，观感足够）。
    void glyphBgraScaled(const GlyphRender &g, double x, double y, double s) {
        int outH = (int)std::ceil(g.h * s), outW = (int)std::ceil(g.w * s);
        for (int row = 0; row < outH; ++row)
            for (int col = 0; col < outW; ++col) {
                int sy = std::min(g.h - 1, (int)(row / s));
                int sx = std::min(g.w - 1, (int)(col / s));
                const uint8_t *p = &g.bgra[((size_t)sy * g.w + sx) * 4];
                blend(int(x + col), int(y + row), p[2], p[1], p[0], p[3] / 255.0);
            }
    }

private:
    static double roundedCov(double lx, double ly, double w, double h, double radius) {
        double dx = std::max(radius - lx, lx - (w - 1.0 - radius));
        double dy = std::max(radius - ly, ly - (h - 1.0 - radius));
        double dist = std::hypot(std::max(dx, 0.0), std::max(dy, 0.0));
        if (dist <= radius - 0.5) return 1.0;
        if (dist >= radius + 0.5) return 0.0;
        return radius + 0.5 - dist;
    }
    void blend(int x, int y, double r, double g, double b, double a) {
        if (x < 0 || y < 0 || x >= w_ || y >= h_ || a <= 0) return;
        uint8_t *p = &data_[((size_t)y * w_ + x) * 4];
        p[0] = (uint8_t)(p[0] * (1 - a) + r * a);
        p[1] = (uint8_t)(p[1] * (1 - a) + g * a);
        p[2] = (uint8_t)(p[2] * (1 - a) + b * a);
        p[3] = (uint8_t)(p[3] * (1 - a) + 255 * a);
    }
    int w_, h_;
    std::vector<uint8_t> data_;
};

// ── 文本段：整形一次，布局（量宽）与绘制共用 ──
struct TextRun {
    std::vector<Shaper::ShapedGlyph> glyphs;
    double widthPt = 0;
};

struct Frame {
    bool horizontal = false;
    int pageSize = 9;
    bool glossRow = false;
    std::string preedit;
    std::vector<std::string> candText, candGloss;
    int selected = 0, page = 0, pageCount = 1, total = 0;
    std::string status, toast;
    bool hasRestore = false, hasOriginal = false;
};

Frame parseFrame(const Json &j) {
    Frame f;
    f.horizontal = j.value("layout", std::string("vertical")) == "horizontal";
    f.pageSize = std::clamp(j.value("pageSize", 9), 1, 99);
    f.glossRow = j.value("glossRow", false);
    f.preedit = j.value("preedit", std::string());
    f.selected = j.value("selected", 0);
    f.page = j.value("page", 0);
    f.pageCount = std::max(1, j.value("pageCount", 1));
    f.total = j.value("total", 0);
    f.status = j.value("status", std::string());
    f.toast = j.value("toast", std::string());
    f.hasRestore = j.value("hasRestore", false);
    f.hasOriginal = j.value("hasOriginal", false);
    if (j.contains("candidates"))
        for (const auto &c : j["candidates"]) {
            f.candText.push_back(c.value("text", std::string()));
            f.candGloss.push_back(c.value("gloss", std::string()));
        }
    return f;
}

// ── 布局（pt；渲染时 ×scale） ──
struct LayoutBox {
    double x = 0, y = 0, w = 0, h = 0;
};
struct PreparedRow {
    LayoutBox box;
    TextRun index, word;
    double indexX = 0, wordX = 0;
    int shownIndex = 0;
    bool selected = false;
};
struct PreparedPanel {
    double panelW = 0, panelH = 0, innerW = 0;
    double rowY = 0, rowH = 0;
    bool rowsHorizontal = false;
    std::vector<PreparedRow> rows;
    bool hasPreedit = false;
    double preeditBaseline = 0;
    TextRun preedit;
    bool hasGloss = false;
    double glossBaseline = 0;
    TextRun gloss;
    bool hasStatus = false;
    double statusBaseline = 0;
    TextRun status;
    bool hasPage = false;
    LayoutBox pageBox;
    TextRun pageLabel;
    std::vector<GcPanelHitRegion> hits;
};

PreparedPanel layout(Shaper &shaper, const Frame &f, const Palette &p) {
    PreparedPanel out;
    out.rowsHorizontal = f.horizontal;
    const double candidatePt = p.fontSize;
    const double commentPt = p.fontSize - 1;
    const double indexPt = std::max(p.indexSize, p.fontSize - 3);

    // 行高锚定 macos 版：legacy 主题 46×字号/21，主题级 visual.rowHeight 是缩放
    // 百分比（100 = 不缩）；内容行高下限取候选行文本高。
    const double commentH = commentPt * 19.0 / 15.0;
    const double pageH = indexPt * 20.0 / 16.0;
    const double baseRowH = p.rowHeight * 46.0 * candidatePt / 21.0 / 100.0;
    out.rowH = std::max({baseRowH, candidatePt * 28.0 / 21.0, commentH, pageH});
    const double preeditH = commentH;
    const double pad = p.padding;

    int inPage = f.candText.empty()
        ? 0
        : std::clamp(f.selected - f.page * f.pageSize, 0, (int)f.candText.size() - 1);

    auto shapeAt = [&](double pt, const std::string &s) {
        // setScale 逐 face；shape 内部用各 face 当前尺寸。
        for (size_t fi = 0; fi < 1; ++fi) (void)fi;
        TextRun run;
        run.glyphs = shaper.shape(s, candidatePt);
        run.widthPt = 0;
        for (auto &g : run.glyphs) run.widthPt += g.advance;
        return run;
    };

    // 竖排注释列宽。
    double maxGloss = 0;
    std::vector<TextRun> glossRuns;
    if (!f.horizontal) {
        for (size_t i = 0; i < f.candText.size(); ++i) {
            if (i < f.candGloss.size() && !f.candGloss[i].empty()) {
                TextRun r;
                r.glyphs = shaper.shape(f.candGloss[i], commentPt);
                for (auto &g : r.glyphs) r.widthPt += g.advance;
                maxGloss = std::max(maxGloss, r.widthPt);
                glossRuns.push_back(std::move(r));
            } else {
                glossRuns.push_back({});
            }
        }
    }

    // 候选行（横排 chip / 竖排行）。
    double wordW = 0;
    for (size_t i = 0; i < f.candText.size(); ++i) {
        PreparedRow row;
        row.shownIndex = (int)i;
        row.selected = (int)i == inPage;
        row.index.glyphs = shaper.shape(std::to_string(i + 1), indexPt);
        for (auto &g : row.index.glyphs) row.index.widthPt += g.advance;
        row.word.glyphs = shaper.shape(f.candText[i], candidatePt);
        for (auto &g : row.word.glyphs) row.word.widthPt += g.advance;
        if (!f.horizontal)
            wordW = std::max(wordW, row.index.widthPt + 4 + row.word.widthPt);
        out.rows.push_back(std::move(row));
    }

    if (f.horizontal) {
        TextRun pageRun;
        bool hasPage = f.pageCount > 1;
        if (hasPage) {
            pageRun.glyphs = shaper.shape(
                std::to_string(f.page + 1) + "/" + std::to_string(f.pageCount), indexPt);
            for (auto &g : pageRun.glyphs) pageRun.widthPt += g.advance;
        }
        double pageReserve = hasPage ? pageRun.widthPt + 12 : 0;
        double chipX = pad + 2;
        for (auto &row : out.rows) {
            double chipW = row.index.widthPt + 5 + row.word.widthPt + 8 * 2;
            row.box = {chipX, 0, chipW, out.rowH};
            row.indexX = chipX + 8;
            row.wordX = chipX + 8 + row.index.widthPt + 5;
            chipX += chipW + 4;
        }
        double chipsW = out.rows.empty() ? 0 : (out.rows.back().box.x + out.rows.back().box.w) - pad;
        double minInner = std::max(320.0 - pad * 2, 1.0);
        double maxInner = std::max(860.0 - pad * 2, minInner);
        out.innerW = std::min(std::max(chipsW + pageReserve, minInner), maxInner);
        if (hasPage) {
            double pageLeft = out.innerW + pad - pageRun.widthPt - 6;
            while (!out.rows.empty()
                   && out.rows.back().box.x + out.rows.back().box.w > pageLeft - 8)
                out.rows.pop_back();
        }
        if (hasPage) {
            out.hasPage = true;
            out.pageLabel = std::move(pageRun);
            out.pageBox = {out.innerW + pad - out.pageLabel.widthPt - 6, 0,
                           out.pageLabel.widthPt, pageH};
        }
    } else {
        double minInner = std::max(180.0 - pad * 2, 1.0);
        double maxInner = std::max(440.0 - pad * 2, minInner);
        out.innerW = std::min(std::max(wordW + (maxGloss > 0 ? 8 + maxGloss : 0), minInner),
                              maxInner);
        // 超宽注释整体截断（右缘留 6pt；不追加省略号，宽注释本身有「…」语义位）。
        if (maxGloss > 0) {
            double avail = out.innerW - wordW - 8;
            for (auto &run : glossRuns) {
                if (run.widthPt <= avail) continue;
                double acc = 0;
                std::vector<Shaper::ShapedGlyph> keep;
                for (auto &g : run.glyphs) {
                    if (acc + g.advance > avail - commentPt) break;
                    keep.push_back(g);
                    acc += g.advance;
                }
                run.glyphs = std::move(keep);
                run.widthPt = acc;
            }
        }
        // 行几何（竖排）。
        for (size_t i = 0; i < out.rows.size(); ++i) {
            PreparedRow &row = out.rows[i];
            row.box = {pad, 0, out.innerW, out.rowH};
            row.indexX = pad + 6;
            row.wordX = pad + 6 + row.index.widthPt + 4;
        }
        // 页码（竖排在行后）。
        if (f.pageCount > 1) {
            out.hasPage = true;
            out.pageLabel.glyphs = shaper.shape(
                std::to_string(f.page + 1) + "/" + std::to_string(f.pageCount), indexPt);
            for (auto &g : out.pageLabel.glyphs) out.pageLabel.widthPt += g.advance;
        }
    }

    // 纵向排布。
    double y = pad;
    if (!f.preedit.empty()) {
        out.hasPreedit = true;
        out.preedit.glyphs = shaper.shape(f.preedit, commentPt);
        for (auto &g : out.preedit.glyphs) out.preedit.widthPt += g.advance;
        y += preeditH + 4;
    }
    out.rowY = y;
    if (f.horizontal) {
        for (auto &row : out.rows) row.box.y = out.rowY;
        y += out.rowH;
        if (f.glossRow && inPage < (int)f.candGloss.size() && !f.candGloss[inPage].empty()) {
            out.hasGloss = true;
            out.gloss.glyphs = shaper.shape(f.candGloss[inPage], commentPt);
            for (auto &g : out.gloss.glyphs) out.gloss.widthPt += g.advance;
            // 释义行截宽。
            double avail = out.innerW - 8;
            if (out.gloss.widthPt > avail) {
                double acc = 0;
                std::vector<Shaper::ShapedGlyph> keep;
                for (auto &g : out.gloss.glyphs) {
                    if (acc + g.advance > avail - commentPt) break;
                    keep.push_back(g);
                    acc += g.advance;
                }
                out.gloss.glyphs = std::move(keep);
                out.gloss.widthPt = acc;
            }
            out.glossBaseline = y + commentPt + 1;
            y += commentH + 2;
        }
        if (out.hasPage) out.pageBox.y = out.rowY + (out.rowH - pageH) / 2;
    } else {
        double rowsBottom = out.rowY + std::max((double)out.rows.size(), 1.0) * out.rowH;
        for (size_t i = 0; i < out.rows.size(); ++i)
            out.rows[i].box.y = out.rowY + (double)i * out.rowH;
        y = rowsBottom;
        if (out.hasPage) {
            out.pageBox = {out.innerW + pad - out.pageLabel.widthPt - 6, y + 2,
                           out.pageLabel.widthPt, pageH};
            y += pageH;
        }
    }
    if (!f.status.empty()) {
        out.hasStatus = true;
        out.status.glyphs = shaper.shape(f.status, commentPt);
        for (auto &g : out.status.glyphs) out.status.widthPt += g.advance;
        out.statusBaseline = y + commentPt;
        y += commentH + 2;
    }
    y += pad;
    out.panelW = out.innerW + pad * 2;
    out.panelH = f.horizontal
        ? std::max(y, out.rowY + out.rowH + pad)
        : std::max(y, out.rowY + std::max((double)out.rows.size(), 1.0) * out.rowH + pad);
    return out;
}

void drawRun(Shaper &shaper, Canvas &canvas, const TextRun &run, Rgb color,
             double xPt, double baselinePt, double scale, double gamma,
             double rasterPt) {
    double x = xPt;
    for (auto &g : run.glyphs) {
        GlyphRender r = shaper.raster(g.face, g.gid, rasterPt, scale);
        if (r.color) {
            // emoji strike 位图按 pt×scale/strike 高缩放贴到基线。
            double s = r.h > 0 ? rasterPt * scale / r.h : 1.0;
            canvas.glyphBgraScaled(r, x * scale, baselinePt * scale - r.h * s, s);
        } else if (r.w || r.h) {
            canvas.glyphGray(r, color, x * scale + r.left * scale,
                             baselinePt * scale - r.top * scale, gamma);
        }
        x += g.advance;
    }
}

}  // namespace

extern "C" int32_t gc_panel_render(const char *frame, size_t frame_len,
                                   const char *theme, size_t theme_len,
                                   double scale, int32_t dark,
                                   GcPanelResult **out) {
    if ((!frame && frame_len) || (!theme && theme_len) || !out) return kErrParam;
    *out = nullptr;
    try {
        Json frameJson = frame ? Json::parse(frame, frame + frame_len) : Json::object();
        Json themeJson = theme ? Json::parse(theme, theme + theme_len) : Json::object();
        if (!frameJson.is_object() || !themeJson.is_object()) return kErrJson;
        Frame f = parseFrame(frameJson);
        if (f.candText.empty() && f.preedit.empty() && f.status.empty() && f.toast.empty())
            return kErrParam;
        Palette p = parseTheme(themeJson, dark != 0);

        Shaper shaper;
        if (frameJson.contains("fonts"))
            for (const auto &e : frameJson["fonts"]) {
                std::string path = e.value("path", std::string());
                if (path.empty()) continue;
                if (shaper.addFace(path, e.value("index", 0), e.value("emoji", false)))
                    continue; // 打不开的字体跳过，回退链继续
            }
        if (shaper.empty()) return kErrFont;

        PreparedPanel L = layout(shaper, f, p);
        double s = scale > 0.01 ? scale : 1.0;
        int w = (int)std::ceil(L.panelW * s), h = (int)std::ceil(L.panelH * s);
        auto result = std::make_unique<GcPanelResult>();
        result->width = w;
        result->height = h;
        result->pixels = (uint8_t *)std::malloc((size_t)std::max(1, w) * std::max(1, h) * 4);
        if (!result->pixels) return kErrMemory;

        Canvas canvas(w, h);
        double gamma = dark ? 0.75 : 0.85;
        canvas.fillRounded(p.background, p.radius, p.bgOpacity / 100.0 * p.opacity / 100.0);

        const double commentPt = p.fontSize - 1;
        const double indexPt = std::max(p.indexSize, p.fontSize - 3);

        if (L.hasPreedit)
            drawRun(shaper, canvas, L.preedit, p.text, p.padding, p.padding + commentPt,
                    s, gamma, commentPt);
        for (auto &row : L.rows) {
            double baseline = row.box.y + row.box.h / 2 + p.fontSize * 0.36;
            if (row.selected)
                canvas.rect(row.box.x * s, row.box.y * s,
                            (row.box.w + (L.rowsHorizontal ? 0 : 4)) * s, row.box.h * s,
                            p.highlight, 1.0, 4 * s);
            Rgb indexColor = row.selected ? p.highlightComment : p.index;
            Rgb wordColor = row.selected ? p.highlightText : p.text;
            drawRun(shaper, canvas, row.index, indexColor, row.indexX, baseline, s, gamma, indexPt);
            drawRun(shaper, canvas, row.word, wordColor, row.wordX, baseline, s, gamma, p.fontSize);
            GcPanelHitRegion hit{GC_PANEL_HIT_CHOOSE,
                                 (int32_t)(f.page * f.pageSize + row.shownIndex),
                                 (int32_t)(row.box.x * s), (int32_t)(row.box.y * s),
                                 (int32_t)std::ceil(row.box.w * s),
                                 (int32_t)std::ceil(row.box.h * s)};
            GcPanelHitRegion *grown = (GcPanelHitRegion *)std::realloc(
                result->hits, sizeof(GcPanelHitRegion) * (result->hit_count + 1));
            if (!grown) { std::free(result->pixels); return kErrMemory; }
            result->hits = grown;
            result->hits[result->hit_count++] = hit;
        }
        if (L.hasGloss)
            drawRun(shaper, canvas, L.gloss, p.comment, p.padding + 4, L.glossBaseline,
                    s, gamma, commentPt);
        if (L.hasStatus)
            drawRun(shaper, canvas, L.status, p.comment, p.padding, L.statusBaseline,
                    s, gamma, commentPt);
        if (L.hasPage)
            drawRun(shaper, canvas, L.pageLabel, p.page, L.pageBox.x,
                    L.pageBox.y + indexPt, s, gamma, indexPt);

        std::memcpy(result->pixels, canvas.pixels(), canvas.size());
        *out = result.release();
        return 0;
    } catch (const Json::parse_error &) {
        return kErrJson;
    } catch (const std::bad_alloc &) {
        return kErrMemory;
    } catch (...) {
        return kErrInternal;
    }
}

extern "C" void gc_panel_result_free(GcPanelResult *result) {
    if (!result) return;
    std::free(result->pixels);
    std::free(result->hits);
    std::free(result);
}
