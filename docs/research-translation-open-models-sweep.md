> **历史研究记录（2026-11-06 起）：** 本地翻译模型已退出产品链路，当前学习翻译只保留用户配置的火山 NMT（默认关闭）。本文的模型、质量门槛与“学习模式关闭”结论仅描述当时实验，不是当前产品状态；不得据此恢复本地模型。

# 开源翻译模型补扫：2025–2026 新发布与未覆盖线索

性质：**纯桌面调研**（2026-11）。未下载、未实测、未改代码，只读与检索；不改变[产品方向](product.md)「学习模式保持关闭、替换须同一评测集＋风险集＋用户盲测」的现行状态。目标机仍为 Intel i9-9880H、CPU-only、AVX2、500ms 短表达／2s 短句预算。

此前已覆盖的候选不在本轮重复研究：NLLB／M2M100／EuroLLM-1.7B／MADLAD-400／Mozilla Marian 59M／HPLT／Tatoeba-Challenge／OPUS-MT 主系／opus-mt_tiny_zho-eng／quickmt／small100（见[模型解堵调研](research-translation-model-unblock.md)）；Index-Translate 家族、HY-MT1.5-1.8B、Qwen2.5-0.5B／1.5B、Llama-3.2、Gemma-3-1B、TranslateGemma（≥4B）（见[截图候选复核](research-translation-screenshot-candidates.md)）；本机 GGUF 实测基线见 [GGUF 实测汇总](../probes/results/gguf-translation/summary.md)。

## 一、结论短名单（值得进 20 句实测）

| # | 候选 | 理由 | 主要未验证点 |
| --- | --- | --- | --- |
| 1 | **NiuTrans/LMT-60-0.6B**（GRPO 版） | Apache-2.0；基座为 Qwen3-0.6B 继续预训练＋翻译专项 SFT/GRPO（论文自述），**与本机已实测的 Qwen3-0.6B 同尺寸同构**——本机该档中位 670ms（4 线程），与 Qwen2.5-0.5B（538ms）同档；即「相近速度下质量可能更高」假设的最直接检验对象，正对当前「快档习惯表达弱」缺口 | 官方未见 GGUF／社区转换未核实；0.6B 卡许可 YAML 未逐个核验；zh↔en 逐向公开分数未在检索摘要中取得（论文含 BLEU/COMET，需读原文表格） |
| 2 | **tencent/Hy-MT2-1.8B**（＋官方 GGUF） | **HY-MT1.5-1.8B 的继任**：官方 GGUF 仓库 LICENSE 全文为 **Apache-2.0**（一手），替换掉 HY-MT1.5 的腾讯 HY 自定义条款（欧盟/英国/韩国排除、月活条款、蒸馏限制），许可解堵；模型卡自报 FLORES-200 全矩阵 XCOMET-XXL 79.77、WMT25 50.30，并称 1.8B 档整体超过 Microsoft/Doubao 商用 API；有官方 GGUF 产物 | 基模（非 GGUF 仓库）许可为聚合页标注，需实测前通读原卡全文；延迟预期与本机已测 HY-MT1.5-1.8B（2 线程中位 1.7s）同档，**不解决速度**，价值在质量＋许可；自报分数未经第三方复核 |
| 3 | **NiuTrans/LMT-60-1.7B**（GRPO 版） | Apache-2.0（同系列）；1.7B 档落在本机已测「质量强但慢」阵营（Index-2B 2.1s／HY 1.7s 附近），作为该阵营里许可最干净的质量对照，回答「同慢档能否再换质量」 | 同 #1 的 GGUF 与逐向分数缺口；预期超 500ms 预算，仅作慢档质量上限对照 |

三条全部满足「许可宽松＋含中英＋翻译专项（或翻译增强）＋有可检验的公开质量证据」；三条都**没有公开 CPU 延迟证据**，同尺寸锚点只用于定位预期，不替代实测。

## 二、正文：逐候选核查表

证据等级说明：**A**＝有公开中英（或含中英的矩阵）翻译分数且指明出处；**B**＝只有通用多语言榜单／未分方向的聚合分；**C**＝未找到公开分数。分数几乎全部为发布方自报（官方技术报告或模型卡），逐条注明。

### 2.1 新发现且可能改变现状的

