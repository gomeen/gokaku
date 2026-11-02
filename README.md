# Gogaku

在日常输入中学习另一种语言的输入法项目。名称取自日语「語学」（gogaku）。

构建独立的语言学习输入法，面向零基础和已有基础的用户。技术栈和框架保持开放，以实际输入性能为首要选型依据，同时满足候选质量、小鹤和提交正确性要求。已基于实测选择 libime 出厂数据＋小鹤＋原生前端为中文路线；业务核心迁移为共享 C++ 实现并通过版本化 C ABI 供两端调用，macOS 用 InputMethodKit／AppKit，Windows 用 TSF。青简、Rime 等保留为历史对照，不宣称所选方案全球最快。产品目标允许不同母语与学习语言配对，不限于英语，也不限于中文母语。

首阶段面向当前 Intel Mac、macOS 26.7.2 与 Windows 11 x64 的本地开发版，覆盖中文与英语双向学习，以及单词、常用短语和完整句子。以下是已确认需求，实现与验证状态单列。

- 普通模式保留中文输入、中文上屏。学习模式支持中文输入、英语上屏，以及英语输入、中文上屏。
- 中文输入需要小鹤双拼，覆盖普通模式与中→英学习路径；英→中需要独立的英语输入路径。
- 支持快捷键、菜单切换模式，并按应用记住模式。学习输入以选词后立即上屏为默认，不额外要求预览和确认翻译。
- 只对用户在英→中方向输入的英语标记疑似问题。点击波浪线查看说明，暂不提供纠正功能。翻译失败时允许保留输入或明确选择原文上屏。
- 核心能力要求离线可用，联网增强默认关闭。拼写检查优先，语法检查可靠时再加入。
- 性能与质量优先保证实际输入过程；设置、学习片段等后台管理采用满足需求的简单方案。
- 默认记录学习片段而非完整输入历史，允许查看、删除和排除误报。工具生成的错误不计为用户的学习错误。

中文引擎和前端路线已选定。普通输入已在独立 AppKit 宿主和 Orca 终端通过限定的上屏与切换检查；完整宿主安全矩阵和学习并发尚未验收，离线翻译尚无合格默认模型。需求边界、建议方案和待验证事项以[产品方向](docs/product.md)为准。

## 当前状态

[首阶段实施总计划](docs/implementation-plan.md)已批准并进入原生工程实施。普通模式已迁入共享 C++ 核心，英文候选与释义数据已随包。2026-11-02 整改轮（构建 6）：**组合中 Shift 改为原样上屏后切英文直输**（用户裁决，替换「上屏不切中英」旧规则；真机探针黄金表同步重写）；候选窗读取宿主 `windowLevel` 并在其上一层显示（修复 Bob 浮窗遮挡），宿主选区未知不再伪造光标矩形；设置页按定稿原型逐项还原并修复快捷键编辑器录制／清除／恢复默认不生效、冲突筛选看不到草稿的问题；系统切换浮层图标根因实证（HUD 进程缓存旧图）并在安装流程重启该代理；原编码／非已学习提交使快速添加失效；菜单「恢复草稿」改「恢复未完成输入」。逐项证据见[验收记录](docs/validation/native-development.md)。

2026-11-03 轮：设置页按[已定稿原型](../prototypes/settings-final.html)完成原生落地（六页外壳、立即保存写入协调器、真实索引的应用列表与可搜索弹层、VS Code 式快捷键表格含录制／冲突检查、自定义词语紧凑列表＋搜索；语言资源页移除 Apple Translation 入口），快捷键模型升级为规范键标识＋修饰键＋明确禁用状态（兼容旧配置），候选窗定位重构（光标矩形三态、100ms 复查、无效位置隐藏保留组合），`verify.py --profile host` 从文字计划改为真实调度（两轮矩阵、Orca Shift 专项、万次性能、新增两小时稳定性浸泡探针）。本轮 fast 档全过（核心 ctest 4/4、Swift Release 87 项），离线渲染 51 项含放置几何，GUI 六页真实点击冒烟截图归档。

2026-11-02 轮：完成[工程化检查与整改](docs/validation/engineering-readiness.md)（版本可追溯、干净构建、备份暴露、/tmp 隐式依赖、测试证据绑定），建立 Git 基线与单一版本来源（`version.json`，见 [版本管理](docs/versioning.md)），新增统一验证入口 `python3 scripts/verify.py`（fast／release／host 三档）；修复 **Shift 提交不更新最近上屏字符**的核心缺陷（Terminal「Shift＋句号」半角根因，上一轮归因平台层有误），释义精简规则落地（`char.` 词性、结构化标签与强语域义项剔除，见[审阅记录](docs/validation/gloss-simplification-review.md)），构建 4 修复自定义拼音词候选剪枝与自动读音解析（详见[验收记录](docs/validation/native-development.md)）。

