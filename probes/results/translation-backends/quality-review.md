# 翻译后端统一实测：风险集审阅索引

本文件由 `scripts/summarize-translation-backends.py` 生成，只列原始输出、加固处置和机械语义信号；
不是用户盲测结论。人工语义判断记录在 `semantic-review.md` / `semantic-review.json`。

## small100

### `zh-not-yet` — zh-en

- 源文：`我还没吃饭。`
- 审阅提示：保留尚未吃饭，而非已吃或习惯性不吃。
- 原始输出：`I have not eaten yet.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — “还没”保留为 not ... yet。

### `zh-phrase` — zh-en

- 源文：`开会`
- 审阅提示：have/attend a meeting 等表达，不要求逐字一致。
- 原始输出：`The Meeting`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`fail` — “开会”是动词短语，输出 The Meeting 名词化且缺动作，不应作为默认候选。

### `zh-time` — zh-en

- 源文：`明天下午三点开会。`
- 审阅提示：明天下午三点，不能改日期和时间。
- 原始输出：`Meeting tomorrow at 3 pm.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 明天下午三点完整保留。

### `zh-greeting` — zh-en

- 源文：`早上好`
- 审阅提示：good morning。
- 原始输出：`Good morning`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 早上好。

### `zh-contrast` — zh-en

- 源文：`他不在上海，在北京。`
- 审阅提示：保留不在上海、在北京的对比。
- 原始输出：`He is not in Shanghai, but in Beijing.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 不在上海、在北京的对比保留。

### `zh-url` — zh-en

- 源文：`请打开 https://example.com/a?x=1。`
- 审阅提示：网址需原样保留。
- 原始输出：`Please open https://example.com/a?x=1`
- 加固判定：`fallback-original` / `length`
- 机械语义：`pass`
- 人工审阅：`pass` — 网址原样保留；加固因长度比率误判回退原文，属安全处置但暴露误报。

### `zh-bank` — zh-en

- 源文：`银行`
- 审阅提示：bank。
- 原始输出：`Banking`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`fail` — Banking 是动名词/行业义，不是“银行”的默认词候选。

### `zh-long` — zh-en

- 源文：`会议改到下周二上午十点半，请不要邀请爱丽丝。`
- 审阅提示：保留下周二上午十点半和不要邀请。
- 原始输出：`The meeting will be changed to 10 a.m. next Tuesday, please don’t invite Alice.`
- 加固判定：`fallback-original` / `time`
- 机械语义：`fail`（需人工判读）
- 未命中：`one-of:10:30|ten thirty|half past ten`、`one-of:not|don't|do not`
- 人工审阅：`pass` — 模型丢掉“半”并输出 10 a.m.；加固按时段/半点规则回退原文。

### `zh-tomorrow` — zh-en

- 源文：`明天`
- 审阅提示：tomorrow。
- 原始输出：`tomorrow`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — tomorrow。

### `zh-names` — zh-en

- 源文：`爱丽丝星期五在北京见鲍勃。`
- 审阅提示：保留人名、地点、星期五与见面关系。
- 原始输出：`Alice will meet Bob in Beijing on Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — Alice、Bob、北京、星期五和见面关系均保留。

### `zh-word` — zh-en

- 源文：`会议`
- 审阅提示：meeting 或 conference，孤立词无唯一义项。
- 原始输出：`Meeting`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — Meeting，孤立词可接受。

### `zh-sentence` — zh-en

- 源文：`我明天有个会。`
- 审阅提示：I have a meeting tomorrow，保留主体和明天。
- 原始输出：`I have a meeting tomorrow.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — I have a meeting tomorrow，主体和明天保留。

### `zh-condition` — zh-en

- 源文：`如果下雨，我们就取消会议。`
- 审阅提示：保留条件与取消会议。
- 原始输出：`If it rains, we cancell the meeting.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`fail` — 条件与取消含义保留，但工具生成英语拼写错误 cancell 进入候选；按产品规则不得作为默认候选。

### `zh-negation` — zh-en

- 源文：`不要发送邮件。`
- 审阅提示：保留不要发送，不得译成发送。
- 原始输出：`Do not send mail.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 否定发送保留。

