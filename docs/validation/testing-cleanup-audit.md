# 旧选型材料清理与发布测试审查

本轮按 `shared/`、`macos/`、`windows/` 分层后的工作树实施。已清理旧选型、修补报告门禁并补离线测试；未执行真实云翻译、真实按键、安装升级或发布。以下区分已修补的工具问题与仍未完成的产品验收。

## 清理结果

已退役青简／Rime 多引擎比较、OPUS／M2M100／small100／quickmt／GGUF 的准备、下载、转换、测速工具及依赖；删除模型排名、逐请求输出、策略调参报告、重复研究与翻译对照 HTML。当前树不再维护这些实验副本，历史从 Git 追溯。

保留内容如下：

| 材料 | 用途 |
| --- | --- |
| `docs/input-selection-decision.md` | libime＋原生前端的简短采用理由及验收边界 |
| `validation/translation-*.json`、`probes/translation-*.json` | 与提供商无关的双向考题、风险输入与参考；合计 688 条输入，不以参考精确匹配代替语义审阅 |
| `validation/manifest.json` | 固定考题／风险索引／留存 TSV 的内容身份 |
| `resources/translation/`、共享安全规则及测试 | 现有表达表、模板、品牌与文本安全规则；保留许可、署名、哈希与核心一致性检查 |
| `probes/volcengine-translate-probe.py` | 当前火山的 20 句实测入口，需授权凭据；结果移到 `probes/results/volcengine/` |
| `scripts/volcengine_translate_worker.py` | 当前签名固定向量的参考实现，不是退役 quickmt worker |
| `macos/Tests/`、`shared/GogakuCore/tests/` 与现役 `probes/` | 输入法会话、取消／缓存／迟到结果、故障恢复、渲染、宿主、性能与稳定性测试 |
| `prepare-libime-input.py`、`libime-input-worker.cpp`、输入样例生成器与两份 input-engine JSON | 当前固定依赖准备与中文质量测试仍有消费者，保留 |

旧 `translation-eval-regression` 和 `learning-worker-protocol` 已退出 fast／release。提供商无关的数据检查抽到 `scripts/validate-translation-data.py`，覆盖数据截断、方向失衡、重复 ID、空源文、哈希／路径、表达表许可及重复键；确认／最终集与开发集去重，保留探针不混入应译分母。说明见 [validation](../../validation/README.md) 与 [probes](../../probes/README.md)。

## 已修补的验证工具问题

| 原问题 | 当前处理与验证 |
| --- | --- |
| 缓存混入源码指纹，测试变化不使旧报告失效 | 遍历时剪枝 `.build` 等缓存目录；产品源码与测试实现分别计算指纹，测试身份覆盖 probes、validation 和工作流 |
| 报告可自称 required=false 或漏检查而通过 | `_gogaku_verification.py` 统一策略版本与每档必需清单；发布端重新计算，拒绝缺项、重复、未知项／档位、错误 required、旧策略、摘要不符与测试身份变化 |
| 验证期间源码变化仍可记通过 | 比较运行前后源码与测试身份；`runIdentityStable` 为 false 时不能通过或发布 |
| CTest 原生跳过仍有 100%／退出 0 | `build.py` 与 verify 共用严格结果校验；必须正数量、逐项 Passed、序号和总数一致，无 skipped／disabled／not run；负例包含真实临时 CTest 工程 |
| 宿主／性能只信总结、不核完成覆盖 | 按探针同一份计划核对宿主、完整组、每组 200 轮与逐轮 JSONL；性能要求一万条当前安装件样本，复用探针汇总／门槛重判。正例及截断、漏组、旧计划／身份反例均离线通过 |
| 人工 GUI 缺失被记为 passed | 缺证据明确 blocked；须绑定当前源码／构建／通道／包，覆盖七页×两尺寸×浅深截图矩阵；键盘、录制、应用选择和 VoiceOver 行为仍需人工核对 |
| dev host 可误查 stable 安装件 | 当前宿主探针仅支持 stable；dev 的 host 明确 blocked，不复用 stable 结果 |
| 迁移后渲染找旧模块／对象目录，空输出也可通过 | 使用当前构建路径与 `GogakuKit` 模块；适配当前光标字形，离屏渲染单项 53 项通过；缺汇总、零／不足数量、逐项记录不符均拒绝 |
| 干净构建可能链接默认根的旧库 | Swift manifest 和 build.py 共用选定的绝对构建根；路径回归覆盖默认／相对／绝对／符号链接根及旧 CMake 缓存。完整 clean-build 本轮未运行 |
| Windows CI preset／DLL 路径错误 | 工作目录指向共享核心，按 bin 输出路径运行 ABI 与 DLL 检查；实际 Windows CI 仍未运行 |
| fast 全绿文案容易被理解成发布就绪 | 输出明确区分档位结果与发布就绪；缺包不妨碍日常逻辑测试，但发布器仍拒绝未绑定当前双端安装包收据／哈希的报告 |

