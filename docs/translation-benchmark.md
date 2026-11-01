# 真实离线翻译首轮实验

## 后续采用决定

后续已明确保留CTranslate2独立进程工程路线，但**拒绝将本页OPUS/M2M100作为默认翻译模型**；完整离线学习产品不通过。详见[技术选型决定](input-selection-decision.md)。本页保留原始翻译事实和当时建议，不代表继续无限扩展模型比较。

## 结论

已把技术选型改为开放比较，青简和 Rime 仅作输入引擎对照。本轮实际运行了独立的 OPUS-MT 与 M2M100 翻译模型，并比较 CPU、量化和 GPU 回退路径。

**目前没有可以直接定为默认上屏后端的完整方案。** 两个模型在简单合成输入上都有会改变意思、重复生成或编造的情况。CTranslate2 INT8 值得保留为后续低延迟实验基线，但速度不能抵消这些问题；也不能把本轮翻译后端成绩当作整个输入法的性能冠军。

## 本轮范围

目标机是 MacBookPro16,1，Intel Core i9-9880H、8 核 16 线程、64 GiB，macOS 26.7.2。硬件与依赖见[实验环境](../probes/results/translation-benchmark/benchmark-environment.json)。本轮使用 Python 3.9.6、CTranslate2 4.6.0、PyTorch 2.2.2、Transformers 4.44.2、SentencePiece 0.2.0。

- 下载并校验两份单向 OPUS-MT 与一份双向 M2M100 418M，全部固定 revision、SHA256 和模型卡许可。OPUS 英→中为 Apache-2.0，中→英为 CC-BY-4.0；M2M100 卡片为 MIT。许可与文件清单见[模型 manifest](../probes/results/translation-benchmark/model-manifests.json)。
- 每个模型生成 FP32 与 INT8 的 CTranslate2 产物。两份 OPUS 的 INT8 转换文件合计 **161,743,601 B**，M2M100 INT8 为 **493,464,484 B**，均不含外部分词资源和依赖。这是磁盘产物大小，不是运行内存。
- 探索性调参比较 22 个可运行配置，覆盖 CT2 两模型、两精度和 1/2/4/8 线程；OPUS Torch CPU 的 1/2/4/8 线程；OPUS MPS FP32/FP16 加显式 CPU 回退。纯 MPS 另做失败验证。
- 质量检查使用[32 条合成输入](../probes/translation-cases.json)，每方向 16 条，另比较两模型 INT8 的 beam=4。它不是通用翻译质量数据集，不报告未经定义的“准确率”。
- 正式延迟子集是每方向五条，共十条，涵盖单词、短语、句子、否定和较长句。它不包含所有质量风险输入。计时包括分词、完整生成、同步和解码；batch=1，不含模型下载、转换、加载、中文解码、候选 UI 或宿主插入。

方法、预先写定的判断规则与复跑命令分别见[实验方案](translation-benchmark-plan.md)和[探针说明](../probes/README.md)。

## 正式热推理延迟

下表来自五轮交错运行，每配置 50 个请求，共 300 次。每轮先算十条输入的中位数，再报告五个轮次中位数的中位数及范围。生成错误均为 0，但只针对这个十条计时子集；不包含质量批次中的重复、空输出和语义错误。

| 配置，greedy / batch=1 | 轮次中位数的中位数 | 轮次中位数范围 | Python 进程峰值 RSS |
| --- | ---: | ---: | ---: |
| OPUS CT2 INT8，2 线程 | **125 ms** | 118–150 ms | 294 MiB |
| OPUS CT2 FP32，4 线程 | 204 ms | 191–247 ms | 735 MiB |
| OPUS Torch CPU FP32，4 线程 | 296 ms | 271–450 ms | 904 MiB |
| M2M100 CT2 INT8，4 线程 | 878 ms | 633–1,093 ms | 635 MiB |
| M2M100 CT2 FP32，2 线程 | 1,830 ms | 1,456–2,168 ms | 2,012 MiB |
| OPUS Torch MPS FP32，加 CPU 回退 | 1,701 ms | 1,148–2,597 ms | 1,028 MiB，另有 GPU 内存 |