### `zh-mixed` — zh-en

- 源文：`请在星期五之前检查 Gogaku v2.1。`
- 审阅提示：保留品牌、版本和星期五之前。
- 原始输出：`Please check Gogaku v2.1 before Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — Gogaku、v2.1、星期五之前均保留。

### `zh-past` — zh-en

- 源文：`我昨天去了银行。`
- 审阅提示：保留昨天和去银行。
- 原始输出：`I went to the bank yesterday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 昨天去银行保留。

### `en-mixed` — en-zh

- 源文：`Please review Gogaku v2.1 before Friday.`
- 审阅提示：保留品牌、版本和星期五之前的时间关系。
- 原始输出：`请在星期五之前查看Gogaku v2.1。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — Gogaku、v2.1、星期五之前均保留。

### `en-phrase` — en-zh

- 源文：`attend a meeting`
- 审阅提示：参加会议。
- 原始输出：`參加會議`
- 加固判定：`candidate-normalized` / `traditional-normalized`
- 归一输出：`参加会议`
- 机械语义：`pass`
- 人工审阅：`pass` — 繁体输出由 t2s 归一为“参加会议”。

### `en-time` — en-zh

- 源文：`The meeting is at 3 p.m. tomorrow.`
- 审阅提示：明天下午三点，不能改时间。
- 原始输出：`会议是明天下午3点。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 明天下午三点保留。

### `en-greeting` — en-zh

- 源文：`good morning`
- 审阅提示：早上好。
- 原始输出：`早上好`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 早上好。

### `en-long` — en-zh

- 源文：`The meeting has been moved to next Tuesday at 10:30 a.m. Please do not invite Alice.`
- 审阅提示：保留下周二上午十点半和不要邀请 Alice 的否定。
- 原始输出：`会议将于下周二下午10点30点,请不要邀请艾丽丝。`
- 加固判定：`fallback-original` / `time`
- 机械语义：`fail`（需人工判读）
- 未命中：`one-of:10:30|十点半|10点半`、`one-of:上午|早上`
- 命中禁词：`下午`
- 人工审阅：`pass` — 模型把上午翻成下午且“30点”语病；加固按时段规则回退原文。

### `en-typo-word` — en-zh

- 源文：`metting`
- 审阅提示：观察能否理解拼写偏差，不保证必须猜对。
- 原始输出：`充足`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留错拼；模型输出“充足”不进入候选。

### `en-tomorrow` — en-zh

- 源文：`tomorrow`
- 审阅提示：明天。
- 原始输出：`明天`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 明天。

### `en-past` — en-zh

- 源文：`I went to the bank yesterday.`
- 审阅提示：昨天去了银行，保留过去时间。
- 原始输出：`我昨天去银行。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 昨天去银行，过去时间保留。

### `en-ambiguous` — en-zh

- 源文：`bank`
- 审阅提示：孤立多义词，记录输出，不武断认定只有一个正确词义。
- 原始输出：`银行`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 银行是合法义项之一。

### `en-names` — en-zh

- 源文：`Alice will meet Bob in Beijing on Friday.`
- 审阅提示：保留两个人名、北京、星期五和见面关系，音译可以变化。
- 原始输出：`艾丽丝星期五将在北京见面。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`（需人工判读）
- 未命中：`one-of:鲍勃|包勃|博布`
- 人工审阅：`fail` — 丢失 Bob，输出仍成为候选；人名对齐检查尚未接入加固层。

### `en-word` — en-zh

- 源文：`meeting`
- 审阅提示：会议或会面，不能把单词翻译当完整义项词典。
- 原始输出：`会议`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 会议。

### `en-sentence` — en-zh

- 源文：`I have a meeting tomorrow.`
- 审阅提示：明天有会，不更改主体或日期。
- 原始输出：`我明天会见。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 未命中：`one-of:会议|开会`
- 命中禁词：`会见`
- 人工审阅：`fail` — “我明天会见”把会议变成会见，主体关系改变且进入候选。