| 模型／家族 | 发布方·时间 | 参数 | 权重许可 | 公开中英分数 | CPU 产物 | 判断 |
| --- | --- | --- | --- | --- | --- | --- |
| **LMT-60**（0.6B/1.7B/4B/8B ＋ Base 四档） | NiuTrans（东北大学）；ACL 2026 论文，HF 全套 | Qwen3 继续预训练 90B tokens，SFT→GRPO | apache-2.0（8B 卡 YAML 标注；同系列其余档实测前逐卡复核） | **A（自报）**：论文报告 BLEU/COMET，234 方向含中英双向，自述同规模覆盖 SOTA；zh↔en 逐向数值在论文/模型卡表格内，本轮检索摘要未取得逐项数字 | 未找到官方 GGUF；未见可靠社区转换。基座为 Qwen3 同构（llama.cpp 支持 qwen3），转换可行性是推断、未验证 | 短名单 #1/#3。中英中心定位与本项目需求最对口 |
| **Hy-MT2**（1.8B / 7B / 30B-A3B） | 腾讯混元；技术报告 arXiv:2605.22064（2026-05），仓库近期仍在更新 | 1.8B dense（短名单对象）；7B、30B-A3B（研究对照） | **官方 GGUF 仓库 LICENSE 全文 Apache-2.0**（一手）；基模聚合页同标 Apache-2.0，原卡全文待通读 | **A（自报）**：模型卡 FLORES-200 全矩阵 XCOMET-XXL 79.77（1.8B）、WMT25 50.30；称 7B/30B-A3B 超 DeepSeek-V4-Pro/Kimi K2.6（fast-thinking）；1.8B 超微软/豆包商用 API | **官方 GGUF**（Hy-MT2-1.8B-GGUF）；另有 AngelSlim 1.25-bit 极量量化（440MB，同 HY-MT1.5 的 ARM 内核前提，Intel AVX2 未证实） | 短名单 #2。是 HY-MT1.5-1.8B 的同尺寸许可升级继任 |
| **Tower+ 2B** | Unbabel，2025-06 | 2.6B（Gemma-2-2B 底座） | **cc-by-nc-sa-4.0**（模型卡 YAML 一手），叠加 Gemma 条款 | **A（自报）**：论文（arXiv:2506.17080）含 FLORES 表；官方自述「<3B 最佳多语言 LLM 之一」；22 语言含 zh（模型卡 YAML 列出 zh），官方另有 IF-MT-en-zh 数据集 | 无官方 GGUF；仅社区量化（DZgas/Tower-Plus-2B-GGUF） | **不进短名单**：NC 按 D3 只作对照；无官方 CPU 产物；与已占位的 Index-2B／HY 慢档重叠 |
| **Seed-X-PPO-7B**（含 Instruct/RL/RM 系列） | 字节 Seed，2025-07（arXiv:2507.13618） | 7B | OpenMDW-1.0（宽松系许可，允许商用） | **A（自报）**：28 语言含中英，论文称部分方向对标 GPT-4o 级 | 无官方 GGUF；社区量化（mradermacher 等） | **不进短名单**：7B 落在已测超预算档（同尺寸预期比 2B 档更慢），「质量强但慢」阵营已有更小占用者 |
| **North-Small-Translate-1.0** | Cohere Labs，2026-09 | MoE，218B 总参／25B 激活 | **CC-BY-NC-4.0**＋Cohere AUP | **A（自报）**：WMT26 聚合 83.6，称胜 DeepL/Google Translate 与开源对照 | 无（218B MoE 无边缘产物） | 排除：规模与许可双重不合格。仅作榜单背景（翻译专项开源质量上限在快速抬升） |

### 2.2 线索核查：存在性确认但不合格的