原始请求和汇总分别在[measurements.json](../probes/results/translation-benchmark/measurements.json)与[measurement-summary.json](../probes/results/translation-benchmark/measurement-summary.json)。峰值 RSS 包括解释器、库、分词器及驻留模型，不是模型本身的内存，也不包含全部 MPS 显存。两个单向 OPUS 同时加载，一个 M2M100 覆盖双向；模型文件大小不能直接代替这张表。

OPUS INT8 单独看输入时，`meeting` 五次中位数为 56 ms，范围 51–62 ms；“会议”为 53 ms，范围 47–66 ms；`I have a meeting tomorrow.` 为 115 ms，“我明天有个会”为 169 ms。两个较长句分别为 501 ms 和 417 ms。总表混合了不同长度，不能解释成所有输入约 125 ms 或立即上屏。

这只能支持本机所测配置下 CT2 INT8 的低延迟潜力，不能宣布全局最快或已调到最优。正式计时时本机 1 分钟 load average 从约 6.1 到 49.0，存在明显后台干扰；调参阶段更高，选中线程是探索性结果，不是严格的线程优劣排名。没有停止用户的其他程序，也没有清空系统文件缓存。

独立采样没有计入正式成绩。OPUS CT2 的采样能看到 `EncoderDecoderReplica::run_translation → decode → TransformerDecoder::decode` 及 MKL GEMM；Torch 采样也进入 GEMM/MKL。正式分阶段计时中，三个 OPUS CPU 配置约 99.2%–99.6% 的请求耗时在完整生成阶段。主要成本落在神经网络生成路径，不能通过省去分词就让它快一倍；本轮没有进一步区分内存带宽与计算吞吐的硬件上限。采样在[FP32 CT2](../probes/results/translation-benchmark/opus-ct2-float32-t4.sample.txt)、[INT8 CT2](../probes/results/translation-benchmark/opus-ct2-int8-t2.sample.txt)与[Torch CPU](../probes/results/translation-benchmark/opus-torch-cpu-t4.sample.txt)。

模型加载单独计时。正式测试首次配置进程中，OPUS INT8 的模型及分词器加载为 3.37 s，从进程启动到 ready 为 5.80 s；它们是受后台负载影响、文件缓存未清空的一次加载样例。后四轮复用驻留进程，不是五次独立冷启动，不能把这些数称为可靠的冷启动分布。

## 译文质量决定的边界

以下均直接读取本轮真实输出，完整对照见[逐条译文](../probes/results/translation-benchmark/quality-outputs.md)。原始记录是[greedy](../probes/results/translation-benchmark/quality-greedy.json)和[beam=4](../probes/results/translation-benchmark/quality-beam4.json)。

| 输入 | OPUS CT2 INT8，greedy | M2M100 CT2 INT8，greedy | 对产品的影响 |
| --- | --- | --- | --- |
| `meeting` | 会议 | 會議 | 孤立词可以命中，但不是多义词词典，M2M100 的中文也未限定简体。 |
| `tomorrow` | 明天见 | 明天 | OPUS 加入了原文没有的“见”。 |
| `good morning` | 重复多次“早啊” | 早安 | OPUS INT8 虽结束生成，仍不可采用；FP32 则重复到输出上限。 |
| `I have a meeting tomorrow.` | 我明天有个会议 | 明天我会见。 | M2M100 改变会议含义，不因模型更大而默认更好。 |
| `明天下午三点开会。` | The meeting will be held tomorrow at 3 p.m. | Tomorrow at 3 a.m. we will meet. | M2M100 把下午改为上午。 |
| `The meeting has been moved to next Tuesday at 10:30 a.m. Please do not invite Alice.` | 保留上午十点半与不要邀请 | 含“下午10点30分” | 时间与否定要逐项核对，不能只看句子通顺。 |
| `metting` | 开 开 | 聚集 | 不承诺错拼一定能译成“会议”。 |
| `meeetingg` | 空输出 | 梅西 | 空输出应允许保留输入；非空也可能是编造。 |

INT8 beam=4 没有消除这些缺陷。OPUS 的 greeting 仍重复到上限；M2M100 把 `meeetingg` 生成“毛泽东”，较长英语样例仍把上午改为下午。OPUS 的 `metting` 在 FP32 greedy 和 INT8 beam=4 可译成“开会”，说明精度和搜索策略会改变个别结果，不能只验证一种配置后宣称整个模型具备容错能力。