### `en-url` — en-zh

- 源文：`Open https://example.com/a?x=1.`
- 审阅提示：网址需原样保留，记录模型是否擅自改写。
- 原始输出：`打开 https://example.com/a?x=1。`
- 加固判定：`fallback-original` / `script`
- 机械语义：`pass`
- 人工审阅：`pass` — 网址原样保留；脚本校验把 URL 的拉丁字符计入而误判回退，属安全处置但暴露误报。

### `en-negation` — en-zh

- 源文：`Do not send the email.`
- 审阅提示：保留禁止发送的否定含义。
- 原始输出：`不要发送电子邮件。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 否定发送保留。

### `en-unknown` — en-zh

- 源文：`meeetingg`
- 审阅提示：观察是否编造可信译文，不能凭生成成功自动提交。
- 原始输出：`同行`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留未知词；模型输出“同行”不进入候选。

### `en-typo-sentence` — en-zh

- 源文：`I have a metting tomorrow.`
- 审阅提示：观察错拼是否仍能译出明天开会，不代表原词正确。
- 原始输出：`我明天有一个聚会。`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留错拼句；模型猜成“聚会”不进入候选。

### 门槛

- usableRate: `0.9434`
- usableRatePass: `False`
- latencyBudgetPass: `True`
- unhandledRisk: `['en-names', 'en-sentence', 'zh-bank', 'zh-condition', 'zh-phrase']`
- manualPending: `[]`
- verdict: `fail-unhandled-risk`

## quickmt

### `zh-mixed` — zh-en

- 源文：`请在星期五之前检查 Gogaku v2.1。`
- 审阅提示：保留品牌、版本和星期五之前。
- 原始输出：`Please check the Gogaku v2.1 by Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — Gogaku、v2.1、星期五之前保留；多一个 the 不影响意义。

### `zh-url` — zh-en

- 源文：`请打开 https://example.com/a?x=1。`
- 审阅提示：网址需原样保留。
- 原始输出：`Please open the https://example.com/a?x=1`
- 加固判定：`fallback-original` / `length`
- 机械语义：`pass`
- 人工审阅：`pass` — 网址原样保留；长度比率误判回退，属安全处置。

### `zh-bank` — zh-en

- 源文：`银行`
- 审阅提示：bank。
- 原始输出：`Bank of the Bank`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`of the`
- 人工审阅：`fail` — Bank of the Bank 不是“银行”的可用词候选。

### `zh-sentence` — zh-en

- 源文：`我明天有个会。`
- 审阅提示：I have a meeting tomorrow，保留主体和明天。
- 原始输出：`I have a group tomorrow.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 未命中：`one-of:meeting`
- 人工审阅：`fail` — “我明天有个会”被译成 I have a group tomorrow，会议变 group。

### `zh-tomorrow` — zh-en

- 源文：`明天`
- 审阅提示：tomorrow。
- 原始输出：`Tomorrow the future`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`future`
- 人工审阅：`fail` — Tomorrow the future 加入原文没有的“未来”。

### `zh-negation` — zh-en

- 源文：`不要发送邮件。`
- 审阅提示：保留不要发送，不得译成发送。
- 原始输出：`Do not send mail.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 否定发送保留。

### `zh-word` — zh-en

- 源文：`会议`
- 审阅提示：meeting 或 conference，孤立词无唯一义项。
- 原始输出：`Conferences by the`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`by the`
- 人工审阅：`fail` — Conferences by the 是残句，不是“会议”的可用词候选。

### `zh-condition` — zh-en