以上针对本地工具误用与缓存陈旧，不把 JSON 报告当作能抵抗有意篡改发布环境的安全边界。`--only` 会保留其它必需项 skipped，quick ASan 不满足完整十万序列门槛；单项成功时整体退出非零是预期。

## 当前云翻译覆盖

新增 `macos/Tests/GogakuKitTests/VolcengineHTTPTests.swift`，经内部 URLProtocol 接缝直接调用生产 `VolcengineClient.translate`，全部离线、临时凭据：

- 双向请求／成功解析、服务端计费字符、凭据每请求热读。
- 401／403／429／5xx、坏 JSON、空 TranslationList、空目标、超大响应。
- timeout／network 映射，以及生产会话拒绝重定向。

生产会话继续采用 ephemeral 策略；空列表统一为 `emptyOutput`。现有签名固定向量、设置迁移、请求身份、取消／缓存／迟到结果与失败保留输入测试继续保留。重定向测试已用临时允许跳转的反向变异确认会失败，随后恢复。

这些不证明真实火山调用或 Windows WinHTTP 已验收。以后换在线提供商，应复用通用会话测试，另补该提供商的协议、凭据和响应异常测试；当前没有新增提供商或通用插件系统。

## 发布前会运行什么

| 入口 | 当前行为 |
| --- | --- |
| `build.py` | 构建并执行共享核心 CTest；不自动跑 Swift test／完整 verify |
| 双端打包脚本 | 核对源码身份、编译来源、收据、资源与许可；不自动做真实安装或打字 |
| fast | 版本、资源、共享核心、Release Swift、通用翻译数据、验证门禁负例、交付合同 |
| release | fast 内容＋干净构建、包检查、质量、离屏渲染、数据可靠性、完整十万序列 ASan／UBSan；安装预检可选 |
| host | stable 安装件身份、两轮 Mac 宿主矩阵、Shift、性能、两小时稳定性、人工 GUI 证据；需用户空闲并授权 |
| `publish-release.py` | 消费已有报告，不重跑测试；dev 至少 fast，rc／定版必须 fast＋release＋host，另核当前双端包与收据 |

操作说明已同步到 [发布流程](../release.md)、[更新合同](../update.md) 与 [开发说明](../native-development.md)。手工发送安装包或在 GitHub 手动发布会绕过脚本，不保证“每次构包就自动全测”。

## 仍未形成强制闭环的部分

- Windows 原生核心运行、TSF／代理冷暖启动、32／64 位真实宿主、完整设置操作，仍需独立运行证据。交叉编译和 Mac 单测不能替代。
- 两端真实安装、双版本升级／恢复、卸载、GitHub 下载到安装重开，以及授权凭据云翻译未全部接入机器门禁。
- 当前 Windows 构建 91 的代理冷启动首组输入仍有历史失败；本轮未修改该行为，也未复验安装件。
- Mac 完整宿主与性能门槛不因 fast／离屏渲染通过而解除。GUI 尚无当前完整人工证据时应继续 blocked。

## 本轮验证证据

- 日常 fast：七项通过，共享核心 CTest 10/10 与 Swift Release 217/217；`runIdentityStable=true`，报告见 [fast](verify/report-fast-20261108-095255.json)。
- 渲染单项：53 项通过；[单项报告](verify/report-release-20261108-095111.json) 的完整 release gate 为 false，其余必需项 skipped，不能作为发布验收。
- 验证／交付门禁单测包含空报告、漏项、required 篡改、旧策略、缓存身份、运行期间变化、CTest 跳过／零测试、GUI 缺失／身份／矩阵、dev host、宿主完成覆盖、性能原始样本、渲染空输出和 quick ASan 负例。验证与交付门禁单测合计 32 项通过。
- 未跑完整 release／十万序列、真实 host、真实网络、Windows CI／VM、安装升级或发布；未对外提供新包。当前产物身份已因源码变化失配，发布前必须递增构建号、重建并绑定新报告。
