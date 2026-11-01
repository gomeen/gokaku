# Intel Mac 离线翻译组件筛选

## 结论与边界

对照 [产品方向](product.md)，此前建议先验证“两份单向 OPUS-MT 模型 + CTranslate2 CPU + SentencePiece”。用户随后明确要求开放选型，本轮已扩展到独立模型与 CPU/GPU 后端对照，候选见[补充核查](translation-candidates.md)，实验方法见[翻译实验方案](translation-benchmark-plan.md)。Apple Translation 保留为系统备选，不据 API 的 macOS 可用性推定 Intel 已能翻译。
本文保留首次来源筛选时的证据与边界，不是最新真机运行报告。该次调查没有下载权重、安装依赖、翻译测试或性能测量。后续实验结果应以独立实测报告为准，不把此前的候选推荐当作最终技术决策。
设备信息由本次任务提供，未在本文重新测量。目标为 x86_64 MacBookPro16,1、macOS 26.7.2、64 GiB RAM、Swift 6.3.3，仅有 CommandLineTools。
默认 Python 尚无 torch、transformers、ctranslate2、sentencepiece。不能假定依赖已可导入，也不能从 M 系列、MLX、ANE 或 Metal 的结果推断这台 Intel Mac 的速度。

## 两条路线的取舍

| 路线 | Intel 证据与代价 | 筛选结论 |
| --- | --- | --- |
| 两份 Marian/OPUS-MT + CTranslate2 CPU | 官方安装文档明确支持 macOS x86-64，并有对应 wheel。需要预先准备、转换模型及匹配分词器。[R1][R2][R3] | 优先做可控、可固定文件版本的双向基线，尚未验证本机运行。 |
| Apple Translation | 官方提供 macOS API 与本地语言下载流程，但所读文档未给出明确的 Intel 硬件支持承诺。[A1][A2] | 作为备选，先检查本机语言对状态及实际翻译，不能当作已解决方案。 |

本页没有评测通用生成小模型，也不据此排除后续候选。体积小、能生成中英文或 runtime 能加载，均不能证明它具备合格的中英双向翻译能力。词典、短语库可补足单词义项，但不替代自由句子翻译。

## 模型逐项核实

### 英→中，Helsinki-NLP/opus-mt-en-zh

- 发布者原始 model card 标注 `license: apache-2.0`，source 为 English，target 为 Chinese。它不是中→英模型。[M1]
- card 列出多个中文目标变体，并要求句首 `>>id<<` 语言标记。简体普通话 `cmn_Hans` 在目标列表中，但实际可用标记必须结合下载版本词表验证，不直接凭语言名拼接后宣称成功。[M1]
- 官方文件 API 给出 `pytorch_model.bin` 为 **312,087,009 bytes**，`source.spm` 为 806,435 bytes，`target.spm` 为 804,600 bytes，`vocab.json` 为 1,617,791 bytes。[M2]
- 上述约 312 MB 是一份 PyTorch 权重的十进制体积，不是完整运行包、内存占用或转换后 INT8 大小。仓库还含其他框架权重，不能全部下载后把仓库总量当必需体积。[M2]
- config 指定 `MarianMTModel`、`max_position_embeddings: 512`。这是 token 位置限制，不是 512 个汉字，也不是可静默截断的许可。[M3]
- 下载边界为该方向的权重、配置、词表、source/target SentencePiece 文件及许可记录。保留 Apache-2.0 许可、版权与适用 NOTICE，转换不消除原模型义务。card 链接的原始 ZIP 是另一种输入格式，不与 HF 权重混用。[M1][M2]

### 中→英，Helsinki-NLP/opus-mt-zh-en

