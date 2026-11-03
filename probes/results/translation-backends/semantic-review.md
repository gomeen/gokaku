# 翻译后端统一实测：语义审阅

日期：2026-11-03。范围：`small100@8ab680e` CT2 INT8 与 `quickmt-en-zh@f48b69e`／`quickmt-zh-en@c27cc8` 原生 CT2，i9-9880H、2 线程、greedy、batch=1、256 最大解码长度、5 轮交错。原始请求见 [requests.jsonl](requests.jsonl)，机械汇总见 [quality-gate.json](quality-gate.json) 与 [quality-review.md](quality-review.md)。

**性质：本页是 agent 逐条语义审阅，不是用户盲测。** 状态口径：`pass` 表示错误译文没有进入默认候选（包括加固安全回退与策略保留），或候选可直接使用；`fail` 表示错误、缺失或明显不自然的译文仍成为候选。用户最终盲测仍未进行。

## 机械门槛

| 后端 | 方向 | 应译条数 | 模型可生成 | 加固后可用 | 可用率 | 回退原因 |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| small100 | en→zh | 103 | 103 | 98 | 95.15% | time 3、script 1、repeat 1 |
| small100 | zh→en | 106 | 106 | 100 | 94.34% | time 3、length 1、repeat 2 |
| quickmt | en→zh | 103 | 101 | 80 | 77.67% | repeat 16、truncated 2、time 2、script 2、length 1 |
| quickmt | zh→en | 106 | 106 | 98 | 92.45% | repeat 3、length 3、time 2 |

短表达／短句预算用速度子集（每桶 10 次热态请求＝5 轮×2 句）判断：small100 p95 为 134.4／180.1ms（短表达）与 300.7／281.3ms（短句）；quickmt 为 43.4／83.6ms 与 68.9／89.7ms。四组均过 500ms／2s 预算。正式全量延迟另见 [latency.json](latency.json)。

## 固定风险集：未处置失败

### small100（5 条）

| 用例 | 源文 | 仍进入候选的输出 | 问题 |
| --- | --- | --- | --- |
| `zh-phrase` | 开会 | `The Meeting` | 动词短语被名词化，缺“开会”动作 |
| `zh-bank` | 银行 | `Banking` | 动名词/行业义，不是“银行”的默认词候选 |
| `zh-condition` | 如果下雨，我们就取消会议。 | `If it rains, we cancell the meeting.` | 条件与取消保留，但工具生成英语拼写错误进入候选 |
| `en-names` | Alice will meet Bob in Beijing on Friday. | `艾丽丝星期五将在北京见面。` | 丢失 Bob；人名对齐尚未接入加固层 |
| `en-sentence` | I have a meeting tomorrow. | `我明天会见。` | “会议”被改成“会见”，主体关系改变 |

安全回退项：`en-long`（上午→下午、30 点语病）、`zh-long`（十点半→10 a.m.）、`en-url`、`zh-url` 均由加固回退原文，未进入候选。`en-phrase` 繁体输出经 t2s 归一为“参加会议”。

### quickmt（12 条）

| 用例 | 仍进入候选的输出 | 问题 |
| --- | --- | --- |
| `zh-bank` | `Bank of the Bank` | 词义/结构错误 |
| `zh-sentence` | `I have a group tomorrow.` | 会议变 group |
| `zh-tomorrow` | `Tomorrow the future` | 加入原文没有的“未来” |
| `zh-word` | `Conferences by the` | 残句 |
| `zh-phrase` | `Meetings for a` | 残句 |
| `zh-time` | `The cast meets tomorrow at 3pm.` | 开会变 cast meets |
| `zh-contrast` | `He's not in Shanghai, in Beijing.` | 缺对比连接，语法不完整 |
| `en-tomorrow` | `明天 开始` | 加入“开始” |
| `en-negation` | `不要发送邮件。 电子邮件` | 尾部残片 |
| `en-word` | `会议介绍` | 加入“介绍” |
| `en-mixed` | `请在周五之前查看Gogaku v2.1。 评分` | 尾部残片 |
| `en-time` | `明天下午3点开会 大家好` | 尾部残片 |

安全回退项：`en-greeting`（复读到上限）、`en-phrase`（“参加会议 会议”）、`en-url`（尾部“支持”）、`zh-url` 等没有进入候选。quickmt 的 en→zh 短语级复读、截断和残片是主要失败源；风险集的长句（`en-long`、`zh-long`）反而通过。

## 加固层误报（安全但损失可用率）

以下不是模型语义失败，而是 v1 规则对正确输出回退原文。它们没有让错误译文进入候选，但把可用率压低：

| 规则 | 触发例 | 说明 |
| --- | --- | --- |
| 时间：源同时含 a.m. 与 p.m. | `enToZh-082`、`zhToEn-082` | 9 a.m.–4 p.m. 这类区间被无条件判为时段矛盾 |
| 时间：英文 `am` 被当作 a.m. | `zhToEn-090`、`enToZh-090` | `I am available ... afternoon` 中的动词 am 触发时段线索 |
| 重复：合法三元组复现 | `zhToEn-085`、`enToZh-083` | “small boxes …”“测试 …”被当作复读 |
| 脚本/长度：URL 的拉丁字符计入 | `en-url`、`zh-url` | 中文＋网址输出的拉丁字符主导，被脚本或长度网误判 |

质量表只含风险集与保留集（保留集 200 条中 180 应译、20 应保留），不含速度子集。按保守口径，即使把这些误报全部修掉，quickmt en→zh 仍只有约 83%（80/103 基础上加回可识别误报），低于 95%；small100 两方向可到约 97%，但仍剩 5 条固定风险语义失败。因此误报修正会改善 small100 的可用率，但不会把 quickmt 的质量门槛变成通过。

## 结论

1. **性能排序稳定**：quickmt 在短表达和保留集上快约 1.6–4 倍，加固与 IPC 合计 p95 不足 0.5ms，性能优势不是测量噪声。
2. **质量排序与速度相反**：small100 的固定风险失败更少，quickmt 在输入法主场景（1–3 词短语）出现大量复读、残句和语义漂移；两者都没有通过“错误译文不得进入默认候选”。
3. **加固层需要第二片**：时间区间/am 动词、合法三元组、URL 脚本与长度四类误报必须先修；人名对齐、品牌对齐和简短表达审阅仍未接入。
4. **学习模式继续阻塞**：不能因为 quickmt 更快就替换，也不能把 small100 的 95% 机械可用率当成语义通过。用户盲测仍未进行。

完整逐条记录见 [semantic-review.json](semantic-review.json) 与 [quality-review.md](quality-review.md)。