- 源文：`如果下雨，我们就取消会议。`
- 审阅提示：保留条件与取消会议。
- 原始输出：`If it rains, we cancel the meeting.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 条件、下雨、取消会议均保留。

### `zh-phrase` — zh-en

- 源文：`开会`
- 审阅提示：have/attend a meeting 等表达，不要求逐字一致。
- 原始输出：`Meetings for a`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`fail` — Meetings for a 是残句，不满足“开会”的表达候选。

### `zh-not-yet` — zh-en

- 源文：`我还没吃饭。`
- 审阅提示：保留尚未吃饭，而非已吃或习惯性不吃。
- 原始输出：`I haven't eaten yet.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — haven't eaten yet 保留尚未。

### `zh-greeting` — zh-en

- 源文：`早上好`
- 审阅提示：good morning。
- 原始输出：`Good morning to you.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — Good morning to you. 语义等价。

### `zh-time` — zh-en

- 源文：`明天下午三点开会。`
- 审阅提示：明天下午三点，不能改日期和时间。
- 原始输出：`The cast meets tomorrow at 3pm.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`fail` — The cast meets tomorrow at 3pm 把“开会”变成 cast meets，主体/动作偏移。

### `zh-past` — zh-en

- 源文：`我昨天去了银行。`
- 审阅提示：保留昨天和去银行。
- 原始输出：`I went to the bank yesterday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — yesterday 和去银行保留。

### `zh-contrast` — zh-en

- 源文：`他不在上海，在北京。`
- 审阅提示：保留不在上海、在北京的对比。
- 原始输出：`He's not in Shanghai, in Beijing.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`fail` — He's not in Shanghai, in Beijing 缺对比连接且语法不完整；虽可猜意，不作为可直接使用的候选。

### `zh-names` — zh-en

- 源文：`爱丽丝星期五在北京见鲍勃。`
- 审阅提示：保留人名、地点、星期五与见面关系。
- 原始输出：`Alice meets Bob in Beijing on Friday.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — Alice、Bob、北京、星期五、见面关系保留。

### `zh-long` — zh-en

- 源文：`会议改到下周二上午十点半，请不要邀请爱丽丝。`
- 审阅提示：保留下周二上午十点半和不要邀请。
- 原始输出：`The meeting is changed to 10:30 a.m. next Tuesday, please don't invite Alice.`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 10:30 a.m. 下周二、否定、Alice 均保留。

### `en-unknown` — en-zh

- 源文：`meeetingg`
- 审阅提示：观察是否编造可信译文，不能凭生成成功自动提交。
- 原始输出：`美泰克 美泰克`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留未知词；模型重复“美泰克”不进入候选。

### `en-typo-word` — en-zh

- 源文：`metting`
- 审阅提示：观察能否理解拼写偏差，不保证必须猜对。
- 原始输出：`美泰简介`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留错拼；模型“美泰简介”不进入候选。

### `en-tomorrow` — en-zh

- 源文：`tomorrow`
- 审阅提示：明天。
- 原始输出：`明天 开始`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`开始`
- 人工审阅：`fail` — “明天 开始”加入原文没有的“开始”。

### `en-sentence` — en-zh

- 源文：`I have a meeting tomorrow.`
- 审阅提示：明天有会，不更改主体或日期。
- 原始输出：`明天我有个会议`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 明天我有个会议，主体和日期保留。

### `en-ambiguous` — en-zh

- 源文：`bank`
- 审阅提示：孤立多义词，记录输出，不武断认定只有一个正确词义。
- 原始输出：`银行业务`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 银行业务是合法义项之一。

### `en-negation` — en-zh

- 源文：`Do not send the email.`
- 审阅提示：保留禁止发送的否定含义。
- 原始输出：`不要发送邮件。 电子邮件`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`fail` — 否定发送保留，但尾部多出“电子邮件”残片；不应作为可直接使用的候选。

### `en-word` — en-zh

- 源文：`meeting`
- 审阅提示：会议或会面，不能把单词翻译当完整义项词典。
- 原始输出：`会议介绍`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`介绍`
- 人工审阅：`fail` — 会议介绍加入原文没有的“介绍”，不是“meeting”的直接词候选。

