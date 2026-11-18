/* 候选窗位图渲染契约（一处实现，两端贴图）。
 *
 * 实现在 panel_render/panel_render.cpp（HarfBuzz＋FreeType vendored 静态编入
 * 核心库）；行为向量在 tests/panel_render_test.cpp，两端 ctest 共跑。
 * 本头文件是唯一声明处，gogaku_core.h 包含它；导出归属规则与
 * settings_contract.h 相同。独立静态目标可编入 x86／x64 TSF 和设置程序；
 * Mac 由核心 dylib 导出。同一源码按目标架构编译，不复制实现。
 *
 * 每次调用拥有独立帧；字体/字形缓存按线程隔离，不缓存帧文字。
 * 不碰 IMK／TSF／窗口 API。
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
    GC_PANEL_HIT_EXPLAIN = 6     /* arg = issues 数组下标；范围使用该帧 UTF-16 */
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

/* frame：JSON 对象（可选项省略时用以下默认值）：
 * fonts: [{path,index:0,postscriptName:"",emoji:false,role:""}]，最多16个。
 *   path 是 UTF-8 本地路径；index=-1 时用 postscriptName 在 TTC 内匹配。
 *   role="latin" 让 fontEN 优先用于拉丁字符；emoji 字体优先用于 emoji 簇。
 * candidates: [{text,gloss:""}] 只含当前页；最多 pageSize 个，不能传全集。
 * layout: "vertical" | "horizontal"；learning:true 强制竖排。
 * pageSize:9 (1..9), page:0, pageCount:1, selected:0（全局下标）。
 * glossRow:true 控制横排高亮释义行；Lite 帧的 gloss 留空。
 * fontSize:14 (12..16) 仅供 rime-macos-like；其他主题使用 typography。
 * preedit:"", preeditCaretUTF16:-1（-1不画光标）, status:"", toast:""。
 * typedPrefixUTF16:0，非负有限数，夹紧到当前 preedit 的 UTF-16 总长；
 *   非 BMP 字符占两个单位；学习英→中整段视为 typed。
 * learning:false, direction:"zhToEn" | "enToZh"。
 * issues:[{location,length,explanation}]：当前预编辑的 UTF-16 范围；
 *   越界范围忽略；EXPLAIN 的 arg 索引此数组，说明文字由壳展示。
 * hasOriginal:false, hasRestore:false：对应按钮和命中区域。
 * theme：套用补丁后的有效主题 JSON（gc_themes_effective 输出中的单个对象）；
 *   imageData 为规范化 PNG 的 base64；深色槽为 null 时使用浅色槽。
 * scale：有限值 [.5,4]；Mac 传 backingScaleFactor，Windows 传 dpi/96。
 * dark：1 请求深色；输出整体 opacity 已乘入所有 RGBA，壳不可再次乘透明度。
 * 成功返回 0；1 参数／范围错误；2 非法 JSON／类型；3 字体数据缺失；
 * 4 内存不足；5 内部错误。失败时 *out=NULL，异常不跨 ABI。
 * 帧/主题各限24MiB，画布限4M像素，文字各限16KiB；超限明确失败供壳回退。
 * 文本度量使用无 hinting advance；具体字体与系统排版的差异见验证记录。 */
GC_PANEL_RENDER_EXPORT int32_t gc_panel_render(const char *frame, size_t frame_len,
                                               const char *theme, size_t theme_len,
                                               double scale, int32_t dark,
                                               GcPanelResult **out);

/* 附加接口，不改变 ABI v4 的现有符号/结构。
 * create 拷贝并解析主题一次（不借用输入），只验证 JSON 对象；配色范围和
 * PNG 在使用对应外观时验证，layout 不解码 PNG，与旧入口保持相同语义。
 * 主题不可变：任何内容变化都创建新句柄；同 ID/同长度不代表相同主题。
 * render/layout 可并发共享同一句柄，字体缓存仍为线程私有；图像缓存至多
 * 保留当前外观一张（每张≤4096×4096 RGBA），在用帧独立持有图像。
 * free(NULL) 安全；调用方必须等全部并发调用结束后才释放句柄。
 * create 失败清空 *out；错误码与旧入口相同。旧 JSON 入口每线程仅保留一个
 * 主题，以完整字节比较命中（仍有 O(theme_len) 比较，不再逐帧解析/分配）。
 * 平台热路径应使用 prepared 接口，使主题相关工作与 payload 大小无关。
 */
typedef struct GcPanelTheme GcPanelTheme;
GC_PANEL_RENDER_EXPORT int32_t gc_panel_theme_create(const char *theme, size_t theme_len, GcPanelTheme **out);
GC_PANEL_RENDER_EXPORT void gc_panel_theme_free(GcPanelTheme *theme);
GC_PANEL_RENDER_EXPORT int32_t gc_panel_render_prepared(const char *frame, size_t frame_len,
                                                        const GcPanelTheme *theme, double scale, int32_t dark,
                                                        GcPanelResult **out);
GC_PANEL_RENDER_EXPORT int32_t gc_panel_layout_prepared(const char *frame, size_t frame_len,
                                                        const GcPanelTheme *theme, double scale, int32_t dark,
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
