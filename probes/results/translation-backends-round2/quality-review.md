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
| 100 | 95 | 0 | 95 | 0 | 5 | 0 | 0 |
- 语义待审：`cf-z-brand-01`、`cf-z-brand-02`、`cf-z-brand-03`、`cf-z-brand-04`、`cf-z-brand-05`、`cf-z-brand-06`、`cf-z-name-01`、`cf-z-name-02`、`cf-z-name-03`、`cf-z-name-04`、`cf-z-name-05`、`cf-z-name-06`、`cf-z-name-07`、`cf-z-name-08`、`cf-z-phrase-01`、`cf-z-phrase-02`、`cf-z-phrase-03`、`cf-z-phrase-04`、`cf-z-phrase-05`、`cf-z-phrase-06`、`cf-z-phrase-07`、`cf-z-phrase-08`、`cf-z-phrase-09`、`cf-z-phrase-10`、`cf-z-phrase-11`、`cf-z-phrase-12`、`cf-z-sent-01`、`cf-z-sent-02`、`cf-z-sent-03`、`cf-z-sent-04`、`cf-z-sent-05`、`cf-z-sent-06`、`cf-z-time-01`、`cf-z-time-02`、`cf-z-time-03`、`cf-z-time-04`、`cf-z-time-05`、`cf-z-time-06`、`cf-z-time-07`、`cf-z-time-08`…
- 仅安全回退：`cf-e-brand-01`、`cf-e-brand-02`、`cf-e-brand-03`、`cf-e-brand-04`、`cf-e-brand-06`

### 套件 `holdout` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 180 | 173 | 0 | 173 | 0 | 7 | 0 | 20 |
- 语义待审：`zhToEn-001`、`zhToEn-002`、`zhToEn-003`、`zhToEn-004`、`zhToEn-005`、`zhToEn-006`、`zhToEn-007`、`zhToEn-008`、`zhToEn-009`、`zhToEn-010`、`zhToEn-011`、`zhToEn-012`、`zhToEn-013`、`zhToEn-014`、`zhToEn-015`、`zhToEn-016`、`zhToEn-017`、`zhToEn-018`、`zhToEn-019`、`zhToEn-020`、`zhToEn-021`、`zhToEn-022`、`zhToEn-023`、`zhToEn-024`、`zhToEn-025`、`zhToEn-026`、`zhToEn-027`、`zhToEn-028`、`zhToEn-029`、`zhToEn-030`、`zhToEn-031`、`zhToEn-032`、`zhToEn-033`、`zhToEn-034`、`zhToEn-035`、`zhToEn-036`、`zhToEn-037`、`zhToEn-038`、`zhToEn-039`、`zhToEn-040`…
- 仅安全回退：`zhToEn-057`、`zhToEn-082`、`zhToEn-085`、`zhToEn-090`、`enToZh-082`、`enToZh-085`、`enToZh-090`

### 套件 `risk` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 29 | 25 | 0 | 24 | 1 | 4 | 0 | 3 |
- 错误放行：`en-sentence`
- 语义待审：`zh-bank`、`zh-condition`、`zh-contrast`、`zh-greeting`、`zh-mixed`、`zh-names`、`zh-negation`、`zh-not-yet`、`zh-past`、`zh-phrase`、`zh-sentence`、`zh-time`、`zh-tomorrow`、`zh-word`、`en-ambiguous`、`en-greeting`、`en-mixed`、`en-names`、`en-negation`、`en-past`、`en-phrase`、`en-time`、`en-tomorrow`、`en-word`
- 仅安全回退：`zh-long`、`zh-url`、`en-long`、`en-url`

### 套件 `short` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 76 | 67 | 0 | 67 | 0 | 9 | 0 | 12 |
- 语义待审：`se-z-brand-01`、`se-z-brand-02`、`se-z-brand-04`、`se-z-brand-05`、`se-z-name-01`、`se-z-name-02`、`se-z-name-03`、`se-z-name-04`、`se-z-name-05`、`se-z-name-06`、`se-z-name-07`、`se-z-name-08`、`se-z-phrase-01`、`se-z-phrase-02`、`se-z-phrase-03`、`se-z-phrase-04`、`se-z-phrase-05`、`se-z-phrase-06`、`se-z-phrase-07`、`se-z-phrase-08`、`se-z-phrase-09`、`se-z-phrase-10`、`se-z-phrase-11`、`se-z-phrase-12`、`se-z-phrase-13`、`se-z-phrase-14`、`se-z-phrase-15`、`se-z-phrase-16`、`se-z-time-02`、`se-z-time-03`、`se-z-time-04`、`se-z-time-05`、`se-z-time-06`、`se-z-time-07`、`se-z-time-08`、`se-e-brand-02`、`se-e-brand-03`、`se-e-brand-05`、`se-e-name-01`、`se-e-name-02`…
- 仅安全回退：`se-z-brand-03`、`se-z-brand-06`、`se-z-time-01`、`se-e-brand-01`、`se-e-brand-04`、`se-e-brand-06`、`se-e-time-02`、`se-e-time-03`、`se-e-time-04`

### 风险用例 `zh-not-yet` — zh-en

- 源文：`我还没吃饭。`
- 审阅提示：保留尚未吃饭，而非已吃或习惯性不吃。
- 原始输出：`I have not eaten yet.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-phrase` — zh-en

- 源文：`开会`
- 审阅提示：have/attend a meeting 等表达，不要求逐字一致。
- 原始输出：`The Meeting`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `zh-time` — zh-en

- 源文：`明天下午三点开会。`
- 审阅提示：明天下午三点，不能改日期和时间。
- 原始输出：`Meeting tomorrow at 3 pm.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-greeting` — zh-en

- 源文：`早上好`
- 审阅提示：good morning。
- 原始输出：`Good morning`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-contrast` — zh-en

- 源文：`他不在上海，在北京。`
- 审阅提示：保留不在上海、在北京的对比。
- 原始输出：`He is not in Shanghai, but in Beijing.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `zh-url` — zh-en

- 源文：`请打开 https://example.com/a?x=1。`
- 审阅提示：网址需原样保留。
- 原始输出：`Please open https://example.com/a?x=1`
- 加固判定：`fallback-original` / `length`
- 机械语义：`pass`

### 风险用例 `zh-bank` — zh-en

- 源文：`银行`
- 审阅提示：bank。
- 原始输出：`Banking`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-long` — zh-en

- 源文：`会议改到下周二上午十点半，请不要邀请爱丽丝。`
- 审阅提示：保留下周二上午十点半和不要邀请。
- 原始输出：`The meeting will be changed to 10 a.m. next Tuesday, please don’t invite Alice.`
- 加固判定：`fallback-original` / `time`
- 机械语义：`fail`（需人工判读）
- 未命中：`one-of:10:30|ten thirty|half past ten`、`one-of:not|don't|do not`

### 风险用例 `zh-tomorrow` — zh-en

- 源文：`明天`
- 审阅提示：tomorrow。
- 原始输出：`tomorrow`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-names` — zh-en

- 源文：`爱丽丝星期五在北京见鲍勃。`
- 审阅提示：保留人名、地点、星期五与见面关系。
- 原始输出：`Alice will meet Bob in Beijing on Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `zh-word` — zh-en