- 发布者原始 model card 在元数据和 Model Details 均标注 **CC-BY-4.0**，明确 source 为 Chinese、target 为 English。不能套用上一个模型的 Apache-2.0。[M4]
- 官方文件 API 给出 `pytorch_model.bin` 为 **312,087,009 bytes**，`source.spm` 为 804,677 bytes，`target.spm` 为 806,530 bytes，`vocab.json` 为 1,617,902 bytes。[M5]
- config 同样指定 `MarianMTModel` 和 512 个位置。卡片未提供本项目短句、孤立词义或拼写偏差的合格保证。[M4][M6]
- 下载边界独立于英→中。只取这一方向相应文件，不复用另一方向分词器。分发原始或转换权重需保留作者与来源署名、许可链接，并标示转换等修改，不能改称统一 MIT 语言包。[M4][M5]

两份 PyTorch 权重合计 **624,174,018 bytes**，由两个文件 API 数值相加，不含分词文件、依赖、缓存或转换产物。INT8 产物及真实峰值内存均待实际生成后记录。[M2][M5]

## 本地 runtime 与下载准备

- CTranslate2 官方列出 macOS x86-64、Python ≥3.9。PyPI 4.8.4 发布文件可核对 `ctranslate2-4.8.4-cp311-cp311-macosx_11_0_x86_64.whl`。这是可安装性证据，不是本机安装成功或性能证据。[R1][R2]
- CTranslate2 为 MIT，SentencePiece 为 Apache-2.0。两者的软件许可不覆盖模型许可。SentencePiece 的 PyPI 文件也有 CPython 3.11 macOS x86-64 wheel。[R4][R5][R6]
- 官方 Transformers 转换器支持 MarianMT，但转换阶段示例要求 `transformers[torch]`。不能在 Intel 上直接假定最新版 torch 有匹配 wheel。可在另一个兼容环境离线准备转换产物，再在本机仅运行 CTranslate2 和分词器。[R3]
- 另一准备入口是原始 Marian/OPUS-MT 文件配 `ct2-opus-mt-converter`。官方例子依赖 SentencePiece，不要求用 PyTorch 做推理；但例子是英德，不是这两个中文模型已转换成功的证据。[R7]
- 建议先以 float32 CPU 建正确性基线，再独立比较 INT8。转换路径必须一致，不能把 HF 与原始 Marian 两种路径的词表映射、EOS 或特殊 token 处理混搭。[R3][R7]
- C++ 集成可作为后续选择。官方源码构建要求 C++17、CMake ≥3.15，提供 Apple Accelerate 选项。仅观察到 Swift 与 CommandLineTools，不足以证明 CMake、后端和链接条件已满足。[R1]
- 后续准备使用隔离目录和独立依赖环境，不覆盖用户现有输入法或系统 Python。固定仓库 revision、文件清单、校验值、转换工具版本及许可副本。只取所选框架权重，避免全仓库下载。
- 运行阶段只打开本地模型目录和分词文件。不得调用会自动补下载的远程模型 ID，不得在缺模型或翻译失败时静默联网。断网冷启动必须作为独立验收，而非仅关闭界面开关。

## Apple 系统 Translation 的备选边界

- 官方 WWDC 说明 `TranslationSession` 使用设备上的模型，语言模型在应用之间共享。缺语言时会请求下载许可，可用 `prepareTranslation()` 提前准备。[A1]
- 自定义翻译 API 的官方示例基线是 macOS 15，示例构建要求 Xcode 16 或更新版。浮层 API 不等于可直接用于选词即上屏的后端。[A2]
- macOS 26 的 `TranslationSession(installedSource:target:)` 可直接使用已安装语言，无需 `.translationTask()`。任一语言未安装时翻译抛错，不替代需要用户许可的语言安装流程。[A3]
- 主代理随后已在本机 Intel/macOS 26.7.2 使用 lowLatency 策略查询两个方向，均返回 supported，而非 installed；探针未下载模型或执行翻译，结果见 [apple-translation.json](../probes/results/apple-translation.json)。这不证明 Intel 实际翻译可用，也不能据此判定完全不支持。仍需安装状态和断网实际调用的证据。[A1][A2]
- 所读 Apple 来源未提供语言包可独立再分发的开源许可或固定字节大小。按系统管理资源处理，不复制语言模型入 Gogaku，不承诺安装体积或 Intel 兼容性。仅有 CommandLineTools 也不等于官方 GUI 示例已具备构建条件。[A2][A3]

