# Gogaku

在日常输入中学习另一种语言的输入法项目。名称取自日语「語学」（gogaku）。

构建独立的语言学习输入法，面向零基础和已有基础的用户。技术栈和框架保持开放，以实际输入性能为首要选型依据，同时满足候选质量、小鹤和提交正确性要求。已基于实测选择 libime 出厂数据＋小鹤＋原生前端为中文路线；业务核心迁移为共享 C++ 实现并通过版本化 C ABI 供两端调用，macOS 用 InputMethodKit／AppKit，Windows 用 TSF。青简、Rime 等保留为历史对照，不宣称所选方案全球最快。产品目标允许不同母语与学习语言配对，不限于英语，也不限于中文母语。

首阶段面向当前 Intel Mac、macOS 26.7.2 与 Windows 11 x64 的本地开发版，覆盖中文与英语双向学习，以及单词、常用短语和完整句子。以下是已确认需求，实现与验证状态单列。

- 普通模式保留中文输入、中文上屏。学习模式支持中文输入、英语上屏，以及英语输入、中文上屏。
- 中文输入需要小鹤双拼，覆盖普通模式与中→英学习路径；英→中需要独立的英语输入路径。
- 支持快捷键、菜单切换模式；模式与方向为全局偏好，切换应用保持当前选择。学习输入以选词后立即上屏为默认，不额外要求预览和确认翻译。
- 只对用户在英→中方向输入的英语标记疑似问题。点击波浪线查看说明，暂不提供纠正功能。翻译失败时允许保留输入或明确选择原文上屏。
- 核心能力要求离线可用，联网增强默认关闭。拼写检查优先，语法检查可靠时再加入。
- 性能与质量优先保证实际输入过程；设置、学习片段等后台管理采用满足需求的简单方案。
- 默认记录学习片段而非完整输入历史，允许查看、删除和排除误报。工具生成的错误不计为用户的学习错误。

中文引擎和前端路线已选定。普通输入已在独立 AppKit 宿主和 Orca 终端通过限定的上屏与切换检查；完整宿主安全矩阵和学习并发尚未验收。学习翻译只保留用户配置的火山 NMT（默认关闭），不再随包或下载本地模型。需求边界、建议方案和待验证事项以[产品方向](docs/product.md)为准；双端逐项状态见[功能对照](docs/feature-parity.md)。

## 当前状态（2026-11-06）

**双端工程实施中。Mac 普通输入有历史限定场景证据；Windows TSF 有启用链与键盘输入的 VM 证据；双端完整验收均未通过。** 详细证据与边界见[原生开发验收](docs/validation/native-development.md)，逐功能状态见[双端功能对照](docs/feature-parity.md)。

- **普通输入**：小鹤双拼／全拼、模糊音、候选窗、标点／Shift／数字／编辑键、英文候选与释义、按应用默认英文、调频、自定义词、快捷键、完整皮肤已在共享核心与 Mac 前端实现；完整宿主安全矩阵与性能门槛未过。Windows 已交叉编译 x86／x64 TSF、x64 用户代理和设置应用；普通核心、配置、候选渲染与持久化已接通；按用户后续授权在 Windows VM 验证安装、七页设置、图标及限定的 64／32 位文本宿主，结果见验收记录。
- **学习翻译**：2026-11-06 裁决后**只保留火山 NMT**，默认关闭；设置页保存凭据、连接测试、本机字符统计。本地模型、CT2、SentencePiece、PyTorch、后端选择、beam 与模型准备入口已移除；旧本地模型配置迁移为关闭云翻译，避免升级后自动上传输入。普通输入完全离线；翻译失败保留输入，可 ⌘Return 明确原文上屏。
- **安装**：Mac 对外只交付 `.pkg`，不再生成或交付 DMG；pkg postinstall 采用解包校验→备份→替换→失败恢复。Windows 提供实际 Inno Setup `Setup.exe`（Windows 11 x64，含 64／32 位 TSF、x64 代理／设置／核心、普通输入资源及许可），在 Mac 上用 MinGW-w64＋Wine／Inno 编译；当前构包、组件哈希和依赖闭包见[报告](docs/validation/windows-setup-build.json)。最初仅要求构包，用户后续授权直接连接已安装的 Windows VM 排障；安装与限定宿主结果在验收记录中另列。
- **检查更新**：两端客户端、签名清单合同与发布脚本已实现；Mac 协议用注入传输与临时密钥测试，Windows 已编译并随包。真实 GitHub Releases 链路未验证，owner／repo 留空时明确显示未配置更新源。自动检查默认关闭，只在设置应用内按 24 小时节流；不自动下载／安装／重启。
- **未通过项**：Mac 完整宿主矩阵、逐键性能 p95≤5ms、双构建 pkg 升级／恢复、真实翻译凭据实测、Windows 完整宿主与升级／卸载矩阵、真实在线更新、朋友真机验收。Windows 构建 91 仍有代理冷启动首组输入未接管的已知失败，不是稳定版；另有主题 WebP codec、共享学习协调及升级恢复等功能缺口，见[功能对照](docs/feature-parity.md)。历史“漏字已修好”“Chrome 是宿主吞键”“性能条件性达标”等结论已撤回；旧报告不自动代表当前源码通过。