### `en-url` — en-zh

- 源文：`Open https://example.com/a?x=1.`
- 审阅提示：网址需原样保留，记录模型是否擅自改写。
- 原始输出：`打开 https://example.com/a?x=1. 支持`
- 加固判定：`fallback-original` / `script`
- 机械语义：`pass`
- 人工审阅：`pass` — 网址原样保留；尾部“支持”残片触发脚本回退，属安全处置。

### `en-phrase` — en-zh

- 源文：`attend a meeting`
- 审阅提示：参加会议。
- 原始输出：`参加会议 会议`
- 加固判定：`fallback-original` / `repeat`
- 机械语义：`pass`
- 人工审阅：`pass` — “参加会议 会议”重复由加固回退原文。

### `en-mixed` — en-zh

- 源文：`Please review Gogaku v2.1 before Friday.`
- 审阅提示：保留品牌、版本和星期五之前的时间关系。
- 原始输出：`请在周五之前查看Gogaku v2.1。 评分`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`
- 命中禁词：`评分`
- 人工审阅：`fail` — Gogaku、v2.1、星期五保留，但尾部多出“评分”残片。

### `en-greeting` — en-zh

- 源文：`good morning`
- 审阅提示：早上好。
- 原始输出：`早上好 好 好 早 好 好 好 早 好 好 好 好 早 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 早 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 好 早 好 好 好 好 好 好 好 好 好 好 好 好 好 好`
- 加固判定：`fallback-original` / `truncated`
- 机械语义：`pass`
- 人工审阅：`pass` — “早上好 好 好…”复读由加固判为截断/重复并回退。

### `en-time` — en-zh

- 源文：`The meeting is at 3 p.m. tomorrow.`
- 审阅提示：明天下午三点，不能改时间。
- 原始输出：`明天下午3点开会 大家好`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`fail`（需人工判读）
- 命中禁词：`大家好`
- 人工审阅：`fail` — 明天下午三点保留，但尾部多出“大家好”。

### `en-typo-sentence` — en-zh

- 源文：`I have a metting tomorrow.`
- 审阅提示：观察错拼是否仍能译出明天开会，不代表原词正确。
- 原始输出：`明天我有个药剂`
- 加固判定：`preserve-expected` / `policy-preserve`
- 机械语义：`not-applicable`
- 人工审阅：`pass` — 策略应保留错拼句；模型“药剂”不进入候选。

### `en-long` — en-zh

- 源文：`The meeting has been moved to next Tuesday at 10:30 a.m. Please do not invite Alice.`
- 审阅提示：保留下周二上午十点半和不要邀请 Alice 的否定。
- 原始输出：`会议已转移到下周二上午10:30。 请不要邀请Alice。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 下周二上午10:30、否定、Alice 均保留。

### `en-names` — en-zh

- 源文：`Alice will meet Bob in Beijing on Friday.`
- 审阅提示：保留两个人名、北京、星期五和见面关系，音译可以变化。
- 原始输出：`爱丽丝将于周五在北京与鲍勃见面。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`（需人工判读）
- 人工审阅：`pass` — 爱丽丝、鲍勃、北京、星期五和见面关系保留。

### `en-past` — en-zh

- 源文：`I went to the bank yesterday.`
- 审阅提示：昨天去了银行，保留过去时间。
- 原始输出：`昨天我去了银行。`
- 加固判定：`candidate` / `checks-passed`
- 机械语义：`pass`
- 人工审阅：`pass` — 昨天和银行保留。

### 门槛

- usableRate: `0.7767`
- usableRatePass: `False`
- latencyBudgetPass: `True`
- unhandledRisk: `['en-mixed', 'en-negation', 'en-time', 'en-tomorrow', 'en-word', 'zh-bank', 'zh-contrast', 'zh-phrase', 'zh-sentence', 'zh-time', 'zh-tomorrow', 'zh-word']`
- manualPending: `[]`
- verdict: `fail-unhandled-risk`

