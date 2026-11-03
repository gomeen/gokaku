# 学习模式 quickmt 开发版裁决

日期：2026-11-03。裁决人：用户。性质：**学习模式翻译后端在 Mac 本机开发版切换为 quickmt（CT2 INT8，双向两份权重），以外置 Python 辅助进程运行，形成本机可真实输入体验的最小闭环；显式替代既有「95% 质量门槛＋风险集处置」阻塞。仅限本机开发版自用，不改变双端交付门槛与正式验收口径。**

## 一、范围

本裁决只覆盖最小闭环：

1. **后端形态**：quickmt 双向（`quickmt-en-zh@f48b69e5`、`quickmt-zh-en@c27cc802`，CC-BY-4.0，原生 CT2 INT8）以**外置 Python 辅助进程**运行（`venv/bin/python`＋`quickmt_worker.py`，位于 `~/Library/Application Support/Gogaku/translation/`，venv＋权重约 900MB，不进 app bundle）。进程常驻、单请求串行、JSON 行协议对齐 `TranslationRequest`／`TranslationResult` v1；无端口、无文本日志、无网络访问。
2. **交互闭环**：输入法菜单「学习模式／学习方向」解除置灰（Ctrl+Shift+K／Ctrl+Shift+J 同款动作）；中→英（小鹤输入中文→候选窗出现英语译文→选择一次上屏）；英→中（英语直输→候选窗出现中文译文→选择上屏）。译文候选带「quickmt 开发版」标注；失败／超时／缺模型保留输入，可 ⌘Return 明确原文上屏。
3. **设置**：语言资源页新增「学习翻译（开发版）」区块——启用开关（默认开）、beam 步进器（1–10，默认 1）、后端状态（就绪／缺失＋准备指引 `python3 scripts/prepare-learning-translation.py`）、「未过质量门槛，仅开发版体验」固定说明。改动即时保存并热生效。
4. **拼写检查**：英→中 NSSpellChecker 随学习解锁恢复现有 `--spell` 通路，行为不变。

## 二、显式接受的已知风险（不作为新门槛）

以下缺陷在开发版被用户明确接受，**不得**被引用为质量验收通过的证据：

- 固定风险集 **12 条**错误译文仍会进入候选（短语级复读、截断、残片为主，见[统一实测决定](../probes/results/translation-backends/decision.md)）。
- 加固后 en→zh 可用率 **77.67%**（small100 为 95.15%／94.34%，均未过 95% 门槛）。
- 组合策略首轮验收未过（en→zh 46.0%／zh→en 53.0%）；加固层第二片（QE／专名对齐）未完成。
- **beam 默认 1** 为用户指定：贪心解码的重复句等缺陷会进入候选（探针实例：`Would you like to go for a walk after dinner?` → 「晚饭后你想出去散步吗? 吃完饭后,你要不要去散步?」，beam4 修复为「晚饭后你想出去散步吗 ? ”」）。用户可在设置自行调高 beam（代价：延迟增加，beam10 中位约 175ms，仍在预算内）。
- **宿主安全矩阵未验收**：真实宿主连续两轮、十万序列插桩、两小时稳定性等 host 档门槛保持原状，本次不解锁、不宣称通过。
- **学习记录保持关闭**（LearningStore 不动，不采集）；资源审核层（`resources/translation/`）本次不接入。
- 首次使用某方向时 worker 懒加载权重（约 1–2s，冷盘可更长，均在 10s 超时内）；此后进程常驻、逐句中位约 35–90ms。

## 三、approved 语义的开发版豁免

正式规则「approved 仅由审核资源清单决定，不能由翻译成功推导」**保持不变**；本次豁免仅指：`resource == "quickmt-ct2-dev"` 的成功结果按 `approved: true` 进入候选（设置开关整体回滚豁免）。其余资源（含未来的正式资源层）仍须走审核清单，不得引用本豁免。

## 四、门禁口径（两处同源）

- `GogakuInputController.learningDevEnabled`（原 `learningHostValidated` 常量）改为读设置 `learningTranslationEnabled`；关闭时菜单置灰、历史学习偏好被忽略、模式回普通。
- `EngineHub.learningSession(_:)` 同源按该设置创建／拒绝共享学习会话（创建含第二份词库加载，仅在用户实际进入学习输入时发生；关闭时 `closeLearningSession()` 释放）。
- 回滚方式：设置关「启用 quickmt 翻译后端」开关，即整体回门禁态（菜单置灰、会话释放、辅助进程随下次重建终止）。

## 五、运行与接口事实

| 项 | 值 |
| --- | --- |
| 准备脚本 | `scripts/prepare-learning-translation.py`（幂等；SHA256 与 pins 不符即拒绝装配；venv 用 `/usr/bin/python3`，pinned `ctranslate2==4.6.0`＋`sentencepiece==0.2.0`，不装 PyTorch） |
| 权重 pins | `probes/results/translation-backends/models.json`（runId 20261103T012307Z）既有 revision／SHA256 |
| worker | `scripts/quickmt_worker.py`（装配后随 `manifest.json` 落盘）；CT2 INT8、CPU 2 线程、max_decoding_length 256、`--beam` 来自设置 |
| 协议 | 请求回显 `protocolVersion`/`id`/`stamp`/`sourceID`/`source`/`resource`，附 `target`/`error`/`milliseconds`；错误码 `invalid_request`／`model_missing`／`empty_output`／`backend_error`；超 512 标量、协议版本≠1、非法方向→`invalid_request` |
| 延迟锚点 | beam1 逐句中位 35–90ms（本机复测 6 样例中位 50.8ms；官方协议同款 beam 曲线 88/117/129/140/142/175ms for beam 1/2/4/5/6/10） |
| 确定性 | 固定样例（两方向各 3 条）与探针记录逐字一致（同 beam 同 INT8 同 2 线程）；回归脚本 `scripts/validate-learning-translation.py`（`protocol` 子命令已接入 `verify.py --profile fast`） |

## 六、后续可选路径（均不在本次范围）

1. 资源审核层接入（`resources/translation/` 风险处置／审阅表达资源），恢复正式 approved 口径。
2. 加固层接入翻译管线＋第二片（QE／专名对齐），处置 12 条固定风险。
3. 原生 Swift helper 化（去 Python 依赖）。
4. 正式验收：宿主安全矩阵、语义盲测、95% 门槛重跑——通过前双端交付门槛维持阻塞表述。
5. 学习记录（LearningStore）与拼写检查联动的正式验收。
