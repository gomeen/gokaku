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

## 当前状态（2026-11-08）

**双端工程实施中。Mac 普通输入有历史限定场景证据；Windows TSF 有启用链与键盘输入的 VM 证据；双端完整验收均未通过。** 详细证据与边界见[原生开发验收](docs/validation/native-development.md)，逐功能状态见[双端功能对照](docs/feature-parity.md)。

- **普通输入**：小鹤双拼／全拼、模糊音、候选窗、标点／Shift／数字／编辑键、英文候选与释义、按应用默认英文、调频、自定义词、快捷键、完整皮肤已在共享核心与 Mac 前端实现；完整宿主安全矩阵与性能门槛未过。Windows 已交叉编译 x86／x64 TSF、x64 用户代理和设置应用；普通核心、配置、候选渲染与持久化已接通；按用户后续授权在 Windows VM 验证安装、七页设置、图标及限定的 64／32 位文本宿主，结果见验收记录。
- **学习翻译**：2026-11-06 裁决后**只保留火山 NMT**，默认关闭；设置页保存凭据、连接测试、本机字符统计。本地模型、CT2、SentencePiece、PyTorch、后端选择、beam 与模型准备入口已移除；旧本地模型配置迁移为关闭云翻译，避免升级后自动上传输入。普通输入完全离线；翻译失败保留输入，可 ⌘Return 明确原文上屏。
- **安装**：Mac 对外只交付 `.pkg`，不再生成或交付 DMG；pkg postinstall 采用解包校验→备份→替换→失败恢复。Windows 提供实际 Inno Setup `Setup.exe`（Windows 11 x64，含 64／32 位 TSF、x64 代理／设置／核心、普通输入资源及许可），在 Mac 上用 MinGW-w64＋Wine／Inno 编译；当前构包、组件哈希和依赖闭包见[报告](docs/validation/windows-setup-build.json)。最初仅要求构包，用户后续授权直接连接已安装的 Windows VM 排障；安装与限定宿主结果在验收记录中另列。
- **检查更新**：两端客户端、签名清单合同与发布脚本已实现。更新源已配置为 `gomeen/gokaku`；**b102（企业微信兼容＋双通道连接名修复）已正式发布**（Draft→published，tag `v0.1.1-dev.2-b102-dev` 落在 main；双端安装包与 Ed25519 签名清单已上传，公开清单签名已用随包公钥远端验证通过，[发布记录](docs/validation/release-b102.json)）。发布地址：https://github.com/gomeen/gokaku/releases/tag/v0.1.1-dev.2-b102-dev 。历史：b100/b101 同链路发布通过（[b100](docs/validation/release-b100.json)／[b101](docs/validation/release-b101.json)，b101 含双通道连接名冲突缺陷，见 b102）。客户端 GUI 内“检查更新”的端到端点击消费仍待验证。自动检查默认关闭，只在设置应用内按 24 小时节流；不自动下载／安装／重启。
- **未通过项**：Mac 完整宿主矩阵、逐键性能 p95≤5ms、双构建 pkg 升级／恢复、真实翻译凭据实测、Windows 完整宿主与升级失败恢复／卸载矩阵、真实在线更新、朋友真机验收。b94 已在限定 Windows 宿主复验冷启动，并通过旧 DLL 仍被加载时的默认升级；完整产品仍未验收。主题 WebP codec、共享学习协调等缺口见[功能对照](docs/feature-parity.md)。历史“漏字已修好”“Chrome 是宿主吞键”“性能条件性达标”等结论已撤回；旧报告不自动代表当前源码通过。

**b98 已修复三个真实输入缺陷，13 轮限定矩阵全部通过，完整验收仍未通过。** 依次修复：宿主终止组合时旧提交资格未撤销（b95，Chrome 跨字段）；宿主复用上下文切换字段后 InputScope 滞后致首键被吞（b97 复核机制，修复 b96 密码轮 `ihc `）；代理调频落盘持全局锁阻塞请求致按键重复出字（b98，修复 b97 `hc你好`）。b98 正式 DLL／代理完成 13 轮矩阵（两次切框、四次 Chrome 新宿主首组、三次密码、记事本两暖两冷），逐轮模块身份确认；b99 再补挂起的恢复 Shift 点击修复并通过切框、密码、记事本无回归验证。见[修复说明](docs/validation/dev-b99-fix/README.md)和[汇总](docs/validation/dev-b99-fix.json)；b95/b96/b97/b98 的失败证据继续保留。VS Code／Electron 类宿主与 Windows Terminal（未安装）记为受限项，未计入通过范围。

当前 `0.1.1-dev.2 / b99 / dev` 双端安装包已重建，[fast 七项通过](docs/validation/verify/report-fast-dev-b99.json)，ASan／UBSan quick 2,000 序列通过（不代表完整 release）。Windows 默认升级成功，71 个文件、双架构注册匹配；最终代理和注册均为正式 b99，设置未改，中文调频因合成提交发生预期变化。Mac b99 已实装并通过 14 项 IMK 冒烟（[证据](docs/validation/imk-host-smoke-dev.json)）。VM 环境另有旧 DLL 宿主会按自身路径复活旧版代理（互斥量拒绝，秒退），已在夹具与文档记录；旧宿主需重开后换用新 DLL。

现行证据见 [工程化检查](docs/validation/engineering-readiness.md)、[皮肤验收](docs/validation/skin-native-status.md) 和 [清理与测试审查](docs/validation/testing-cleanup-audit.md)。旧引擎／本地模型选型工具、结果和研究已移出当前树，可从 Git 历史追溯；只保留 [采用理由](docs/input-selection-decision.md)、通用考题和当前产品测试。

Mac 开发版已重新安装并发布（2026-11-09）：本机 dev 通道为构建 102（企业微信兼容＋连接名修复，选中已验证不回弹），已安装并注册，在系统设置启用「Gogaku Dev」输入源即可使用；stable 通道仍为旧构建 86（仅收正式版）。安装、恢复与卸载见[开发版使用说明](docs/native-development.md)。Mac 输入源采用双通道（stable／dev），用户数据共用。

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
- [Windows 实现调研](docs/research/windows-implementation-research.md)（历史，未完成）：安装向导／设置应用／翻译部署的 C 线结论已并入[发布与构包](docs/release.md)，TSF 注册对照的 A、B 线未写完。

## 许可

项目许可证尚未确定。复用青简源码、词库或第三方模型前，需分别核对相应许可和分发条件。
