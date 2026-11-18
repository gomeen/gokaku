# 共享位图渲染接入验收

日期：2026-11-17。开发机：Intel Mac，macOS 26.7.3。范围：共享实现、Mac／Windows 接入、离屏验证与开发构建；不代表当前系统输入源或 Windows 真机已验收。实现说明见[共享候选窗位图渲染](../bitmap-rendering.md)。

## 实施状态

| 阶段 | 本轮结论 | 边界 |
| --- | --- | --- |
| S1 可行性 | Mac 多语言、指定苹方度量及彩色 emoji 有离屏证据 | Windows 并排观感、性能及字体冷启动门槛未完成；此前“四问全过”已在 [spike 记录](bitmap-renderer-spike.md)更正 |
| S2 共享实现 | 横竖排、释义、学习动作、预编辑范围、背景、透明度与命中由一份 C++ 实现；异常与所有权回归通过 | 不含 IMK／TSF／窗口 API；无障碍逐候选元素待后续实现 |
| S3 Mac 接入 | 消费 CGImage 与命中表；设置开关、自动回退、分页与原文／恢复／说明回调已接入；Swift 回归通过 | 原生路径保留至少一个发布版本；真实输入源未测 |
| S4 Windows 接入 | 消费预乘 BGRA DIB；DPI、字体解析、索引／UTF-16 转换与动作已接入；full／lite 双架构完整构建、收据及安装器输入检查通过 | Windows EXE 尚未执行，未生成安装器 |
| S5 验收 | fast、ASan 冒烟、Mac Lite 内部构包、Windows 双形态安装器输入、16 组离屏图像及三轮性能复测已完成 | Mac 去重后完整 16 组 C ABI 热态 p95 达标，探针单次冷帧 6.51ms；命名字体冷启动尾部、App／真实宿主、Windows 观感、跨屏 DPI、全部皮肤热更新与发行包未验收 |

当前保留 `candidateRenderer=bitmap|system` 与逐帧失败回退。尚未证明全部目标平台满足原计划的性能退出门槛，不能移除系统路径或宣称正式验收通过。

## 本次工作区审查后的增量（2026-11-17）

逻辑／规格、代码规范、性能三组审查后，确认并修复了大图主题每帧 JSON 处理导致的延迟：共享核心增加 prepared theme 句柄，Mac／Windows 逐帧复用不可变快照；同时夹紧 UTF-16 前缀，并清理渲染器枚举与局部变量命名。修复范围、过程报告与保留问题见[审查记录](bitmap-theme-cache/README.md)。以下其他章节保留修复前对应二进制的历史证据，不能当作最新源码的构建收据。

最终固定 PNG 探针五组输入与 RGBA 哈希一致；1MiB／8MiB 热态 p95 分别为 **1.15／1.13ms**，修前为 10.89／81.89ms。该探针只覆盖四候选竖排、scale 2、单个 PingFang face。**冷加载仍未达标**：8MiB 主题准备＋首帧约 **159ms**，无图首帧也有波动。[最终报告](bitmap-theme-cache/final-prepared.json)、[对照](bitmap-theme-cache/final-comparison.json)保留所有样本。

修复后 fast 7/7（CTest 11/11、Swift 277/277）、ASan／UBSan 2,000 序列及共享渲染向量通过；Windows full 双架构模块／自检 EXE 编译通过，但未执行 Windows 程序，也未重建 Lite 包或安装 Mac App。源码及构建哈希见[最终身份核对](bitmap-theme-cache/final-identity.json)。未进行真实宿主按键注入或完整 release 验收。

## 冻结源码后的测试

- `python3 scripts/verify.py --profile fast`：**7 项检查全部通过，退出码 0**；CTest **11/11**，Swift Release **272/272**；`runIdentityStable=true`、`gate.passed=true`。[报告](verify/report-fast-20261117-114701.json)。
- `python3 scripts/verify.py --profile release --only asan-ubsan --quick`：**ASan／UBSan 检查通过**，2,000 个随机序列与共享渲染器插桩向量无错误，`runIdentityStable=true`。[报告](verify/report-release-20261117-114626.json)、[渲染日志](verify/release-20261117-114611/asan-panel-render.log)。该命令退出码 1 来自 `--only` 跳过其余必需检查，总体 release gate 为 false；不是完整 release 验收，也不是 ASan 失败。
- 共享向量覆盖：横排每页 4–9 个候选全部保留、分页全局下标、竖排释义、无释义不占行、学习操作、深浅色、2 倍缩放、背景图、预乘 alpha、整体透明度、长预编辑省略后的 UTF-16 范围与输入边界。
- 本机 Apple Color Emoji：12pt／24pt 在 scale 1 的 advance 为 12／24px，scale 2 为 24／48px；度量与位图缩放一致，VS15／VS16 回归通过。此结果不能外推到 Windows Segoe Emoji。
- 首次 fast 中新增设置保存测试失败：临时 `SettingsStore` 在异步写入前释放。测试现持有对象直到保存回调完成；上面的最终 fast 是修正后的结果。早期 `runIdentityStable=false` 的报告保留为过程证据，不用于最终通过结论。

