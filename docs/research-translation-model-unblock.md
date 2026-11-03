# 翻译模型解堵调研：small100 质量门槛不通过后的路线

更新：2026-11-02。性质：**调研完成，未经用户裁决，不改变当前"双端学习交付保持阻塞"的状态**；任何路线落地前都需先修订[实施总计划](implementation-plan.md)§4/§8 的现行停止规则（"不恢复 OPUS／M2M100，不扩模型名单"）。失败证据基线见 [small100 Mac 门槛语义审阅](../probes/results/small100-gate/semantic-review.md)。

## 一、问题定义与硬约束

small100@`8ab680e`（CT2 INT8，i9-9880H 实测）速度充分（热态短表达 p95 125ms／短句 219ms，预算 500ms／2s），但质量门槛不通过，失败分五类：

| 类别 | 实例 |
| --- | --- |
| 人名丢失 | "Alice will meet Bob in Beijing"→Bob 消失 |
| 时间翻转/丢失 | `10:30 a.m.`→「下午10点30点」、`9 a.m. to 4 p.m.`→「下午9点至下午4点」、`十点半`→`10 a.m.` |
| 繁体输出 | `attend a meeting`→「參加會議」 |
| 品牌改写 | `Gogaku v3.2.1`→「古巴 v3.2.1」 |
| 错拼/乱码编造 | `qqxzzv`→181 个重复 Q |

任何解法都必须同时满足：离线 CPU-only（AVX2）、热态短表达 p95≤500ms／短句≤2s、macOS（CT2 dylib）＋Windows（MSVC）两端同模型同参数、许可可接受（项目许可未定、当前仅本地开发版不分发；宽松许可优先，非商用许可须标注为分发风险）。

调研覆盖三条路线：**A 换 NMT 模型**、**B 小型 LLM**、**C 现有模型工程加固**。结论先行：

- 路线 A：解冻名单**救不了** NLLB／M2M100 线（前者结构性中文缺陷＋NC 许可，后者论文证据质量≈small100）；宽松许可＋CT2 原生支持的现成单模型只有 **MADLAD-400 3B-MT**，延迟贴预算需实测；分方向小模型（Mozilla zh→en 59M）质量证据最好但转换链未验证。
- 路线 B：**EuroLLM-1.7B（Apache-2.0）是 ≤2B 唯一有官方 zh↔en 基准的模型**，质量上限可能最高，但 decoder-only 推断慢 4–15 倍，500ms 短表达预算不现实，与用户已裁决的「选词后立即上屏、不加确认」产品交互冲突。
- 路线 C：五类失败**每条都有对症处置手段且大都有生产级先例**，对固定风险集可逐条处置并用测试验证达标；但开放输入下只能"显著降低、无法消除"（NER 漏检、正则漏配是结构性残余）。

## 二、路线 A：换 encoder-decoder NMT 模型

逐候选核实（许可与指标均查一手来源）：

| 候选 | 许可 | zh↔en 质量 | CPU 延迟 vs 预算 | CT2 | 判定 |
| --- | --- | --- | --- | --- | --- |
| NLLB-200 distilled 600M | **CC-BY-NC 4.0**（权重；LICENSE.model.md 全文核读，无附加条款） | 官方 FLORES chrF++：en→zh_Hans **仅 19.6**、zh_Hans→en 52.9；TICO-19 en→zh spBLEU 24.9 **低于 OPUS-MT 37.5**；词表缺常用汉字（鸡、鹰、《》），译向中文出 `<unk>`（fairseq Issue #4560，2022 年开至今 open；OpenNMT 维护者确认"中文输出相当差"） | 推测 250–400ms 可过（按 CT2 官方 benchmark 外推，需实测） | 官方支持 | **质量＋许可双不达标，排除** |
| SeamlessM4T v2 2.3B | CC-BY-NC 4.0 | 未核 | 必超（2.3B 多模态） | **不支持**（无官方转换器） | 三重不合格，排除 |
| M2M100-1.2B | MIT | SMaLL-100 论文（EMNLP 2022）明文：small100 "achieves comparable results to M2M-100 (1.2B)" | 比 small100 慢约 4 倍 | 官方支持 | **升级收益≈0，不升级** |
| MADLAD-400 3B-MT | **Apache 2.0**（模型卡核读；数据 CC BY 4.0） | 论文称以小胜大（对标 NLLB/MT5）；zh 人名/时间/繁简无专项证据 | 推测 300ms–1.5s，**贴预算**，必须实测 | **最新版原生支持** | **唯一宽松许可＋CT2 原生的现成单模型；候选第一，需风险集＋速度实测** |
| Mozilla zh→en Marian 59M | MPL 2.0 | zh→en 官方 chrF++ **55.4**／COMET 0.861，状态 "Release Desktop"（强于 small100 同向证据）；**en→zh 弱**（base chrF++ 26.6）；训练管线以 NLLB-3.3B 为教师做 QE 蒸馏，有 `short-sentences/` 短句专项配置 | 推测 <100ms（浏览器实时级） | bergamot intgemm→CT2 转换**未验证**（CT2 有 Marian 转换器） | **分方向候选：zh→en 方向最有希望；en→zh 缺口待补；最大未验证点是转换链** |
| T5Gemma-2 270m | Gemma 条款（可商用，非宽松） | 非翻译预训练，需自建微调 | 推测可过 | 原生支持 | 长线备选（训练成本未知） |
| ALMA／Tower+ | Llama 条款／CC-BY-NC | — | 无 ≤3B 版本 | — | 排除 |

