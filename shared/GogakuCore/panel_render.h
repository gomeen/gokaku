/* 候选窗位图渲染契约（一处实现，两端贴图）。
 *
 * 实现在 panel_render/panel_render.cpp（HarfBuzz＋FreeType vendored 静态编入
 * 核心库）；行为向量在 tests/panel_render_test.cpp，两端 ctest 共跑。
 * 本头文件是唯一声明处，gogaku_core.h 包含它；导出归属规则与
 * settings_contract.h 相同（渲染器不编入 x86 TSF，只随核心 DLL 提供）。
 *
 * 渲染器无状态、线程不安全（单候选窗串行调用）；不碰 IMK／TSF／窗口 API。
 * 布局规格（行高 46×字号/21、内边距 8、圆角 8、高亮扩 4 圆角 4、宽度夹紧、
 * 横排高亮释义行）以 docs/product.md 为准，本契约不重复数值。
 */
#ifndef GOGAKU_PANEL_RENDER_H
#define GOGAKU_PANEL_RENDER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(GOGAKU_SETTINGS_CONTRACT_STATIC)
#  define GC_PANEL_RENDER_EXPORT
#elif defined(GOGAKU_CORE_EXPORT)
#  define GC_PANEL_RENDER_EXPORT GOGAKU_CORE_EXPORT
#elif defined(_WIN32) && defined(GOGAKU_CORE_BUILDING)
#  define GC_PANEL_RENDER_EXPORT __declspec(dllexport)
#elif defined(GOGAKU_CORE_BUILDING)
#  define GC_PANEL_RENDER_EXPORT __attribute__((visibility("default")))
#else
#  error "gc_panel_render 声明需要先包含 gogaku_core.h，或定义 GOGAKU_SETTINGS_CONTRACT_STATIC"
#endif

/* 命中区域动作（与两端现有候选窗回调一一对应）。 */
enum {
    GC_PANEL_HIT_NONE = 0,
    GC_PANEL_HIT_CHOOSE = 1,     /* arg = 候选全局下标（页起点＋页内下标） */
    GC_PANEL_HIT_PAGE_PREV = 2,
    GC_PANEL_HIT_PAGE_NEXT = 3,
    GC_PANEL_HIT_ORIGINAL = 4,   /* 学习组合「原文上屏」（Lite 帧不含） */
    GC_PANEL_HIT_RESTORE = 5,    /* 草稿恢复 */
    GC_PANEL_HIT_EXPLAIN = 6     /* 拼写问题说明（status 行置 explanation） */
};

typedef struct GcPanelHitRegion {
    int32_t action;   /* GC_PANEL_HIT_* */
    int32_t arg;      /* CHOOSE：候选全局下标；其余 0 */
    int32_t x, y, w, h; /* 像素矩形（输出位图坐标系） */
} GcPanelHitRegion;

/* 渲染结果。pixels 为库内分配的预乘 RGBA（每像素 4 字节，R,G,B,A，
 * A 已乘入 RGB），行主序、无行间 padding；width*height*4 字节。
 * hits 数组紧随 pixels 语义，两个缓冲各自独立分配。
 * 用 gc_panel_result_free 一次释放。
 */
typedef struct GcPanelResult {
    uint8_t *pixels;
    int32_t width, height;
    GcPanelHitRegion *hits;
    size_t hit_count;
} GcPanelResult;

/* frame：帧数据 JSON（见 gogaku_core.h 的 gc_panel_render 注释）。
 * theme：套用补丁后的有效主题 JSON（gc_themes_effective 输出形状，对象）。
 * scale：1.0 = 1pt→1px；Mac 传 backingScaleFactor，Windows 传 dpi/96。
 * dark：1 取主题 dark 配色（无 dark 时仍用 light，主题规则由 gc_themes 定）。
 * 成功返回 0；1 参数错误；2 frame/theme 不是 JSON 对象；3 字体数据缺失
 * （fonts 数组为空或全部打不开）；4 内存不足；5 内部错误（异常不跨 ABI）。
 * 文本宽度在无 hinting 下取设计 advance（与 CoreText 一致；spike 记录）。 */
GC_PANEL_RENDER_EXPORT int32_t gc_panel_render(const char *frame, size_t frame_len,
                                               const char *theme, size_t theme_len,
                                               double scale, int32_t dark,
                                               GcPanelResult **out);

GC_PANEL_RENDER_EXPORT void gc_panel_result_free(GcPanelResult *result);

/* 只算布局不出位图（设置页预览与测试用）：输出与 gc_panel_render 相同的
 * 命中区域表与画布尺寸（pixels 为 NULL）。像素位图依赖字体栅格，布局
 * 只依赖 advance，两者同一实现路径，预览与实机不会分叉。 */
GC_PANEL_RENDER_EXPORT int32_t gc_panel_layout(const char *frame, size_t frame_len,
                                               const char *theme, size_t theme_len,
                                               double scale, int32_t dark,
                                               GcPanelResult **out);

#ifdef __cplusplus
}
#endif
#endif