同一 OPUS FP32 模型在 CT2 CPU、Torch CPU 和 MPS 回退下，32 条样例的完整输出逐条一致。INT8 与 FP32 有 6 条输出不同。精度比较同时涉及生成内容，不能只比较文件大小或算出一个纯速度提升比例。

本轮还观察到 M2M100 将“如果下雨，我们就取消会议”译为带拼写错误的 `If it rains, we cancell the meeting.`。这属于工具生成质量问题，不应算作用户的学习错误。

## 运行失败与隔离

最初在同一 venv 中做 CT2 推理时，间接加载了 Torch 与两份 OpenMP runtime，出现 `OMP Error #15`；多线程转换也曾崩溃。仅指定 tokenizer 不用 Torch 的环境变量不能避免 CT2 导入转换模块。单独创建不安装 Torch 的 CT2 推理环境后，双向推理可运行；转换则以单线程完成。本轮没有用 `KMP_DUPLICATE_LIB_OK` 掩盖问题。原始推理失败保留在[smoke 记录](../probes/results/translation-benchmark/smoke.json)及相邻 stderr 文件中；转换崩溃的信号、线程栈和两个 OpenMP image ID 见[诊断摘录](../probes/results/translation-benchmark/conversion-diagnostic.json)。

本机 PyTorch 返回 MPS 可用，但纯 MPS FP32/FP16 均因 `aten::isin.Tensor_Tensor_out` 未实现而不能生成。显式启用 CPU 回退后能推理，其结果单独标为 MPS 加 CPU 回退，不声称是全程 GPU 推理，也不据此排除其他 GPU runtime。

## 禁网与失败路径验证

[offline-validation.json](../probes/results/translation-benchmark/offline-validation.json) 的四项检查均通过。先以实际 socket 连接确认沙箱拒绝网络，再在同类沙箱中新建推理进程：

- OPUS INT8 和 M2M100 INT8 均从本地加载，实际完成英→中、中文短句→英语及英语否定句→中文。
- 缺少中→英模型目录时加载明确失败，退出码 2；没有静默补下载或继续提交其他方向结果。
- 用故意损坏的转换权重时加载明确失败，退出码 2，没有把异常当作译文。
- 1,102 个输入 token 对 OPUS 的 512 上限及 M2M100 的 1,024 上限均被明确拒绝；空输入也被拒绝，未静默截断。随后仍可翻译正常否定句。

这是禁止网络的本地推理进程验证，不是全机物理断网，也不覆盖 IMK 与其他系统服务。三份独立 CPU 采样批次均实际生成 120 条结果、无运行错误，`sample` 返回 0；这些批次的时间没有混入正式性能统计。

Python 文件已通过语法检查；结果 JSON 可解析，复跑工具在仓库外输出路径的真实双向单词冒烟也已通过。LSP 工具没有可用的 Python 服务，未把本轮语法检查称为完整静态分析。

## 对下一步的决定

1. 中文解码器与翻译后端分开选。中文候选已扩展为青简、librime、libime 与 Fcitx macOS 路线，见[输入引擎候选](input-engine-candidates.md)。libime 的小鹤接口已有源码证据，尚未做本机性能与宿主验收。
2. 保留 CT2 的 FP32/INT8 作为可复现翻译实验基线；词与常用表达优先补充有许可依据的词典、义项与短语资源，不让一个句子模型承担所有词级输入。该分层是建议，尚未实现，也不保证能修好任意自由句。
3. 后续继续加入 small100 等独立模型或其他合适后端，用同样的风险样例和计时边界比较。当前两模型均有质量缺口，不提前锁定 OPUS，不用更大的模型或更宽 beam 代替实测。
4. 进入真实 IMK 最小闭环时仍须验证异步结果版本、取消、焦点切换、按应用模式、译文失败保留原输入。此次脚本没有实现或验证这些输入法行为。

此前 Apple Translation 的本机资源状态仍为 supported、未安装；本轮没有改变系统语言资源或输入法配置，也没有得到 Apple 实际译文。不能把它算作已跑过的第三个模型。