澄清两点：「MADLAB-400」不存在（Mozilla 下一代即上述 Marian 学生模型）；MADLAD-400 是 Google 项目，勿混淆。

## 三、路线 B：小型 LLM

候选与许可（模型卡核读）：

| 候选 | 许可 | 翻译质量证据 | 判定 |
| --- | --- | --- | --- |
| **EuroLLM-1.7B-Instruct** | **Apache-2.0** | **≤2B 唯一官方 zh↔en 基准**：FLORES-200 en→zh 87.89／zh→en 86.60，WMT-23/24 同级；官方自述与 Gemma-7B 相当。风险：未对齐人类偏好（幻觉），短文本无专项评测 | **首选试点** |
| Qwen3-1.7B | Apache-2.0 | 模型卡声称翻译强但无分尺寸官方 benchmark；社区评测（ja→zh FLORES）BLEU 27.1 **优于 NLLB-1.3B（20.9）**；**thinking 模式灾难性拉高延迟，必须强制 no_think** | 次选 |
| Qwen3-0.6B | Apache-2.0 | 同源社区评测 BLEU 仅 12.6，未微调明显不合格 | 仅作延迟对照 |
| Gemma-3-1B-it | Gemma 自定义条款（有使用限制，需法务评估） | 官方 WMT24++ ChrF 36.7（4B 为 48.4），1B 档翻译弱 | 排除 |
| Llama-3.2-1B/3B | Llama 社区许可 | 官方支持语言 8 种**不含中文**，明文 Out of Scope | 排除 |
| Tower+ 2B／ALMA | CC-BY-NC | 质量文档强 | NC＋延迟，排除 |
| TranslateGemma（Google 2026-01） | Gemma 系 | Gemini 蒸馏＋MetricX-QE RL，55 语言；**最小 4B，超预算** | 长线观察：若出 ≤2B 版优先复查 |

延迟现实性（跨硬件外推，标注假设；9880H 实机 llama-bench 未测）：

- 0.6B Q4_K_M：tg≈35–60 tok/s → 端到端 0.4–0.9s，**500ms p95 基本达不到**
- 1.7B Q4/Q8：tg≈18–30 tok/s → 端到端 0.9–1.8s，短句 2s 勉强达标；对照 small100 实测 125ms，**慢 4–15 倍**
- encoder-decoder（small100 类）短输入结构上每 token 便宜约一个数量级

工程要点：llama.cpp 官方支持 Windows x64 MSVC（两端同引擎可行）；GBNF 约束解码能管输出**格式**（禁英文混入、禁思考前缀、限定汉字区），**管不住语义编造**（人名丢失、错拼改写需运行时校验兜底）；复杂 grammar 有采样性能陷阱；量化建议 Q8_0（Q4 语义略降）。

产品冲突：用户已裁决「学习模式选词后立即上屏、不加二次确认」；LLM 1–2s 延迟意味着输入后必须等候选或改异步确认制——**与既定交互裁决直接冲突**。Gboard/SwiftKey 先例也表明键盘内小 LLM 只做短输出辅助（Gboard Proofread 用 Gemini Nano 仅限旗舰 NPU），无端上 LLM 全功能翻译先例。

## 四、路线 C：现有模型工程加固

逐失败类别的处置手段（证据强度与来源）：