- 源文：`会议`
- 审阅提示：meeting 或 conference，孤立词无唯一义项。
- 原始输出：`Meeting`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-sentence` — zh-en

- 源文：`我明天有个会。`
- 审阅提示：I have a meeting tomorrow，保留主体和明天。
- 原始输出：`I have a meeting tomorrow.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-condition` — zh-en

- 源文：`如果下雨，我们就取消会议。`
- 审阅提示：保留条件与取消会议。
- 原始输出：`If it rains, we cancell the meeting.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `zh-negation` — zh-en

- 源文：`不要发送邮件。`
- 审阅提示：保留不要发送，不得译成发送。
- 原始输出：`Do not send mail.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-mixed` — zh-en

- 源文：`请在星期五之前检查 Gogaku v2.1。`
- 审阅提示：保留品牌、版本和星期五之前。
- 原始输出：`Please check Gogaku v2.1 before Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-past` — zh-en

- 源文：`我昨天去了银行。`
- 审阅提示：保留昨天和去银行。
- 原始输出：`I went to the bank yesterday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `en-mixed` — en-zh

- 源文：`Please review Gogaku v2.1 before Friday.`
- 审阅提示：保留品牌、版本和星期五之前的时间关系。
- 原始输出：`请在星期五之前查看Gogaku v2.1。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `en-phrase` — en-zh

- 源文：`attend a meeting`
- 审阅提示：参加会议。
- 原始输出：`參加會議`
- 加固判定：`candidate-normalized` / `traditional-normalized`
- 归一输出：`参加会议`
- 机械语义：`pass`

### 风险用例 `en-time` — en-zh

- 源文：`The meeting is at 3 p.m. tomorrow.`
- 审阅提示：明天下午三点，不能改时间。
- 原始输出：`会议是明天下午3点。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `en-greeting` — en-zh

- 源文：`good morning`
- 审阅提示：早上好。
- 原始输出：`早上好`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `en-long` — en-zh

- 源文：`The meeting has been moved to next Tuesday at 10:30 a.m. Please do not invite Alice.`
- 审阅提示：保留下周二上午十点半和不要邀请 Alice 的否定。
- 原始输出：`会议将于下周二下午10点30点,请不要邀请艾丽丝。`
- 加固判定：`fallback-original` / `time`
- 机械语义：`fail`（需人工判读）
- 未命中：`one-of:10:30|十点半|10点半`、`one-of:上午|早上`
- 命中禁词：`下午`

### 风险用例 `en-typo-word` — en-zh

- 源文：`metting`
- 审阅提示：观察能否理解拼写偏差，不保证必须猜对。
- 原始输出：`充足`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`

### 风险用例 `en-tomorrow` — en-zh

- 源文：`tomorrow`
- 审阅提示：明天。
- 原始输出：`明天`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `en-past` — en-zh

- 源文：`I went to the bank yesterday.`
- 审阅提示：昨天去了银行，保留过去时间。
- 原始输出：`我昨天去银行。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `en-ambiguous` — en-zh

- 源文：`bank`
- 审阅提示：孤立多义词，记录输出，不武断认定只有一个正确词义。
- 原始输出：`银行`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `en-names` — en-zh

- 源文：`Alice will meet Bob in Beijing on Friday.`
- 审阅提示：保留两个人名、北京、星期五和见面关系，音译可以变化。
- 原始输出：`艾丽丝星期五将在北京见面。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`（需人工判读）
- 未命中：`one-of:鲍勃|包勃|博布`

### 风险用例 `en-word` — en-zh

- 源文：`meeting`
- 审阅提示：会议或会面，不能把单词翻译当完整义项词典。
- 原始输出：`会议`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `en-sentence` — en-zh

- 源文：`I have a meeting tomorrow.`
- 审阅提示：明天有会，不更改主体或日期。
- 原始输出：`我明天会见。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 未命中：`one-of:会议|开会`
- 命中禁词：`会见`

### 风险用例 `en-url` — en-zh

- 源文：`Open https://example.com/a?x=1.`
- 审阅提示：网址需原样保留，记录模型是否擅自改写。
- 原始输出：`打开 https://example.com/a?x=1。`
- 加固判定：`fallback-original` / `script`
- 机械语义：`pass`

### 风险用例 `en-negation` — en-zh

- 源文：`Do not send the email.`
- 审阅提示：保留禁止发送的否定含义。
- 原始输出：`不要发送电子邮件。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `en-unknown` — en-zh

- 源文：`meeetingg`
- 审阅提示：观察是否编造可信译文，不能凭生成成功自动提交。
- 原始输出：`同行`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`

### 风险用例 `en-typo-sentence` — en-zh

