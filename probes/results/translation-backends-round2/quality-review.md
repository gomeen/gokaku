# 翻译后端统一实测：质量审阅索引

本文件由 `scripts/summarize-translation-backends.py` 生成，列出原始输出、加固处置和逐套件结果统计；
不是用户盲测结论。人工语义判断记录在 `semantic-review` 文件中。

口径：`候选放行`＝输出通过加固层进入默认候选；`语义合格`＝候选且审阅合格；
`错误放行`＝错误译文进入候选；`安全回退`＝加固层回退原文（不是译文）；
`应保留`用例按测试标签分组，只统计标签一致性，不代表真实识别能力。

## small100

### 套件 `confirm` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 95 | 64 | 0 | 31 | 5 | 0 | 0 |
- 错误放行：`cf-z-brand-01`、`cf-z-brand-03`、`cf-z-brand-04`、`cf-z-brand-05`、`cf-z-name-04`、`cf-z-name-07`、`cf-z-phrase-01`、`cf-z-phrase-04`、`cf-z-phrase-05`、`cf-z-phrase-08`、`cf-z-phrase-09`、`cf-z-phrase-10`、`cf-z-phrase-11`、`cf-z-sent-01`、`cf-z-sent-03`、`cf-z-time-08`、`cf-z-word-07`、`cf-z-word-10`、`cf-e-brand-05`、`cf-e-name-07`、`cf-e-name-08`、`cf-e-phrase-05`、`cf-e-phrase-07`、`cf-e-phrase-10`、`cf-e-sent-01`、`cf-e-sent-03`、`cf-e-sent-05`、`cf-e-sent-06`、`cf-e-time-05`、`cf-e-time-07`、`cf-e-time-08`
- 仅安全回退：`cf-e-brand-01`、`cf-e-brand-02`、`cf-e-brand-03`、`cf-e-brand-04`、`cf-e-brand-06`

### 套件 `holdout` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 180 | 173 | 128 | 0 | 45 | 7 | 0 | 20 |
- 错误放行：`zhToEn-002`、`zhToEn-003`、`zhToEn-004`、`zhToEn-006`、`zhToEn-010`、`zhToEn-028`、`zhToEn-033`、`zhToEn-035`、`zhToEn-037`、`zhToEn-040`、`zhToEn-047`、`zhToEn-055`、`zhToEn-058`、`zhToEn-061`、`zhToEn-064`、`zhToEn-073`、`zhToEn-075`、`zhToEn-078`、`zhToEn-080`、`zhToEn-081`、`zhToEn-084`、`zhToEn-086`、`zhToEn-087`、`zhToEn-089`、`enToZh-002`、`enToZh-010`、`enToZh-018`、`enToZh-024`、`enToZh-027`、`enToZh-028`、`enToZh-033`、`enToZh-035`、`enToZh-040`、`enToZh-043`、`enToZh-045`、`enToZh-056`、`enToZh-057`、`enToZh-062`、`enToZh-064`、`enToZh-073`…
- 仅安全回退：`zhToEn-057`、`zhToEn-082`、`zhToEn-085`、`zhToEn-090`、`enToZh-082`、`enToZh-085`、`enToZh-090`

### 套件 `risk` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 29 | 25 | 20 | 0 | 5 | 4 | 0 | 3 |
- 错误放行：`zh-bank`、`zh-condition`、`zh-phrase`、`en-names`、`en-sentence`
- 仅安全回退：`zh-long`、`zh-url`、`en-long`、`en-url`

### 套件 `short` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 76 | 67 | 43 | 0 | 24 | 9 | 0 | 12 |
- 错误放行：`se-z-brand-04`、`se-z-name-02`、`se-z-name-05`、`se-z-phrase-03`、`se-z-phrase-05`、`se-z-phrase-09`、`se-z-phrase-10`、`se-z-phrase-12`、`se-z-phrase-13`、`se-z-time-07`、`se-z-time-08`、`se-e-brand-02`、`se-e-brand-03`、`se-e-brand-05`、`se-e-name-02`、`se-e-name-06`、`se-e-phrase-06`、`se-e-phrase-08`、`se-e-phrase-10`、`se-e-phrase-11`、`se-e-phrase-14`、`se-e-phrase-15`、`se-e-time-01`、`se-e-time-07`
- 仅安全回退：`se-z-brand-03`、`se-z-brand-06`、`se-z-time-01`、`se-e-brand-01`、`se-e-brand-04`、`se-e-brand-06`、`se-e-time-02`、`se-e-time-03`、`se-e-time-04`

### 风险用例 `zh-not-yet` — zh-en

