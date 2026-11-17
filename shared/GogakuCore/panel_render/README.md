# 候选窗共享位图渲染器（S2）

输入帧 JSON 与主题，输出预乘 RGBA 位图与命中区域表。一处实现，两端贴图。

帧数据形状见 `include/gogaku_core.h` 的 `gc_panel_render` 注释；行为向量在
`tests/panel_render_test.cpp`，两端 ctest 共跑。

## 源码 vendored 版本

- HarfBuzz 14.5.0（MIT）。只编 `src/harfbuzz.cc` unity build；默认关闭
  glib／coretext／directwrite／icu／freetype 之外的全部后端开关。
- FreeType 2.14.3（FTL／GPL 双许可，取 FTL）。剥除 docs／subprojects／
  ChangeLog；构建配置禁 zlib／bzip2／png／brotli／harfbuzz（纯 TrueType／
  CFF 光栅，位图字体走系统 emoji 字体的 strike 表）。

升级时替换目录并同步 `docs/third-party.md` 的版本记录。
