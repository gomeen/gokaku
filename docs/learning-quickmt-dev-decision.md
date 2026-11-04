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

## 五点五、交互修订（2026-11-03 用户反馈，构建 25）

用户实测后裁决：**学习模式的交互应与普通输入模式完全一致，唯一区别是上屏文本换成相反语言；快捷键不单独定制，使用与普通模式相同的键位**。本节覆盖 product.md「三状态按键表」在开发版范围内的口径：

- **中→英**：与普通模式同一条共享核心路径（同一候选列表、释义、调频、数字 1–9 选词、空格选高亮、Enter 上屏原编码、标点一次上屏规则、Ctrl 编辑键、分页）。提交拦截：中文提交文本换成 quickmt 译文上屏；纯非 CJK 提交（原编码、英文候选）按普通语义原样上屏。
- **预译与预览**：组合期间预译当前高亮候选，状态行显示「译文：…」；提交时多数命中缓存同步上屏（零额外延迟）。缓存未命中时请求即发（免抖动），后续按键缓冲至译文落地后重放，防止异步插入与新组合交错；译文失败上屏原文并提示。
- **英→中**：保留独立英语缓冲（普通模式无英文组合可对应）；数字 1–9 直接选编号候选（不再用 ⌥数字），Enter 选中文译文，空格保留为英文空格输入（英语短句需要），⌘Return 原文上屏，Esc 取消。
- **已知偏差（开发版接受）**：学习提交经共享核心，也参与本地调频学习；快速添加的「最近上屏中文」可能包含学习提交（⌃⇧A 仍仅普通模式可用）。
- 组合面板学习行前缀同步去掉 ⌥。


## 五点六、方向识别评估结论（2026-11-03 用户裁决，构建 28）

用户提出「不限制方向、不主动切换、自动识别」后经评估选择**维持手动**：⌃⇧J（设置可自定义）切方向。评估要点（如未来重开此题）：拼音轨/英文轨可按「共享核心有无中文候选」逐键确定性判定，但 mini＝小鹤「迷你」＝英文词一类真歧义无解，Space 语义（拼音轨选词 vs 英文轨空格）存在硬冲突，误判会在错误时机提交——需要逃逸键＋预览兜底，收益不抵复杂度。已落地：模式／方向切换提示浮层跟随输入插入点（优先光标上方，PanelPlacement.toastOrigin 纯几何＋单测），浮层按文本自适应宽度，无有效锚点回退右上角。

## 五点七、quickmt 配置项清单（2026-11-03 用户问询，构建 41）

全部配置集中在三处，代码内其余行为均为固定实现（双向权重懒加载、单请求串行、无端口/无日志/无网络、尾部孤立标点剥离、源标量上限 512）。

**1. 输入法设置（`~/Library/Application Support/Gogaku/settings.json`）**

| 键 | 默认 | 取值 | 作用 |
|---|---|---|---|
| `learningTranslationEnabled` | `true` | 开关 | 学习模式总开关；关闭后切换键不再进入学习模式 |
| `learningBeamSize` | `1` | 1–10（超界自动钳制） | beam 大小；越大译文越稳、首译越慢；worker 由该值带 `--beam` 启动（两后端共用） |
| `learningTranslationBackend` | `"quickmt"` | `"quickmt"`｜`"small100"` | 翻译后端（2026-11-03 用户裁决的质量试验，见五点八）；未知值回退 quickmt |

**2. worker 启动参数（输入法按设置自动传参，一般不动）**

quickmt（`scripts/quickmt_worker.py`）与 small100（`scripts/small100_worker.py`）参数面完全一致，设置键两后端通用：

| 参数 | 默认 | 作用 |
|---|---|---|
| `--root` | 脚本所在目录 | 装配目录（venv＋权重） |
| `--beam` | `1`（由 `learningBeamSize` 传入） | 解码 beam，1 即贪心 |
| `--threads` | `2` | CT2 intra 线程数 |
| `--compute-type` | `int8` | ctranslate2 计算精度（可 `float16`/`int8_float16` 等） |
| `--max-decoding-length` | `256` | 解码最大 token 数（长译文上限） |