历史证据仍保留：[工程化检查](docs/validation/engineering-readiness.md)（版本、干净构建、备份、测试证据绑定）、[皮肤验收](docs/validation/skin-native-status.md)、[翻译实测](docs/translation-benchmark.md)、[组合策略决定](docs/translation-strategy-decision.md)、[模型解堵调研](docs/research-translation-model-unblock.md)。这些是研究记录，不是当前能力或已验收声明。

已授权当前用户安装 Mac 开发版，由用户手动启用输入源；安装、恢复与卸载见[开发版使用说明](docs/native-development.md)。Mac 输入源采用双通道（stable／dev），用户数据共用。

已有两个单文件浏览器原型仍只使用预设样例；独立真实模型实验与核心回归不能代替完整输入源验收。[输入习惯原型](docs/prototype-input-habits.md)经六轮迭代定稿，其按键裁决已并入[产品方向](docs/product.md)，但尚未落到原生输入法。

直接用浏览器打开 [输入流程原型](prototypes/input-flow.html)，无需安装依赖。macOS 也可以在项目目录运行 `open prototypes/input-flow.html`。本页状态只保存在内存中，刷新会清空。

另有一个用于确认输入习惯与候选窗外观的 [输入习惯原型](prototypes/input-habits-demo.html)：候选来自 libime 出厂数据的预生成快照，覆盖标点、Shift、大写、数字、方向键、分段选择、英文候选、按应用默认英文等场景，并可用示例数据演示学习中→英／英→中的交互；说明与边界见[输入习惯原型说明](docs/prototype-input-habits.md)。在确认结果回写正式计划之前，这些行为不代表已实现的输入法能力。

另已完成青简核心的选定测试、本机 librime 小鹤及 macOS 拼写接口探针。结果见[可行性验证](docs/feasibility.md)。真实 OPUS/M2M100 的双向推理、五轮延迟与禁网测试见[翻译实测](docs/translation-benchmark.md)。这些模型均已退出产品链路；历史结果保留为证据。

中文核心另已完成青简统计配置、Rime 官方小鹤、雾凇小鹤、万象标准版小鹤与 libime 出厂数据的实际装配、候选及逐键实验，见[首轮输入引擎实测](docs/input-engine-benchmark.md)。这里只覆盖核心，不代表候选窗、真实宿主或翻译并发已验收。新增 libpinyin、SunPinyin、Google 开放拼音及不同前端的接口与待测项见[其他路线](docs/research-ime-alternatives.md)。