- 源文：`I have a metting tomorrow.`
- 审阅提示：观察错拼是否仍能译出明天开会，不代表原词正确。
- 原始输出：`我明天有一个聚会。`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`

### 门槛

- usableRate: `0.9162`
- usableRatePass: `false`
- latencyBudget: `"pass"`
- latencyOverBudget: `{"count": 1, "cases": ["cf-e-sent-06"], "note": "任何应译请求（成功或失败）等待超过该输入长度档预算都会记录在案；有超限记录不得报通过。"}`
- unhandledRisk: `["en-sentence"]`
- errorReleased: `{"count": 1, "cases": ["en-sentence"]}`
- manualPending: `["cf-e-brand-05", "cf-e-name-01", "cf-e-name-02", "cf-e-name-03", "cf-e-name-04", "cf-e-name-05", "cf-e-name-06", "cf-e-name-07", "cf-e-name-08", "cf-e-phrase-01", "cf-e-phrase-02", "cf-e-phrase-03", "cf-e-phrase-04", "cf-e-phrase-05", "cf-e-phrase-06", "cf-e-phrase-07", "cf-e-phrase-08", "cf-e-phrase-09", "cf-e-phrase-10", "cf-e-phrase-11", "cf-e-phrase-12", "cf-e-sent-01", "cf-e-sent-02", "cf-e-sent-03", "cf-e-sent-04", "cf-e-sent-05", "cf-e-sent-06", "cf-e-time-01", "cf-e-time-02", "cf-e-time-03", "cf-e-time-04", "cf-e-time-05", "cf-e-time-06", "cf-e-time-07", "cf-e-time-08", "cf-e-word-01", "cf-e-word-02", "cf-e-word-03", "cf-e-word-04", "cf-e-word-05", "cf-e-word-06", "cf-e-word-07", "cf-e-word-08", "cf-e-word-09", "cf-e-word-10", "cf-z-brand-01", "cf-z-brand-02", "cf-z-brand-03", "cf-z-brand-04", "cf-z-brand-05", "cf-z-brand-06", "cf-z-name-01", "cf-z-name-02", "cf-z-name-03", "cf-z-name-04", "cf-z-name-05", "cf-z-name-06", "cf-z-name-07", "cf-z-name-08", "cf-z-phrase-01", "cf-z-phrase-02", "cf-z-phrase-03", "cf-z-phrase-04", "cf-z-phrase-05", "cf-z-phrase-06", "cf-z-phrase-07", "cf-z-phrase-08", "cf-z-phrase-09", "cf-z-phrase-10", "cf-z-phrase-11", "cf-z-phrase-12", "cf-z-sent-01", "cf-z-sent-02", "cf-z-sent-03", "cf-z-sent-04", "cf-z-sent-05", "cf-z-sent-06", "cf-z-time-01", "cf-z-time-02", "cf-z-time-03", "cf-z-time-04", "cf-z-time-05", "cf-z-time-06", "cf-z-time-07", "cf-z-time-08", "cf-z-word-01", "cf-z-word-02", "cf-z-word-03", "cf-z-word-04", "cf-z-word-05", "cf-z-word-06", "cf-z-word-07", "cf-z-word-08", "cf-z-word-09", "cf-z-word-10", "en-ambiguous", "en-greeting", "en-mixed", "en-names", "en-negation", "en-past", "en-phrase", "en-time", "en-tomorrow", "en-word", "enToZh-001", "enToZh-002", "enToZh-003", "enToZh-004", "enToZh-005", "enToZh-006", "enToZh-007", "enToZh-008", "enToZh-009", "enToZh-010", "enToZh-011", "enToZh-012", "enToZh-013", "enToZh-014", "enToZh-015", "enToZh-016", "enToZh-017", "enToZh-018", "enToZh-019", "enToZh-020", "enToZh-021", "enToZh-022", "enToZh-023", "enToZh-024", "enToZh-025", "enToZh-026", "enToZh-027", "enToZh-028", "enToZh-029", "enToZh-030", "enToZh-031", "enToZh-032", "enToZh-033", "enToZh-034", "enToZh-035", "enToZh-036", "enToZh-037", "enToZh-038", "enToZh-039", "enToZh-040", "enToZh-041", "enToZh-042", "enToZh-043", "enToZh-044", "enToZh-045", "enToZh-046", "enToZh-047", "enToZh-048", "enToZh-049", "enToZh-050", "enToZh-051", "enToZh-052", "enToZh-053", "enToZh-054", "enToZh-055", "enToZh-056", "enToZh-057", "enToZh-058", "enToZh-059", "enToZh-060", "enToZh-061", "enToZh-062", "enToZh-063", "enToZh-064", "enToZh-065", "enToZh-066", "enToZh-067", "enToZh-068", "enToZh-069", "enToZh-070", "enToZh-071", "enToZh-072", "enToZh-073", "enToZh-074", "enToZh-075", "enToZh-076", "enToZh-077", "enToZh-078", "enToZh-079", "enToZh-080", "enToZh-081", "enToZh-083", "enToZh-084", "enToZh-086", "enToZh-087", "enToZh-088", "enToZh-089", "se-e-brand-02", "se-e-brand-03", "se-e-brand-05", "se-e-name-01", "se-e-name-02", "se-e-name-03", "se-e-name-04", "se-e-name-05", "se-e-name-06", "se-e-name-07", "se-e-name-08", "se-e-phrase-01", "se-e-phrase-02", "se-e-phrase-03", "se-e-phrase-04", "se-e-phrase-05", "se-e-phrase-06", "se-e-phrase-07", "se-e-phrase-08", "se-e-phrase-09", "se-e-phrase-10", "se-e-phrase-11", "se-e-phrase-12", "se-e-phrase-13", "se-e-phrase-14", "se-e-phrase-15", "se-e-phrase-16", "se-e-time-01", "se-e-time-05", "se-e-time-06", "se-e-time-07", "se-e-time-08", "se-z-brand-01", "se-z-brand-02", "se-z-brand-04", "se-z-brand-05", "se-z-name-01", "se-z-name-02", "se-z-name-03", "se-z-name-04", "se-z-name-05", "se-z-name-06", "se-z-name-07", "se-z-name-08", "se-z-phrase-01", "se-z-phrase-02", "se-z-phrase-03", "se-z-phrase-04", "se-z-phrase-05", "se-z-phrase-06", "se-z-phrase-07", "se-z-phrase-08", "se-z-phrase-09", "se-z-phrase-10", "se-z-phrase-11", "se-z-phrase-12", "se-z-phrase-13", "se-z-phrase-14", "se-z-phrase-15", "se-z-phrase-16", "se-z-time-02", "se-z-time-03", "se-z-time-04", "se-z-time-05", "se-z-time-06", "se-z-time-07", "se-z-time-08", "zh-bank", "zh-condition", "zh-contrast", "zh-greeting", "zh-mixed", "zh-names", "zh-negation", "zh-not-yet", "zh-past", "zh-phrase", "zh-sentence", "zh-time", "zh-tomorrow", "zh-word", "zhToEn-001", "zhToEn-002", "zhToEn-003", "zhToEn-004", "zhToEn-005", "zhToEn-006", "zhToEn-007", "zhToEn-008", "zhToEn-009", "zhToEn-010", "zhToEn-011", "zhToEn-012", "zhToEn-013", "zhToEn-014", "zhToEn-015", "zhToEn-016", "zhToEn-017", "zhToEn-018", "zhToEn-019", "zhToEn-020", "zhToEn-021", "zhToEn-022", "zhToEn-023", "zhToEn-024", "zhToEn-025", "zhToEn-026", "zhToEn-027", "zhToEn-028", "zhToEn-029", "zhToEn-030", "zhToEn-031", "zhToEn-032", "zhToEn-033", "zhToEn-034", "zhToEn-035", "zhToEn-036", "zhToEn-037", "zhToEn-038", "zhToEn-039", "zhToEn-040", "zhToEn-041", "zhToEn-042", "zhToEn-043", "zhToEn-044", "zhToEn-045", "zhToEn-046", "zhToEn-047", "zhToEn-048", "zhToEn-049", "zhToEn-050", "zhToEn-051", "zhToEn-052", "zhToEn-053", "zhToEn-054", "zhToEn-055", "zhToEn-056", "zhToEn-058", "zhToEn-059", "zhToEn-060", "zhToEn-061", "zhToEn-062", "zhToEn-063", "zhToEn-064", "zhToEn-065", "zhToEn-066", "zhToEn-067", "zhToEn-068", "zhToEn-069", "zhToEn-070", "zhToEn-071", "zhToEn-072", "zhToEn-073", "zhToEn-074", "zhToEn-075", "zhToEn-076", "zhToEn-077", "zhToEn-078", "zhToEn-079", "zhToEn-080", "zhToEn-081", "zhToEn-083", "zhToEn-084", "zhToEn-086", "zhToEn-087", "zhToEn-088", "zhToEn-089"]`
- reviewCoverage: `{"required": 360, "reviewFile": "missing", "missingIds": ["cf-e-brand-05", "cf-e-name-01", "cf-e-name-02", "cf-e-name-03", "cf-e-name-04", "cf-e-name-05", "cf-e-name-06", "cf-e-name-07", "cf-e-name-08", "cf-e-phrase-01", "cf-e-phrase-02", "cf-e-phrase-03", "cf-e-phrase-04", "cf-e-phrase-05", "cf-e-phrase-06", "cf-e-phrase-07", "cf-e-phrase-08", "cf-e-phrase-09", "cf-e-phrase-10", "cf-e-phrase-11", "cf-e-phrase-12", "cf-e-sent-01", "cf-e-sent-02", "cf-e-sent-03", "cf-e-sent-04", "cf-e-sent-05", "cf-e-sent-06", "cf-e-time-01", "cf-e-time-02", "cf-e-time-03", "cf-e-time-04", "cf-e-time-05", "cf-e-time-06", "cf-e-time-07", "cf-e-time-08", "cf-e-word-01", "cf-e-word-02", "cf-e-word-03", "cf-e-word-04", "cf-e-word-05", "cf-e-word-06", "cf-e-word-07", "cf-e-word-08", "cf-e-word-09", "cf-e-word-10", "cf-z-brand-01", "cf-z-brand-02", "cf-z-brand-03", "cf-z-brand-04", "cf-z-brand-05", "cf-z-brand-06", "cf-z-name-01", "cf-z-name-02", "cf-z-name-03", "cf-z-name-04", "cf-z-name-05", "cf-z-name-06", "cf-z-name-07", "cf-z-name-08", "cf-z-phrase-01", "cf-z-phrase-02", "cf-z-phrase-03", "cf-z-phrase-04", "cf-z-phrase-05", "cf-z-phrase-06", "cf-z-phrase-07", "cf-z-phrase-08", "cf-z-phrase-09", "cf-z-phrase-10", "cf-z-phrase-11", "cf-z-phrase-12", "cf-z-sent-01", "cf-z-sent-02", "cf-z-sent-03", "cf-z-sent-04", "cf-z-sent-05", "cf-z-sent-06", "cf-z-time-01", "cf-z-time-02", "cf-z-time-03", "cf-z-time-04", "cf-z-time-05", "cf-z-time-06", "cf-z-time-07", "cf-z-time-08", "cf-z-word-01", "cf-z-word-02", "cf-z-word-03", "cf-z-word-04", "cf-z-word-05", "cf-z-word-06", "cf-z-word-07", "cf-z-word-08", "cf-z-word-09", "cf-z-word-10", "en-ambiguous", "en-greeting", "en-mixed", "en-names", "en-negation", "en-past", "en-phrase", "en-sentence", "en-time", "en-tomorrow", "en-word", "enToZh-001", "enToZh-002", "enToZh-003", "enToZh-004", "enToZh-005", "enToZh-006", "enToZh-007", "enToZh-008", "enToZh-009", "enToZh-010", "enToZh-011", "enToZh-012", "enToZh-013", "enToZh-014", "enToZh-015", "enToZh-016", "enToZh-017", "enToZh-018", "enToZh-019", "enToZh-020", "enToZh-021", "enToZh-022", "enToZh-023", "enToZh-024", "enToZh-025", "enToZh-026", "enToZh-027", "enToZh-028", "enToZh-029", "enToZh-030", "enToZh-031", "enToZh-032", "enToZh-033", "enToZh-034", "enToZh-035", "enToZh-036", "enToZh-037", "enToZh-038", "enToZh-039", "enToZh-040", "enToZh-041", "enToZh-042", "enToZh-043", "enToZh-044", "enToZh-045", "enToZh-046", "enToZh-047", "enToZh-048", "enToZh-049", "enToZh-050", "enToZh-051", "enToZh-052", "enToZh-053", "enToZh-054", "enToZh-055", "enToZh-056", "enToZh-057", "enToZh-058", "enToZh-059", "enToZh-060", "enToZh-061", "enToZh-062", "enToZh-063", "enToZh-064", "enToZh-065", "enToZh-066", "enToZh-067", "enToZh-068", "enToZh-069", "enToZh-070", "enToZh-071", "enToZh-072", "enToZh-073", "enToZh-074", "enToZh-075", "enToZh-076", "enToZh-077", "enToZh-078", "enToZh-079", "enToZh-080", "enToZh-081", "enToZh-083", "enToZh-084", "enToZh-086", "enToZh-087", "enToZh-088", "enToZh-089", "se-e-brand-02", "se-e-brand-03", "se-e-brand-05", "se-e-name-01", "se-e-name-02", "se-e-name-03", "se-e-name-04", "se-e-name-05", "se-e-name-06", "se-e-name-07", "se-e-name-08", "se-e-phrase-01", "se-e-phrase-02", "se-e-phrase-03", "se-e-phrase-04", "se-e-phrase-05", "se-e-phrase-06", "se-e-phrase-07", "se-e-phrase-08", "se-e-phrase-09", "se-e-phrase-10", "se-e-phrase-11", "se-e-phrase-12", "se-e-phrase-13", "se-e-phrase-14", "se-e-phrase-15", "se-e-phrase-16", "se-e-time-01", "se-e-time-05", "se-e-time-06", "se-e-time-07", "se-e-time-08", "se-z-brand-01", "se-z-brand-02", "se-z-brand-04", "se-z-brand-05", "se-z-name-01", "se-z-name-02", "se-z-name-03", "se-z-name-04", "se-z-name-05", "se-z-name-06", "se-z-name-07", "se-z-name-08", "se-z-phrase-01", "se-z-phrase-02", "se-z-phrase-03", "se-z-phrase-04", "se-z-phrase-05", "se-z-phrase-06", "se-z-phrase-07", "se-z-phrase-08", "se-z-phrase-09", "se-z-phrase-10", "se-z-phrase-11", "se-z-phrase-12", "se-z-phrase-13", "se-z-phrase-14", "se-z-phrase-15", "se-z-phrase-16", "se-z-time-02", "se-z-time-03", "se-z-time-04", "se-z-time-05", "se-z-time-06", "se-z-time-07", "se-z-time-08", "zh-bank", "zh-condition", "zh-contrast", "zh-greeting", "zh-mixed", "zh-names", "zh-negation", "zh-not-yet", "zh-past", "zh-phrase", "zh-sentence", "zh-time", "zh-tomorrow", "zh-word", "zhToEn-001", "zhToEn-002", "zhToEn-003", "zhToEn-004", "zhToEn-005", "zhToEn-006", "zhToEn-007", "zhToEn-008", "zhToEn-009", "zhToEn-010", "zhToEn-011", "zhToEn-012", "zhToEn-013", "zhToEn-014", "zhToEn-015", "zhToEn-016", "zhToEn-017", "zhToEn-018", "zhToEn-019", "zhToEn-020", "zhToEn-021", "zhToEn-022", "zhToEn-023", "zhToEn-024", "zhToEn-025", "zhToEn-026", "zhToEn-027", "zhToEn-028", "zhToEn-029", "zhToEn-030", "zhToEn-031", "zhToEn-032", "zhToEn-033", "zhToEn-034", "zhToEn-035", "zhToEn-036", "zhToEn-037", "zhToEn-038", "zhToEn-039", "zhToEn-040", "zhToEn-041", "zhToEn-042", "zhToEn-043", "zhToEn-044", "zhToEn-045", "zhToEn-046", "zhToEn-047", "zhToEn-048", "zhToEn-049", "zhToEn-050", "zhToEn-051", "zhToEn-052", "zhToEn-053", "zhToEn-054", "zhToEn-055", "zhToEn-056", "zhToEn-058", "zhToEn-059", "zhToEn-060", "zhToEn-061", "zhToEn-062", "zhToEn-063", "zhToEn-064", "zhToEn-065", "zhToEn-066", "zhToEn-067", "zhToEn-068", "zhToEn-069", "zhToEn-070", "zhToEn-071", "zhToEn-072", "zhToEn-073", "zhToEn-074", "zhToEn-075", "zhToEn-076", "zhToEn-077", "zhToEn-078", "zhToEn-079", "zhToEn-080", "zhToEn-081", "zhToEn-083", "zhToEn-084", "zhToEn-086", "zhToEn-087", "zhToEn-088", "zhToEn-089"], "missingCount": 360, "complete": false, "note": "每个进入候选的应译用例都必须有人工审阅记录；缺失审阅不能报完成。"}`
- verdict: `"fail-unhandled-risk"`

## quickmt

### 套件 `confirm` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 79 | 0 | 79 | 0 | 21 | 0 | 0 |
- 语义待审：`cf-z-brand-01`、`cf-z-brand-02`、`cf-z-brand-03`、`cf-z-brand-04`、`cf-z-brand-05`、`cf-z-brand-06`、`cf-z-name-01`、`cf-z-name-02`、`cf-z-name-03`、`cf-z-name-05`、`cf-z-name-06`、`cf-z-name-07`、`cf-z-name-08`、`cf-z-phrase-01`、`cf-z-phrase-02`、`cf-z-phrase-03`、`cf-z-phrase-04`、`cf-z-phrase-05`、`cf-z-phrase-06`、`cf-z-phrase-07`、`cf-z-phrase-08`、`cf-z-phrase-09`、`cf-z-phrase-11`、`cf-z-phrase-12`、`cf-z-sent-01`、`cf-z-sent-02`、`cf-z-sent-03`、`cf-z-sent-04`、`cf-z-sent-05`、`cf-z-sent-06`、`cf-z-time-01`、`cf-z-time-02`、`cf-z-time-03`、`cf-z-time-04`、`cf-z-time-05`、`cf-z-time-06`、`cf-z-time-07`、`cf-z-time-08`、`cf-z-word-01`、`cf-z-word-02`…
- 仅安全回退：`cf-z-name-04`、`cf-z-phrase-10`、`cf-z-word-03`、`cf-z-word-08`、`cf-e-brand-01`、`cf-e-brand-02`、`cf-e-brand-04`、`cf-e-brand-05`、`cf-e-brand-06`、`cf-e-name-03`、`cf-e-name-06`、`cf-e-name-07`、`cf-e-name-08`、`cf-e-phrase-01`、`cf-e-phrase-02`、`cf-e-phrase-06`、`cf-e-phrase-07`、`cf-e-phrase-08`、`cf-e-phrase-09`、`cf-e-phrase-10`、`cf-e-word-08`

### 套件 `holdout` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 180 | 153 | 0 | 153 | 0 | 27 | 0 | 20 |
- 语义待审：`zhToEn-002`、`zhToEn-003`、`zhToEn-004`、`zhToEn-005`、`zhToEn-006`、`zhToEn-007`、`zhToEn-008`、`zhToEn-011`、`zhToEn-013`、`zhToEn-014`、`zhToEn-015`、`zhToEn-016`、`zhToEn-017`、`zhToEn-018`、`zhToEn-019`、`zhToEn-020`、`zhToEn-021`、`zhToEn-022`、`zhToEn-023`、`zhToEn-024`、`zhToEn-025`、`zhToEn-026`、`zhToEn-027`、`zhToEn-028`、`zhToEn-029`、`zhToEn-030`、`zhToEn-031`、`zhToEn-032`、`zhToEn-033`、`zhToEn-034`、`zhToEn-035`、`zhToEn-036`、`zhToEn-037`、`zhToEn-038`、`zhToEn-039`、`zhToEn-040`、`zhToEn-041`、`zhToEn-042`、`zhToEn-043`、`zhToEn-044`…
- 仅安全回退：`zhToEn-001`、`zhToEn-009`、`zhToEn-010`、`zhToEn-012`、`zhToEn-082`、`zhToEn-085`、`zhToEn-090`、`enToZh-021`、`enToZh-023`、`enToZh-024`、`enToZh-025`、`enToZh-026`、`enToZh-028`、`enToZh-031`、`enToZh-032`、`enToZh-033`、`enToZh-038`、`enToZh-042`、`enToZh-045`、`enToZh-049`、`enToZh-051`、`enToZh-052`、`enToZh-073`、`enToZh-082`、`enToZh-083`、`enToZh-085`、`enToZh-090`

### 套件 `risk` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 29 | 25 | 0 | 18 | 7 | 4 | 0 | 3 |
- 错误放行：`zh-bank`、`zh-sentence`、`zh-tomorrow`、`zh-word`、`en-mixed`、`en-tomorrow`、`en-word`
- 语义待审：`zh-condition`、`zh-contrast`、`zh-greeting`、`zh-long`、`zh-mixed`、`zh-names`、`zh-negation`、`zh-not-yet`、`zh-past`、`zh-phrase`、`zh-time`、`en-ambiguous`、`en-long`、`en-names`、`en-negation`、`en-past`、`en-sentence`、`en-time`
- 仅安全回退：`zh-url`、`en-greeting`、`en-phrase`、`en-url`

### 套件 `short` 结果统计

| 应译 | 候选放行 | 语义合格 | 语义待审 | 错误放行 | 安全回退 | 运行错误 | 应保留 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 76 | 59 | 0 | 59 | 0 | 17 | 0 | 12 |
- 语义待审：`se-z-brand-02`、`se-z-brand-04`、`se-z-brand-05`、`se-z-brand-06`、`se-z-name-02`、`se-z-name-03`、`se-z-name-04`、`se-z-name-05`、`se-z-name-06`、`se-z-name-07`、`se-z-name-08`、`se-z-phrase-01`、`se-z-phrase-02`、`se-z-phrase-03`、`se-z-phrase-04`、`se-z-phrase-05`、`se-z-phrase-06`、`se-z-phrase-07`、`se-z-phrase-08`、`se-z-phrase-09`、`se-z-phrase-10`、`se-z-phrase-11`、`se-z-phrase-12`、`se-z-phrase-13`、`se-z-phrase-14`、`se-z-phrase-15`、`se-z-phrase-16`、`se-z-time-01`、`se-z-time-02`、`se-z-time-03`、`se-z-time-04`、`se-z-time-05`、`se-z-time-06`、`se-z-time-07`、`se-z-time-08`、`se-e-brand-01`、`se-e-brand-02`、`se-e-brand-03`、`se-e-brand-05`、`se-e-brand-06`…
- 仅安全回退：`se-z-brand-01`、`se-z-brand-03`、`se-z-name-01`、`se-e-brand-04`、`se-e-name-01`、`se-e-name-02`、`se-e-name-04`、`se-e-name-07`、`se-e-phrase-01`、`se-e-phrase-02`、`se-e-phrase-07`、`se-e-phrase-08`、`se-e-phrase-09`、`se-e-phrase-12`、`se-e-phrase-13`、`se-e-time-03`、`se-e-time-05`

### 风险用例 `zh-mixed` — zh-en

- 源文：`请在星期五之前检查 Gogaku v2.1。`
- 审阅提示：保留品牌、版本和星期五之前。
- 原始输出：`Please check the Gogaku v2.1 by Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-url` — zh-en

- 源文：`请打开 https://example.com/a?x=1。`
- 审阅提示：网址需原样保留。
- 原始输出：`Please open the https://example.com/a?x=1`
- 加固判定：`fallback-original` / `length`
- 机械语义：`pass`

