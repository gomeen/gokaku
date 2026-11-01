# 中文输入引擎候选与公平验证边界

## 目标与证据范围

**状态更新：首阶段已选择libime出厂组合＋原生前端，详见[技术选型决定](input-selection-decision.md)。** 本文保留候选比较背景，后文的“下一步设计”不意味着继续穷举或重新打开已经收敛的中文选型。

扩大候选范围，实际输入性能第一；技术栈和框架保持开放，在满足小鹤、中文质量与提交正确性后实测选择。下列四条集成路线是初始对照，候选不设此上限。新增 libpinyin、SunPinyin、Google 开放拼音及 OpenVanilla 等前端的接口、版本与缺口见[其他引擎与前端](research-ime-alternatives.md)。本文主体为资料核查；后续本机装配、质量与逐键核心结果单列于[首轮实测](input-engine-benchmark.md)，不能把源码可行性等同于运行验收。
本轮目标设备为 Intel macOS 26.7.2、i9-9880H、8 核 16 线程、64 GiB，硬件记录见[翻译实验环境](../probes/results/translation-benchmark/benchmark-environment.json)。下述源码可行性不等于该设备已经验收。
需求是普通中文与中→英共用小鹤双拼，学习模式选词即提交英语。英→中独立捕获英语，在自有区域显示疑似问题波浪线。核心离线，联网增强默认关闭。
青简与 librime 的固定版本、源码审计和许可细节分别沿用[青简研究](research-qingjian.md)与[Rime 研究](research-rime.md)，不重复大审计。
新增证据固定于 libime `5be1300ea00e899b3f2c46d1e9f6bca21139cdeb`、fcitx5-macos `3466612499c149d5002b1aab37b92bb257da1a75`、chinese-addons `e8d930f402e359cfd76a101ee3e46815d1331d83`。

## 四条路线，三个中文引擎家族

集成成本为根据接口与现有前端作出的工程判断，不是测量值。C、D 共用 libime，不能算两个独立解码器。

| 路线 | 中文候选与小鹤 | macOS 集成成本与产品缺口 | 许可与词库条件 | 后续可测项目 |
| --- | --- | --- | --- | --- |
| A．青简核心及现有 macOS 前端 | 已有小鹤解码、中文候选与选词评分。双拼不是音形。[青简研究](research-qingjian.md) | 中。已有前端和译词提交接缝，但局部选词、暂存中文、焦点切换、独立英语诊断需适配。 | 代码 GPL-3.0-or-later。词库、释义、统计模型及权重分别核对，部分词表来源未附许可证。不能默认全部可分发。 | 核心候选延迟、评分组件开关的质量与延迟、模型加载和驻留内存、整机按键到候选显示。 |
| B．librime 加独立 IMK 前端 | 官方小鹤 schema、中文词典与用户学习接口已有，既有隔离探针不等于完整输入法验收。[Rime 研究](research-rime.md) | 高。C API 可接新前端，需实现候选窗、模式和生命周期。改造 Squirrel 是另一种前端复用选择，不自动满足学习需求。同步候选链不得等待慢翻译。 | librime BSD-3-Clause。复制 Squirrel 与小鹤 schema 涉及 GPL v3，朙月词库及反查数据涉及 LGPL v3。插件与模型另审。 | 部署时间与启动时间分开、按键处理及惰性候选枚举延迟、词库学习写盘、端到端 UI 延迟。 |
| C．libime 加轻量自建 IMK 前端 | `ShuangpinBuiltinProfile::Xiaohe` 已内置。`PinyinContext` 提供候选、选词、取消、预编辑和学习接口。[小鹤接口][sp] [上下文接口][ctx] | 高。可直接使用解码库而非整个 Fcitx 插件框架，但仍依赖 Fcitx5Utils、Boost iostreams 和 zstd。[构建][cmake] 需写语言桥接、按键策略、宿主提交与 UI。“轻量”是目标，不是实测事实。 | 所读接口标 LGPL-2.1-or-later。数据的 REUSE 声明同许可，但下载包、传递依赖与最终分发物仍需审查。[数据声明][reuse] | `PinyinContext` 更新到候选可读延迟、beam 与 nbest 的质量成本、桥接成本、前端自身 CPU 和内存。 |
| D．fcitx5-macos 加 chinese-addons 的 libime 拼音 | 拼音插件显式映射 Xiaohe，并设置双拼上下文。[拼音插件][addon] 插件仓库列出 macOS 的 chinese-addons。[插件目录][plugins] | 中至高。已有 IMK controller、会话与菜单，但不是 Gogaku 前端。默认包只有键盘引擎，中文需另配插件。[前端说明][macreadme] 学习状态、译词一次提交、独立英语及波浪线仍需开发。 | 前端 LICENSE 为 GPL v3。[前端许可][maclicense] 所读拼音代码为 LGPL-2.1-or-later，libime 数据条件同 C。不能用框架许可覆盖全部插件。 | 与 C 固定相同 libime 和数据，测框架事件链、同步响应序列化、候选展示及插件驻留的额外成本。 |

## libime 与 Fcitx 路线的具体接缝