**性能与宿主阻塞未变，仍未到试用阶段**：上一轮 10,035 次真实 IMK 事件主线程 p95 10.35ms／p99 15.38ms（门槛 5ms／10ms）未达标；归因结论（长单行文档的必要同步宿主写入本身超预算）未被本轮工作改变。最终宿主连续两轮、十万序列插桩、两小时稳定性／内存／冷启动未完成；Orca 的 Shift 单击失败待专项追踪；「5.55ms 低于 5ms」等历史文字错误已更正（见[收尾复测报告](docs/validation/pre-user-test.md)）。此前“漏字已修好”“Chrome 是宿主吞键”“性能条件性达标”等结论已撤回。本轮 Shift 修复在真实宿主复验前，不标宿主通过。

**完整首阶段仍未通过。** 学习路线采用两端统一 small100＋CT2；Mac 分词、转换、速度和离线可行，但模型质量门槛不通过，生产学习辅助和真实学习记录保持关闭。Windows 桌面环境尚未提供，Windows 与双端闭环未开始。工程化检查结论：0.1.0 前工程侧阻塞已清零，剩余全部为验收门槛项（见[工程化检查](docs/validation/engineering-readiness.md) §7）。

已授权当前用户安装开发版，由用户手动启用输入源；设置页不再提供 Apple 语言资源安装或查询入口（Apple Translation 已退出正式链路），随包资源状态与功能开放状态见设置「语言资源」页。构建、安装、恢复和卸载见[开发版使用说明](docs/native-development.md)。

已有两个单文件浏览器原型仍只使用预设样例；独立真实模型实验与核心回归不能代替完整输入源验收。[输入习惯原型](docs/prototype-input-habits.md)经六轮迭代定稿，其按键裁决已并入[产品方向](docs/product.md)，但尚未落到原生输入法。

直接用浏览器打开 [输入流程原型](prototypes/input-flow.html)，无需安装依赖。macOS 也可以在项目目录运行 `open prototypes/input-flow.html`。本页状态只保存在内存中，刷新会清空。

另有一个用于确认输入习惯与候选窗外观的 [输入习惯原型](prototypes/input-habits-demo.html)：候选来自 libime 出厂数据的预生成快照，覆盖标点、Shift、大写、数字、方向键、分段选择、英文候选、按应用默认英文等场景，并可用示例数据演示学习中→英／英→中的交互；说明与边界见[输入习惯原型说明](docs/prototype-input-habits.md)。在确认结果回写正式计划之前，这些行为不代表已实现的输入法能力。

另已完成青简核心的选定测试、本机 librime 小鹤及 macOS 拼写接口探针。结果见[可行性验证](docs/feasibility.md)。真实 OPUS/M2M100 的双向推理、五轮延迟与禁网测试见[翻译实测](docs/translation-benchmark.md)。模型均有质量缺陷，不采用为默认上屏后端。中文底座已选定，但完整离线学习产品仍不通过，见[技术选型决定](docs/input-selection-decision.md)。

中文核心另已完成青简统计配置、Rime 官方小鹤、雾凇小鹤、万象标准版小鹤与 libime 出厂数据的实际装配、候选及逐键实验，见[首轮输入引擎实测](docs/input-engine-benchmark.md)。这里只覆盖核心，不代表候选窗、真实宿主或翻译并发已验收。新增 libpinyin、SunPinyin、Google 开放拼音及不同前端的接口与待测项见[其他路线](docs/research-ime-alternatives.md)。

## 文档

- [开发版使用说明](docs/native-development.md)：构建、安装、手动启用、语言资源、恢复和卸载。
- [版本与构建管理](docs/versioning.md)：version.json 单一版本来源、构建身份、阶段规则与拒绝路径。
- [变更记录](../CHANGELOG.md)：各版本变更摘要。
- [工程化检查](docs/validation/engineering-readiness.md)：交付链路六项检查、整改与发布阻塞分列。
- [原生开发验收记录](docs/validation/native-development.md)：实际测试证据、状态和阻塞。
- [第三方许可](docs/third-party.md)：固定组件、实际打包许可和公开分发前义务。
- [释义词性数据调研](docs/research-gloss-data.md)：候选窗「词性＋译文」注释的数据源选择、许可义务与落地路径。
- [首阶段实施总计划](docs/implementation-plan.md)：统一执行入口，按原生输入、语言资源、学习交互、真实集成、记录和最终验收推进；明确阻塞与阶段通过条件。
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
- [协作说明](AGENTS.md)：后续开发与文档维护的约定。

## 许可

项目许可证尚未确定。复用青简源码、词库或第三方模型前，需分别核对相应许可和分发条件。