### 风险用例 `zh-bank` — zh-en

- 源文：`银行`
- 审阅提示：bank。
- 原始输出：`Bank of the Bank`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`of the`

### 风险用例 `zh-sentence` — zh-en

- 源文：`我明天有个会。`
- 审阅提示：I have a meeting tomorrow，保留主体和明天。
- 原始输出：`I have a group tomorrow.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 未命中：`one-of:meeting`

### 风险用例 `zh-tomorrow` — zh-en

- 源文：`明天`
- 审阅提示：tomorrow。
- 原始输出：`Tomorrow the future`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`future`

### 风险用例 `zh-negation` — zh-en

- 源文：`不要发送邮件。`
- 审阅提示：保留不要发送，不得译成发送。
- 原始输出：`Do not send mail.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-word` — zh-en

- 源文：`会议`
- 审阅提示：meeting 或 conference，孤立词无唯一义项。
- 原始输出：`Conferences by the`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`by the`

### 风险用例 `zh-condition` — zh-en

- 源文：`如果下雨，我们就取消会议。`
- 审阅提示：保留条件与取消会议。
- 原始输出：`If it rains, we cancel the meeting.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `zh-phrase` — zh-en

- 源文：`开会`
- 审阅提示：have/attend a meeting 等表达，不要求逐字一致。
- 原始输出：`Meetings for a`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `zh-not-yet` — zh-en

