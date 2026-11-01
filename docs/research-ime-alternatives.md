# 其他中文引擎与前端路线

核查日期：2026-10-30。承接[产品方向](product.md)、[候选路线](input-engine-candidates.md)与[首轮核心实测](input-engine-benchmark.md)。用户要求技术栈与框架保持开放，以实际输入性能为首要选型依据，同时满足小鹤、候选质量与提交正确性。

本文核查公开接口和固定版本源码；以下新增路线尚未在本机装配、计时或通过宿主验收。编程语言、存在 Intel 发布包和框架层数均不能证明谁最快。

**后续决定：** 已据现有测试选择libime＋原生前端，见[技术选型决定](input-selection-decision.md)。下列路线保留为研究资料，不继续逐一装配；没有已测速度差的证据，也没有为穷举而推迟选择的要求。

## 新增解码器

| 候选 | 已核实的接缝 | 尚缺的证据与补测优先级 |
| --- | --- | --- |
| libpinyin | `DOUBLE_PINYIN_XHE`、`pinyin_set_double_pinyin_scheme`、连续双拼解析、整句猜测与候选查询；按音节 offset 选择候选、清除约束、reset 和显式 train 接口。[L1][L2] | **优先补测。** 固定实际模型后，比较逐键解析、猜句和前十枚举的合计成本，以及局部选择与原编码消费区间。GLib、数据库依赖、启动、RSS 和写盘同样计入。Homebrew 有 Intel Sonoma 的 2.10.3 产物，但本机尚未运行。[L3] |
| SunPinyin | 小鹤声韵母及零声母表，连续拼音解码、语言模型与部分选词接口。[S1][S2] | **第二补测项。** 官方 rc2 有 x64 包，2024 年有 macOS 15.1 适配提交；这些不能替代当前 Intel macOS 验证。固定数据包后测试零声母、尾部单键、长句及修订。[S3] |
| AOSP PinyinIME／libgooglepinyin | 公开原生解码接口支持增量搜索、整句候选、局部固定与撤销。[G1][G2] | **保留备选。** 尚未核实直接的小鹤入口，需要验证双拼到音节及原始按键区间的适配；全局解码状态、旧构建选项与维护情况增加集成工作。不能把闭源桌面谷歌拼音的功能或体验归给这份开放代码。 |

libpinyin 固定源码 `85905e59cb19d0343cae84d831027aee113420b8`；SunPinyin 固定 `e4be7e64e4a168a684b26679b7e076118a2c97f7`；AOSP 固定 `49aebad1c1cfbbcaa9288ffed5161e79e57c3679`，libgooglepinyin 固定 `6055722c98bf203ecde8e109a0d36c8a6a2e8007`。维护时间只用于判断维护风险，不作为质量或速度成绩。

## 代码与数据许可分开

- libpinyin 代码为 GPL-3.0-or-later；构建会取得 `model20.text.tar.gz`。[L4] `opengram.license` 只明确部分来自 Android 拼音的词条采用 Apache-2.0，不能据此认定整个统计模型和所有词表已经完成许可核查。[L5] 下一步先查实际包及完整授权，再纳入装配；当前记录为数据授权待核实，不能记作质量失败。
- SunPinyin 代码提供 LGPL-2.1-only 或 CDDL 选择；具体 open-gram 数据包需另外固定并核查。其构建脚本动态获取数据的行为不能直接用作可复跑实验输入。[S4]
- AOSP／libgooglepinyin 所核实接口代码为 Apache-2.0；仍需核查实际词典文件和包内声明。代码许可不自动覆盖出厂数据。

Gogaku 的项目许可尚未确定。这些是当前核查边界，不是完整分发审计或已经批准引入全部资源的结论。

## 前端与桥接单独比较