## 构建与裁剪

Mac Lite 内部构建命令：

```sh
GOGAKU_BUILD_ROOT=.build/bitmap-lite python3 scripts/build.py --channel dev --flavor lite
```

构建退出码 0，附带 9 项 Lite CTest 通过。输出 `dist/Gogaku Lite Dev.app` 与 `dist/Gogaku Lite Settings Dev.app`；两包均含 HarfBuzz、FreeType、libpng、zlib 许可及 `panel-render-NOTICE.txt`，无翻译 helper 和 `gloss.tsv`。最终增量构建的源码指纹与当前源码一致，收据和日志归档为 [mac-lite-build-identity.json](bitmap-rendering-20261117/mac-lite-build-identity.json)、[mac-lite-build.log](bitmap-rendering-20261117/mac-lite-build.log)。随后 `check-bundle.py --lite` 通过：双包 ad-hoc 签名、动态依赖闭包、包内小鹤 `nihc→你好`、设置自动读音与 Lite 裁剪均有[检查记录](bitmap-rendering-20261117/mac-lite-bundle-check.json)。

构建身份为 `0.1.5-dev.1 / b114 / dev / lite / release / dirty=true`。这是内部验证构包，未安装、未切换输入源、未递增构建号，不能当作定版发行包提供。

Windows **full／lite 完整构建均退出 0**，每种形态包含 x64 核心、Agent、Settings、x64／x86 TSF，以及双架构的共享渲染与平台接缝自检 EXE。四份架构收据的源码指纹与当前源码一致；full 核心 `GOGAKU_LITE=OFF`，lite 为 `ON`，两者均开启共享渲染。渲染模块按各自架构静态编入，TSF 不导入 `libgogaku_core.dll`，无需新增 HarfBuzz／FreeType／PNG DLL。

两版安装器输入组装与 PE 依赖闭包检查均通过：完整版有 `gloss.tsv`，Lite 无此文件且保留英文词表；两版均含四项渲染依赖的许可及 NOTICE。详见[构建汇总](bitmap-rendering-20261117/windows-build-summary.json)、[full 身份](bitmap-rendering-20261117/windows-full-build-identity.json)、[lite 身份](bitmap-rendering-20261117/windows-lite-build-identity.json)。没有执行 Windows EXE、生成安装器或安装。

```sh
python3 scripts/compile-win-native.py --arch all --channel dev --flavor full \
  --out .build/s4-windows --core-build .build/s4-windows/core --jobs 2
python3 scripts/compile-win-native.py --arch all --channel dev --flavor lite \
  --out .build/bitmap-win-lite --core-build .build/bitmap-win-lite/core --jobs 2
python3 scripts/build-win-app.py --channel dev --flavor full \
  --bin-dir .build/s4-windows/bin --data-dir .build/win-app/dev/data --out .build/s4-windows/package
python3 scripts/build-win-app.py --channel dev --flavor lite \
  --bin-dir .build/bitmap-win-lite/bin --data-dir .build/win-app/dev/data --out .build/bitmap-win-lite/package
```

首次 full 构建因同时修正测试而发生源码指纹变化，必要增量重跑后通过。首次组装使用默认 `.build/win-data` 时缺少 `sc.dict`，改为本机已有的 `.build/win-app/dev/data` 后两版均通过；组装入口校验了出厂数据锁和派生词表哈希，没有绕过校验或修改产品源码。

## 离屏图像与耗时

[16 组 PNG、预乘 RGBA 哈希、命中表与耗时报告](bitmap-rendering-20261117/report.json)使用当前 Release 核心：四套内置主题 × 深浅色 × 九候选竖排／七候选横排，scale 2，每组 200 帧。包含中文、拉丁、日文和彩色 emoji。字体为公开 PingFang SC（face 3）、SFNS、Apple Color Emoji；字体文件未复制入库。

| 指标 | 本轮观测 |
| --- | --- |
| 九候选竖排稳态中位数 | 1.30–1.36ms |
| 七候选横排稳态中位数 | 0.81–1.30ms |
| 竖排各组 p95 | 1.41–1.92ms |
| 横排各组 p95 | 0.88–2.34ms |
| 新进程第一帧 | 12.47ms；超过原计划 8ms 目标 |

首轮测量与编译／验证并行，不能当作空闲目标机的性能验收。先前探针曾测得首帧约 6.1ms，但不是最终核心的冻结证据。只有每份报告第一组的 `firstMs` 是新进程首帧，其余组沿用线程内字体／字形缓存。

本轮编译全部结束后，使用**相同 SHA-256 的核心二进制**又顺序启动三个新进程，各测 16 组 × 200 帧，全部结果如下：