新增 [20 句翻译对照页](prototypes/translation-comparison.html)：small100、quickmt、Index-Translate-2B、HY-MT1.5-1.8B、Qwen2.5-0.5B（2/4 线程）与 Qwen3-0.6B（2/4 线程）在本机分别运行中→英、英→中各 10 句，展示全部未经修正的真实输出及单次耗时，可切换方向、展开参考译法、保存并导出个人评价。GGUF 模型（官方量化、llama.cpp CPU）实测汇总见 [GGUF 实测记录](probes/results/gguf-translation/summary.md)：质量初观明显改善；4 线程下最快的 Qwen2.5-0.5B 逐句中位 538ms，仍超 500ms 短表达预算；资源占用 0.6–2GiB 级，空闲 CPU 为 0%，不是约束。它是独立的离线推理结果快照，区别于上述预设交互原型；不代表当前火山翻译质量已通过或学习链路已验收。复跑与数据边界见 [探针说明](probes/README.md#20-句翻译网页对照)。

## 文档

- [开发版使用说明](docs/native-development.md)：构建、pkg 安装、手动启用、火山翻译配置、检查更新、恢复和卸载。
- [版本与构建管理](docs/versioning.md)：version.json 单一版本来源、构建身份、阶段规则与拒绝路径。
- [发布与构包](docs/release.md)：日常 fast 档、release 与 host 验证、双端构包、publish-release 与 Draft 发布步骤。
- [Windows 安装说明](docs/windows-testing.md)：Setup.exe 安装、启用输入法、限定验证边界。
- [主题与皮肤规格](docs/skin-themes.md)：四套内置主题、单／双色、主题包格式与预览几何。
- [变更记录](../CHANGELOG.md)：各版本变更摘要。
- [工程化检查](docs/validation/engineering-readiness.md)：交付链路六项检查、整改与发布阻塞分列。
- [双端功能对照](docs/feature-parity.md)：逐项实现／验证状态、平台差异与本轮缺口。
- [检查更新](docs/update.md)：清单 schema、Ed25519 签名、通道／构建号规则、发布与 Draft 流程。
- [原生开发验收记录](docs/validation/native-development.md)：实际测试证据、状态和阻塞。
- [第三方许可](docs/third-party.md)：固定组件、实际打包许可和公开分发前义务。
- [释义词性数据调研](docs/research-gloss-data.md)：候选窗「词性＋译文」注释的数据源选择、许可义务与落地路径。
- [双端实施计划](docs/implementation-plan.md)：P0–P6 执行顺序、共享合同、安装与更新门槛。
- [技术选型决定](docs/input-selection-decision.md)：libime＋原生前端的采用理由、其他方案不选原因，以及自由句模型与完整产品的未通过结论。
- [产品方向](docs/product.md)：已确认需求、建议方案、待验证问题与验收方向。
- [输入习惯原型说明](docs/prototype-input-habits.md)：候选窗外观与比例、标点、Shift、编辑键、分段选择、英文候选与学习演示的六轮迭代定稿；含青简本机配置逐项对照与三项用户裁决。
- [输入流程原型说明](docs/prototype-input-flow.md)：体验方式、浏览器验证结果与模拟边界。
- [可行性验证](docs/feasibility.md)：青简、Rime、小鹤双拼与 macOS 检查接口的证据及剩余工作。
- [输入法整体选型](docs/input-method-research.md)：围绕实际打字性能与质量，覆盖前端、引擎与数据、学习调度、宿主兼容、耗电、隐私和分发的全面调研与下一轮验证。
- [输入引擎首轮实测](docs/input-engine-benchmark.md)：五套小鹤配置的候选、完整提交、逐键核心、内存、禁网与环境限制。
- [输入引擎候选](docs/input-engine-candidates.md)：初始集成路线与公平比较边界；[其他路线](docs/research-ime-alternatives.md)补充新增解码器、前端与桥接方案。
- [离线翻译候选](docs/translation-candidates.md)：OPUS 之外的模型与许可核查。
- [翻译实测](docs/translation-benchmark.md)：模型质量缺陷、五轮延迟、内存、禁网与失败路径结果。
- [翻译实验方案](docs/translation-benchmark-plan.md)：真实模型测试的样例、计时范围与判定条件。
- [翻译后端统一实测决定](probes/results/translation-backends/decision.md)（历史）：small100 与 quickmt 的模型层／IPC／加固层性能与质量门槛；本地模型已退出产品链路。
- [协作说明](AGENTS.md)：后续开发与文档维护的约定。
- [Windows 实现调研](docs/research/windows-implementation-research.md)（历史，未完成）：安装向导／设置应用／翻译部署的 C 线结论已并入[发布与构包](docs/release.md)，TSF 注册对照的 A、B 线未写完。

## 许可

项目许可证尚未确定。复用青简源码、词库或第三方模型前，需分别核对相应许可和分发条件。