| 路线 | 可复用内容 | 应如何比较 |
| --- | --- | --- |
| 自建 Swift／AppKit 前端 | 通过 InputMethodKit 与宿主通信；中文核心可经 C ABI、C++ 互操作或 Rust 桥接接入。[F1][F2][F3] | 固定解码器和数据，分别记录事件处理、跨语言字符串复制、调度、候选构建、UI 更新及宿主实际收字。IMK 是公开接入接口，不能当作另一套中文解码器。 |
| OpenVanilla | 固定 `ecf3260a49e61aacf4ffc951d40d390a46dc4cec`，MIT；已有 IMK 与 AppKit CandidateUI 接缝。[F4] | 可作为前端复用候选；其形码模块不能代替小鹤解码器。当前 Intel 产物、学习模式和焦点行为仍需验证。 |
| Fcitx macOS | 固定 `3466612499c149d5002b1aab37b92bb257da1a75`，GPL v3；CI 有 x86_64 路径，已有输入事件、插件与候选窗集成。[F5] | 候选窗使用 `WebviewCandidateWindow`。[F6] 与独立前端采用同一 libime、数据和参数，才可比较框架、同步响应序列化和绘制开销；不能仅凭 WebView 推断慢。 |
| 现有 libpinyin macOS 前端 | `macos-libpinyin` 提供另一条 IMK 接缝，GPL v3。[F7] | 项目较旧，保留源码参考；不当作当前系统已经兼容或可直接交付的证据。 |

Swift、Objective-C++、Rust、C++ 均可作为实现选择。优先把解码、桥接、UI、模型调度和宿主提交分段计时，找出瓶颈后再决定技术组合；后台设置与记录管理不主导输入链路选型。

## 纳入实测的方法

1. 在[首轮方案](input-engine-benchmark-plan.md)的同一 worker 协议下加入新引擎，先核对小鹤、前十枚举、局部选词、取消和完整提交；数据或平台装配失败保留具体原因。
2. 沿用冻结样例做回归，并增加独立保留集。先产品数据组合，再做受控词表实验；不可统一的权重、词表和语言模型明确披露。
3. 热态核心测量与原生可见响应分开。记录候选质量、完成目标所需的实际按键、p95/p99、首次加载、CPU 和 RSS，不能只给一个 API 的平均耗时。
4. 使用同一原生最小闭环换引擎和前端，加入实际宿主、翻译并发、焦点变化、退格重输与长时间输入，随后确定默认组合。

目前没有覆盖上述所有候选的同机对照成绩；首轮测量只能支持已测配置的阶段判断，不能宣布全局最快方案。

## 一手来源

[L1]: https://github.com/libpinyin/libpinyin/blob/85905e59cb19d0343cae84d831027aee113420b8/src/pinyin.h
[L2]: https://github.com/libpinyin/libpinyin/blob/85905e59cb19d0343cae84d831027aee113420b8/src/storage/pinyin_custom2.h
[L3]: https://formulae.brew.sh/api/formula/libpinyin.json
[L4]: https://github.com/libpinyin/libpinyin/blob/85905e59cb19d0343cae84d831027aee113420b8/data/Makefile.am
[L5]: https://github.com/libpinyin/libpinyin/blob/85905e59cb19d0343cae84d831027aee113420b8/data/opengram.license
[S1]: https://github.com/sunpinyin/sunpinyin/blob/e4be7e64e4a168a684b26679b7e076118a2c97f7/src/pinyin/shuangpin_data.cpp
[S2]: https://github.com/sunpinyin/sunpinyin/blob/e4be7e64e4a168a684b26679b7e076118a2c97f7/src/ime-core/imi_context.h
[S3]: https://github.com/sunpinyin/sunpinyin/releases/tag/v3.0.0-rc2
[S4]: https://github.com/sunpinyin/sunpinyin/blob/e4be7e64e4a168a684b26679b7e076118a2c97f7/src/sunpinyin-dictgen.mk.in
[G1]: https://android.googlesource.com/platform/packages/inputmethods/PinyinIME/+/49aebad1c1cfbbcaa9288ffed5161e79e57c3679/jni/include/pinyinime.h
[G2]: https://github.com/qgears/libgooglepinyin/tree/6055722c98bf203ecde8e109a0d36c8a6a2e8007
[F1]: https://developer.apple.com/documentation/inputmethodkit
[F2]: https://www.swift.org/documentation/cxx-interop/
[F3]: https://cxx.rs/
[F4]: https://github.com/openvanilla/openvanilla/tree/ecf3260a49e61aacf4ffc951d40d390a46dc4cec
[F5]: https://github.com/fcitx/fcitx5-macos/blob/3466612499c149d5002b1aab37b92bb257da1a75/.github/workflows/ci.yml
[F6]: https://github.com/fcitx/fcitx5-macos/blob/3466612499c149d5002b1aab37b92bb257da1a75/webpanel/webpanel.cpp
[F7]: https://github.com/makibus/macos-libpinyin/tree/937201dfc465a47b8daafce680839b20fb42329a