- 源文：`我还没吃饭。`
- 审阅提示：保留尚未吃饭，而非已吃或习惯性不吃。
- 原始输出：`I haven't eaten yet.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-greeting` — zh-en

- 源文：`早上好`
- 审阅提示：good morning。
- 原始输出：`Good morning to you.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-time` — zh-en

- 源文：`明天下午三点开会。`
- 审阅提示：明天下午三点，不能改日期和时间。
- 原始输出：`The cast meets tomorrow at 3pm.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-past` — zh-en

- 源文：`我昨天去了银行。`
- 审阅提示：保留昨天和去银行。
- 原始输出：`I went to the bank yesterday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `zh-contrast` — zh-en

- 源文：`他不在上海，在北京。`
- 审阅提示：保留不在上海、在北京的对比。
- 原始输出：`He's not in Shanghai, in Beijing.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `zh-names` — zh-en

- 源文：`爱丽丝星期五在北京见鲍勃。`
- 审阅提示：保留人名、地点、星期五与见面关系。
- 原始输出：`Alice meets Bob in Beijing on Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `zh-long` — zh-en

- 源文：`会议改到下周二上午十点半，请不要邀请爱丽丝。`
- 审阅提示：保留下周二上午十点半和不要邀请。
- 原始输出：`The meeting is changed to 10:30 a.m. next Tuesday, please don't invite Alice.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `en-unknown` — en-zh