small100 另有模型侧固定项（不开放配置，与质量实测口径绑定）：语言协议锁定
gate 口径（目标语言令牌作输入前缀、解码器从 eos 开始，见五点八）；输入上限
`max_position_embeddings` 1024 token（超限按 invalid_request 拒绝）。

**3. 装配脚本（`scripts/prepare-learning-translation.py`，一次性）**

| 参数 | 默认 | 作用 |
|---|---|---|
| `--root` | 默认安装目录 | 装配目标 |
| `--cache` | 探针权重缓存 | 免重复下载 |
| `--python` | 系统 `python3` | venv 基解释器 |
| `--skip-venv` | — | 跳过 venv 重建 |
| `--worker-only` | — | 只更新 worker 脚本 |

## 五点八、small100 后端选项（2026-11-03 用户裁决，构建 43）

用户裁决：**仅换模型的质量试验**——新增 small100 后端选项，其余功能层（组合、面板、
预译、缓存、提交、防抖）一律不动。动机：quickmt en→zh 加固后可用率仅 77.67%
（固定风险 12 条），small100 实测 95.15%／94.34%、修加固误报后约 97%，逐句
p50 约 242ms、p95 约 700ms，仍在 2s 预算内（见 [统一实测决定]
(../probes/results/translation-backends/decision.md)）。

- **模型与许可**：alirezamsh/small100 @ 8ab680e2，MIT（模型卡）；
  tokenization_small100.py Apache-2.0。CT2 INT8 一次性转换。
- **装配**：`python3 scripts/prepare-learning-small100.py` →
  `~/Library/Application Support/Gogaku/translation/small100/`
  （venv 运行时不含 PyTorch——OpenMP 隔离教训；venv-convert 仅构建期）。
- **worker**：`scripts/small100_worker.py` 与 quickmt worker 同协议同错误码。
  运行时差异：显式加载仓库自带 SMALL100Tokenizer（AutoTokenizer 会按
  tokenizer_config 误选 M2M100Tokenizer，src_lang 语义与 small100 训练协议不符、
  方向错乱——已实测踩坑）；语言协议对齐 `scripts/validate-small100-gate.py`
  （目标语言令牌 `__en__`／`__zh__` 作输入前缀＋eos 后缀，解码器从纯 eos 开始，
  解码过滤 `</s>`／`<pad>`／`<unk>`）。转换环境含 PyTorch 须单线程
  （OMP_NUM_THREADS=1，Intel Mac 重复 OpenMP runtime 会 SIGSEGV，见
  conversion-diagnostic.json）。
- **设置**：`settings.json` 的 `"learningTranslationBackend": "small100"`；
  变更热生效（销毁重建辅助进程）。未装配时走现行失败路径（提示对应准备命令）。
- **验证**：`scripts/validate-learning-small100.py`（protocol＋samples）。
  samples 六条固定样例（beam1/INT8/2 线程）与探针记录逐字一致，6/6 过
  （2026-11-04 实测：首译含权重懒加载 1550ms，其后 115–270ms，与探针
  p50 约 242ms 同档）；protocol 15 项断言全过。
- **状态**：质量结论待用户实测；未过 95% 正式门槛前双端交付口径不变。

## 六、后续可选路径（均不在本次范围）

1. 资源审核层接入（`resources/translation/` 风险处置／审阅表达资源），恢复正式 approved 口径。
2. 加固层接入翻译管线＋第二片（QE／专名对齐），处置 12 条固定风险。
3. 原生 Swift helper 化（去 Python 依赖）。
4. 正式验收：宿主安全矩阵、语义盲测、95% 门槛重跑——通过前双端交付门槛维持阻塞表述。
5. 学习记录（LearningStore）与拼写检查联动的正式验收。
