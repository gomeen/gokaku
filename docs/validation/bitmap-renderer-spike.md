# 位图渲染器 spike 记录（S1）

日期：2026-11-17。机器：Intel Mac（本仓库开发机）。目的：回答共享位图渲染方案的四个验收问题（多语言文本、观感对齐、性能、emoji），为「候选窗一处实现」计划提供裁决依据。本目录代码是一次性验证件，不进产品。

## 结论（四问全部通过，位图路线可行）

| 问题 | 结果 | 证据 |
| --- | --- | --- |
| 中日文本渲染 | **通过** | `中文 hello 日本語 nihao` 一行 HarfBuzz 整形＋FreeType 栅格渲染正常，PNG 目测无缺字（`/tmp/spike-pfsc2.png`，本记录保留复现命令） |
| 与 CoreText 宽度对齐 | **通过（核心发现见下）** | `nihc` 26.844pt vs CoreText 26.85pt；整句 149.53pt vs 149.55pt（差 0.02pt） |
| 一帧性能 | **通过** | 18 字一行稳态：整形 0.40ms＋栅格合成 0.06–0.16ms；字体加载 0.9–1.2ms（每轮重栅格、无字形缓存的下界；产品侧加缓存只会更快）。Gogaku 门槛逐键 UI 线程 p95≤5ms，余量充足 |
| 彩色 emoji | **通过（macOS）** | Apple Color Emoji（SBIX）经 `FT_LOAD_COLOR` 直接出 BGRA 位图（pixel_mode=7），20/40/160px 三档实测可用；Windows 侧 Segoe COLRv0 同为 FreeType 支持路径，待 Windows 真机复测 |

## 核心发现（写进 S2 实现要求）

1. **必须 `FT_LOAD_NO_HINTING`**。默认 hinting 把 advance 取整到整数 pt，拉丁文本比 CoreText 宽（`nihc` 28.00 vs 26.85）。加 NO_HINTING 后逐字 advance 与 CoreText 到 0.005pt 级一致。苹方未启用 trak 表路径时宽度已对齐，**trak 解析暂不需要**（青简为对齐 SF 系字体才补的；Gogaku 默认字体为苹方／雅黑，S2 实现时保留「若测得差异再补」的登记项）。
2. **系统私有 PingFangUI.ttc 不可用**。它用私有表（`hvgl`/`cidg`）存字形，无 `glyf`/`CFF`，FreeType 打开 face 即失败（FT error 2）。必须用公开 PingFang.ttc（24 faces，SC Regular=face 3）或走 CoreText 解析出公开字体路径。**Gogaku 产品侧字体解析必须容错**：解析失败回退系统字体（现有行为）。
3. **gamma 笔画加深待真机并排**。spike 产出 0.85/1.0 两版对比图（`/tmp/spike-g085.png`、`/tmp/spike-g100.png`）；最终值按青简经验浅色 0.85／深色 0.75 起步，S3 Mac 接入后与原生并排微调，spike 不单独裁决。
4. **emoji 走独立位图通道**。SBIX 位图按 strike 尺寸取（160px 最近邻缩到目标行高），不经 mask 合成路径；候选文本以码位区间（≥U+1F300 等基本判断＋字体覆盖探测）分流。

## 与计划的偏差

- 计划 S1 提到评估 tiny-skia-cpp 作栅格器。spike 实测 FreeType mask＋自写 alpha 合成已足够（一行 18 字 0.1–0.2ms），圆角矩形与高亮色块用简单几何合成即可，**不引入 tiny-skia**，减少一个第三方依赖与许可义务。
- opsz（光学字号）：PingFang 非变量字号敏感字体，本轮不需要；登记为「主题启用 SF 系字体时再补」。

## 复现

```sh
cd probes/bitmap-renderer-spike
clang++ -std=c++17 -O2 hello_text.cpp $(pkg-config --cflags --libs freetype2 harfbuzz libpng) -o /tmp/gc-spike
# 列 ttc 的 face（找 SC Regular）
/tmp/gc-spike --font <PingFang.ttc 路径> --name
# 渲染＋计时
GC_FACE_INDEX=3 /tmp/gc-spike --text "中文 hello 日本語 nihao" --font <PingFang.ttc> --out /tmp/out.png --repeat 200
# CoreText 宽度基准
swift probes/bitmap-renderer-spike/coretext_width.swift
```

spike 产出图（本目录）：`spike-pfsc2.png`（对齐后整句）、`spike-g085.png`/`spike-g100.png`（gamma 对比）。

Windows 侧（COLRv0、灰度抗锯齿观感、雅黑回退）在 S4 接入时于真机补测，spike 不阻塞 S2 开工。
