# 截图候选与 Index-Translate：离线中英翻译复核

本轮仅研究；未下载模型、未运行新增模型、未改变生产选型。用户已允许重新考虑这些候选，旧文档的“不扩模型名单”不阻止此次研究。目标机仍是 **Intel i9-9880H（8 核／16 线程）、64 GiB、macOS**；讨论的是完整译文就绪的 500ms 级体验，不是首 token 或 GPU 吞吐。

**建议：保留 small100／quickmt 为同 20 句的实测基线；新增优先测 Index-Translate-2B Q4_K_M，再测 Qwen2.5-0.5B-Instruct Q4_K_M。HY-MT1.5-1.8B 可作为有条件的专用翻译对照，先用常规 GGUF；1.25bit 不能凭手机宣传直接升为 Intel 首选。NLLB、Llama 3.2 与 Index 大型号留作研究对照。** 所有新增模型在这台机器上的速度与语义质量均未验证，优先级表示实验价值，不表示已能替换当前后端。

## 1. 已有证据不能当成“尚未测过”

| 候选／路线 | 仓库已经确认什么 | 对这次网页比较的影响 |
| --- | --- | --- |
| Helsinki OPUS-MT 双向 | [首轮实测](translation-benchmark.md)：两份单向模型，CT2 INT8、2 线程；混合十条输入的五轮中位数汇总约 125ms，进程峰值 RSS 294MiB。出现增义、复读、空输出等缺陷，未采用 | 不是新发现；125ms 不是 p95，也不表示每句低于 500ms。若加网页列，身份为历史基线 |
| small100／quickmt | [统一复测](../probes/results/translation-backends/decision.md)：短表达热态 p95 分别为 134–180ms／43–84ms；两者质量均未通过 | 速度已有同机证据；本次 20 句应实际生成，不拿旧句子的译文冒充 |
| 第二轮语义审阅 | [最终选择报告](../probes/results/translation-backends-round2/final-selection.md)：small100 放行候选合格 255/360，quickmt 145/316；这是 agent 审阅，非用户盲测。quickmt 句子优于孤立词／短语，且有复读导致的长等待 | 不再把第一轮“加固后可用率”当翻译正确率；20 条完整句子可能掩盖词／短语弱点 |
| 资源／模板＋small100＋quickmt 反向评分 | [组合策略决定](translation-strategy-decision.md)：新验收集英→中 46%、中→英 53%，未过 95% 门槛 | 结构检查通过不等于语义正确；不同数据集分数不能直接相减宣称退步 |
| NLLB、小型 LLM 等 | [此前解堵研究](research-translation-model-unblock.md)已有调研，但未给这些新增确切版本的 i9 实测 | 沿用许可事实；不沿用“参数规模必然超时”“其他硬件速度可换算为本机成绩”等强推断 |

## 2. 型号、架构、语言与生产许可

表中“可商用”仍需履行相应署名、许可和修改说明义务；与 Gogaku 是否已经允许公开分发是两回事。