- 源文：`我还没吃饭。`
- 审阅提示：保留尚未吃饭，而非已吃或习惯性不吃。
- 原始输出：`I have not eaten yet.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — “还没”保留为 not ... yet。

### 风险用例 `zh-phrase` — zh-en

- 源文：`开会`
- 审阅提示：have/attend a meeting 等表达，不要求逐字一致。
- 原始输出：`The Meeting`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`fail` — “开会”是动词短语，输出 The Meeting 名词化且缺动作，不应作为默认候选。

### 风险用例 `zh-time` — zh-en

- 源文：`明天下午三点开会。`
- 审阅提示：明天下午三点，不能改日期和时间。
- 原始输出：`Meeting tomorrow at 3 pm.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 明天下午三点完整保留。

### 风险用例 `zh-greeting` — zh-en

- 源文：`早上好`
- 审阅提示：good morning。
- 原始输出：`Good morning`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 早上好。

### 风险用例 `zh-contrast` — zh-en

- 源文：`他不在上海，在北京。`
- 审阅提示：保留不在上海、在北京的对比。
- 原始输出：`He is not in Shanghai, but in Beijing.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 不在上海、在北京的对比保留。

### 风险用例 `zh-url` — zh-en

- 源文：`请打开 https://example.com/a?x=1。`
- 审阅提示：网址需原样保留。
- 原始输出：`Please open https://example.com/a?x=1`
- 加固判定：`fallback-original` / `length`
- 机械语义：`pass`
- 人工审阅：`pass` — 网址原样保留；加固因长度比率误判回退原文，属安全处置但暴露误报。

### 风险用例 `zh-bank` — zh-en

- 源文：`银行`
- 审阅提示：bank。
- 原始输出：`Banking`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`fail` — Banking 是动名词/行业义，不是“银行”的默认词候选。

### 风险用例 `zh-long` — zh-en

- 源文：`会议改到下周二上午十点半，请不要邀请爱丽丝。`
- 审阅提示：保留下周二上午十点半和不要邀请。
- 原始输出：`The meeting will be changed to 10 a.m. next Tuesday, please don’t invite Alice.`
- 加固判定：`fallback-original` / `time`
- 机械语义：`fail`（需人工判读）
- 未命中：`one-of:10:30|ten thirty|half past ten`、`one-of:not|don't|do not`
- 人工审阅：`pass` — 模型丢掉“半”并输出 10 a.m.；加固按时段/半点规则回退原文。

### 风险用例 `zh-tomorrow` — zh-en

- 源文：`明天`
- 审阅提示：tomorrow。
- 原始输出：`tomorrow`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — tomorrow。

### 风险用例 `zh-names` — zh-en

- 源文：`爱丽丝星期五在北京见鲍勃。`
- 审阅提示：保留人名、地点、星期五与见面关系。
- 原始输出：`Alice will meet Bob in Beijing on Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — Alice、Bob、北京、星期五和见面关系均保留。

### 风险用例 `zh-word` — zh-en

- 源文：`会议`
- 审阅提示：meeting 或 conference，孤立词无唯一义项。
- 原始输出：`Meeting`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — Meeting，孤立词可接受。

### 风险用例 `zh-sentence` — zh-en

- 源文：`我明天有个会。`
- 审阅提示：I have a meeting tomorrow，保留主体和明天。
- 原始输出：`I have a meeting tomorrow.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — I have a meeting tomorrow，主体和明天保留。

### 风险用例 `zh-condition` — zh-en

- 源文：`如果下雨，我们就取消会议。`
- 审阅提示：保留条件与取消会议。
- 原始输出：`If it rains, we cancell the meeting.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`fail` — 条件与取消含义保留，但工具生成英语拼写错误 cancell 进入候选；按产品规则不得作为默认候选。

### 风险用例 `zh-negation` — zh-en

- 源文：`不要发送邮件。`
- 审阅提示：保留不要发送，不得译成发送。
- 原始输出：`Do not send mail.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 否定发送保留。

### 风险用例 `zh-mixed` — zh-en

- 源文：`请在星期五之前检查 Gogaku v2.1。`
- 审阅提示：保留品牌、版本和星期五之前。
- 原始输出：`Please check Gogaku v2.1 before Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — Gogaku、v2.1、星期五之前均保留。

### 风险用例 `zh-past` — zh-en

- 源文：`我昨天去了银行。`
- 审阅提示：保留昨天和去银行。
- 原始输出：`I went to the bank yesterday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 昨天去银行保留。

### 风险用例 `en-mixed` — en-zh