## 检查组件与输入方案不混入翻译结论

- `NSSpellChecker` 由主代理真机验证，本调查不重复执行，不把系统 API 存在写成离线检测成功。
- `metting` 能否被译成“会议”必须单独测。翻译成功不证明拼写正确，波浪线也不能证明译文可靠。不承诺容错，不自动改写英语源文。[产品方向](product.md)
- 首轮保留独立拼写检查，语法检查无可靠本地证据则不加入。姓名、品牌、网址、邮箱、代码和自定义词的免标记策略另验，不把词典未收录直接等同错误。
- 小鹤双拼属于中文输入解码层，不是翻译 tokenizer。当前任务不核查其实现与数据许可，也不把翻译路线成立写成小鹤已支持。

## 后续最小验证候选与退出条件

1. 首先准备上述两份模型、对应分词资源及一个固定版本 CTranslate2 CPU 环境，作为可复现基线；其他模型与后端另设对照，不限于这组。先在 Intel 进程确认实际架构、可导入依赖、可加载文件，再分别翻译。
2. 双向各测单词、常用短语和完整短句。包含“会议 / meeting”“明天下午三点开会 / The meeting is at 3 p.m. tomorrow”“不要发送邮件 / Do not send the email.”，另加姓名、数字、网址、否定、时态和歧义词。人工记录译文是否保义，不用往返翻译代替质量判断。
3. 将 `meeting` 与 `metting` 对照。原文、拼写标记和翻译采用结果分开记录，不把人工观察变成自动判断译文可靠的算法。无法采用时保留输入并允许明确原文上屏。
4. 检查超 token 上限、缺任一方向模型、文件损坏、首次断网冷启动和切换输入后的过期结果。失败不得自动联网、静默截断或提交猜测译文。
5. 通过正确性与断网检查后，才测本机冷启动、短内容延迟与内存，分别记录 float32 和 INT8。本文不给未测延迟数字，也不从模型体积或 M 系列成绩推断输入法流畅性。
6. Apple 只做第二候选的可用性门槛验证。若 Intel 语言状态或实际调用失败，保留错误证据，退回可控本地路线，不因此宣称离线目标不可行。

## 一手来源

[M1]: https://huggingface.co/Helsinki-NLP/opus-mt-en-zh/raw/main/README.md
[M2]: https://huggingface.co/api/models/Helsinki-NLP/opus-mt-en-zh/tree/main
[M3]: https://huggingface.co/Helsinki-NLP/opus-mt-en-zh/raw/main/config.json
[M4]: https://huggingface.co/Helsinki-NLP/opus-mt-zh-en/raw/main/README.md
[M5]: https://huggingface.co/api/models/Helsinki-NLP/opus-mt-zh-en/tree/main
[M6]: https://huggingface.co/Helsinki-NLP/opus-mt-zh-en/raw/main/config.json
[R1]: https://opennmt.net/CTranslate2/installation.html
[R2]: https://pypi.org/project/ctranslate2/4.8.4/
[R3]: https://opennmt.net/CTranslate2/guides/transformers.html#marianmt
[R4]: https://raw.githubusercontent.com/OpenNMT/CTranslate2/master/LICENSE
[R5]: https://raw.githubusercontent.com/google/sentencepiece/master/LICENSE
[R6]: https://pypi.org/project/sentencepiece/
[R7]: https://opennmt.net/CTranslate2/guides/opus_mt.html
[A1]: https://developer.apple.com/videos/play/wwdc2024/10117/
[A2]: https://developer.apple.com/documentation/translation/translating-text-within-your-app
[A3]: https://developer.apple.com/documentation/translation/translationsession/init(installedsource:target:)