| 失败类别 | 处置手段 | 证据强度 | CPU 开销 | 残余风险 |
| --- | --- | --- | --- | --- |
| 繁体输出 | OpenCC t2s 后处理 | **高**：C++ 跨平台，macOS Homebrew／Windows vcpkg 一手可装；t2s 方向歧义远小于 s2t | 毫秒级以下 | 繁体地区词（滑鼠）不改词；歧义字保守跳过 |
| 人名丢失、品牌改写 | 专名占位符保护（大写启发式＋保护词表，可选 NER） | **高**：Unbabel 产线 EAMT 2022（entity masking 38.6% 用例质量提升）；微软 Extract-and-Attend 实体错误率降 35% | 启发式可忽略；NER 十毫秒级 | 漏检仍丢名；误检破坏句子 |
| 乱码编造 | 语言识别门槛（fastText lid 917KB）＋字符分布启发式，不过关→**不翻译保留原文** | 中：Firefox Translations 用 CLD2、Chromium 用 CLD3 生产实践；乱码专用拦截无公开先例 | 可忽略 | 乱码被误判为某语言漏放行 |
| 时间翻转 | a.m./p.m. 前置规范化为 24h＋输出时段一致性校验 | 中：时间误译为 MT 评审文献公认 critical error（EAMT 2022；ACL 2022 Findings）；**处理手法本身无生产先例（新组合）** | 可忽略 | 正则漏配/误配；中文源「十点半」需前置展开 |
| 错拼编造 | 系统拼写检查前置（NSSpellChecker／Windows Spell API，两端一手可用）＋仅审核过的容错表达有译文资格（计划已有） | 低-中：系统 API 一手；MT 前置纠正无先例 | 低 | 纠错误改人名/品牌（限保护词表外低置信词） |
| 各类兜底 | 输出质量估计（解码 log-prob＋长度比率＋输出语向校验），低置信→回退原文 | 高：Bergamot `QualityEstimator` 生产级、随翻译近零开销，Firefox 在用；可参照其 C++ 实现 | 近零 | 只能报警/回退，不能修正 |

Comet-QE 级神经 QE 模型大，CPU 预算内不现实，不推荐。

**本质限制**：加固层对固定 32 条风险集可以逐条处置（修正或安全拦截）并用测试验证；但开放输入下 NER 漏检、正则漏配、乱码误放行会持续出现，是**结构性残余而非工程缺陷**——护栏不能保证"译文正确"，只能保证"错误译文不进入默认候选"。

## 五、组合判断（2026-11-02 裁决后更新）

用户裁决速度优先（死守 500ms）、本地离线不变后：**主路线为加固层（路线 C）解堵 small100；LLM 路线出局；MADLAD-400 3B 因延迟贴/超预算降级为可选对照；Mozilla zh→en 59M 为唯一保留的新模型验证项**（推测 <100ms，完全符合预算）。加固层仍是任何后续换模型的基础设施。

无论哪条，都应先建**自建短文本评测集**（含人名、时间、品牌、错拼、繁简陷阱样本，冻结后盲评）：≤20 字短文本没有任何公开 benchmark，这是所有路线共同的证据空洞。

## 六、决策记录（2026-11-02 用户裁决）

| # | 决策 | 裁决 |
| --- | --- | --- |
| D1 | 是否解除「不扩模型名单」 | **解堵主路线用加固层，不换现有模型**；宽松许可新候选允许进入验证流程（须修订计划后） |
| D2 | 门槛「处置」口径 | **修正或安全拦截（含回退显示原文不译）均算已处置**；只有错误译文进入默认候选才算失败 |
| D3 | 非商用许可（CC-BY-NC） | **宽松许可（MIT/Apache/BSD/MPL）优先；NC 模型仅做评测对照基线，不进生产** |
| D4 | 500ms 短表达预算 | **死守 500ms，不松动、不分层**；词/短语候选必须 0.5s 内出现。LLM 路线出局（1–2s）；MADLAD-400 3B 降级为可选对照 |
| D5 | llama.cpp 进生产链路 | 随 LLM 路线出局，不引入 |
| D6 | Mozilla 分方向模型 | **值得验证**（推测 <100ms，符合死守 500ms；zh→en 方向 chrF++ 55.4 质量证据最强）：验证 bergamot→CT2 转换链，通过则 zh→en 方向替换，en→zh 继续 small100＋加固；两端仍统一同一组模型 |
| D7 | 评测集 | 先建：所有路线共用，含冻结留存集与盲测流程 |

**落地含义**：主路线为「small100＋加固层」（路线 2），以 D2 口径对固定风险集逐条处置达标后解除学习阻塞；并行验证 Mozilla zh→en 59M（D6）。加固五件套：OpenCC t2s、专名占位符保护、语言识别门槛＋乱码不翻、时间表达前置规范化＋输出校验、log-prob/长度比率/输出语向低置信回退。

## 七、快档补充调研（2026-11-02 第二轮，同日）