- 源文：`Please review Gogaku v2.1 before Friday.`
- 审阅提示：保留品牌、版本和星期五之前的时间关系。
- 原始输出：`请在星期五之前查看Gogaku v2.1。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — Gogaku、v2.1、星期五之前均保留。

### 风险用例 `en-phrase` — en-zh

- 源文：`attend a meeting`
- 审阅提示：参加会议。
- 原始输出：`參加會議`
- 加固判定：`candidate-normalized` / `traditional-normalized`
- 归一输出：`参加会议`
- 机械语义：`pass`
- 人工审阅：`pass` — 繁体输出由 t2s 归一为“参加会议”。

### 风险用例 `en-time` — en-zh

- 源文：`The meeting is at 3 p.m. tomorrow.`
- 审阅提示：明天下午三点，不能改时间。
- 原始输出：`会议是明天下午3点。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 明天下午三点保留。

### 风险用例 `en-greeting` — en-zh

- 源文：`good morning`
- 审阅提示：早上好。
- 原始输出：`早上好`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 早上好。

### 风险用例 `en-long` — en-zh

- 源文：`The meeting has been moved to next Tuesday at 10:30 a.m. Please do not invite Alice.`
- 审阅提示：保留下周二上午十点半和不要邀请 Alice 的否定。
- 原始输出：`会议将于下周二下午10点30点,请不要邀请艾丽丝。`
- 加固判定：`fallback-original` / `time`
- 机械语义：`fail`（需人工判读）
- 未命中：`one-of:10:30|十点半|10点半`、`one-of:上午|早上`
- 命中禁词：`下午`
- 人工审阅：`pass` — 模型把上午翻成下午且“30点”语病；加固按时段规则回退原文。

### 风险用例 `en-typo-word` — en-zh

- 源文：`metting`
- 审阅提示：观察能否理解拼写偏差，不保证必须猜对。
- 原始输出：`充足`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留错拼；模型输出“充足”不进入候选。

### 风险用例 `en-tomorrow` — en-zh

- 源文：`tomorrow`
- 审阅提示：明天。
- 原始输出：`明天`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 明天。

### 风险用例 `en-past` — en-zh

- 源文：`I went to the bank yesterday.`
- 审阅提示：昨天去了银行，保留过去时间。
- 原始输出：`我昨天去银行。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 昨天去银行，过去时间保留。

### 风险用例 `en-ambiguous` — en-zh

- 源文：`bank`
- 审阅提示：孤立多义词，记录输出，不武断认定只有一个正确词义。
- 原始输出：`银行`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 银行是合法义项之一。

### 风险用例 `en-names` — en-zh

- 源文：`Alice will meet Bob in Beijing on Friday.`
- 审阅提示：保留两个人名、北京、星期五和见面关系，音译可以变化。
- 原始输出：`艾丽丝星期五将在北京见面。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`（需人工判读）
- 未命中：`one-of:鲍勃|包勃|博布`
- 人工审阅：`fail` — 丢失 Bob，输出仍成为候选；人名对齐检查尚未接入加固层。

### 风险用例 `en-word` — en-zh

- 源文：`meeting`
- 审阅提示：会议或会面，不能把单词翻译当完整义项词典。
- 原始输出：`会议`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 会议。

### 风险用例 `en-sentence` — en-zh

- 源文：`I have a meeting tomorrow.`
- 审阅提示：明天有会，不更改主体或日期。
- 原始输出：`我明天会见。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 未命中：`one-of:会议|开会`
- 命中禁词：`会见`
- 人工审阅：`fail` — “我明天会见”把会议变成会见，主体关系改变且进入候选。

### 风险用例 `en-url` — en-zh

- 源文：`Open https://example.com/a?x=1.`
- 审阅提示：网址需原样保留，记录模型是否擅自改写。
- 原始输出：`打开 https://example.com/a?x=1。`
- 加固判定：`fallback-original` / `script`
- 机械语义：`pass`
- 人工审阅：`pass` — 网址原样保留；脚本校验把 URL 的拉丁字符计入而误判回退，属安全处置但暴露误报。

### 风险用例 `en-negation` — en-zh