- libime 的 `PinyinIME` 接收词典及用户语言模型，可配置 `nbest`、`beamSize`、`frameSize` 和候选限制。[引擎接口][ime] 这些是可控制变量，不是速度优势证据。
- `select()` 与 `selected()` 区分局部和完整选择，`learn()` 是单独操作。[上下文接口][ctx] 建议前端保存中文候选身份与消费范围，翻译输出不要写成中文用户词条。仍需行为测试。
- 默认数据构建分别下载 `lm_sc.arpa-20260629.tar.zst` 与 `dict-20260907.tar.zst`，源码给出哈希并生成 `zh_CN.lm`、`sc.dict`。[数据构建][data] 后续首轮实验已实际下载、核对预期哈希并转换出厂数据，保存 REUSE 声明及组件许可；完整分发审计仍待完成，见[实测配置](input-engine-benchmark.md)。中文语言模型不是中英翻译模型。
- 官方词典文本格式支持汉字、全拼、可选权重。[词典格式][dict] 可用于受控数据转换，但跨引擎权重语义和语言模型不因此等价。
- fcitx5-macos CI 明列 x86_64 Release 与 Debug 构建。[CI][ci] 这是 Intel 构建路径证据，不是本机运行证据。README 要求 macOS ≥13.3，源码构建要求 macOS ≥26.2 与 Xcode ≥26.4；设备的实际工具链仍须核对。[前端说明][macreadme]
- 前端 `processKey` 调用 `process_key`，再解析包含 commit、preedit 的 JSON 同步响应。[controller][controller] 可以插入分阶段计时，不能仅据这条边界宣称框架慢。
- [Apple InputMethodKit][imk] 是公开的输入法宿主通信与候选 UI 接口，不是公开中文解码引擎。系统拼音的私有服务或未公开 API 不列为可复用方案。

## 所有路线都要补的学习输入边界

普通模式仅提交中文。中→英保留中文来源与输入版本，准备好译文后一次提交，不先提交中文再替换。缺译文时保留输入或明确选择原文，不静默联网。
英→中必须绕开小鹤解析，单独管理英语原文、词句边界、检查范围及中文候选。波浪线先放自有区域，只标用户英语，不承诺装饰任意宿主已提交正文。
模式按应用记忆、焦点变化不串应用、取消与过期结果丢弃、输入隐私和错误学习隔离均须验收。以上是共同设计要求，不是任何候选已实现的声明。

## 公平 benchmark 的下一步设计

1. 固定本机 OS build、原生 x86_64 Release、编译器、优化参数、引擎提交、数据哈希、插件及模型开关。断网，用独立临时用户目录，禁止读取个人词库与输入日志。
2. 分两条赛道。产品包赛道使用各自推荐数据，比较用户实际体验；受控赛道尽可能使用同一合法词表、读音、评测集及候选数量。无法统一的频率、权重和语言模型必须逐项披露，不把结果归因于引擎本身。
3. 用同一批小鹤按键轨迹覆盖短词、长句、歧义、新词、数字标点、尾部单键、局部选词、翻页、退格、取消与切应用。标注多个合法目标，报告首选命中、Top-k、完成目标所需按键数和失败率。
4. 核心测试只计按键输入、候选实际生成及枚举，防止把惰性计算移出计时。UI 测试另计按键到候选显示、确认到宿主实际收字。C 与 D 使用相同 libime 及参数，以隔离前端开销。
5. 冷启动、首次候选、热输入分别报告 p50、p95、p99。另记峰值 RSS、稳定驻留、加载与部署耗时、CPU 时间、空闲 CPU 和磁盘体积。每项记录样本数、重复轮次与计时边界，随机化运行顺序并控制热状态。
6. 先冻结用户学习，再用同一训练轨迹测试学习收益与写盘成本。把候选质量、延迟和内存放在一起比较，不能用更少候选或更差质量换来的低延迟直接取胜。
7. 中文赛道关闭真实翻译，必要时统一注入固定即时译文以测试提交协议。真实翻译性能由主代理独立实验，不与中文引擎耗时混成一个数。

libime 已纳入首轮核心对照，原生前端与 Fcitx 集成路线分别保留。数据、词库、评分模型及质量不同；首轮也尚未测新增解码器、原生候选显示和真实宿主，不能据此宣布全局性能冠军。

## 新增一手来源

[sp]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/src/libime/pinyin/shuangpinprofile.h
[ctx]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/src/libime/pinyin/pinyincontext.h
[ime]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/src/libime/pinyin/pinyinime.h
[cmake]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/CMakeLists.txt
[data]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/data/CMakeLists.txt
[reuse]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/REUSE.toml
[dict]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/src/libime/pinyin/pinyindictionary-text-format.md
[addon]: https://github.com/fcitx/fcitx5-chinese-addons/blob/e8d930f402e359cfd76a101ee3e46815d1331d83/im/pinyin/pinyin.cpp
[macreadme]: https://github.com/fcitx/fcitx5-macos/blob/3466612499c149d5002b1aab37b92bb257da1a75/README.md
[controller]: https://github.com/fcitx/fcitx5-macos/blob/3466612499c149d5002b1aab37b92bb257da1a75/src/controller.swift
[ci]: https://github.com/fcitx/fcitx5-macos/blob/3466612499c149d5002b1aab37b92bb257da1a75/.github/workflows/ci.yml
[maclicense]: https://github.com/fcitx/fcitx5-macos/blob/3466612499c149d5002b1aab37b92bb257da1a75/LICENSE
[plugins]: https://github.com/fcitx-contrib/fcitx5-plugins/blob/36138780889db72c49f9507c4d2d511384f33454/README.md
[imk]: https://developer.apple.com/documentation/inputmethodkit
