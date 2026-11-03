# 翻译后端统一实测决定

日期：2026-11-03。性质：**性能与质量门槛实测完成；不改变当前 `approved=false`、学习模式置灰和 `0.1.1-rc.1` 版本状态。** 本轮没有实现翻译辅助进程、没有打开学习模式，也没有把任何模型写进生产包。

## 一、结论先行

1. **性能：quickmt 明显更快。** 短表达 p95 43–84ms、短句 p95 69–90ms，约为 small100 的 1/2–1/3；保留集 p95 155–186ms，约为 small100 的 1/4。加固层 p95 约 0.1ms、辅助进程 IPC p95 约 0.4ms，均未吃掉速度优势。
2. **质量：quickmt 在输入法主场景不达标。** 短语级复读、截断、残片和语义漂移导致 en→zh 加固后可用率仅 **77.67%**，固定风险集有 **12 条**错误译文仍进入候选；small100 也有 **5 条**，但可用率为 **95.15%／94.34%**，更接近门槛。
3. **决定：不切换到 quickmt。** 保持 `small100` 为当前中英主路线，先修加固层误报并补齐人名/品牌与短语审阅；quickmt 保留为性能对照，不在没有新质量证据时因速度替换。
4. **学习模式继续阻塞。** 两个后端都没有通过“固定风险集的错误译文不得进入默认候选”，用户盲测也未进行。不得把机械可用率当成语义通过，也不得把安全回退原文伪装成译文。

## 二、实测范围与环境

| 项 | 值 |
| --- | --- |
| 机器 | Intel Core i9-9880H、16 核、64 GiB、macOS 26.7.2、x86_64 |
| 推理 | CTranslate2 4.6.0、SentencePiece 0.2.0、CPU-only、无 PyTorch 的 venv |
| 参数 | INT8、batch=1、greedy（beam=1）、2 线程、最大解码 256 |
| 轮次 | 5 轮交错，共 2,400 条请求（每轮 480），0 运行错误 |
| small100 | `alirezamsh/small100@8ab680e26a596d2e3d2d2d17ae0f68df1037328c`，CT2 INT8，MIT（tokenizer Apache-2.0） |
| quickmt | `quickmt-en-zh@f48b69e53866b717607b59f94350e9aae3ed021c`、`quickmt-zh-en@c27cc8024e01a047733a1e34796e2ab19d74b237`，原生 CT2，CC-BY-4.0 |
| 分层 | 模型层（分词＋CT2＋解码）、辅助进程层（JSONL stdio）、加固层（`.build/core/libgogaku_core.dylib`） |

模型文件、revision、许可证、字节数与 SHA256 见 [models.json](models.json)；主机与依赖见 [environment.json](environment.json)。本轮只从本地缓存加载，未在运行中下载模型。

## 三、性能

### 3.1 代表短输入（速度子集，热态，每桶 10 次＝5 轮×2 句）

| 后端 | 方向 | 短表达 p50／p95 | 短句 p50／p95 | 预算 |
| --- | --- | ---: | ---: | --- |
| small100 | en→zh | 137.4／**180.1ms** | 200.6／**281.3ms** | 500ms／2s，通过 |
| small100 | zh→en | 113.7／**134.4ms** | 218.7／**300.7ms** | 通过 |
| quickmt | en→zh | 47.2／**83.6ms** | 59.3／**89.7ms** | 通过 |
| quickmt | zh→en | 36.6／**43.4ms** | 53.8／**68.9ms** | 通过 |

### 3.2 更大样本（风险集＋保留集，纯模型耗时）

| 后端 | 方向 | 保留集 p50／p95／max | 风险集 p95 |
| --- | --- | ---: | ---: |
| small100 | en→zh | 194.7／619.8／883.2ms | 483.9ms |
| small100 | zh→en | 195.3／658.2／814.0ms | 498.5ms |
| quickmt | en→zh | 63.9／186.4／242.3ms | 152.5ms |
| quickmt | zh→en | 54.1／155.4／213.7ms | 125.5ms |

small100 的保留集 p95 被长句拉高，但仍低于 2s；短输入预算以速度子集为准。线程 1／2／4 只在速度子集探索：2 线程的短表达 p95 优于 1 线程，4 线程没有稳定收益（small100 en→zh 180.1→191.2ms；quickmt 有升有降），保留 2 线程为生产候选基线；见 [thread-scaling.json](thread-scaling.json)。