- 源文：`Do not send the email.`
- 审阅提示：保留禁止发送的否定含义。
- 原始输出：`不要发送电子邮件。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 否定发送保留。

### 风险用例 `en-unknown` — en-zh

- 源文：`meeetingg`
- 审阅提示：观察是否编造可信译文，不能凭生成成功自动提交。
- 原始输出：`同行`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留未知词；模型输出“同行”不进入候选。

### 风险用例 `en-typo-sentence` — en-zh

- 源文：`I have a metting tomorrow.`
- 审阅提示：观察错拼是否仍能译出明天开会，不代表原词正确。
- 原始输出：`我明天有一个聚会。`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留错拼句；模型猜成“聚会”不进入候选。

### 门槛

- usableRate: `0.9162`
- usableRatePass: `false`
- latencyBudget: `"pass"`
- latencyOverBudget: `{"count": 1, "cases": ["cf-e-sent-06"], "note": "任何应译请求（成功或失败）等待超过该输入长度档预算都会记录在案；有超限记录不得报通过。"}`
- unhandledRisk: `["en-names", "en-sentence", "zh-bank", "zh-condition", "zh-phrase"]`
- errorReleased: `{"count": 105, "cases": ["cf-e-brand-05", "cf-e-name-07", "cf-e-name-08", "cf-e-phrase-05", "cf-e-phrase-07", "cf-e-phrase-10", "cf-e-sent-01", "cf-e-sent-03", "cf-e-sent-05", "cf-e-sent-06", "cf-e-time-05", "cf-e-time-07", "cf-e-time-08", "cf-z-brand-01", "cf-z-brand-03", "cf-z-brand-04", "cf-z-brand-05", "cf-z-name-04", "cf-z-name-07", "cf-z-phrase-01", "cf-z-phrase-04", "cf-z-phrase-05", "cf-z-phrase-08", "cf-z-phrase-09", "cf-z-phrase-10", "cf-z-phrase-11", "cf-z-sent-01", "cf-z-sent-03", "cf-z-time-08", "cf-z-word-07", "cf-z-word-10", "en-names", "en-sentence", "enToZh-002", "enToZh-010", "enToZh-018", "enToZh-024", "enToZh-027", "enToZh-028", "enToZh-033", "enToZh-035", "enToZh-040", "enToZh-043", "enToZh-045", "enToZh-056", "enToZh-057", "enToZh-062", "enToZh-064", "enToZh-073", "enToZh-075", "enToZh-080", "enToZh-081", "enToZh-083", "enToZh-084", "se-e-brand-02", "se-e-brand-03", "se-e-brand-05", "se-e-name-02", "se-e-name-06", "se-e-phrase-06", "se-e-phrase-08", "se-e-phrase-10", "se-e-phrase-11", "se-e-phrase-14", "se-e-phrase-15", "se-e-time-01", "se-e-time-07", "se-z-brand-04", "se-z-name-02", "se-z-name-05", "se-z-phrase-03", "se-z-phrase-05", "se-z-phrase-09", "se-z-phrase-10", "se-z-phrase-12", "se-z-phrase-13", "se-z-time-07", "se-z-time-08", "zh-bank", "zh-condition", "zh-phrase", "zhToEn-002", "zhToEn-003", "zhToEn-004", "zhToEn-006", "zhToEn-010", "zhToEn-028", "zhToEn-033", "zhToEn-035", "zhToEn-037", "zhToEn-040", "zhToEn-047", "zhToEn-055", "zhToEn-058", "zhToEn-061", "zhToEn-064", "zhToEn-073", "zhToEn-075", "zhToEn-078", "zhToEn-080", "zhToEn-081", "zhToEn-084", "zhToEn-086", "zhToEn-087", "zhToEn-089"]}`
- manualPending: `[]`
- reviewCoverage: `{"required": 360, "reviewFile": "present", "missingIds": [], "missingCount": 0, "complete": true, "note": "每个进入候选的应译用例都必须有人工审阅记录；缺失审阅不能报完成。"}`
- verdict: `"fail-unhandled-risk"`

## quickmt

### 套件 `confirm` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 79 | 16 | 0 | 63 | 21 | 0 | 0 |
- 错误放行：`cf-z-brand-01`、`cf-z-brand-02`、`cf-z-brand-04`、`cf-z-brand-05`、`cf-z-name-01`、`cf-z-name-05`、`cf-z-phrase-01`、`cf-z-phrase-02`、`cf-z-phrase-03`、`cf-z-phrase-04`、`cf-z-phrase-05`、`cf-z-phrase-06`、`cf-z-phrase-07`、`cf-z-phrase-08`、`cf-z-phrase-09`、`cf-z-phrase-11`、`cf-z-phrase-12`、`cf-z-sent-03`、`cf-z-time-01`、`cf-z-time-02`、`cf-z-time-03`、`cf-z-time-04`、`cf-z-time-05`、`cf-z-time-06`、`cf-z-time-07`、`cf-z-time-08`、`cf-z-word-01`、`cf-z-word-02`、`cf-z-word-04`、`cf-z-word-05`、`cf-z-word-06`、`cf-z-word-07`、`cf-z-word-09`、`cf-z-word-10`、`cf-e-brand-03`、`cf-e-name-01`、`cf-e-name-02`、`cf-e-name-04`、`cf-e-name-05`、`cf-e-phrase-03`…
- 仅安全回退：`cf-z-name-04`、`cf-z-phrase-10`、`cf-z-word-03`、`cf-z-word-08`、`cf-e-brand-01`、`cf-e-brand-02`、`cf-e-brand-04`、`cf-e-brand-05`、`cf-e-brand-06`、`cf-e-name-03`、`cf-e-name-06`、`cf-e-name-07`、`cf-e-name-08`、`cf-e-phrase-01`、`cf-e-phrase-02`、`cf-e-phrase-06`、`cf-e-phrase-07`、`cf-e-phrase-08`、`cf-e-phrase-09`、`cf-e-phrase-10`、`cf-e-word-08`

### 套件 `holdout` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 180 | 153 | 97 | 0 | 56 | 27 | 0 | 20 |
- 错误放行：`zhToEn-002`、`zhToEn-003`、`zhToEn-004`、`zhToEn-006`、`zhToEn-007`、`zhToEn-011`、`zhToEn-014`、`zhToEn-015`、`zhToEn-017`、`zhToEn-018`、`zhToEn-019`、`zhToEn-020`、`zhToEn-021`、`zhToEn-024`、`zhToEn-026`、`zhToEn-031`、`zhToEn-032`、`zhToEn-033`、`zhToEn-034`、`zhToEn-040`、`zhToEn-041`、`zhToEn-048`、`zhToEn-058`、`zhToEn-061`、`zhToEn-073`、`zhToEn-075`、`zhToEn-079`、`zhToEn-083`、`enToZh-001`、`enToZh-002`、`enToZh-003`、`enToZh-005`、`enToZh-006`、`enToZh-007`、`enToZh-008`、`enToZh-009`、`enToZh-010`、`enToZh-011`、`enToZh-012`、`enToZh-013`…
- 仅安全回退：`zhToEn-001`、`zhToEn-009`、`zhToEn-010`、`zhToEn-012`、`zhToEn-082`、`zhToEn-085`、`zhToEn-090`、`enToZh-021`、`enToZh-023`、`enToZh-024`、`enToZh-025`、`enToZh-026`、`enToZh-028`、`enToZh-031`、`enToZh-032`、`enToZh-033`、`enToZh-038`、`enToZh-042`、`enToZh-045`、`enToZh-049`、`enToZh-051`、`enToZh-052`、`enToZh-073`、`enToZh-082`、`enToZh-083`、`enToZh-085`、`enToZh-090`

### 套件 `risk` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 29 | 25 | 13 | 0 | 12 | 4 | 0 | 3 |
- 错误放行：`zh-bank`、`zh-contrast`、`zh-phrase`、`zh-sentence`、`zh-time`、`zh-tomorrow`、`zh-word`、`en-mixed`、`en-negation`、`en-time`、`en-tomorrow`、`en-word`
- 仅安全回退：`zh-url`、`en-greeting`、`en-phrase`、`en-url`

### 套件 `short` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 76 | 59 | 19 | 0 | 40 | 17 | 0 | 12 |
- 错误放行：`se-z-brand-06`、`se-z-name-02`、`se-z-name-03`、`se-z-name-04`、`se-z-name-05`、`se-z-name-08`、`se-z-phrase-01`、`se-z-phrase-03`、`se-z-phrase-04`、`se-z-phrase-05`、`se-z-phrase-06`、`se-z-phrase-08`、`se-z-phrase-09`、`se-z-phrase-10`、`se-z-phrase-11`、`se-z-phrase-13`、`se-z-phrase-14`、`se-z-phrase-15`、`se-z-phrase-16`、`se-z-time-02`、`se-z-time-04`、`se-z-time-05`、`se-z-time-07`、`se-e-brand-01`、`se-e-brand-02`、`se-e-brand-05`、`se-e-name-03`、`se-e-name-08`、`se-e-phrase-04`、`se-e-phrase-05`、`se-e-phrase-06`、`se-e-phrase-10`、`se-e-phrase-11`、`se-e-phrase-14`、`se-e-phrase-15`、`se-e-time-01`、`se-e-time-02`、`se-e-time-04`、`se-e-time-06`、`se-e-time-07`
- 仅安全回退：`se-z-brand-01`、`se-z-brand-03`、`se-z-name-01`、`se-e-brand-04`、`se-e-name-01`、`se-e-name-02`、`se-e-name-04`、`se-e-name-07`、`se-e-phrase-01`、`se-e-phrase-02`、`se-e-phrase-07`、`se-e-phrase-08`、`se-e-phrase-09`、`se-e-phrase-12`、`se-e-phrase-13`、`se-e-time-03`、`se-e-time-05`

### 风险用例 `zh-mixed` — zh-en

- 源文：`请在星期五之前检查 Gogaku v2.1。`
- 审阅提示：保留品牌、版本和星期五之前。
- 原始输出：`Please check the Gogaku v2.1 by Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — Gogaku、v2.1、星期五之前保留；多一个 the 不影响意义。