用户追问「本地又快的大脑有没有别的选择」后，专项核实 Marian/encoder-decoder 快档家族。

### 重大发现：quickmt（双向、CC-BY-4.0、原生 CT2）

- `quickmt/quickmt-en-zh` 与 `quickmt/quickmt-zh-en` 均存在且 2026-04 仍在更新；200M 参数 transformer-big，**8 层 encoder＋仅 2 层 decoder**（刻意为速度设计），独立 spm32k 词表，**原生 CTranslate2 格式（model.bin＋sentencepiece），零转换成本**；工具链 Apache-2.0，模型 CC-BY-4.0。
- 官方评测（Flores200 devtest，sacrebleu＋COMET22）：en→zh chrF2 **35.22**／COMET **85.39**（opus-mt-en-zh 29.20／82.36；nllb-600M 24.52／78.41；m2m100-418M 25.86／73.76）；zh→en BLEU **30.0**／chrF2 **58.42**／COMET **86.72**（opus-mt-zh-en 22.99／53.98；nllb-600M 26.02／55.27）。
- 风险：**无官方 CPU p95**（只有 GPU 数据）；8 层 big encoder 偏重，必须在 i9-9880H 实测 int8 延迟。训练数据为 OPUS 系混合（zh-en 版另加 madlad400/newscrawl2024 回译增广）——计划「不恢复 OPUS」指的是旧 OPUS-MT 模型，quickmt 是新训练的新模型族，在 D1 解冻许可后可验证。

### 其他快档结论

- **HPLT（爱丁堡）：排除**。v1.0 只有繁体（en↔zh_hant，chrF++ 18.5 弱）；v2.0 数据准备脚本无简体中文。
- **Tatoeba-Challenge zho↔eng：弱对照**。短句域契合，但 eng→zho chrF≈0.29 与 Mozilla base 同档无优势；zip 内 LICENSE 需逐个核验，HF 系 tc-big 为 CC-BY-4.0。
- **OPUS-MT 现状：无翻案证据**。主系停留在 2022–2023，无 tc-big en↔zh，2024–2026 仅发圣经域；quickmt 对照表中老 OPUS 全面落后。原「不恢复 OPUS/M2M100」裁决维持。
- **Mozilla en→zh 方向：排除（修正此前预期）**。enzh base 用 SSRU 解码器 **CT2 不支持**（只能跑 bergamot runtime，与 CT2 统一路线冲突）；mozilla/translations#1033 官方自曝训练数据缺陷（误用反向回译语料、繁简机械转换），2025-04 才修复，现网 base 模型是修复前产物；bergamot ssplit 分句器不支持 CJK（bugzilla 1916064）。**Mozilla zh→en 59M 不受影响，仍有效**。
- **opus-mt_tiny_zho-eng（2026-04 新发布）：备选**。Apache-2.0，约 20M（d_model 256，enc 6 层／dec 2 层），Flores+ chrF 50.9，仅 zh→en，短句域契合，应是最快档。
- TranslateGemma 仍无 ≤2B；ModelScope 未核实（搜索配额受限，如实标注）。

### 修订后的实测优先级（取代原 D6 单项）

1. **quickmt-en-zh ＋ quickmt-zh-en（首选）**：双向覆盖、质量系统性领先、许可干净、原生 CT2；胜负手在 i9-9880H 实测 int8 是否进 500ms 预算。
2. **opus-mt_tiny_zho-eng（超快档备选）**：若 quickmt 延迟不达标，用换速度。
3. **Mozilla zh→en 59M（保留）**：quickmt-zh-en 同档更强（chrF 58.4 vs 55.4），退居第三。
4. Tatoeba zip 模型：许可核验后作对照。

注：以上均为「验证候选」而非「替换决定」；任何替换仍需同一张自建评测集＋固定风险集＋用户盲测，并按裁决「安全回退也算处置」验证加固层兼容性。

### 实测结果（2026-11-02 当日补入，[探针报告](../probes/results/quickmt-speed/report.md)）

**速度解堵确认**：i9-9880H、CT2 4.6.0 int8、greedy、2 线程、12 轮热态——短表达 p95：en→zh 66.8ms／zh→en 41.6ms；短句 p95：79.0ms／82.2ms。约为预算的 1/6–1/8，比 small100 同参数实测快 2–2.8 倍；载入 0.9s；当时机械口径风险集 32/32、留存集 180/180 可用（未含加固层），句级 p95 ≈ 100–112ms。

