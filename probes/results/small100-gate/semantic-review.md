# small100 Mac 门槛：语义审阅记录

审阅时间：2026-10-31。环境：Intel Mac i9-9880H，macOS 26.7.2，CTranslate2 4.6.0 INT8，greedy、batch=1、2 线程。模型 `alirezamsh/small100@8ab680e26a596d2e3d2d2d17ae0f68df1037328c`（MIT，见 manifest.json 哈希）。机械判定与全部输出见 [evaluate.json](evaluate.json) 与 [evaluate.json.summary.json](evaluate.json.summary.json)。

## 结论

**G0 Mac 技术可行性通过；模型质量门槛不通过。** 依据[实施总计划](../../../docs/implementation-plan.md)§7：应译可用率≥95% 达标（risk 32/32、holdout 180/180，空输出／重复／超时均为 0），但**固定 32 条风险回归存在未处置的意义破坏进入默认候选**，该条件未满足。按§4 停止条件与§8 规则：双端学习交付保持阻塞；不改用 Apple、不恢复 OPUS／M2M100、不扩模型名单。用户语义盲测确认未进行（前置质量条件已不成立）。

## 技术可行性（通过项）

- **分词与协议**：仓库自带 `SMALL100Tokenizer` 可用；协议与 M2M100 不同——目标语言 token（`__zh__`／`__en__`）是编码器输入前缀，解码器从纯 eos 开始，无 forced_bos。已在脚本中按协议断言。
- **转换**：`ct2-transformers-converter --quantization int8` 成功，产物 model.bin 338,727,246 字节＋共享词表；转换在含 PyTorch 的隔离环境、`OMP_NUM_THREADS=1` 下完成，推理在无 PyTorch 环境完成（历史 OpenMP 冲突教训落实）。
- **HF 一致性**：6 个对照句 5 个逐字一致；1 个分歧（en-names，见下）。证明同一权重不同后端输出不保证逐字一致，计划要求的两端分别跑验收集是必要的。
- **速度**（12 轮×4 句，热态）：短表达 p95 125.5ms（en→zh）/111.2ms（zh→en）；短句 p95 218.7ms/198.9ms。均远低于 500ms／2s 门槛。
- **离线**：评测全程 `HF_HUB_OFFLINE=1`，venv-ct2 无 PyTorch、无网络调用。

## 固定风险集意义破坏（不通过项）

| 用例 | 源文 | 输出 | 破坏 |
| --- | --- | --- | --- |
| en-names | Alice will meet Bob in Beijing on Friday. | 艾丽丝星期五将在北京见面。 | 丢失人名 Bob，见面关系缺对象（与 HF 参考分歧处） |
| en-long | …moved to next Tuesday at 10:30 a.m. … | 会议将于下周二下午10点30点,… | 上午→下午翻转，且"30点"语病 |
| zh-long | 会议改到下周二上午十点半，… | …changed to 10 a.m. next Tuesday… | 丢失"半"（十点半→10 点整） |
| en-phrase | attend a meeting | 參加會議 | 繁体字形输出（首阶段面向简体） |

保留集扫描补充（enToZh-082）：`9 a.m. to 4 p.m.` 译为`下午9点至下午4点`，上午时段翻转。时间类错误在两个集合均有出现，非孤立现象。

## 其他缺陷记录（机制相关）

- **错拼／乱码输入编造可信译文**：`metting`→充足、`meeetingg`→同行、`recievee`→收藏、`unkn0wnzz`→无奈、`qqxzzv`→181 个重复 Q。产品规则（仅审核过的容错表达命中才提供可提交目标，否则保留原文＋提示）必须落实为硬拦截；生成成功不能作为提交资格。
- **专有名词改写**：`Gogaku v3.2.1`→`古巴 v3.2.1`（品牌被译成"古巴"）。代码 `let count = 42;` 被改写。
- **次要不自然**：zh-bank→Banking、zh-phrase→The Meeting、en-sentence→我明天会见（事件性质偏移）、zh-condition→`cancell`（工具生成英语拼写错误，按规则不计用户错误，但不得进入默认候选）。

## 后续

1. 学习分支按停止规则保持阻塞；本结果与哈希留档，不删失败样本。
2. 普通输入与共享核心工作（G1/G2）不受此阻塞影响，继续推进。
3. 不扩大模型名单；若用户后续明确改变模型决定，需另行修订计划。