### 风险用例 `zh-url` — zh-en

- 源文：`请打开 https://example.com/a?x=1。`
- 审阅提示：网址需原样保留。
- 原始输出：`Please open the https://example.com/a?x=1`
- 加固判定：`fallback-original` / `length`
- 机械语义：`pass`
- 人工审阅：`pass` — 网址原样保留；长度比率误判回退，属安全处置。

### 风险用例 `zh-bank` — zh-en

- 源文：`银行`
- 审阅提示：bank。
- 原始输出：`Bank of the Bank`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`of the`
- 人工审阅：`fail` — Bank of the Bank 不是“银行”的可用词候选。

### 风险用例 `zh-sentence` — zh-en

- 源文：`我明天有个会。`
- 审阅提示：I have a meeting tomorrow，保留主体和明天。
- 原始输出：`I have a group tomorrow.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 未命中：`one-of:meeting`
- 人工审阅：`fail` — “我明天有个会”被译成 I have a group tomorrow，会议变 group。

### 风险用例 `zh-tomorrow` — zh-en

- 源文：`明天`
- 审阅提示：tomorrow。
- 原始输出：`Tomorrow the future`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`future`
- 人工审阅：`fail` — Tomorrow the future 加入原文没有的“未来”。

### 风险用例 `zh-negation` — zh-en

- 源文：`不要发送邮件。`
- 审阅提示：保留不要发送，不得译成发送。
- 原始输出：`Do not send mail.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 否定发送保留。

