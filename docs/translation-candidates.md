> **历史研究记录（2026-11-06 起）：** 本地翻译模型已退出产品链路，当前学习翻译只保留用户配置的火山 NMT（默认关闭）。本文的模型、质量门槛与“学习模式关闭”结论仅描述当时实验，不是当前产品状态；不得据此恢复本地模型。

# 离线翻译候选核查

本页为 Gogaku 的性能优选提供两个 OPUS 之外的候选，不锁定青简、Rime 或现有后端。目标设备为 Intel macOS i9-9880H、8 核、64 GiB。本轮只读取官方公开资料，没有下载权重、安装依赖、转换或运行模型，不能视为本机质量或延迟验收。

## 两个候选及取舍

| 核查项 | `facebook/m2m100_418M` | `alirezamsh/small100` |
| --- | --- | --- |
| 模型与年代 | 2020 年 M2M-100，多语言 encoder-decoder MT。[M] | 2022 年 SMaLL-100，从 M2M-100 12B 蒸馏的浅解码器 MT，比前者更新，不是近年最新模型，也不是专门中英优化模型。[S] |
| 中英方向 | 100 语言互译，含 `en` 与 `zh`，同一权重覆盖中→英、英→中。[M] | 支持 `en` 与 `zh` 互译，模型卡给出中→英示例；目标语言控制方向。[S] |
| 权重文件 | `pytorch_model.bin` 为 **1,935,796,948 B**，约 1.936 GB。另有 Rust 权重，不必下载。[MA] | `model.safetensors` 为 **1,330,973,772 B**，或 `pytorch_model.bin` 为 **1,331,029,275 B**，二选一。API 报告 332,735,488 个 F32 参数。[SA] |
| 体积解释 | 文件大小来自 HF API，不是转换后大小、运行内存或速度。[MA] | ONNX 文件为另一导出版本，无需与上述权重一起下载。较小权重不证明低延迟或中英质量更好。[SA] |
| 模型许可 | 模型卡标注 MIT，上游 fairseq 提供 MIT 正文。[M][ML] | 模型卡标注 MIT，上游提供 MIT 正文；**自定义 tokenizer 源码另为 Apache-2.0**。[S][SL][ST] |
| CT2 证据 | 官方转换文档直接用此模型演示，属于明确支持路径。[C] | 配置为 `M2M100ForConditionalGeneration`，12 层 encoder、3 层 decoder，CT2 有 M2M100 loader。属于有源码依据的转换候选，未找到官方 small100 专门示例，仍需实际转换核验。[SC][CL] |
| 主要取舍 | 接入风险低于 small100，适合立即建立第二条 MT 基线；体积大于单向 OPUS，不先判定其速度。[C][MA] | 较浅 decoder 值得比较，但自定义 tokenizer 增加接入和版本核验成本；作者的跨语言平均结果不能代替 Gogaku 中英实测。[S][ST] |

## CPU、运行时与公平比较边界

- CT2 官方安装文档列出 macOS x86-64 wheel，硬件文档要求 x86-64 至少 SSE 4.1，并自动选择 AVX、AVX2 或 AVX512 后端。目标机具备适用的 CPU 架构，但本轮未核验具体 wheel 与 Python 版本组合。[I][H]
- 两候选的模型卡均使用 PyTorch 的 `M2M100ForConditionalGeneration`，没有 GPU 必需条件；具体 Intel macOS PyTorch 版本是否仍有 wheel，需沿用主实验已可用的环境核验，不能拿 CT2 的支持声明代替 PyTorch 验证。[M][S]
- CT2 支持 x86-64 CPU 的 INT8 和 FP32。Intel CPU 上 FP16 会回退 FP32，因此不要把 FP16 文件大小当作 CPU 加速证据。[Q]
- 公平加入不要求与 OPUS 同体积。固定双向样例、线程预算、batch=1、beam 和长度规则，分别记录冷启动、热延迟、峰值内存、磁盘占用与译文；原始精度和 INT8 分开比较。此段是待执行方案，不是测试结果。
- 质量必须覆盖词、短语、句子、否定、数字、人名、错拼和中英混排。成功生成或输出目标语言不等于翻译正确；作者论文指标也不能替代同一输入的对照审阅。[M][S]

