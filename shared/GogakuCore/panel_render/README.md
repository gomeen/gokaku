# 候选窗共享位图渲染器

`gc_panel_render` 输入当前页帧 JSON、有效主题 JSON 和缩放，输出预乘 RGBA 位图、尺寸和像素命中区域。`gc_panel_layout` 共用布局路径，只省略像素分配与栅格化。唯一合同见 [`../panel_render.h`](../panel_render.h)，两端共跑 [`../tests/panel_render_test.cpp`](../tests/panel_render_test.cpp)。

布局、长文本省略、学习释义换行、字体回退、HarfBuzz 整形、FreeType 栅格、PNG 背景、整体透明度与命中区域均在本目录实现。Mac 只提供 CoreText 解析出的本地字体、显示位图与窗口位置；Windows 用 DirectWrite 解析字体，转换 RGBA→BGRA 后贴到分层窗口。用户主题不捆绑字体。普通输入和 Lite 使用同一布局实现；Lite 的帧不带释义和学习动作。

字体库与字形缓存按线程隔离，最多保留当前字体配置与约 8MiB 字形；帧文本不进入持久缓存。PNG 缓存只保留当前主题图片。返回值及两个缓冲由 `gc_panel_result_free` 释放；失败返回空输出。超限、字体不可读或图片不合法时由平台回退系统渲染。

## 源码与构建

- HarfBuzz 14.5.0（Old MIT），编译 `src/harfbuzz.cc`；禁用 CoreText／DirectWrite／GDI／Uniscribe／ICU／Cairo 后端，使用 FreeType 字体函数。
- FreeType 2.14.3（选择 FTL），保留 TrueType／CFF／SFNT、灰度栅格与字体缓存模块。精简模块表在 `ftconfig/ftmodule.h`，支持 PNG 彩色 sbix；不编 SVG／BDF／PCF 等未使用驱动。
- libpng 1.6.44（PNG Reference Library License v2）、zlib 1.3.1（zlib License），用于主题 PNG 与字体内 PNG 位图。

上游源码位于 `shared/third_party/`；收录时剥除文档、示例与未编译部分，版权与许可保留。全部静态编译，升级时同步 `docs/third-party.md`、头文件版本、随包许可与本目录验证。

独立 `panel_render/CMakeLists.txt` 支持在没有 libime 的情况下构建渲染器，供 Windows x86／x64 TSF 使用；Mac 核心包含相同源码并导出 C ABI。构建产物必须按架构隔离。

## 离屏验证

```sh
GOGAKU_PANEL_FONT="<本机字体文件>" GOGAKU_PANEL_FONT_INDEX=0 ctest --test-dir .build/core -R panel_render --output-on-failure
python3 probes/render-shared-panel.py --library .build/core/libgogaku_core.dylib \
  --font "<中文字体>" --face 0 --out /tmp/panel-render
```

字体相关像素哈希只用于固定字体／平台的重复性检查，不跨机器固定。几何、预乘 alpha、命中区域、分页、省略与错误路径由共享测试冻结。真实宿主观感、DPI 热切换和逐键性能仍须单独验收，详见 `docs/bitmap-rendering.md`。