### 风险用例 `zh-word` — zh-en

- 源文：`会议`
- 审阅提示：meeting 或 conference，孤立词无唯一义项。
- 原始输出：`Conferences by the`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`by the`
- 人工审阅：`fail` — Conferences by the 是残句，不是“会议”的可用词候选。

### 风险用例 `zh-condition` — zh-en

- 源文：`如果下雨，我们就取消会议。`
- 审阅提示：保留条件与取消会议。
- 原始输出：`If it rains, we cancel the meeting.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 条件、下雨、取消会议均保留。

### 风险用例 `zh-phrase` — zh-en

- 源文：`开会`
- 审阅提示：have/attend a meeting 等表达，不要求逐字一致。
- 原始输出：`Meetings for a`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`fail` — Meetings for a 是残句，不满足“开会”的表达候选。

### 风险用例 `zh-not-yet` — zh-en

- 源文：`我还没吃饭。`
- 审阅提示：保留尚未吃饭，而非已吃或习惯性不吃。
- 原始输出：`I haven't eaten yet.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — haven't eaten yet 保留尚未。

### 风险用例 `zh-greeting` — zh-en

- 源文：`早上好`
- 审阅提示：good morning。
- 原始输出：`Good morning to you.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — Good morning to you. 语义等价。

### 风险用例 `zh-time` — zh-en

- 源文：`明天下午三点开会。`
- 审阅提示：明天下午三点，不能改日期和时间。
- 原始输出：`The cast meets tomorrow at 3pm.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`fail` — The cast meets tomorrow at 3pm 把“开会”变成 cast meets，主体/动作偏移。

### 风险用例 `zh-past` — zh-en

- 源文：`我昨天去了银行。`
- 审阅提示：保留昨天和去银行。
- 原始输出：`I went to the bank yesterday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — yesterday 和去银行保留。

### 风险用例 `zh-contrast` — zh-en

- 源文：`他不在上海，在北京。`
- 审阅提示：保留不在上海、在北京的对比。
- 原始输出：`He's not in Shanghai, in Beijing.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`fail` — He's not in Shanghai, in Beijing 缺对比连接且语法不完整；虽可猜意，不作为可直接使用的候选。

### 风险用例 `zh-names` — zh-en

- 源文：`爱丽丝星期五在北京见鲍勃。`
- 审阅提示：保留人名、地点、星期五与见面关系。
- 原始输出：`Alice meets Bob in Beijing on Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — Alice、Bob、北京、星期五、见面关系保留。

### 风险用例 `zh-long` — zh-en

- 源文：`会议改到下周二上午十点半，请不要邀请爱丽丝。`
- 审阅提示：保留下周二上午十点半和不要邀请。
- 原始输出：`The meeting is changed to 10:30 a.m. next Tuesday, please don't invite Alice.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 10:30 a.m. 下周二、否定、Alice 均保留。

### 风险用例 `en-unknown` — en-zh

- 源文：`meeetingg`
- 审阅提示：观察是否编造可信译文，不能凭生成成功自动提交。
- 原始输出：`美泰克 美泰克`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留未知词；模型重复“美泰克”不进入候选。

### 风险用例 `en-typo-word` — en-zh

- 源文：`metting`
- 审阅提示：观察能否理解拼写偏差，不保证必须猜对。
- 原始输出：`美泰简介`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留错拼；模型“美泰简介”不进入候选。

### 风险用例 `en-tomorrow` — en-zh

- 源文：`tomorrow`
- 审阅提示：明天。
- 原始输出：`明天 开始`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`开始`
- 人工审阅：`fail` — “明天 开始”加入原文没有的“开始”。