**质量观察（烟测级）**：small100 四个固定失败点修了三个（Bob、10:30 上午/下午、十点半→10:30 a.m.）；但短语级（1–3 词）新暴露重复、繁体漂移、截断、语义跑偏——恰在输入法主场景，与加固层对症范围重合；beam=2/5 不消除重复。替换决定仍需风险集语义审阅＋自建短文本评测集＋用户盲测。

### 2026-11-03 统一复测（决定：暂不切换）

同一驱动、同一轮次、同一加固层下复测 small100 与 quickmt 双向（i9-9880H、CT2 INT8、greedy、batch=1、2 线程、5 轮交错，2,400 条请求）：quickmt 短表达 p95 43.4–83.6ms、短句 p95 68.9–89.7ms，仍比 small100 快约 1.6–3 倍；加固 p95 约 0.1ms、辅助进程 IPC p95 约 0.4ms，性能优势不是噪声。

但 2026-11-02 烟测的“风险集 32/32、留存集 180/180 机械可用”没有经过生产加固层，也没有审阅短语级输出。统一复测把重复/截断/脚本/时间/长度规则应用到每条输出后：**small100 可用率 95.15%（en→zh）／94.34%（zh→en），5 条固定风险未处置；quickmt 77.67%／92.45%，12 条固定风险未处置**。quickmt 的 en→zh 主要失败是 1–3 词短语的复读、截断、尾部残片和语义漂移；它修好的 Bob、上午/下午、十点半等长句风险不足以抵消主场景失败。加固层还存在时间区间、英文动词 `am`、合法三元组、URL 脚本/长度四类误报，修掉后 small100 约 97%，quickmt en→zh 仍约 83%。

**决定**：不因速度切换 quickmt；保持 small100 主路线，先修加固误报并补人名/品牌与短语审阅，学习模式继续阻塞。完整证据见[统一实测决定](../probes/results/translation-backends/decision.md)、[语义审阅](../probes/results/translation-backends/semantic-review.md)与[质量门槛](../probes/results/translation-backends/quality-gate.json)。

## 引用（主要一手来源）

- 失败基线：[small100 语义审阅](../probes/results/small100-gate/semantic-review.md)
- NLLB 许可/指标：HF `facebook/nllb-200-distilled-600M`；fairseq `LICENSE.model.md`；官方指标 CSV（chrF++）；fairseq Issue #4560；OpenNMT 论坛（vince62s 评审、TICO-19 对比）
- M2M100≈small100：SMaLL-100 论文 https://aclanthology.org/2022.emnlp-main.571
- MADLAD-400：HF `google/madlad400-3b-mt`（Apache-2.0）；CTranslate2 README（原生支持）
- Mozilla 下一代模型：官方 `models.json`（storage.googleapis.com/moz-fx-translations-data）；`mozilla/translations` README（MPL 2.0、短句配置）
- EuroLLM：HF `utter-project/EuroLLM-1.7B`（模型卡基准表）
- Qwen3 社区评测：HF `telecomadm1145/NanoSakura-0.3B` 页（含 nllb-1.3B 对照）
- llama.cpp：官方 `docs/build.md`（MSVC）、`grammars/README.md`、issue #4218（grammar 性能）
- 时间误译：EAMT 2022 https://aclanthology.org/2022.eamt-1.20/；ACL 2022 Findings https://aclanthology.org/2022.findings-acl.224.pdf
- 专名保护：EAMT 2022 Unbabel https://aclanthology.org/2022.eamt-1.17/；微软 Extract-and-Attend（ACL 2023）
- OpenCC：https://github.com/BYVoid/OpenCC 及 DESIGN_PRINCIPLES.md；Homebrew/vcpkg port
- 语言识别门槛：Firefox Translations 文档（CLD2）、Chromium 设计文档（CLD3）、fastText lid 文档
- QE 兜底：Bergamot `QualityEstimator` API 文档与源码；Firefox Translations bergamot 文档
- TranslateGemma：Google 博客（2026-01）与技术报告 arXiv:2601.09012
- quickmt：HF `quickmt/quickmt-en-zh`／`quickmt/quickmt-zh-en` 模型卡（评测表、license tags）；GitHub `quickmt/quickmt`（Apache-2.0）
- HPLT：v1.0 模型卡；HPLT-MT-Models v2.0 `get_data.py`（无 zh）
- Tatoeba-Challenge：models/zho-eng、eng-zho README；HF license tags
- Mozilla en→zh 排除证据：mozilla/translations#1033（训练数据缺陷自曝）、bugzilla 1916064（ssplit 不支持 CJK）、firefox-translations-models `models/base/enzh/metadata.json`（SSRU）
- opus-mt_tiny_zho-eng：HF 模型卡（2026-04-10，Apache-2.0，Flores+ 指标）
