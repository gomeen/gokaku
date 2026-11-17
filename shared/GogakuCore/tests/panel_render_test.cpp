// 候选窗位图渲染契约的行为向量（S2）。
// 冻结：布局几何（宽度夹紧、行高、页码仅多页、横排释义行、命中区域）、
// 错误路径（空帧、非法 JSON、缺字体）、位图非空与非全透明。
// 几何断言用 gc_panel_render 的命中区域（像素矩形）表达，两端同跑。
#include "../include/gogaku_core.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

int gFailures = 0;

void expect(bool ok, const char *what) {
    if (!ok) {
        ++gFailures;
        fprintf(stderr, "FAIL: %s\n", what);
    }
}

const char *kTheme = R"({
  "id":"gogaku","name":"Gogaku",
  "light":{"background":16777215,"border":14147545,"text":2107685,"comment":8214528,
           "index":7897981,"highlight":1218922,"highlightText":16777215,"highlightComment":16777215,
           "cursor":5465434,"page":8095872,
           "visual":{"radius":8,"padding":8,"rowHeight":100,"opacity":100,"bgOpacity":100}},
  "typography":{"fontCN":"system-ui","fontEN":"system-ui","fontSize":14,"indexSize":11}
})";

// 从环境变量取字体路径（测试机不同；缺失时跳过，退出码 3）。
std::string fontPath() {
    const char *v = getenv("GOGAKU_PANEL_FONT");
    return v ? v : "";
}

std::string frameWith(const char *extra, const std::string &font) {
    return std::string(R"({"fonts":[{"path":")") + font + R"(", "index":3}],"layout":"vertical","pageSize":9,)"
        + std::string(R"("preedit":"nihc","selected":0,"page":0,"pageCount":4,"total":31,)")
        + std::string(R"("candidates":[{"text":"你好","gloss":"(int.) hello · hi"},{"text":"您号","gloss":""},)")
        + std::string(R"({"text":"泥壕","gloss":""},{"text":"拟好","gloss":""}])")
        + std::string(extra) + "}";
}

void render(const std::string &frame, GcPanelResult **out) {
    *out = nullptr;
    int32_t rc = gc_panel_render(frame.c_str(), frame.size(), kTheme, std::strlen(kTheme),
                                 2.0, 0, out);
    expect(rc == 0, "gc_panel_render 成功");
    (void)rc;
}

}  // namespace

int main() {
    std::string font = fontPath();
    if (font.empty()) {
        fprintf(stderr, "SKIP: 未设置 GOGAKU_PANEL_FONT\n");
        return 3;
    }

    // 错误路径。
    {
        GcPanelResult *r = nullptr;
        expect(gc_panel_render("[]", 2, kTheme, strlen(kTheme), 1, 0, &r) == 2, "帧非对象拒绝");
        expect(gc_panel_render("no json", 7, kTheme, strlen(kTheme), 1, 0, &r) == 2,
               "帧非 JSON 拒绝");
        std::string empty = std::string(R"({"fonts":[{"path":")") + font + R"(", "index":3}]})";
        expect(gc_panel_render(empty.c_str(), empty.size(), kTheme, strlen(kTheme), 1, 0, &r) == 1,
               "空帧（无候选无预编辑无状态）拒绝");
        std::string nofont = R"({"fonts":[],"candidates":[{"text":"你好","gloss":""}]})";
        expect(gc_panel_render(nofont.c_str(), nofont.size(), kTheme, strlen(kTheme), 1, 0, &r) == 3,
               "缺字体拒绝");
    }

    // 竖排：四候选一页、多页页码、命中区域递增、位图非空。
    {
        GcPanelResult *r = nullptr;
        render(frameWith("", font), &r);
        if (!r) { fprintf(stderr, "SKIP: 渲染失败\n"); return 1; }
        expect(r->width > 0 && r->height > 0, "位图尺寸为正");
        expect(r->hit_count == 4, "四个候选命中区域");
        if (r->hit_count == 4) {
            expect(r->hits[0].action == GC_PANEL_HIT_CHOOSE && r->hits[0].arg == 0,
                   "首候选命中 CHOOSE arg=0");
            expect(r->hits[3].arg == 3, "末候选命中 arg=3");
            expect(r->hits[1].y > r->hits[0].y, "竖排命中纵向递增");
            expect(r->hits[1].x == r->hits[0].x, "竖排命中同列");
            expect(r->hits[0].w > 0 && r->hits[0].h > 0, "命中矩形非退化");
        }
        // 背景已填：预乘 RGBA 的 alpha 有值（角落圆角外为 0，中心必非 0）。
        size_t mid = ((size_t)r->height / 2 * r->width + r->width / 2) * 4;
        expect(r->pixels[mid + 3] > 0, "位图中心不透明");
        gc_panel_result_free(r);
    }

    // 横排：候选横向排布、宽度夹紧到 [320,860]、释义行增高。
    {
        auto horizontal = [&](bool glossRow) {
            return std::string(R"({"fonts":[{"path":")") + font +
                R"(", "index":3}],"layout":"horizontal","pageSize":7,)"
                R"("selected":0,"page":0,"pageCount":1,"total":4,)" +
                (glossRow ? R"("glossRow":true,)" : R"("glossRow":false,)") +
                R"("candidates":[{"text":"你好","gloss":"(int.) hello · hi"},{"text":"您号","gloss":""},)"
                R"({"text":"泥壕","gloss":""},{"text":"拟好","gloss":""}]})";
        };
        GcPanelResult *plain = nullptr, *gloss = nullptr;
        render(horizontal(true), &gloss);
        render(horizontal(false), &plain);
        if (gloss && plain) {
            expect(gloss->hit_count == 4, "横排四候选命中");
            if (gloss->hit_count == 4) {
                expect(gloss->hits[1].x > gloss->hits[0].x, "横排命中横向递增");
                expect(gloss->hits[1].y == gloss->hits[0].y, "横排命中同行");
            }
            expect(gloss->width >= 320 * 2 && gloss->width <= 860 * 2,
                   "横排宽度夹紧 [320,860]pt（2x）");
            expect(gloss->height > plain->height, "释义行使面板增高");
        }
        if (gloss) gc_panel_result_free(gloss);
        if (plain) gc_panel_result_free(plain);
    }

    // 单页不显示页码：pageCount=1 与 pageCount=2 的画布高度（竖排）差一行页码高。
    {
        std::string one = std::string(R"({"fonts":[{"path":")") + font +
            R"(", "index":3}],"layout":"vertical","pageSize":9,"selected":0,"page":0,)"
            R"("pageCount":1,"total":2,)"
            R"("candidates":[{"text":"你好","gloss":""},{"text":"您号","gloss":""}]})";
        std::string two = one;
        two.replace(two.find("\"pageCount\":1,"), 14, "\"pageCount\":2,");
        GcPanelResult *a = nullptr, *b = nullptr;
        render(one, &a);
        render(two, &b);
        if (a && b) expect(b->height > a->height, "多页才显示页码（高度差）");
        if (a) gc_panel_result_free(a);
        if (b) gc_panel_result_free(b);
    }

    if (gFailures) {
        fprintf(stderr, "panel_render: %d 项失败\n", gFailures);
        return 1;
    }
    printf("panel_render: 全部通过\n");
    return 0;
}