### 风险用例 `en-sentence` — en-zh

- 源文：`I have a meeting tomorrow.`
- 审阅提示：明天有会，不更改主体或日期。
- 原始输出：`明天我有个会议`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 明天我有个会议，主体和日期保留。

### 风险用例 `en-ambiguous` — en-zh

- 源文：`bank`
- 审阅提示：孤立多义词，记录输出，不武断认定只有一个正确词义。
- 原始输出：`银行业务`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 银行业务是合法义项之一。

### 风险用例 `en-negation` — en-zh

- 源文：`Do not send the email.`
- 审阅提示：保留禁止发送的否定含义。
- 原始输出：`不要发送邮件。 电子邮件`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`fail` — 否定发送保留，但尾部多出“电子邮件”残片；不应作为可直接使用的候选。

### 风险用例 `en-word` — en-zh

- 源文：`meeting`
- 审阅提示：会议或会面，不能把单词翻译当完整义项词典。
- 原始输出：`会议介绍`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`介绍`
- 人工审阅：`fail` — 会议介绍加入原文没有的“介绍”，不是“meeting”的直接词候选。

### 风险用例 `en-url` — en-zh

- 源文：`Open https://example.com/a?x=1.`
- 审阅提示：网址需原样保留，记录模型是否擅自改写。
- 原始输出：`打开 https://example.com/a?x=1. 支持`
- 加固判定：`fallback-original` / `script`
- 机械语义：`pass`
- 人工审阅：`pass` — 网址原样保留；尾部“支持”残片触发脚本回退，属安全处置。

### 风险用例 `en-phrase` — en-zh

- 源文：`attend a meeting`
- 审阅提示：参加会议。
- 原始输出：`参加会议 会议`
- 加固判定：`fallback-original` / `repeat`
- 机械语义：`pass`
- 人工审阅：`pass` — “参加会议 会议”重复由加固回退原文。

### 风险用例 `en-mixed` — en-zh

- 源文：`Please review Gogaku v2.1 before Friday.`
- 审阅提示：保留品牌、版本和星期五之前的时间关系。
- 原始输出：`请在周五之前查看Gogaku v2.1。 评分`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`评分`
- 人工审阅：`fail` — Gogaku、v2.1、星期五保留，但尾部多出“评分”残片。

### 风险用例 `en-greeting` — en-zh

- 源文：`good morning`
- 审阅提示：早上好。
- 原始输出：`早上好 好 好 早 好 好 好 早 好 好 好 好 早 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 早 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 早 好 好 好 好 好 好 好 好 好 好 好 好 好 好`
- 加固判定：`fallback-original` / `truncated`
- 机械语义：`pass`
- 人工审阅：`pass` — “早上好 好 好…”复读由加固判为截断/重复并回退。

### 风险用例 `en-time` — en-zh

- 源文：`The meeting is at 3 p.m. tomorrow.`
- 审阅提示：明天下午三点，不能改时间。
- 原始输出：`明天下午3点开会 大家好`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`（需人工判读）
- 命中禁词：`大家好`
- 人工审阅：`fail` — 明天下午三点保留，但尾部多出“大家好”。

### 风险用例 `en-typo-sentence` — en-zh

- 源文：`I have a metting tomorrow.`
- 审阅提示：观察错拼是否仍能译出明天开会，不代表原词正确。
- 原始输出：`明天我有个药剂`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留错拼句；模型“药剂”不进入候选。

### 风险用例 `en-long` — en-zh

- 源文：`The meeting has been moved to next Tuesday at 10:30 a.m. Please do not invite Alice.`
- 审阅提示：保留下周二上午十点半和不要邀请 Alice 的否定。
- 原始输出：`会议已转移到下周二上午10:30。 请不要邀请Alice。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 下周二上午10:30、否定、Alice 均保留。

### 风险用例 `en-names` — en-zh

- 源文：`Alice will meet Bob in Beijing on Friday.`
- 审阅提示：保留两个人名、北京、星期五和见面关系，音译可以变化。
- 原始输出：`爱丽丝将于周五在北京与鲍勃见面。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 爱丽丝、鲍勃、北京、星期五和见面关系保留。

### 风险用例 `en-past` — en-zh

- 源文：`I went to the bank yesterday.`
- 审阅提示：昨天去了银行，保留过去时间。
- 原始输出：`昨天我去了银行。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 昨天和银行保留。

### 门槛

