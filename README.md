# Gogaku

在日常输入中学习另一种语言的输入法项目。名称取自日语「語学」（gogaku）。

构建独立的语言学习输入法，面向零基础和已有基础的用户。技术栈和框架保持开放，以实际输入性能为首要选型依据，同时满足候选质量、小鹤和提交正确性要求。已基于实测选择 libime 出厂数据＋小鹤＋原生前端为中文路线；业务核心迁移为共享 C++ 实现并通过版本化 C ABI 供两端调用，macOS 用 InputMethodKit／AppKit，Windows 用 TSF。旧引擎对比已退役，不宣称所选方案全球最快。产品目标允许不同母语与学习语言配对，不限于英语，也不限于中文母语。

首阶段面向当前 Intel Mac、macOS 26.7.2 与 Windows 11 x64 的本地开发版，覆盖中文与英语双向学习，以及单词、常用短语和完整句子。以下是已确认需求，实现与验证状态单列。

- 普通模式保留中文输入、中文上屏。学习模式支持中文输入、英语上屏，以及英语输入、中文上屏。
- 中文输入需要小鹤双拼，覆盖普通模式与中→英学习路径；英→中需要独立的英语输入路径。
- 支持快捷键、菜单切换模式；模式与方向为全局偏好，切换应用保持当前选择。学习输入以选词后立即上屏为默认，不额外要求预览和确认翻译。
- 只对用户在英→中方向输入的英语标记疑似问题。点击波浪线查看说明，暂不提供纠正功能。翻译失败时允许保留输入或明确选择原文上屏。
- 核心能力要求离线可用，联网增强默认关闭。拼写检查优先，语法检查可靠时再加入。
- 性能与质量优先保证实际输入过程；设置、学习片段等后台管理采用满足需求的简单方案。
- 默认记录学习片段而非完整输入历史，允许查看、删除和排除误报。工具生成的错误不计为用户的学习错误。

中文引擎和前端路线已选定。普通输入已在独立 AppKit 宿主和 Orca 终端通过限定的上屏与切换检查；完整宿主安全矩阵和学习并发尚未验收。学习翻译只保留用户配置的火山 NMT（默认关闭），不再随包或下载本地模型。需求边界、建议方案和待验证事项以[产品方向](docs/product.md)为准；双端逐项状态见[功能对照](docs/feature-parity.md)。

## 当前状态（2026-11-10）

**双端工程已进入 b110 stable 发布基线。** 版本来源为 `0.1.3 / build 110`；Mac pkg 与 Windows Setup 均已发布，公开更新清单的签名已验证。b110 的 fast／release 自动化验证通过，真实 host 未运行且已记录用户豁免，因此 Mac 真实输入源、Windows 当前包宿主、客户端在线更新 E2E、完整升级恢复／卸载仍未验收。详细证据与边界见[原生开发验收](docs/validation/native-development.md)，逐功能状态见[双端功能对照](docs/feature-parity.md)。

- **普通输入**：小鹤双拼／全拼、模糊音、候选窗、标点／Shift／数字／编辑键、英文候选与释义、按应用默认英文、调频、自定义词、快捷键、完整皮肤已在共享核心与 Mac 前端实现；完整宿主安全矩阵与性能门槛未过。Windows 已交叉编译 x86／x64 TSF、x64 用户代理和设置应用；普通核心、配置、候选渲染与持久化已接通。历史 b94–b99 曾在 Windows VM 验证安装、七页设置、图标及限定的 64／32 位文本宿主；b110 当前宿主尚未验收。
- **学习翻译**：2026-11-06 裁决后**只保留火山 NMT**，默认关闭；设置页保存凭据、连接测试、本机字符统计。本地模型、CT2、SentencePiece、PyTorch、后端选择、beam 与模型准备入口已移除；旧本地模型配置迁移为关闭云翻译，避免升级后自动上传输入。普通输入完全离线；翻译失败保留输入，可 ⌘Return 明确原文上屏。
- **安装**：Mac 对外只交付 `.pkg`，不再生成或交付 DMG；pkg postinstall 采用解包校验→备份→替换→失败恢复。Windows 提供实际 Inno Setup `Setup.exe`（Windows 11 x64，含 64／32 位 TSF、x64 代理／设置／核心、普通输入资源及许可），b110 的资产与哈希见[发布记录](docs/validation/release-b110.json)；[构包报告](docs/validation/windows-setup-build.json)是 b91 的历史静态证据，不能代表 b110 宿主验收。
- **检查更新**：两端客户端、签名清单合同与发布脚本已实现。更新源为 `gomeen/gokaku`；b110 stable 已发布，双端资产和 Ed25519 清单签名已验证，详见[发布记录](docs/validation/release-b110.json)。客户端 GUI 从旧版点击检查、下载、安装并重开仍待验证。自动检查默认关闭，只在设置应用内按 24 小时节流；不自动下载／安装／重启。
- **未通过项**：Mac 真实输入源与完整宿主矩阵、逐键性能 p95≤5ms、双构建 pkg 升级／恢复、真实翻译凭据实测、Windows 当前 b110 宿主与升级失败恢复／卸载矩阵、客户端在线更新 E2E、朋友真机验收。b110 的 host 豁免已写入发布记录，不得解释为宿主验收通过。主题 WebP codec、共享学习协调等缺口见[功能对照](docs/feature-parity.md)。历史报告只代表对应构建。