| 确切候选 | 架构与语言 | 许可及生产边界 | 本轮定位 |
| --- | --- | --- | --- |
| `Helsinki-NLP/opus-mt-en-zh` ＋ `opus-mt-zh-en` | Marian Transformer 编码器—解码器；每方向一份。英→中卡包含多种汉语／书写变体，需按模型协议处理目标标签，不能把 OPUS 品牌当单一双向模型 | **en→zh Apache-2.0；zh→en CC-BY-4.0**，后者可商用但需署名、许可链接及修改说明。不是整个 OPUS 家族统一 MIT [S1] | 已测历史对照；新 tiny／tc 型号需另立身份，不能借旧测试结论 |
| `facebook/nllb-200-distilled-600M`、`nllb-200-distilled-1.3B` | 600M／1.3B 蒸馏编码器—解码器 NMT，200 语言；中英使用 `zho_Hans`／`eng_Latn`，另有繁体 `zho_Hant`。`nllb-200-1.3B` 与 **distilled-1.3B** 不应混名 | **CC-BY-NC-4.0**，非商用；模型卡还明确研究用途、非生产部署。不能把开源推理代码的 MIT 许可套给权重 [S2] | 只做研究质量对照；没有生产许可解堵价值，不优先下载两个尺寸 |
| `tencent/HY-MT1.5-1.8B`；常规 `HY-MT1.5-1.8B-GGUF`；`Hy-MT1.5-1.8B-1.25bit-GGUF` | 翻译专项训练的 **Hunyuan dense 自回归因果语言模型**，不是 Marian 式 NMT；官方称 33 语言＋5 种民族语言／方言变体，含中文、英语、繁体中文。低比特版基于相同模型家族，采用 Sherry 稀疏三值量化 [S3–S5] | **Tencent HY Community License**，不是 Apache/MIT。允许范围内可商用，但有地域、规模、用途与分发限制，详见下文 | 专用翻译值得比较；常规 Q4_K_M 优于直接押注 1.25bit 的部署风险 |
| `Qwen/Qwen2.5-0.5B-Instruct`、`Qwen2.5-1.5B-Instruct` | 通用 decoder-only 因果语言模型；官方分别为 0.49B／1.54B 参数，24／28 层、GQA，支持 29+ 语言含中英。不是翻译专项模型，不能用新版 Qwen3 的成绩替代 [S6] | 两个指定尺寸均 **Apache-2.0**；可商用，保留许可／相关 NOTICE 和修改声明。不要套用 Qwen 其他尺寸或版本的许可 | 0.5B 是小型通用模型对照；1.5B 是可选质量对照，不承诺一定更好 |
| `meta-llama/Llama-3.2-3B-Instruct` | 约 **3.21B**，自回归 Transformer、GQA；官方支持英、德、法、意、葡、印地、西、泰八种语言，**不含中文** [S7] | 自定义 Llama 3.2 社区许可，可商用但有 AUP、许可／NOTICE、“Built with Llama”等义务；发布时上月月活超过 7 亿需另获授权。模型卡把未支持语言列为 out of scope，同时允许合规微调扩展语言 | 当前原版不优先做中英输入法候选；“可能输出中文”不等于官方支持，也不等于中文在技术上完全不能生成 |
| `IndexTeam/Index-Translate-2B`、`Index-Translate-9B`、`Index-Translate-35B-A3B-preview` | 基于 **Qwen3.5** 的翻译模型家族；2B／9B 为 dense，35B-A3B 为约 35B 总参数／3B 激活的 MoE。文本覆盖 **150 语言，含中英**；另提供视觉翻译。Echo、Homura、NativeLong 是不同任务分支，不替代本次文本模型 [S8–S10] | 官方代码仓库与指定模型卡均为 **Apache-2.0**，比腾讯／Llama 自定义许可更适合当前生产候选方向 | **2B 优先做新一轮质量实验**；9B、35B-A3B 仅研究对照。3B 激活不能解释成只需装载 3B 权重 |