`qqxzzv` 等策略应保留输入若被模型调用会拖到 5–6.5s（small100），生产管线本就不应把这类输入送进模型；它们已从翻译延迟统计中剥离，只在 [latency.json](latency.json) 的 `preservePolicy` 记录。

### 3.3 资源与加载

| 后端 | 模型加载 | 峰值 RSS | 生产产物 | 备注 |
| --- | ---: | ---: | ---: | --- |
| small100 | 1.83s | 574 MiB | 332 MiB | 单模型双向；方向切换只换目标语言前缀 |
| quickmt en→zh | 1.13s | 766 MiB | 394 MiB | 每方向一份模型 |
| quickmt zh→en | 1.21s | 688 MiB | 391 MiB | 切换方向需加载另一份或双常驻 |

quickmt 本轮使用上游原生 CT2 权重并在加载时按 `compute_type=int8` 在线转换；small100 使用已转换的 CT2 INT8 产物。因此 quickmt 的加载时间与 RSS 含在线转换成本，不能直接当作预转换产物的冷启动或常驻内存；推理延迟比较不受影响，预转换后的资源差异未测。三份 worker 同时驻留峰值约 2.0 GiB（2.13 GB）。quickmt 若只常驻当前方向约 0.7–0.8 GiB；双向常驻约 1.4 GiB。CPU 与墙钟比约 1.8，说明 2 线程基本跑满。模型加载、首个请求和预热记录见 [resource.json](resource.json)；加固与 IPC 开销见 [latency.json](latency.json) `layers`。

## 四、质量门槛

| 后端 | 方向 | 应译 | 模型可生成 | 加固后可用 | 可用率 | 固定风险未处置 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| small100 | en→zh | 103 | 103 | 98 | **95.15%** | 5 |
| small100 | zh→en | 106 | 106 | 100 | **94.34%** | （合计）5 |
| quickmt | en→zh | 103 | 101 | 80 | **77.67%** | 12 |
| quickmt | zh→en | 106 | 106 | 98 | **92.45%** | （合计）12 |

质量表只含风险集与保留集（保留集 200 条中 180 应译、20 应保留），不含速度子集。

- **small100 未处置失败**：`zh-phrase`（The Meeting）、`zh-bank`（Banking）、`zh-condition`（cancell）、`en-names`（丢 Bob）、`en-sentence`（我明天会见）。
- **quickmt 未处置失败**：`zh-bank`、`zh-sentence`、`zh-tomorrow`、`zh-word`、`zh-phrase`、`zh-time`、`zh-contrast`、`en-tomorrow`、`en-negation`、`en-word`、`en-mixed`、`en-time`；以短语复读、残句和尾部残片为主。
- **加固层误报**：时间区间（a.m.–p.m.）、英文动词 `am` 被当 a.m.、合法三元组复现、URL 拉丁字符主导脚本/长度检查。它们只造成安全回退，没有放行错误译文，但压低了可用率。修掉后 small100 两方向约 97%，quickmt en→zh 仍约 83%。
- 固定风险集的逐条输出与人工审阅见 [quality-review.md](quality-review.md)、[semantic-review.md](semantic-review.md)、[semantic-review.json](semantic-review.json)；机械门槛见 [quality-gate.json](quality-gate.json)。**用户盲测仍未进行。**

## 五、未来语言扩展成本

当前版本范围只有中英，因此没有把扩展语言列入交付；这里只回答“以后加语言要付什么成本”。

| 维度 | quickmt | small100 |
| --- | --- | --- |
| 增加一个语言对 | 通常两份方向模型；代表三对（en↔ja、en↔ko、en↔es）的 `model.bin` 合计约 **2.33GB** | 同一 332 MiB 模型；只换目标语言前缀 |
| 已发布语言对 | 29 对，按对线性增加磁盘/加载/测试/许可清单 | 100 语言，单模型 |
| 本机实测 | 中英已测；扩展方向未下载、未测 | 六方向探针已测：短表达 p95 109–209ms、短句 p95 372–451ms |
| 质量证据 | 每对独立 spm＋模型，需逐对审阅 | 每语言质量未被本探针验证，不能以语言数量代替质量 |

扩展探针只含每方向 4 条，没有人工参考，不报告语义分数；详见 [language-extension.json](language-extension.json) 与 `probes/results/translation-backends-multilingual/`。`MADLAD-400 3B-MT` 未下载、未转换、未实测：当前版本不需要它，按停止规则留作后续多语言版本预研，不把调研推断写成成绩。

## 六、决定与下一步