**历史 b98–b99 限定验证**：b98 修复三个真实输入缺陷并完成 13 轮限定矩阵，b99 补充恢复 Shift 点击修复；这些证据仍用于解释缺陷和回归范围，不代表 b110 已通过真实宿主验收。详情见[历史修复说明](docs/validation/dev-b99-fix/README.md)。

历史 `0.1.1-dev.2 / b99 / dev` 安装包及其 fast／ASan／Windows VM 证据继续保留在验证目录，作为对应构建的回归材料。它们不再是当前发布基线，也不自动代表 b110。

现行证据见 [工程化检查](docs/validation/engineering-readiness.md)、[皮肤验收](docs/validation/skin-native-status.md) 和 [清理与测试审查](docs/validation/testing-cleanup-audit.md)。旧引擎／本地模型选型工具、结果和研究已移出当前树，可从 Git 历史追溯；只保留 [采用理由](docs/input-selection-decision.md)、通用考题和当前产品测试。

Mac 开发版与 stable 的旧构建记录仍可从 Git 历史和发布记录追溯；当前公开发布基线统一为 b110 stable。安装、恢复与卸载的实际边界见[原生开发验收](docs/validation/native-development.md)。

保留的三份浏览器定稿原型使用预设样例，只用于核对输入习惯、设置布局与皮肤；核心回归和真实宿主验收分别留证。[输入习惯原型](docs/prototype-input-habits.md)经六轮迭代定稿，其按键裁决已并入[产品方向](docs/product.md)；原型可能保留旧提示，实现与验证状态以产品文档及原生验收为准。

可以直接用浏览器打开 [输入习惯原型](prototypes/input-habits-demo.html)、[设置定稿](prototypes/settings-final.html)和[皮肤定稿](prototypes/skin-settings-demo.html)，无需安装依赖。输入习惯原型的候选来自 libime 出厂数据的预生成快照；英文释义与学习翻译使用示例数据。早期输入流程探索及重复设置截图已退役，历史可从 Git 追溯。


## 文档

- [开发版使用说明](docs/native-development.md)：构建、pkg 安装、手动启用、火山翻译配置、检查更新、恢复和卸载。
- [版本与构建管理](docs/versioning.md)：version.json 单一版本来源、构建身份、阶段规则与拒绝路径。
- [发布与构包](docs/release.md)：日常 fast 档、release 与 host 验证、双端构包、publish-release 与 Draft 发布步骤。
- [Windows 安装说明](docs/windows-testing.md)：Setup.exe 安装、启用输入法、限定验证边界。
- [主题与皮肤规格](docs/skin-themes.md)：四套内置主题、单／双色、主题包格式与预览几何。
- [变更记录](CHANGELOG.md)：各版本变更摘要。
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
- [早期输入流程决策](docs/prototype-input-flow.md)：保留已采纳结论，旧演示与截图已退役。
- [协作说明](AGENTS.md)：后续开发与文档维护的约定。

## 许可

Gogaku 自身代码以 [MIT](LICENSE) 发布；第三方组件与随包数据保留各自原许可——LGPL-2.1-or-later 组件的源码提供与重链接义务、CC BY-SA 4.0 数据的署名与相同方式共享等均不受 MIT 影响，实际义务见[第三方许可](docs/third-party.md)。复用青简源码、词库或第三方模型前，仍需分别核对相应许可和分发条件。

## 致谢

- **青简输入法**：候选窗样式与学习模式交互的设计对照参考（见[输入习惯原型说明](docs/prototype-input-habits.md)）；未复制其代码、词库或个人数据。
- **[Rime 中州韵输入法](https://rime.im/)**：开源输入法社区的先行实践，为项目形态提供灵感；未使用其代码或词库。