- 源文：`meeetingg`
- 审阅提示：观察是否编造可信译文，不能凭生成成功自动提交。
- 原始输出：`美泰克 美泰克`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`

### 风险用例 `en-typo-word` — en-zh

- 源文：`metting`
- 审阅提示：观察能否理解拼写偏差，不保证必须猜对。
- 原始输出：`美泰简介`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`

### 风险用例 `en-tomorrow` — en-zh

- 源文：`tomorrow`
- 审阅提示：明天。
- 原始输出：`明天 开始`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`开始`

### 风险用例 `en-sentence` — en-zh

- 源文：`I have a meeting tomorrow.`
- 审阅提示：明天有会，不更改主体或日期。
- 原始输出：`明天我有个会议`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `en-ambiguous` — en-zh

- 源文：`bank`
- 审阅提示：孤立多义词，记录输出，不武断认定只有一个正确词义。
- 原始输出：`银行业务`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 风险用例 `en-negation` — en-zh

- 源文：`Do not send the email.`
- 审阅提示：保留禁止发送的否定含义。
- 原始输出：`不要发送邮件。 电子邮件`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `en-word` — en-zh

- 源文：`meeting`
- 审阅提示：会议或会面，不能把单词翻译当完整义项词典。
- 原始输出：`会议介绍`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`介绍`

### 风险用例 `en-url` — en-zh

- 源文：`Open https://example.com/a?x=1.`
- 审阅提示：网址需原样保留，记录模型是否擅自改写。
- 原始输出：`打开 https://example.com/a?x=1. 支持`
- 加固判定：`fallback-original` / `script`
- 机械语义：`pass`

### 风险用例 `en-phrase` — en-zh

- 源文：`attend a meeting`
- 审阅提示：参加会议。
- 原始输出：`参加会议 会议`
- 加固判定：`fallback-original` / `repeat`
- 机械语义：`pass`

### 风险用例 `en-mixed` — en-zh

- 源文：`Please review Gogaku v2.1 before Friday.`
- 审阅提示：保留品牌、版本和星期五之前的时间关系。
- 原始输出：`请在周五之前查看Gogaku v2.1。 评分`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`评分`

### 风险用例 `en-greeting` — en-zh

- 源文：`good morning`
- 审阅提示：早上好。
- 原始输出：`早上好 好 好 早 好 好 好 早 好 好 好 好 早 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 早 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 早 好 好 好 好 好 好 好 好 好 好 好 好 好 好`
- 加固判定：`fallback-original` / `truncated`
- 机械语义：`pass`

### 风险用例 `en-time` — en-zh

- 源文：`The meeting is at 3 p.m. tomorrow.`
- 审阅提示：明天下午三点，不能改时间。
- 原始输出：`明天下午3点开会 大家好`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`（需人工判读）
- 命中禁词：`大家好`

### 风险用例 `en-typo-sentence` — en-zh

- 源文：`I have a metting tomorrow.`
- 审阅提示：观察错拼是否仍能译出明天开会，不代表原词正确。
- 原始输出：`明天我有个药剂`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`

### 风险用例 `en-long` — en-zh

- 源文：`The meeting has been moved to next Tuesday at 10:30 a.m. Please do not invite Alice.`
- 审阅提示：保留下周二上午十点半和不要邀请 Alice 的否定。
- 原始输出：`会议已转移到下周二上午10:30。 请不要邀请Alice。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `en-names` — en-zh

- 源文：`Alice will meet Bob in Beijing on Friday.`
- 审阅提示：保留两个人名、北京、星期五和见面关系，音译可以变化。
- 原始输出：`爱丽丝将于周五在北京与鲍勃见面。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）

### 风险用例 `en-past` — en-zh

- 源文：`I went to the bank yesterday.`
- 审阅提示：昨天去了银行，保留过去时间。
- 原始输出：`昨天我去了银行。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`

### 门槛