| 线索 | 核查结果 | 判断 |
| --- | --- | --- |
| TowerInstruct-7B／TowerBase-7B | 存在；≥7B；TowerInstruct v0.2 为 cc-by-nc-sa-4.0；10 语言含 zh | 排除：无 ≤3B、NC |
| ALMA／ALMA-R 系列 | 存在；≥7B（LLaMA-2 底座，Llama 条款）；此前调研已按「无 ≤3B 版本」排除，本轮未见翻案证据 | 维持排除 |
| IBM Granite 4.0（≤3B：h-micro 3B／350m） | 存在；Apache-2.0；混合 Mamba-2/transformer＋部分 MoE；官方基准为通用能力，**未找到公开中英翻译分数** | **C 级，排除**：无质量证据；混合架构的 CT2/llama.cpp CPU 支持未见证据 |
| Phi-4-mini（3.8B） | 存在；MIT；官方基准为推理/数学/代码类，**未找到公开 FLORES zh↔en 分数** | **C 级，排除**：无质量证据；3.8B 超 ≤3B 优先档 |
| SeamlessM4T v2 2.3B | 存在；CC-BY-NC-4.0；无 CT2 转换器（前轮已核） | 维持排除，仅 NC 对照（按 D3） |
| Gemma-3-4B 及以上／TranslateGemma | 前轮已排除（Gemma-3-1B 翻译弱、TranslateGemma 最小 4B）；本轮新增旁证：FLORES+ 榜单 Gemma3-12B 8-shot 聚合 spBLEU 44.34（多语言对聚合，**非中英单向证据**，B 级） | 维持 ≥4B 观察线 |
| Qwen3-1.7B／4B 原版 | 无官方分尺寸 zh↔en FLORES；社区 zh↔en 微调版 Interpreter-Qwen3-1.7B 存在（WMT23 zh→en BLEU 20.31／COMET 0.8053，en→zh BLEU 33.69／COMET 0.8540，社区个人发布）；本机已测 Qwen3-0.6B：同价不优于 Qwen2.5-0.5B | 原版维持「延迟对照」定位；社区微调不进候选（无审核链、分数平凡）；**翻译专项化的 Qwen3 档走 LMT-60 路线** |
| ByteDance **Dolphin** | 存在，但为**文档图像解析模型**（arXiv:2505.14059），非机器翻译 | 线索解除，排除 |
| ByteDance **Ouro**（1.4B/2.6B） | 存在；LoopLM（循环架构）研究模型，模型卡明示 research purposes only；非翻译专项 | 排除：架构无 CPU 推理产物证据 |
| Hy-SimulMT-30B-A3B（2026-10） | 存在；Apache-2.0；语音同传、30B-A3B | 排除：语音域＋超预算 |
| TranslatePsy（QVAC/Tether，2026-09） | 存在；AfriSLM-2B（英语＋19 非洲语言，Qwen3.5-2B SFT）、EuroNano（9 欧洲语言）；端侧定位与本项目相近 | 排除：**无中文** |
| Hunyuan-MT-7B（WMT25） | WMT25 通用任务人工评测 31 项中 30 项第一（含中英方向）；为 HY-MT1.5／Hy-MT2 的 7B 同源 | 不单独测：7B 超预算；其 1.8B 档即短名单 #2 |

### 2.3 WMT 榜单定位（背景）

- **WMT25**（人工 ESA 评测）：开源翻译专项 Hunyuan-MT-7B 拿下 31 项中 30 项第一，其余头名多为闭源/商用系统——开源翻译专项在 7B 档已能争顶，但**缩小到 ≤2B 档公开证据仍然稀缺**，这正是当前候选困境。
- **WMT24**（"The LLM Era is Here but MT is Not Solved Yet"）：自动指标前列出现了开源 LLM 系统（如 IKUN-C，Llama-3-8B 底座，自动指标 6 项第一），但均为 7–8B 以上、decoder-only，延迟档位与本项目预算不符，只作背景。

### 2.4 延迟证据边界（全部候选）

本轮所有新候选均**未找到公开 CPU 延迟**；发布方性能数据均为 GPU（Index A100 tok/s、Hy-MT2 家族 GPU 吞吐等），**不能换算到 Intel CPU**。可用的定位锚点只有本机已实测的同尺寸档：0.5–0.6B 档中位 538–670ms（4 线程）、2B 档中位 1.7–2.1s（2 线程）（[GGUF 实测汇总](../probes/results/gguf-translation/summary.md)）。短名单的预期是：**#1 同速度档换质量、#2/#3 同质量档换许可（不解决速度）**——没有一条有望同时改善质量与速度；若 #1 实测质量达标且延迟贴近 538ms 档，才是唯一可能的例外。

## 三、证据边界与检索口径

- 本机直抓公开页面被 fake-IP／SSRF 检查阻断（与[前轮](research-translation-screenshot-candidates.md)相同），未启动浏览器绕过；许可与分数依据**检索返回的官方页面正文摘录**交叉核对，HF 模型卡原文全文（许可标签、语言 YAML、逐向分数表）未能直接抓取，凡此均已在表中标注「待通读/未取得」。
- 两条检索因上游限流失败（Granite/Phi-4-mini 首查），已用单条查询补齐并如实记录结果。
- 分数口径：Hy-MT2 与 LMT-60 的公开分数均为**发布方自报**，无独立第三方复核；XCOMET-XXL/WMT25 聚合分与 chrF++/COMET 单向分不可直接互比，也不可与本机自建 200 条验收集互比。
- 「相近速度」的比较基础是同尺寸同构（LMT-60-0.6B vs 本机 Qwen3-0.6B），不是任何速度换算。
- 截至 2026-11 检索快照；HF 页面数据（下载量、更新时间）随时可能变化，实测前需重新核对 revision 与文件 SHA256。

## 四、官方来源

**短名单**