| # | 决定 | 理由 |
| --- | --- | --- |
| D1 | **不切换到 quickmt** | 速度领先，但短语级复读/截断/残片使 en→zh 可用率仅 77.67%，固定风险 12 条未处置；速度不能抵消错误候选 |
| D2 | **保持 small100 为当前中英主路线，但学习模式继续阻塞** | 风险失败较少、可用率接近门槛；仍需修加固误报和 5 条语义失败 |
| D3 | **先做加固层第二片** | 修时间区间/`am` 动词、合法三元组、URL 脚本与长度四类误报；再接人名/品牌对齐和短语审阅 |
| D4 | **quickmt 保留为性能对照** | 若后续通过重训、约束解码或其他方式解决短语级复读，再按同一风险集复测；不在本轮写进生产 |
| D5 | **未来语言不进入当前版本** | small100 的多语言延迟可行，但质量未验证；quickmt 每对两份模型，成本线性增长 |
| D6 | **版本与状态不变** | `0.1.1-rc.1`、学习菜单置灰、`approved=false` 保持不变 |

下一步顺序：

1. 修 `translate_safety` 的时间检查（同时支持 a.m.–p.m. 区间、排除动词 `am`）和重复检查（合法三元组复现），并补回归测试。
2. 让脚本/长度检查忽略 URL 等受保护片段；补人名/品牌对齐和简短表达审阅。
3. 用同一套风险集、保留集、短文本集复跑；修掉误报后确认 small100 的可用率与 5 条语义失败的实际处置。
4. 通过后再做用户盲测；盲测通过前不打开学习模式、不接生产翻译辅助进程。
5. Windows 和真实 IMK/宿主验收仍按原计划单独进行，不能复用本轮模型层成绩。

## 七、未测与不能声称

- 未做用户盲测、真实 IMK 候选窗、宿主插字、焦点/取消/迟到结果、Windows TSF。
- 辅助进程层只测 JSONL 串行请求/回传；未测取消、并发调度、二进制协议。加固层只测纯函数应用，未接入真实翻译管线。
- 未测 quickmt 扩展语言的实际运行；未测 MADLAD-400 3B。
- `opus-mt-tiny-zho-eng` 与 Mozilla zh→en 59M 未测：前者只覆盖中→英且转换链未验证，后者只覆盖单方向，均不能作为双向完整方案；本轮结果已能区分 small100/quickmt，按停止规则不扩展单方向下限测试。
- NLLB、M2M100、Seamless、小型 decoder-only LLM 不重新下载重复证明；既有许可/质量/延迟排除证据见[模型解堵调研](../../../docs/research-translation-model-unblock.md)§二／§三。
- 未在清空文件缓存或隔离后台负载的条件下测“冷启动”；加载时间只代表本机一次进程启动。
- 未证明 small100 在 Windows/MSVC 或不同 CPU 后端逐字一致；同一权重不同后端需分别跑同一验收集。
- 未单独采样稳定驻留内存；本轮 RSS 是进程峰值，不能当作长期常驻。
- 未把安全回退原文当成译文；未把机械可用率当成语义通过。

## 八、产物索引

| 文件 | 内容 |
| --- | --- |
| `probes/results/translation-backends/run.json` | 参数、环境、worker 加载、轮次与系统负载 |
| `probes/results/translation-backends/requests.jsonl` | 2,400 条请求级记录（源文哈希、token、分阶段耗时、输出、加固、语义信号） |
| `probes/results/translation-backends/models.json` | 模型 revision、许可证、文件大小与 SHA256 |
| `probes/results/translation-backends/latency.json` | 分方向/输入类型/套件的分位数与分层计时 |
| `probes/results/translation-backends/resource.json` | 加载、RSS、CPU、磁盘、方向切换 |
| `probes/results/translation-backends/quality-gate.json` | 机械门槛、风险未处置、审阅合并结果 |
| `probes/results/translation-backends/quality-review.md` | 风险集逐条输出与加固处置索引 |
| `probes/results/translation-backends/semantic-review.md` | agent 语义审阅与失败清单 |
| `probes/results/translation-backends/language-extension.json` | 多语言扩展成本与 small100 探针延迟 |
| `probes/results/translation-backends/thread-scaling.json` | 1／2／4 线程速度子集对照 |
| `probes/benchmark-translation-backends.py` | 统一驱动（模型层＋辅助进程层＋加固层） |
| `probes/translation-backend-worker.py` | 隔离 worker（small100/quickmt 协议适配） |
| `scripts/summarize-translation-backends.py` | 汇总与门槛报告生成 |