## tokenizer 与特殊标记不能照搬

- M2M100 依赖 SentencePiece。设置 `src_lang="en"` 或 `"zh"`，编码保留源语言标记与 EOS。PyTorch 用 `forced_bos_token_id=tokenizer.get_lang_id(tgt)`；CT2 官方示例用 `target_prefix=[["__zh__"]]` 或 `[["__en__"]]`，取结果时去掉目标语言前缀，再解码。[M][C]
- small100 的输入格式是 **`[目标语言标记] + 源文本 tokens + </s>`**，不是源语言前缀。显式使用 `SMALL100Tokenizer` 并设置 `tgt_lang`；PyTorch 示例没有强制目标 BOS。[S][ST]
- small100 的 `tokenizer_config.json` 仍写 `M2M100Tokenizer`，所以直接 `AutoTokenizer` 不会自动采用正确的 small100 输入语义。源码中部分继承注释也不准确，应以 `set_lang_special_tokens` 的实际 prefix、suffix 和模型卡为准。[ST][TC]
- small100 转换可尝试 CT2 的 M2M100 loader，但推理必须使用上述目标前缀输入语义，不照搬 M2M100 的 decoder `target_prefix`。应先核对词表 ID、`decoder_start_token_id=2`、EOS，以及 PyTorch 与 CT2 的同输入输出，再测性能。此项是源码推断，尚未验证。[SC][ST][CL]

## 证据入口

[M]: https://huggingface.co/facebook/m2m100_418M/raw/main/README.md
[MA]: https://huggingface.co/api/models/facebook/m2m100_418M?blobs=true
[ML]: https://raw.githubusercontent.com/pytorch/fairseq/main/LICENSE
[S]: https://huggingface.co/alirezamsh/small100/raw/main/README.md
[SA]: https://huggingface.co/api/models/alirezamsh/small100?blobs=true
[SL]: https://raw.githubusercontent.com/alirezamshi/small100/main/LICENSE
[ST]: https://huggingface.co/alirezamsh/small100/raw/main/tokenization_small100.py
[SC]: https://huggingface.co/alirezamsh/small100/raw/main/config.json
[TC]: https://huggingface.co/alirezamsh/small100/raw/main/tokenizer_config.json
[C]: https://opennmt.net/CTranslate2/guides/transformers.html
[CL]: https://raw.githubusercontent.com/OpenNMT/CTranslate2/master/python/ctranslate2/converters/transformers.py
[I]: https://opennmt.net/CTranslate2/installation.html
[H]: https://opennmt.net/CTranslate2/hardware_support.html
[Q]: https://opennmt.net/CTranslate2/quantization.html

本轮 API 快照为 M2M100 `55c2e61bbf05dfb8d7abccdc3fae6fc8512fd636`，small100 `8ab680e26a596d2e3d2d2d17ae0f68df1037328c`。后续下载应固定 revision，网页 main 与转换器 master 可能继续变化。[MA][SA]

## 推荐当场验证的第二模型

推荐 **`facebook/m2m100_418M`** 接在 OPUS 基线后验证。依据是 CT2 官方已有精确模型示例、双向中英和 MIT 声明，不是已经证明它更快或更准。small100 保留为较新、较浅 decoder 的后续候选，不为省转换工作而排除，也不提前承诺兼容。[M][C][S]

- M2M100 转换与外部分词的必要文件为 `pytorch_model.bin`、`config.json`、`vocab.json`、`sentencepiece.bpe.model`、`tokenizer_config.json`、`special_tokens_map.json`。保留 `generation_config.json` 以记录官方生成默认值；不要下载 `rust_model.ot`。[MA]
- 许可材料保留模型卡 MIT 声明及上游 MIT 正文与版权通知；HF 文件列表本身没有独立 LICENSE 文件，不应假称已取得模型仓库内的许可正文。[M][MA][ML]
- 若之后验证 small100，必要文件为一份权重、`config.json`、`vocab.json`、`sentencepiece.bpe.model`、`tokenizer_config.json`、`special_tokens_map.json`、`tokenization_small100.py`。同时保留模型卡、MIT 正文及 tokenizer 的 Apache-2.0 许可和版权头。[SA][S][SL][ST]