| 复测 | 新进程首帧 | 各组稳态中位数范围 | 各组 p95 范围 |
| --- | --- | --- | --- |
| [第 1 轮](bitmap-rendering-20261117/after-build-1/report.json) | 56.77ms | 1.43–2.88ms | 1.76–4.66ms |
| [第 2 轮](bitmap-rendering-20261117/after-build-2/report.json) | 23.34ms | 1.54–3.85ms | 1.90–11.61ms |
| [第 3 轮](bitmap-rendering-20261117/after-build-3/report.json) | 23.78ms | 1.56–3.95ms | 1.89–15.47ms |

**此前完整性能验收未通过，最终验收仍未闭环。** 三轮结束后的 `pmset -g therm` 报告 `CPU_Speed_Limit=39`；当时不能证明每一帧的限速值，也不能把超限全部归因于限速。之后定位到 macOS 字体列表重复传入同一 SFNS face，已合并重复项并保留拉丁／emoji 优先级。去重后的聚焦测量与边界见下节；它不替代全主题、Windows 或真实宿主验收。没有调整电源设置或停止用户应用。

## macOS 字体去重后的完整离屏复测

2026-11-17 在 CPU 限速 100% 时，以同一 Release 核心二进制（SHA-256 `5cb56298c5cdec97224b78bcddea59fd0a6f2d1289f42093a3a6076dd48cb11b`）调用 `gc_panel_render`。Mac 字体列表原先把 `.SFNS-Regular` 作为普通字体和拉丁字体各传一次；`SharedPanelBitmapRenderer.fontList` 现按路径与 PostScript 名去重，并合并 `latin`／`emoji` 标记。独立进程冷首帧中位数从四 face 的 8.55ms（n=5）降为三 face 的 7.36ms（n=9）；后者样本范围较宽，且没有清空 OS 字体文件缓存，因此只能作为诊断结果。

预热后各测 300 帧，九候选竖排（514×658）中位数 1.17ms、p95 1.75ms、p99 2.49ms；七候选横排（1119×178）中位数 0.70ms、p95 0.95ms、p99 1.22ms。wall time 与进程 CPU time 的 p95 差值分别为 0.054ms 和 0.038ms。去重前后四种横／竖排深浅组合的 RGBA 哈希一致。

随后以相同核心二进制跑完四主题 × 深浅色 × 横竖排、每组 200 帧：[完整报告与 PNG](bitmap-rendering-20261117/after-font-dedup/report.json)。九候选竖排各组稳态中位数 1.09–1.26ms、p95 1.41–1.67ms；七候选横排中位数 0.66–0.80ms、p95 0.87–1.06ms。新进程的第一个冷帧 6.51ms；后续 15 组沿用线程内字体／字形缓存，不能视为冷帧。字体面通过明确 face index 传入，命名 face 与去重前后的像素哈希相同。

原始聚焦摘要见[字体去重性能记录](bitmap-rendering-20261117/font-dedup-performance.json)。这组完整数据只覆盖 `gc_panel_render`，不含 Swift JSON／CGImage 封装、窗口提交或真实按键；没有重建或安装 Mac App，Windows 和真实宿主也未复测。300 帧诊断中竖排 p99 为 2.49ms，命名 face 冷启动九进程样本仍有高波动。因此目前可以确认 Mac 离屏 C ABI 的首帧观测值及热态 p95 达到目标，不能宣称整体性能验收通过。

这些数字只覆盖 `gc_panel_render`，不包括宿主读取、贴图提交和实际按键，因此不证明逐键 UI 线程 p95≤5ms 或热态候选 p95≤30ms。ASan 日志中的耗时受插桩影响，不作产品性能依据。

复现（路径按本机公开字体实际位置替换）：

```sh
python3 probes/render-shared-panel.py \
  --library .build/core/libgogaku_core.dylib \
  --font /path/to/PingFang.ttc --face 3 \
  --latin-font /System/Library/Fonts/SFNS.ttf \
  --emoji-font '/System/Library/Fonts/Apple Color Emoji.ttc' \
  --out /tmp/gogaku-panel-render --repeat 200
```

像素哈希绑定具体字体、核心二进制及源码指纹。跨系统采用同一份行为向量断言布局、命中与像素性质；不同系统字体不要求像素哈希相等。

## 剩余验收

1. Windows 实测相同输入并与 D2D 并排比较，完成共享向量、Segoe Emoji、中文字体回退及分层窗口 alpha 验证。
2. 在包含字体去重的新 Mac App 上执行真实 IMK 宿主测试；Windows 构建需执行 TSF 宿主测试。覆盖点击、翻页、横竖排、原文／恢复／说明、背景图及全部皮肤属性热更新，并记录跨屏 DPI 与 Space／前后台切换。
3. 定版时递增构建号、保持工作区干净，完成 release／host 档及双端安装包验证。当前未运行完整 release，也未执行真实按键注入。
