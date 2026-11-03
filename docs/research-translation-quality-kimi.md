# 翻译质量独立研究（kimi / kimi-k3.1-pro）

> 本文保留子代理的原始独立意见，包含尚未证实或经复核不成立的统计、推断与建议。请结合[汇总与复核](research-translation-quality-synthesis.md)阅读，不将本页直接当作产品决定或验收证据。

本研究只读产品文档、原方案源码、资源与原始记录，未阅读其他模型报告；未下载模型、运行推理或修改既有数据。1280 请求只是 256 用例重复五轮，不是 1280 个独立语义样本（`probes/results/translation-strategy-final/run.json:226-228`）。下文 `requests.jsonl`、`acceptance.json`、`report.md`、`final-labels.json` 均位于该结果目录；两个 Python 文件均位于 `probes/`。

## 一、瓶颈与高价值漏查

**已证事实：生成器是首要瓶颈，排序是次要瓶颈，结构检查不具备语义验收能力。** 最终标注为 46/100、53/100 合格，91 条错误译文全部越过结构检查（`acceptance.json:15-20,391-396`；`report.md:9`）。检查实际只有重复、时间、长度、脚本和品牌保留（`probes/translation_strategy.py:396-437`），无法识别否定、时态、义项与搭配错误；继续收紧它只能增加回退，不能创造合格译文。

我逐条查看了 91 条错误放行的首轮候选。“正确答案常在 beam 内”缺少证据：`stapler` 两个候选都是编造音译，receipt 的三个英译中候选也全错（`requests.jsonl:205,243`）。确有少数排序反例：`欢迎光临` 的第二候选是 `Welcome`，航班句第三候选是 `will land`，收据句第三候选是 `Please keep the receipt as needed`（`requests.jsonl:27,177,225`）。因此重排可挽救少数，却远不能解释或弥合 95% 缺口。原标注只评最终候选，并未给全部候选做语义标注，故“beam 内正确率”和重排净收益仍是未测量项。zh→en 冻结为 λ=0，44 条错误根本未经过 quickmt 排序；en→zh 反向分数虽会把 `lands` 从“起飞”改选为“降落”（`requests.jsonl:182`），也会重排两个都错的候选，不能视为可靠性证明。

**资源与输入分布是第二瓶颈。** 480 条资源只做完整输入精确命中（`translation_strategy.py:107-134,559`），最终仅命中 9/200；句中的 receipt、package 等完全用不上审核义项。孤立词本身多义，资源却强制唯一首义，如 `order→订单`、`cool→凉快`（`resources/translation/review-log.tsv:12,22`）。这既限制覆盖，也不能保证语境正确。

**实现漏查并非只有已知模板边界。** ① 品牌 `map` 只匹配完整输入，运行时保护只扫描 `preserve`（`translation_strategy.py:339-350`），所以“用微信扫码支付”“淘宝上买的”中的中文品牌根本不受保护，最终分别译成 micro-scans、wallet（`requests.jsonl:48,143`；`resources/translation/brands.tsv:36-42`）。② worker 已计算 `sourceUnknownTokens`（`translation-backend-worker.py:173`），编排却没有保留该信号；整句中的 `metting` 又绕过仅检查“全字母单词”的保留判定。未知词元能否有效拦截仍待验证。③ 去重只去空白（`translation_strategy.py:606`），部分 beam 名额耗在大小写／标点变体上，属于实现损耗而非主因。

**验收口径有噪声，但不是失败主因。** `forecast→预计`、`on sale→出售` 在无语境时可成立；反之 `Gogaku v1.4.2 is out→已退出` 确为错译，不能算正确误拒（`final-labels.json:53,185,275`；`requests.jsonl:13`）。放宽这些边界只会小幅改数。两轮测试集、分母和解码不同，不能用 70.8% 与约 49% 证明策略导致模型退步。分词／转换也未发现足以解释普遍错译的证据：worker 强制校验 small100 语言前缀和源尾 EOS（`translation-backend-worker.py:108-110`）；但与原始框架逐 logits／输出对齐未做，不能宣称完全排除转换问题。

## 二、新思路（按价值排序）

1. **停止给 small100 叠加过滤器，单次验证更强的生成器。** 可验证 `google/madlad400-3b-mt`：官方模型卡为 Apache-2.0、3B、T5，训练规模和通用基准结果有官方论文依据（https://huggingface.co/google/madlad400-3b-mt ；https://proceedings.neurips.cc/paper_files/paper/2023/file/d49042a5d49818711c401d34172f9900-Paper-Datasets_and_Benchmarks.pdf）。它针对的是“候选本身不含正确译法”。**有根据假设**是质量会改善；能否到 95% 完全未验证，且 3B 在 Intel 上的 500ms 风险很高，模型卡也明确未做生产场景评估。
2. **把审核术语变成全句解码约束，而非只做整串查表。** 让模型在生成整句时必须采用审核过的 receipt／包裹／WeChat 等译法，保持句法由模型统一生成，禁止译文后替换和逐词拼接。它直接针对术语丢失与资源零句内覆盖；但约束解码实现、歧义处理和自然度均是**未验证猜想**，预期也只是增量，不足以单独承诺 95%。
3. **独立跨语语义编码器只做否决门。** LaBSE 可将 109 种语言映射到共享向量空间，许可为 Apache-2.0（https://huggingface.co/sentence-transformers/LaBSE ；https://research.google/blog/language-agnostic-bert-sentence-embedding/）。它可研究“原文—候选”相似度能否拦下 high-score 错译，但只会**降低错误放行、增加回退**，不会提高 beam 外合格覆盖；阈值可靠性及额外 471M 模型的延迟、内存均未验证，不应现在扩成选型轮。

## 三、只推荐一次最小验证

只验证思路 1：先冻结边界多义标签（不计入调参），固定 MADLAD-400-3B-MT 的官方 revision、CT2 INT8、greedy、2 线程；不加资源、模板、quickmt 或参数搜索，在同一 200 应译＋32 风险用例上跑一次裸模型质量门，并在当前 Intel Mac 串行测热态延迟。**任一方向合格覆盖 <95%、任一固定关键意义破坏进入候选、短表达 p95>500ms、短句 p95>2s，或无法离线复现转换／推理，即停止；不继续试 beam、量化档位或下一个模型，学习模式保持关闭。** 即便全过，也只获得进入新冻结集、用户盲测和 Windows 验证的资格，不是产品达标。

## 四、现实约束与证据边界

现路线 Intel 串行热态 p95 为 353.8ms／527.7ms，但有两条短表达超 500ms，冷启动、持续输入排队和 Windows 均未过（`report.md:28,70-78`）。不能外推更大的 MADLAD 或额外 LaBSE 达标；云模型、Apple／Windows 系统翻译不能作为离线双端默认替代。CC-CEDICT 衍生资源是 CC BY-SA 4.0（`resources/translation/manifest.json:9`），仍需署名、相同方式共享及项目分发审查。本文对 MADLAD 的官方资料来自联网检索内容；直接页面抓取受本机 fake-IP 拦截，未做本机模型实测。以上“当前产物失败”是事实，“更强模型可能改善”是假设，“能满足全部产品门槛”仍是猜想。