腾讯许可的具体限制：[基础权重许可](https://huggingface.co/tencent/HY-MT1.5-1.8B/blob/main/License.txt)与[1.25bit 权重许可](https://huggingface.co/tencent/Hy-MT1.5-1.8B-1.25bit/blame/main/License.txt)均指向腾讯 HY 条款。授权地域**排除欧盟、英国、韩国**；发布时上月所有产品／服务月活超过 1 亿需另获授权；分发需附协议、NOTICE、修改标记并传递用途限制，向终端用户披露实际提供方及非腾讯背书关系。第 5(b) 条限制使用模型或输出改进其他 AI 模型（腾讯 HY 及其衍生模型除外）。不能将它的译文自由拿来蒸馏 small100／quickmt。`Powered by Tencent HY` 在所读条款中是鼓励项，不应误写为强制项。AngelSlim 工具代码的许可也不取代模型权重许可。

## 3. “1.25bit／440MB／CPU 快”分别指什么

**440MB 是官方低比特模型的体积宣传，既不是 RAM 上限，也不是 Intel 500ms 延迟证明。** 官方 GGUF 文件树当前显示约 **462MB（十进制）**，约相当于 440MiB；这与“440MB”的差异可能涉及单位／修订，精确交付应固定文件 SHA256 与字节数。普通 1.25bit safetensors 仓库仍有约 4.08GB 文件，不能假设下载该仓库就得到 440MB 的可运行包。[S4]

- Sherry 以每四权重中三个非零、一个为零的结构，用 5 bit 编码；**1.25 是编码主体的位宽**。STQ1_0 每 256 权重还含一个 FP16 scale，42 字节／256＝**1.3125 bit/weight**；嵌入等其他精度张量又使全文件平均位宽更高。[S5]
- 官方示例依赖 STQ 内核，模型卡指向 llama.cpp **PR #22836**。该 PR 的加速实现／基准针对 **ARM NEON、Apple M4 Pro**；其中 147 tok/s 表格还是另一个 **1.24B Llama 测试模型**，不能当 HY 1.8B 成绩。手机 demo 使用骁龙，也不是 Intel AVX2。
- PR 的一次运行日志同时列出约 436MiB 模型映射、256MiB KV、248MiB计算缓冲，合计约 939MiB 的这三部分；这不是 i9 的实测 RSS，只用于说明**文件体积与运行开销不同**。上下文、批次、runtime 和分词器都会改变内存。
- 不能据早期“仅 ARM 加速”的评论断言今后永无 x86 支持。本轮未确认最新可用 AVX2 分支及主线合并状态；测试 1.25bit 前需核对具体提交、模型布局和本机内核路径。没有这一步，就不应把它放在 Intel 首选位置。

其他产物也应按实物口径比较：

| 官方产物 | 页面公布文件大小 | 不能从体积推导的结论 |
| --- | ---: | --- |
| HY 1.8B 常规 Q4_K_M／Q8_0 | 约 1.13GB／1.91GB [S3] | 更小精度不自动更快，也不保证语义损失可接受 |
| Qwen2.5 0.5B／1.5B 官方 Q4_K_M | 约 491MB／1.12GB [S6] | 混合精度张量和元数据使大小不等于参数量×4bit |
| Index-Translate-2B Q4_K_M／Q8_0／F16 | 约 **1.31GB／2.08GB／3.90GB** [S9] | 官方图片教程的“约 1.5GB”是概数；不能当峰值内存。纯文本测试不需要额外 mmproj |

## 4. Index-Translate 的推理与速度证据

这是新增的实质候选：翻译专项、明确中英支持、Apache-2.0、官方 GGUF 均具备；但不能据这些条件宣布已满足输入法延迟。

| 核验项 | 官方证据与本机含义 |
| --- | --- |
| 版本身份 | 2026-09-30 发布 2B／9B／35B-A3B-preview 文本权重，官方 GGUF 卡记录 2026-10-03 转换发布。确切执行对象建议 `IndexTeam/Index-Translate-2B-GGUF` 的 `Index-Translate-2B.Q4_K_M.gguf`；正式测试再锁 revision／SHA256 [S8–S9] |
| 本地推理 | GPU 侧提供 vLLM／SGLang；GGUF 可用 llama.cpp。本机应固定支持 `qwen35` 的 runtime、CPU-only（`-ngl 0`）、纯文本、不加载 mmproj。不要照抄图片示例 `-ngl 99` 当作 CPU 测试 |
| 输入协议 | 官方翻译 prompt＋chat template，**`enable_thinking=false`、greedy／temperature=0**；不把聊天解释、思考内容或截断文本算成功译文。当前 20 句不需要长文／语音分支 |
| 官方速度 | 推理指南列 **NVIDIA A100-SXM4-80GB**：2B 自回归解码 221.4 tok/s；9B 79.7 tok/s，MTP 97.4–107.7 tok/s；35B-A3B TP=2 为 135.1 tok/s。均非 i9 测量，也不是含分词、prefill、完整生成的请求 p95 [S10] |
| 量化质量 | 官方称 GGUF 发布前在 A100 对照 F16／BF16 做概率差异与 greedy 抽查，Q4_K_M 输出近乎一致。它证明上游做过一致性检查，**不证明这 20 句正确，更不证明输入法词／短语质量** [S9] |
| 本轮缺证 | 未找到同一 i9 的完整中英请求延迟、驻留内存、短语风险集与禁网实测。“CPU 可运行／轻量”属于部署定位，不能代替 500ms 成绩 |

## 5. 下一轮同 20 句测试的优先级

用户要求的 small100／quickmt 20 句真实网页对比已由主线程完成。本报告建议后续新增候选继续复用同一份 [20 句数据](../probes/translation-comparison-cases.json)（每方向 10 句），不为了偏爱某个模型另换例子。网页扩展列应展示实测原始译文、完整耗时、型号／精度／runtime、超时与失败；参考译文只帮助语义判断，不以字符串完全相同计算正确率。

| 顺序 | 测试对象 | 能改变什么决策 |
| --- | --- | --- |
| 已完成基线 | **small100＋quickmt**，沿用已验证 CT2 协议 | 用户直接可读的真实网页对比已完成；保留已有速度／质量事实，不能因这 20 句较好就撤销风险结论 |
| 新增 1 | **Index-Translate-2B Q4_K_M**，CPU-only、禁思考 | 优先检验翻译专项与指令遵循能否明显改善句意／时间／专名，同时直接测能否接近 500ms。速度不合格则保留质量对照，不接生产 |
| 新增 2 | **Qwen2.5-0.5B-Instruct Q4_K_M** | 在较小通用模型上检验速度与质量折中，Apache 许可路径清楚；不预先宣称比 NMT 快或质量足够 |
| 条件新增 | **HY-MT1.5-1.8B 常规 Q4_K_M** | 在可接受腾讯地域／分发条款的前提下比较专用翻译质量。1.25bit 先完成 AVX2 内核与格式核验，之后才与常规版同句比较，不以低比特宣传跳过检查 |
| 可选后续 | **Qwen2.5-1.5B-Instruct Q4_K_M** | 只有需要回答“0.5B 的质量缺口能否通过增大模型解决”时再加；无需同时铺开所有精度 |
| 仅研究对照 | **NLLB 600M／distilled-1.3B、Llama3.2-3B、Index 9B／35B-A3B** | NLLB 有 NC／非生产定位；Llama 原版中文不在官方支持范围；Index 大型号增加资源与延迟验证成本。当前没有理由优先于上述小型号。不是宣称它们在 i9 已被实测判慢 |
| 可复用历史列 | **OPUS-MT 双向** | 若用户希望看截图所有路线，可用已缓存模型在同句集补一列；不必重做整套选型，也不将旧译文拼到新例句上 |

计时必须覆盖分词／prompt 预处理、prefill、完整解码、后处理；另列冷启动、峰值 RSS 与稳定驻留内存。给出逐句耗时及多轮热态 p50／p95，保留超时与复读，不把失败请求从延迟里消失。比如 20 个输出 token 若要在 500ms 内完成，即使忽略其他开销也需要约 40 tok/s；这只是预算算术，**不是任何模型的速度预测**。同一词在不同 tokenizer 下 token 数不同，不能仅按 tok/s 排胜负。

这 20 条主要是完整句子，只能做可视化初筛。仓库原门槛区分短表达 500ms 与短句 2s；如果本轮要求所有 20 句均 500ms，应单独标明为更严格目标，不能混用。进入候选替换前仍需最小词／短语检查、既有关键风险、冻结留存集语义审阅与用户盲评；本轮研究不开放学习模式。

## 官方来源

本轮公开页面直抓受到本机 fake-IP／SSRF 检查阻断，因此依据联网搜索返回的**官方页面正文摘录**交叉核对；未绕过检查、未启动浏览器。可变文件树大小及 PR 状态不作为锁定版本，后续运行时需再次核对。下列链接均指向发布方或上游官方项目，未把第三方量化宣传当事实来源。

- **S1 OPUS**：[en→zh 模型卡](https://huggingface.co/Helsinki-NLP/opus-mt-en-zh/blob/main/README.md)、[zh→en 模型卡](https://huggingface.co/Helsinki-NLP/opus-mt-zh-en)。
- **S2 NLLB**：[600M 模型卡及许可标记](https://huggingface.co/facebook/nllb-200-distilled-600M/blob/main/README.md)、[distilled-1.3B 模型卡](https://huggingface.co/facebook/nllb-200-distilled-1.3B)、[编码器—解码器配置](https://huggingface.co/facebook/nllb-200-distilled-600M/blob/main/config.json)。
- **S3 HY 基础版**：[模型卡与 prompt](https://huggingface.co/tencent/HY-MT1.5-1.8B)、[常规 GGUF 文件树](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/tree/main)、[权重许可](https://huggingface.co/tencent/HY-MT1.5-1.8B/blob/main/License.txt)。
- **S4 HY 1.25bit**：[官方模型卡](https://huggingface.co/tencent/Hy-MT1.5-1.8B-1.25bit-GGUF)、[GGUF 文件树](https://huggingface.co/tencent/Hy-MT1.5-1.8B-1.25bit-GGUF/tree/main)、[safetensors 文件树](https://huggingface.co/tencent/Hy-MT1.5-1.8B-1.25bit/tree/main)、[低比特版许可](https://huggingface.co/tencent/Hy-MT1.5-1.8B-1.25bit/blame/main/License.txt)。
- **S5 STQ 内核**：[llama.cpp PR #22836：编码布局、ARM 基准与讨论](https://github.com/ggml-org/llama.cpp/pull/22836)。
- **S6 Qwen**：[0.5B 模型卡](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct)、[1.5B 模型卡](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct)、[0.5B 许可](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/blob/main/LICENSE)、[1.5B 许可](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct/blob/main/LICENSE)、[0.5B GGUF](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/tree/main)、[1.5B GGUF](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/tree/main)。
- **S7 Llama**：[3B Instruct 官方模型卡](https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct)、[社区许可](https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct/blob/main/LICENSE.txt)。
- **S8 Index 家族**：[官方仓库与发布记录](https://github.com/bilibili/Index-Translate)、[2B 模型卡](https://huggingface.co/IndexTeam/Index-Translate-2B)、[9B 模型卡](https://huggingface.co/IndexTeam/Index-Translate-9B)、[35B-A3B-preview 模型卡](https://huggingface.co/IndexTeam/Index-Translate-35B-A3B-preview)、[仓库许可](https://github.com/bilibili/Index-Translate/blob/main/LICENSE)。
- **S9 Index 本地量化**：[官方 2B GGUF 卡及大小／一致性验证](https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF)、[文件树](https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/tree/main)。
- **S10 Index 推理与性能**：[推理指南，A100 性能与 MTP](https://github.com/bilibili/Index-Translate/blob/main/inference/llm/README.md)、[视觉教程，mmproj 与硬件定位](https://github.com/bilibili/Index-Translate/blob/main/docs/image_translate.md)。