- usableRate: `0.7173`
- usableRatePass: `false`
- latencyBudget: `"pass"`
- latencyOverBudget: `{"count": 25, "cases": ["cf-e-phrase-07", "cf-z-word-08", "en-greeting", "enToZh-025", "se-e-phrase-01"], "note": "任何应译请求（成功或失败）等待超过该输入长度档预算都会记录在案；有超限记录不得报通过。"}`
- unhandledRisk: `["en-mixed", "en-tomorrow", "en-word", "zh-bank", "zh-sentence", "zh-tomorrow", "zh-word"]`
- errorReleased: `{"count": 7, "cases": ["en-mixed", "en-tomorrow", "en-word", "zh-bank", "zh-sentence", "zh-tomorrow", "zh-word"]}`
- manualPending: `["cf-e-brand-03", "cf-e-name-01", "cf-e-name-02", "cf-e-name-04", "cf-e-name-05", "cf-e-phrase-03", "cf-e-phrase-04", "cf-e-phrase-05", "cf-e-phrase-11", "cf-e-phrase-12", "cf-e-sent-01", "cf-e-sent-02", "cf-e-sent-03", "cf-e-sent-04", "cf-e-sent-05", "cf-e-sent-06", "cf-e-time-01", "cf-e-time-02", "cf-e-time-03", "cf-e-time-04", "cf-e-time-05", "cf-e-time-06", "cf-e-time-07", "cf-e-time-08", "cf-e-word-01", "cf-e-word-02", "cf-e-word-03", "cf-e-word-04", "cf-e-word-05", "cf-e-word-06", "cf-e-word-07", "cf-e-word-09", "cf-e-word-10", "cf-z-brand-01", "cf-z-brand-02", "cf-z-brand-03", "cf-z-brand-04", "cf-z-brand-05", "cf-z-brand-06", "cf-z-name-01", "cf-z-name-02", "cf-z-name-03", "cf-z-name-05", "cf-z-name-06", "cf-z-name-07", "cf-z-name-08", "cf-z-phrase-01", "cf-z-phrase-02", "cf-z-phrase-03", "cf-z-phrase-04", "cf-z-phrase-05", "cf-z-phrase-06", "cf-z-phrase-07", "cf-z-phrase-08", "cf-z-phrase-09", "cf-z-phrase-11", "cf-z-phrase-12", "cf-z-sent-01", "cf-z-sent-02", "cf-z-sent-03", "cf-z-sent-04", "cf-z-sent-05", "cf-z-sent-06", "cf-z-time-01", "cf-z-time-02", "cf-z-time-03", "cf-z-time-04", "cf-z-time-05", "cf-z-time-06", "cf-z-time-07", "cf-z-time-08", "cf-z-word-01", "cf-z-word-02", "cf-z-word-04", "cf-z-word-05", "cf-z-word-06", "cf-z-word-07", "cf-z-word-09", "cf-z-word-10", "en-ambiguous", "en-long", "en-names", "en-negation", "en-past", "en-sentence", "en-time", "enToZh-001", "enToZh-002", "enToZh-003", "enToZh-004", "enToZh-005", "enToZh-006", "enToZh-007", "enToZh-008", "enToZh-009", "enToZh-010", "enToZh-011", "enToZh-012", "enToZh-013", "enToZh-014", "enToZh-015", "enToZh-016", "enToZh-017", "enToZh-018", "enToZh-019", "enToZh-020", "enToZh-022", "enToZh-027", "enToZh-029", "enToZh-030", "enToZh-034", "enToZh-035", "enToZh-036", "enToZh-037", "enToZh-039", "enToZh-040", "enToZh-041", "enToZh-043", "enToZh-044", "enToZh-046", "enToZh-047", "enToZh-048", "enToZh-050", "enToZh-053", "enToZh-054", "enToZh-055", "enToZh-056", "enToZh-057", "enToZh-058", "enToZh-059", "enToZh-060", "enToZh-061", "enToZh-062", "enToZh-063", "enToZh-064", "enToZh-065", "enToZh-066", "enToZh-067", "enToZh-068", "enToZh-069", "enToZh-070", "enToZh-071", "enToZh-072", "enToZh-074", "enToZh-075", "enToZh-076", "enToZh-077", "enToZh-078", "enToZh-079", "enToZh-080", "enToZh-081", "enToZh-084", "enToZh-086", "enToZh-087", "enToZh-088", "enToZh-089", "se-e-brand-01", "se-e-brand-02", "se-e-brand-03", "se-e-brand-05", "se-e-brand-06", "se-e-name-03", "se-e-name-05", "se-e-name-06", "se-e-name-08", "se-e-phrase-03", "se-e-phrase-04", "se-e-phrase-05", "se-e-phrase-06", "se-e-phrase-10", "se-e-phrase-11", "se-e-phrase-14", "se-e-phrase-15", "se-e-phrase-16", "se-e-time-01", "se-e-time-02", "se-e-time-04", "se-e-time-06", "se-e-time-07", "se-e-time-08", "se-z-brand-02", "se-z-brand-04", "se-z-brand-05", "se-z-brand-06", "se-z-name-02", "se-z-name-03", "se-z-name-04", "se-z-name-05", "se-z-name-06", "se-z-name-07", "se-z-name-08", "se-z-phrase-01", "se-z-phrase-02", "se-z-phrase-03", "se-z-phrase-04", "se-z-phrase-05", "se-z-phrase-06", "se-z-phrase-07", "se-z-phrase-08", "se-z-phrase-09", "se-z-phrase-10", "se-z-phrase-11", "se-z-phrase-12", "se-z-phrase-13", "se-z-phrase-14", "se-z-phrase-15", "se-z-phrase-16", "se-z-time-01", "se-z-time-02", "se-z-time-03", "se-z-time-04", "se-z-time-05", "se-z-time-06", "se-z-time-07", "se-z-time-08", "zh-condition", "zh-contrast", "zh-greeting", "zh-long", "zh-mixed", "zh-names", "zh-negation", "zh-not-yet", "zh-past", "zh-phrase", "zh-time", "zhToEn-002", "zhToEn-003", "zhToEn-004", "zhToEn-005", "zhToEn-006", "zhToEn-007", "zhToEn-008", "zhToEn-011", "zhToEn-013", "zhToEn-014", "zhToEn-015", "zhToEn-016", "zhToEn-017", "zhToEn-018", "zhToEn-019", "zhToEn-020", "zhToEn-021", "zhToEn-022", "zhToEn-023", "zhToEn-024", "zhToEn-025", "zhToEn-026", "zhToEn-027", "zhToEn-028", "zhToEn-029", "zhToEn-030", "zhToEn-031", "zhToEn-032", "zhToEn-033", "zhToEn-034", "zhToEn-035", "zhToEn-036", "zhToEn-037", "zhToEn-038", "zhToEn-039", "zhToEn-040", "zhToEn-041", "zhToEn-042", "zhToEn-043", "zhToEn-044", "zhToEn-045", "zhToEn-046", "zhToEn-047", "zhToEn-048", "zhToEn-049", "zhToEn-050", "zhToEn-051", "zhToEn-052", "zhToEn-053", "zhToEn-054", "zhToEn-055", "zhToEn-056", "zhToEn-057", "zhToEn-058", "zhToEn-059", "zhToEn-060", "zhToEn-061", "zhToEn-062", "zhToEn-063", "zhToEn-064", "zhToEn-065", "zhToEn-066", "zhToEn-067", "zhToEn-068", "zhToEn-069", "zhToEn-070", "zhToEn-071", "zhToEn-072", "zhToEn-073", "zhToEn-074", "zhToEn-075", "zhToEn-076", "zhToEn-077", "zhToEn-078", "zhToEn-079", "zhToEn-080", "zhToEn-081", "zhToEn-083", "zhToEn-084", "zhToEn-086", "zhToEn-087", "zhToEn-088", "zhToEn-089"]`
- reviewCoverage: `{"required": 316, "reviewFile": "missing", "missingIds": ["cf-e-brand-03", "cf-e-name-01", "cf-e-name-02", "cf-e-name-04", "cf-e-name-05", "cf-e-phrase-03", "cf-e-phrase-04", "cf-e-phrase-05", "cf-e-phrase-11", "cf-e-phrase-12", "cf-e-sent-01", "cf-e-sent-02", "cf-e-sent-03", "cf-e-sent-04", "cf-e-sent-05", "cf-e-sent-06", "cf-e-time-01", "cf-e-time-02", "cf-e-time-03", "cf-e-time-04", "cf-e-time-05", "cf-e-time-06", "cf-e-time-07", "cf-e-time-08", "cf-e-word-01", "cf-e-word-02", "cf-e-word-03", "cf-e-word-04", "cf-e-word-05", "cf-e-word-06", "cf-e-word-07", "cf-e-word-09", "cf-e-word-10", "cf-z-brand-01", "cf-z-brand-02", "cf-z-brand-03", "cf-z-brand-04", "cf-z-brand-05", "cf-z-brand-06", "cf-z-name-01", "cf-z-name-02", "cf-z-name-03", "cf-z-name-05", "cf-z-name-06", "cf-z-name-07", "cf-z-name-08", "cf-z-phrase-01", "cf-z-phrase-02", "cf-z-phrase-03", "cf-z-phrase-04", "cf-z-phrase-05", "cf-z-phrase-06", "cf-z-phrase-07", "cf-z-phrase-08", "cf-z-phrase-09", "cf-z-phrase-11", "cf-z-phrase-12", "cf-z-sent-01", "cf-z-sent-02", "cf-z-sent-03", "cf-z-sent-04", "cf-z-sent-05", "cf-z-sent-06", "cf-z-time-01", "cf-z-time-02", "cf-z-time-03", "cf-z-time-04", "cf-z-time-05", "cf-z-time-06", "cf-z-time-07", "cf-z-time-08", "cf-z-word-01", "cf-z-word-02", "cf-z-word-04", "cf-z-word-05", "cf-z-word-06", "cf-z-word-07", "cf-z-word-09", "cf-z-word-10", "en-ambiguous", "en-long", "en-mixed", "en-names", "en-negation", "en-past", "en-sentence", "en-time", "en-tomorrow", "en-word", "enToZh-001", "enToZh-002", "enToZh-003", "enToZh-004", "enToZh-005", "enToZh-006", "enToZh-007", "enToZh-008", "enToZh-009", "enToZh-010", "enToZh-011", "enToZh-012", "enToZh-013", "enToZh-014", "enToZh-015", "enToZh-016", "enToZh-017", "enToZh-018", "enToZh-019", "enToZh-020", "enToZh-022", "enToZh-027", "enToZh-029", "enToZh-030", "enToZh-034", "enToZh-035", "enToZh-036", "enToZh-037", "enToZh-039", "enToZh-040", "enToZh-041", "enToZh-043", "enToZh-044", "enToZh-046", "enToZh-047", "enToZh-048", "enToZh-050", "enToZh-053", "enToZh-054", "enToZh-055", "enToZh-056", "enToZh-057", "enToZh-058", "enToZh-059", "enToZh-060", "enToZh-061", "enToZh-062", "enToZh-063", "enToZh-064", "enToZh-065", "enToZh-066", "enToZh-067", "enToZh-068", "enToZh-069", "enToZh-070", "enToZh-071", "enToZh-072", "enToZh-074", "enToZh-075", "enToZh-076", "enToZh-077", "enToZh-078", "enToZh-079", "enToZh-080", "enToZh-081", "enToZh-084", "enToZh-086", "enToZh-087", "enToZh-088", "enToZh-089", "se-e-brand-01", "se-e-brand-02", "se-e-brand-03", "se-e-brand-05", "se-e-brand-06", "se-e-name-03", "se-e-name-05", "se-e-name-06", "se-e-name-08", "se-e-phrase-03", "se-e-phrase-04", "se-e-phrase-05", "se-e-phrase-06", "se-e-phrase-10", "se-e-phrase-11", "se-e-phrase-14", "se-e-phrase-15", "se-e-phrase-16", "se-e-time-01", "se-e-time-02", "se-e-time-04", "se-e-time-06", "se-e-time-07", "se-e-time-08", "se-z-brand-02", "se-z-brand-04", "se-z-brand-05", "se-z-brand-06", "se-z-name-02", "se-z-name-03", "se-z-name-04", "se-z-name-05", "se-z-name-06", "se-z-name-07", "se-z-name-08", "se-z-phrase-01", "se-z-phrase-02", "se-z-phrase-03", "se-z-phrase-04", "se-z-phrase-05", "se-z-phrase-06", "se-z-phrase-07", "se-z-phrase-08", "se-z-phrase-09", "se-z-phrase-10", "se-z-phrase-11", "se-z-phrase-12", "se-z-phrase-13", "se-z-phrase-14", "se-z-phrase-15", "se-z-phrase-16", "se-z-time-01", "se-z-time-02", "se-z-time-03", "se-z-time-04", "se-z-time-05", "se-z-time-06", "se-z-time-07", "se-z-time-08", "zh-bank", "zh-condition", "zh-contrast", "zh-greeting", "zh-long", "zh-mixed", "zh-names", "zh-negation", "zh-not-yet", "zh-past", "zh-phrase", "zh-sentence", "zh-time", "zh-tomorrow", "zh-word", "zhToEn-002", "zhToEn-003", "zhToEn-004", "zhToEn-005", "zhToEn-006", "zhToEn-007", "zhToEn-008", "zhToEn-011", "zhToEn-013", "zhToEn-014", "zhToEn-015", "zhToEn-016", "zhToEn-017", "zhToEn-018", "zhToEn-019", "zhToEn-020", "zhToEn-021", "zhToEn-022", "zhToEn-023", "zhToEn-024", "zhToEn-025", "zhToEn-026", "zhToEn-027", "zhToEn-028", "zhToEn-029", "zhToEn-030", "zhToEn-031", "zhToEn-032", "zhToEn-033", "zhToEn-034", "zhToEn-035", "zhToEn-036", "zhToEn-037", "zhToEn-038", "zhToEn-039", "zhToEn-040", "zhToEn-041", "zhToEn-042", "zhToEn-043", "zhToEn-044", "zhToEn-045", "zhToEn-046", "zhToEn-047", "zhToEn-048", "zhToEn-049", "zhToEn-050", "zhToEn-051", "zhToEn-052", "zhToEn-053", "zhToEn-054", "zhToEn-055", "zhToEn-056", "zhToEn-057", "zhToEn-058", "zhToEn-059", "zhToEn-060", "zhToEn-061", "zhToEn-062", "zhToEn-063", "zhToEn-064", "zhToEn-065", "zhToEn-066", "zhToEn-067", "zhToEn-068", "zhToEn-069", "zhToEn-070", "zhToEn-071", "zhToEn-072", "zhToEn-073", "zhToEn-074", "zhToEn-075", "zhToEn-076", "zhToEn-077", "zhToEn-078", "zhToEn-079", "zhToEn-080", "zhToEn-081", "zhToEn-083", "zhToEn-084", "zhToEn-086", "zhToEn-087", "zhToEn-088", "zhToEn-089"], "missingCount": 316, "complete": false, "note": "每个进入候选的应译用例都必须有人工审阅记录；缺失审阅不能报完成。"}`
- verdict: `"fail-unhandled-risk"`