- usableRate: `0.7173`
- usableRatePass: `false`
- latencyBudget: `"pass"`
- latencyOverBudget: `{"count": 25, "cases": ["cf-e-phrase-07", "cf-z-word-08", "en-greeting", "enToZh-025", "se-e-phrase-01"], "note": "任何应译请求（成功或失败）等待超过该输入长度档预算都会记录在案；有超限记录不得报通过。"}`
- unhandledRisk: `["en-mixed", "en-negation", "en-time", "en-tomorrow", "en-word", "zh-bank", "zh-contrast", "zh-phrase", "zh-sentence", "zh-time", "zh-tomorrow", "zh-word"]`
- errorReleased: `{"count": 171, "cases": ["cf-e-brand-03", "cf-e-name-01", "cf-e-name-02", "cf-e-name-04", "cf-e-name-05", "cf-e-phrase-03", "cf-e-phrase-04", "cf-e-phrase-05", "cf-e-phrase-11", "cf-e-phrase-12", "cf-e-sent-01", "cf-e-sent-03", "cf-e-time-01", "cf-e-time-02", "cf-e-time-03", "cf-e-time-04", "cf-e-time-05", "cf-e-time-06", "cf-e-time-07", "cf-e-time-08", "cf-e-word-01", "cf-e-word-02", "cf-e-word-03", "cf-e-word-04", "cf-e-word-05", "cf-e-word-06", "cf-e-word-07", "cf-e-word-09", "cf-e-word-10", "cf-z-brand-01", "cf-z-brand-02", "cf-z-brand-04", "cf-z-brand-05", "cf-z-name-01", "cf-z-name-05", "cf-z-phrase-01", "cf-z-phrase-02", "cf-z-phrase-03", "cf-z-phrase-04", "cf-z-phrase-05", "cf-z-phrase-06", "cf-z-phrase-07", "cf-z-phrase-08", "cf-z-phrase-09", "cf-z-phrase-11", "cf-z-phrase-12", "cf-z-sent-03", "cf-z-time-01", "cf-z-time-02", "cf-z-time-03", "cf-z-time-04", "cf-z-time-05", "cf-z-time-06", "cf-z-time-07", "cf-z-time-08", "cf-z-word-01", "cf-z-word-02", "cf-z-word-04", "cf-z-word-05", "cf-z-word-06", "cf-z-word-07", "cf-z-word-09", "cf-z-word-10", "en-mixed", "en-negation", "en-time", "en-tomorrow", "en-word", "enToZh-001", "enToZh-002", "enToZh-003", "enToZh-005", "enToZh-006", "enToZh-007", "enToZh-008", "enToZh-009", "enToZh-010", "enToZh-011", "enToZh-012", "enToZh-013", "enToZh-014", "enToZh-015", "enToZh-017", "enToZh-018", "enToZh-019", "enToZh-020", "enToZh-022", "enToZh-027", "enToZh-029", "enToZh-030", "enToZh-036", "enToZh-039", "enToZh-040", "enToZh-054", "enToZh-062", "enToZh-084", "se-e-brand-01", "se-e-brand-02", "se-e-brand-05", "se-e-name-03", "se-e-name-08", "se-e-phrase-04", "se-e-phrase-05", "se-e-phrase-06", "se-e-phrase-10", "se-e-phrase-11", "se-e-phrase-14", "se-e-phrase-15", "se-e-time-01", "se-e-time-02", "se-e-time-04", "se-e-time-06", "se-e-time-07", "se-z-brand-06", "se-z-name-02", "se-z-name-03", "se-z-name-04", "se-z-name-05", "se-z-name-08", "se-z-phrase-01", "se-z-phrase-03", "se-z-phrase-04", "se-z-phrase-05", "se-z-phrase-06", "se-z-phrase-08", "se-z-phrase-09", "se-z-phrase-10", "se-z-phrase-11", "se-z-phrase-13", "se-z-phrase-14", "se-z-phrase-15", "se-z-phrase-16", "se-z-time-02", "se-z-time-04", "se-z-time-05", "se-z-time-07", "zh-bank", "zh-contrast", "zh-phrase", "zh-sentence", "zh-time", "zh-tomorrow", "zh-word", "zhToEn-002", "zhToEn-003", "zhToEn-004", "zhToEn-006", "zhToEn-007", "zhToEn-011", "zhToEn-014", "zhToEn-015", "zhToEn-017", "zhToEn-018", "zhToEn-019", "zhToEn-020", "zhToEn-021", "zhToEn-024", "zhToEn-026", "zhToEn-031", "zhToEn-032", "zhToEn-033", "zhToEn-034", "zhToEn-040", "zhToEn-041", "zhToEn-048", "zhToEn-058", "zhToEn-061", "zhToEn-073", "zhToEn-075", "zhToEn-079", "zhToEn-083"]}`
- manualPending: `[]`
- reviewCoverage: `{"required": 316, "reviewFile": "present", "missingIds": [], "missingCount": 0, "complete": true, "note": "每个进入候选的应译用例都必须有人工审阅记录；缺失审阅不能报完成。"}`
- verdict: `"fail-unhandled-risk"`