- LMT-60：[HF 模型卡 0.6B](https://huggingface.co/NiuTrans/LMT-60-0.6B)／[1.7B](https://huggingface.co/NiuTrans/LMT-60-1.7B)／[8B（含 YAML 许可标注）](https://huggingface.co/NiuTrans/LMT-60-8B/blob/1fa0390b786be9004a44692eb5d31e94820e01f3/README.md)；[论文（ACL 2026）](https://aclanthology.org/2026.acl-long.1153.pdf)；[GitHub](https://github.com/NiuTrans/LMT)
- Hy-MT2：[HF 模型卡 1.8B](https://huggingface.co/tencent/Hy-MT2-1.8B)；[官方 GGUF 许可全文（Apache-2.0）](https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/blob/main/LICENSE.txt)；[家族集合](https://huggingface.co/collections/tencent/hy-mt2)；[GitHub](https://github.com/Tencent-Hunyuan/Hy-MT2)；[技术报告 arXiv:2605.22064](https://arxiv.org/html/2605.22064)
- LMT-60 与 Hy-MT2 的第三方描述页（benchgen.com、savrn.com、digitalapplied.com）仅用于交叉确认许可标注与聚合分，非一手来源。

**背景与排除项**

- WMT25 findings：[aclanthology 2025.wmt-1.22](https://aclanthology.org/2025.wmt-1.22.pdf)；[Hunyuan-MT GitHub](https://github.com/Tencent-Hunyuan/Hunyuan-MT/)；[SCMP 报道（30/31 第一）](https://www.scmp.com/tech/article/3324018/tencents-open-source-translation-model-beats-google-openai-top-global-ai-competition)
- WMT24 findings：[aclanthology 2024.wmt-1.1](https://aclanthology.org/2024.wmt-1.1.pdf)；自动排名 [arXiv:2407.19884](https://arxiv.org/html/2407.19884)
- Tower+：[2B 模型卡（含 YAML：cc-by-nc-sa-4.0、22 语言含 zh）](https://huggingface.co/Unbabel/Tower-Plus-2B)；[论文 arXiv:2506.17080](https://arxiv.org/html/2506.17080)；[社区 GGUF（非官方）](https://huggingface.co/DZgas/Tower-Plus-2B-GGUF)
- Seed-X：[PPO-7B 模型卡（OpenMDW-1.0）](https://huggingface.co/ByteDance-Seed/Seed-X-PPO-7B)；[论文 arXiv:2507.13618](https://arxiv.org/html/2507.13618)；[社区 GGUF（非官方）](https://huggingface.co/mradermacher/Seed-X-PPO-7B-GGUF)
- North-Small-Translate-1.0：[模型卡（CC-BY-NC-4.0，218B/25B MoE）](https://huggingface.co/CohereLabs/North-Small-Translate-1.0)；[官方博客](https://cohere.com/blog/north-small-translate)；[文档页](https://docs.cohere.com/docs/north-small-translate-1.0)
- Tower 旧系：[TowerInstruct-7B-v0.2](https://huggingface.co/Unbabel/TowerInstruct-7B-v0.2)；[ALMA-7B-R](https://huggingface.co/haoranxu/ALMA-7B-R)
- Granite 4.0：[官方文档](https://www.ibm.com/granite/docs/models/granite4-0)；[GitHub](https://github.com/ibm-granite/granite-4.0-language-models/)；[350m 模型卡](https://huggingface.co/ibm-granite/granite-4.0-350m-base)
- Phi-4-mini：[模型卡](https://huggingface.co/microsoft/Phi-4-mini-instruct)；[技术报告 arXiv:2503.01743](https://arxiv.org/html/2503.01743v2)
- SeamlessM4T v2：[模型卡](https://huggingface.co/facebook/seamless-m4t-v2-large/raw/main/README.md)；[论文 arXiv:2308.11596](https://arxiv.org/html/2308.11596v3)
- Qwen3 社区微调：[Interpreter-Qwen3-1.7B（WMT23 分数）](https://huggingface.co/Ismantic/Interpreter-Qwen3-1.7B)
- Dolphin（非翻译）：[模型卡](https://huggingface.co/ByteDance/Dolphin)；[论文 arXiv:2505.14059](https://arxiv.org/abs/2505.14059)
- Ouro（非翻译）：[Ouro-2.6B](https://huggingface.co/ByteDance/Ouro-2.6B)；[项目页](https://ouro-llm.github.io/)
- Hy-SimulMT-30B-A3B：[GitHub（Hy-MT2 仓库内）](https://github.com/Tencent-Hunyuan/Hy-MT2)与发布报道
- TranslatePsy（无中文）：[AfriSLM-2B 模型卡](https://huggingface.co/qvac/TranslatePsy-AfriSLM-2B)；[EuroNano 博客](https://huggingface.co/blog/qvac/translatepsy-nano)
- FLORES+ 聚合榜单（Gemma3-12B 等通用模型条目）：[sota2.com](https://www.sota2.com/research/sota/multilingual-machine-translation-on-flores-plus-devtest)
