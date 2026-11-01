# 原始译文对照

本表从实际探针输出生成。`generated` 只表示非空且未触及输出上限，不表示质量合格。空、截断及错误也保留。

## en-word

原文：meeting

审阅要点：会议或会面，不能把单词翻译当完整义项词典。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 会议 | True |
| opus-torch-cpu-t4 beam=1 | 会议 | True |
| opus-torch-mps-float32-fallback beam=1 | 会议 | True |
| m2m100-ct2-int8-t4 beam=1 | 會議 | True |
| m2m100-ct2-float32-t2 beam=1 | 會議 | True |
| opus-ct2-float32-t4 beam=1 | 会议 | True |
| m2m100-ct2-int8-t4 beam=4 | 會議 | True |
| opus-ct2-int8-t2 beam=4 | 会 议 | True |

## en-ambiguous

原文：bank

审阅要点：孤立多义词，记录输出，不武断认定只有一个正确词义。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 银行 | True |
| opus-torch-cpu-t4 beam=1 | 银行 | True |
| opus-torch-mps-float32-fallback beam=1 | 银行 | True |
| m2m100-ct2-int8-t4 beam=1 | 银行 | True |
| m2m100-ct2-float32-t2 beam=1 | 银行 | True |
| opus-ct2-float32-t4 beam=1 | 银行 | True |
| m2m100-ct2-int8-t4 beam=4 | 银行 | True |
| opus-ct2-int8-t2 beam=4 | 银行 | True |

## en-tomorrow

原文：tomorrow

审阅要点：明天。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 明天见 | True |
| opus-torch-cpu-t4 beam=1 | 明天见 | True |
| opus-torch-mps-float32-fallback beam=1 | 明天见 | True |
| m2m100-ct2-int8-t4 beam=1 | 明天 | True |
| m2m100-ct2-float32-t2 beam=1 | 明天 | True |
| opus-ct2-float32-t4 beam=1 | 明天见 | True |
| m2m100-ct2-int8-t4 beam=4 | 明天 | True |
| opus-ct2-int8-t2 beam=4 | 明天见 | True |

## en-phrase

原文：attend a meeting

审阅要点：参加会议。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 出席某次会议 | True |
| opus-torch-cpu-t4 beam=1 | 出席某次会议 | True |
| opus-torch-mps-float32-fallback beam=1 | 出席某次会议 | True |
| m2m100-ct2-int8-t4 beam=1 | 出席会议 | True |
| m2m100-ct2-float32-t2 beam=1 | 出席会议 | True |
| opus-ct2-float32-t4 beam=1 | 出席某次会议 | True |
| m2m100-ct2-int8-t4 beam=4 | 參加會議 | True |
| opus-ct2-int8-t2 beam=4 | 出席某次会议 | True |

## en-greeting

原文：good morning

审阅要点：早上好。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 早啊 早啊 早啊 早啊 早啊 早啊 早啊 早啊 早啊 早啊 早啊 早啊 | True |
| opus-torch-cpu-t4 beam=1 | 早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早 [达到输出上限] | False |
| opus-torch-mps-float32-fallback beam=1 | 早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早 [达到输出上限] | False |
| m2m100-ct2-int8-t4 beam=1 | 早安 | True |
| m2m100-ct2-float32-t2 beam=1 | 早安 | True |
| opus-ct2-float32-t4 beam=1 | 早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早,早 [达到输出上限] | False |
| m2m100-ct2-int8-t4 beam=4 | 早上好 | True |
| opus-ct2-int8-t2 beam=4 | 早 早 早 早 早 早 晚 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 早 [达到输出上限] | False |

## en-sentence

原文：I have a meeting tomorrow.

审阅要点：明天有会，不更改主体或日期。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 我明天有个会议 | True |
| opus-torch-cpu-t4 beam=1 | 我明天有个会议 | True |
| opus-torch-mps-float32-fallback beam=1 | 我明天有个会议 | True |
| m2m100-ct2-int8-t4 beam=1 | 明天我会见。 | True |
| m2m100-ct2-float32-t2 beam=1 | 明天我会见。 | True |
| opus-ct2-float32-t4 beam=1 | 我明天有个会议 | True |
| m2m100-ct2-int8-t4 beam=4 | 明天我会见。 | True |
| opus-ct2-int8-t2 beam=4 | 我明天有个会议 | True |

## en-negation

原文：Do not send the email.

审阅要点：保留禁止发送的否定含义。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 不要发送电子邮件 。 | True |
| opus-torch-cpu-t4 beam=1 | 不要发送电子邮件 。 | True |
| opus-torch-mps-float32-fallback beam=1 | 不要发送电子邮件 。 | True |
| m2m100-ct2-int8-t4 beam=1 | 不要发送电子邮件。 | True |
| m2m100-ct2-float32-t2 beam=1 | 不要发送电子邮件。 | True |
| opus-ct2-float32-t4 beam=1 | 不要发送电子邮件 。 | True |
| m2m100-ct2-int8-t4 beam=4 | 不要发送电子邮件。 | True |
| opus-ct2-int8-t2 beam=4 | 不要发送电子邮件 。 | True |

## en-time

原文：The meeting is at 3 p.m. tomorrow.

审阅要点：明天下午三点，不能改时间。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 明天下午3时开会 | True |
| opus-torch-cpu-t4 beam=1 | 明天下午3时开会 | True |
| opus-torch-mps-float32-fallback beam=1 | 明天下午3时开会 | True |
| m2m100-ct2-int8-t4 beam=1 | 会议是明天下午3点。 | True |
| m2m100-ct2-float32-t2 beam=1 | 会议将于明天下午3点举行。 | True |
| opus-ct2-float32-t4 beam=1 | 明天下午3时开会 | True |
| m2m100-ct2-int8-t4 beam=4 | 会议是明天下午3点。 | True |
| opus-ct2-int8-t2 beam=4 | 明天下午3时开会 | True |

## en-names

原文：Alice will meet Bob in Beijing on Friday.

审阅要点：保留两个人名、北京、星期五和见面关系，音译可以变化。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 爱丽丝周五在北京见鲍勃 | True |
| opus-torch-cpu-t4 beam=1 | 爱丽丝周五在北京见鲍勃 | True |
| opus-torch-mps-float32-fallback beam=1 | 爱丽丝周五在北京见鲍勃 | True |
| m2m100-ct2-int8-t4 beam=1 | 阿里斯将于周五在北京见到鲍勃。 | True |
| m2m100-ct2-float32-t2 beam=1 | 阿里斯将于周五在北京见到鲍勃。 | True |
| opus-ct2-float32-t4 beam=1 | 爱丽丝周五在北京见鲍勃 | True |
| m2m100-ct2-int8-t4 beam=4 | 爱丽丝将于周五在北京与鲍勃会面。 | True |
| opus-ct2-int8-t2 beam=4 | 爱丽丝周五会在北京见鲍勃 | True |

## en-typo-sentence

原文：I have a metting tomorrow.

审阅要点：观察错拼是否仍能译出明天开会，不代表原词正确。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 明天我有个约会 | True |
| opus-torch-cpu-t4 beam=1 | 明天我有个约会 | True |
| opus-torch-mps-float32-fallback beam=1 | 明天我有个约会 | True |
| m2m100-ct2-int8-t4 beam=1 | 明天我会见。 | True |
| m2m100-ct2-float32-t2 beam=1 | 明天我会见。 | True |
| opus-ct2-float32-t4 beam=1 | 明天我有个约会 | True |
| m2m100-ct2-int8-t4 beam=4 | 明天我会见。 | True |
| opus-ct2-int8-t2 beam=4 | 我明天有个约会 | True |

## en-typo-word

原文：metting

审阅要点：观察能否理解拼写偏差，不保证必须猜对。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 开 开 | True |
| opus-torch-cpu-t4 beam=1 | 开会 | True |
| opus-torch-mps-float32-fallback beam=1 | 开会 | True |
| m2m100-ct2-int8-t4 beam=1 | 聚集 | True |
| m2m100-ct2-float32-t2 beam=1 | 聚会 | True |
| opus-ct2-float32-t4 beam=1 | 开会 | True |
| m2m100-ct2-int8-t4 beam=4 | 聚会 | True |
| opus-ct2-int8-t2 beam=4 | 开会 | True |

## en-unknown

原文：meeetingg

审阅要点：观察是否编造可信译文，不能凭生成成功自动提交。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | [空输出] | False |
| opus-torch-cpu-t4 beam=1 | [空输出] | False |
| opus-torch-mps-float32-fallback beam=1 | [空输出] | False |
| m2m100-ct2-int8-t4 beam=1 | 梅西 | True |
| m2m100-ct2-float32-t2 beam=1 | 梅西 | True |
| opus-ct2-float32-t4 beam=1 | [空输出] | False |
| m2m100-ct2-int8-t4 beam=4 | 毛泽东 | True |
| opus-ct2-int8-t2 beam=4 | 米丁格语 | True |

## en-url

原文：Open https://example.com/a?x=1.

审阅要点：网址需原样保留，记录模型是否擅自改写。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 打开 https://example.com/a?x=1 | True |
| opus-torch-cpu-t4 beam=1 | 打开 https://example.com/a?x=1 | True |
| opus-torch-mps-float32-fallback beam=1 | 打开 https://example.com/a?x=1 | True |
| m2m100-ct2-int8-t4 beam=1 | 打开 https://example.com/a?x=1。 | True |
| m2m100-ct2-float32-t2 beam=1 | 打开 https://example.com/a?x=1。 | True |
| opus-ct2-float32-t4 beam=1 | 打开 https://example.com/a?x=1 | True |
| m2m100-ct2-int8-t4 beam=4 | 打开 https://example.com/a?x=1。 | True |
| opus-ct2-int8-t2 beam=4 | 打开 https://example.com/a?x=1 | True |

## en-mixed

原文：Please review Gogaku v2.1 before Friday.

审阅要点：保留品牌、版本和星期五之前的时间关系。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 请在星期五之前审查Gogaku v2.1。 | True |
| opus-torch-cpu-t4 beam=1 | 请在星期五前审查Gogaku v2.1。 | True |
| opus-torch-mps-float32-fallback beam=1 | 请在星期五前审查Gogaku v2.1。 | True |
| m2m100-ct2-int8-t4 beam=1 | 请在周五之前查看 Gogaku v2.1。 | True |
| m2m100-ct2-float32-t2 beam=1 | 请在周五之前查看 Gogaku v2.1。 | True |
| opus-ct2-float32-t4 beam=1 | 请在星期五前审查Gogaku v2.1。 | True |
| m2m100-ct2-int8-t4 beam=4 | 请在周五之前查看Gogaku v2.1。 | True |
| opus-ct2-int8-t2 beam=4 | 请在周五之前审查Gogaku v2.1。 | True |

## en-past

原文：I went to the bank yesterday.

审阅要点：昨天去了银行，保留过去时间。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 我昨天去银行了 | True |
| opus-torch-cpu-t4 beam=1 | 我昨天去银行了 | True |
| opus-torch-mps-float32-fallback beam=1 | 我昨天去银行了 | True |
| m2m100-ct2-int8-t4 beam=1 | 昨天我去银行。 | True |
| m2m100-ct2-float32-t2 beam=1 | 昨天我去银行。 | True |
| opus-ct2-float32-t4 beam=1 | 我昨天去银行了 | True |
| m2m100-ct2-int8-t4 beam=4 | 昨天我去了银行。 | True |
| opus-ct2-int8-t2 beam=4 | 我昨天去银行了 | True |

## en-long

原文：The meeting has been moved to next Tuesday at 10:30 a.m. Please do not invite Alice.

审阅要点：保留下周二上午十点半和不要邀请 Alice 的否定。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | 会议已移至下星期二上午10时30分举行。 请不要邀请爱丽丝。 | True |
| opus-torch-cpu-t4 beam=1 | 会议已移至下星期二上午10时30分举行。 请不要邀请爱丽丝。 | True |
| opus-torch-mps-float32-fallback beam=1 | 会议已移至下星期二上午10时30分举行。 请不要邀请爱丽丝。 | True |
| m2m100-ct2-int8-t4 beam=1 | 会议将于下周二下午10点30分推迟,请不要邀请阿里斯。 | True |
| m2m100-ct2-float32-t2 beam=1 | 会议将于下周二下午10点30分推迟,请不要邀请阿里斯。 | True |
| opus-ct2-float32-t4 beam=1 | 会议已移至下星期二上午10时30分举行。 请不要邀请爱丽丝。 | True |
| m2m100-ct2-int8-t4 beam=4 | 会议已推迟到下周二下午10点30分,请不要邀请爱丽丝。 | True |
| opus-ct2-int8-t2 beam=4 | 会议已移至下星期二上午10时30分举行。 请不要邀请爱丽丝。 | True |

## zh-word

原文：会议

审阅要点：meeting 或 conference，孤立词无唯一义项。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | Meetings | True |
| opus-torch-cpu-t4 beam=1 | Meetings | True |
| opus-torch-mps-float32-fallback beam=1 | Meetings | True |
| m2m100-ct2-int8-t4 beam=1 | Meeting | True |
| m2m100-ct2-float32-t2 beam=1 | Meeting | True |
| opus-ct2-float32-t4 beam=1 | Meetings | True |
| m2m100-ct2-int8-t4 beam=4 | Meeting | True |
| opus-ct2-int8-t2 beam=4 | Meetings | True |

## zh-tomorrow

原文：明天

审阅要点：tomorrow。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | Tomorrow. | True |
| opus-torch-cpu-t4 beam=1 | Tomorrow. | True |
| opus-torch-mps-float32-fallback beam=1 | Tomorrow. | True |
| m2m100-ct2-int8-t4 beam=1 | tomorrow | True |
| m2m100-ct2-float32-t2 beam=1 | tomorrow | True |
| opus-ct2-float32-t4 beam=1 | Tomorrow. | True |
| m2m100-ct2-int8-t4 beam=4 | tomorrow | True |
| opus-ct2-int8-t2 beam=4 | Tomorrow. | True |

## zh-bank

原文：银行

审阅要点：bank。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | Bank | True |
| opus-torch-cpu-t4 beam=1 | Bank | True |
| opus-torch-mps-float32-fallback beam=1 | Bank | True |
| m2m100-ct2-int8-t4 beam=1 | The Bank | True |
| m2m100-ct2-float32-t2 beam=1 | The Bank | True |
| opus-ct2-float32-t4 beam=1 | Bank | True |
| m2m100-ct2-int8-t4 beam=4 | The Bank | True |
| opus-ct2-int8-t2 beam=4 | Bank | True |

## zh-phrase

原文：开会

审阅要点：have/attend a meeting 等表达，不要求逐字一致。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | Meetings | True |
| opus-torch-cpu-t4 beam=1 | Meetings | True |
| opus-torch-mps-float32-fallback beam=1 | Meetings | True |
| m2m100-ct2-int8-t4 beam=1 | Meeting | True |
| m2m100-ct2-float32-t2 beam=1 | Meeting | True |
| opus-ct2-float32-t4 beam=1 | Meetings | True |
| m2m100-ct2-int8-t4 beam=4 | Meeting | True |
| opus-ct2-int8-t2 beam=4 | Meetings | True |

## zh-greeting

原文：早上好

审阅要点：good morning。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | Good morning. | True |
| opus-torch-cpu-t4 beam=1 | Good morning. | True |
| opus-torch-mps-float32-fallback beam=1 | Good morning. | True |
| m2m100-ct2-int8-t4 beam=1 | Good morning. | True |
| m2m100-ct2-float32-t2 beam=1 | Good morning. | True |
| opus-ct2-float32-t4 beam=1 | Good morning. | True |
| m2m100-ct2-int8-t4 beam=4 | Good morning. | True |
| opus-ct2-int8-t2 beam=4 | Good morning. | True |

## zh-sentence

原文：我明天有个会。

审阅要点：I have a meeting tomorrow，保留主体和明天。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | I have a meeting tomorrow. | True |
| opus-torch-cpu-t4 beam=1 | I have a meeting tomorrow. | True |
| opus-torch-mps-float32-fallback beam=1 | I have a meeting tomorrow. | True |
| m2m100-ct2-int8-t4 beam=1 | I have a meeting tomorrow. | True |
| m2m100-ct2-float32-t2 beam=1 | I have a meeting tomorrow. | True |
| opus-ct2-float32-t4 beam=1 | I have a meeting tomorrow. | True |
| m2m100-ct2-int8-t4 beam=4 | I have a meeting tomorrow. | True |
| opus-ct2-int8-t2 beam=4 | I have a meeting tomorrow. | True |

## zh-negation

原文：不要发送邮件。

审阅要点：保留不要发送，不得译成发送。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | Don't send mail. | True |
| opus-torch-cpu-t4 beam=1 | Don't send mail. | True |
| opus-torch-mps-float32-fallback beam=1 | Don't send mail. | True |
| m2m100-ct2-int8-t4 beam=1 | Do not send emails. | True |
| m2m100-ct2-float32-t2 beam=1 | Do not send emails. | True |
| opus-ct2-float32-t4 beam=1 | Don't send mail. | True |
| m2m100-ct2-int8-t4 beam=4 | Do not send emails. | True |
| opus-ct2-int8-t2 beam=4 | Don't send mail. | True |

## zh-time

原文：明天下午三点开会。

审阅要点：明天下午三点，不能改日期和时间。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | The meeting will be held tomorrow at 3 p.m. | True |
| opus-torch-cpu-t4 beam=1 | The meeting will be held tomorrow at 3 p.m. | True |
| opus-torch-mps-float32-fallback beam=1 | The meeting will be held tomorrow at 3 p.m. | True |
| m2m100-ct2-int8-t4 beam=1 | Tomorrow at 3 a.m. we will meet. | True |
| m2m100-ct2-float32-t2 beam=1 | Tomorrow at 3 a.m. | True |
| opus-ct2-float32-t4 beam=1 | The meeting will be held tomorrow at 3 p.m. | True |
| m2m100-ct2-int8-t4 beam=4 | Meeting tomorrow at 3 p.m. | True |
| opus-ct2-int8-t2 beam=4 | The meeting will be held tomorrow at 3 p.m. | True |

## zh-names

原文：爱丽丝星期五在北京见鲍勃。

审阅要点：保留人名、地点、星期五与见面关系。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | Alice, meet Bob in Beijing Friday. | True |
| opus-torch-cpu-t4 beam=1 | Alice met Bob in Beijing Friday. | True |
| opus-torch-mps-float32-fallback beam=1 | Alice met Bob in Beijing Friday. | True |
| m2m100-ct2-int8-t4 beam=1 | Alice is meeting Bob on Friday in Beijing. | True |
| m2m100-ct2-float32-t2 beam=1 | Alice met Bob on Friday in Beijing. | True |
| opus-ct2-float32-t4 beam=1 | Alice met Bob in Beijing Friday. | True |
| m2m100-ct2-int8-t4 beam=4 | Alice met Bob on Friday in Beijing. | True |
| opus-ct2-int8-t2 beam=4 | Alice's meeting Bob in Beijing Friday. | True |

## zh-past

原文：我昨天去了银行。

审阅要点：保留昨天和去银行。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | I went to the bank yesterday. | True |
| opus-torch-cpu-t4 beam=1 | I went to the bank yesterday. | True |
| opus-torch-mps-float32-fallback beam=1 | I went to the bank yesterday. | True |
| m2m100-ct2-int8-t4 beam=1 | I went to the bank yesterday. | True |
| m2m100-ct2-float32-t2 beam=1 | I went to the bank yesterday. | True |
| opus-ct2-float32-t4 beam=1 | I went to the bank yesterday. | True |
| m2m100-ct2-int8-t4 beam=4 | I went to the bank yesterday. | True |
| opus-ct2-int8-t2 beam=4 | I went to the bank yesterday. | True |

## zh-url

原文：请打开 https://example.com/a?x=1。

审阅要点：网址需原样保留。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | Open https://example.com/a?x=1. | True |
| opus-torch-cpu-t4 beam=1 | Please open https://example.com/a?x=1. | True |
| opus-torch-mps-float32-fallback beam=1 | Please open https://example.com/a?x=1. | True |
| m2m100-ct2-int8-t4 beam=1 | Please open https://example.com/a?x=1. | True |
| m2m100-ct2-float32-t2 beam=1 | Please open https://example.com/a?x=1. | True |
| opus-ct2-float32-t4 beam=1 | Please open https://example.com/a?x=1. | True |
| m2m100-ct2-int8-t4 beam=4 | Please open https://example.com/a?x=1. | True |
| opus-ct2-int8-t2 beam=4 | Open https://example.com/a?x=1. | True |

## zh-mixed

原文：请在星期五之前检查 Gogaku v2.1。

审阅要点：保留品牌、版本和星期五之前。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | Check Gogaku v2.1 by Friday. | True |
| opus-torch-cpu-t4 beam=1 | Check Gogaku v2.1 by Friday. | True |
| opus-torch-mps-float32-fallback beam=1 | Check Gogaku v2.1 by Friday. | True |
| m2m100-ct2-int8-t4 beam=1 | Please check Gogaku v2.1 before Friday. | True |
| m2m100-ct2-float32-t2 beam=1 | Please check Gogaku v2.1 before Friday. | True |
| opus-ct2-float32-t4 beam=1 | Check Gogaku v2.1 by Friday. | True |
| m2m100-ct2-int8-t4 beam=4 | Please check Gogaku v2.1 before Friday. | True |
| opus-ct2-int8-t2 beam=4 | Check Gogaku v2.1 by Friday. | True |

## zh-condition

原文：如果下雨，我们就取消会议。

审阅要点：保留条件与取消会议。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | If it rains, we cancel the meeting. | True |
| opus-torch-cpu-t4 beam=1 | If it rains, we cancel the meeting. | True |
| opus-torch-mps-float32-fallback beam=1 | If it rains, we cancel the meeting. | True |
| m2m100-ct2-int8-t4 beam=1 | If it rains, we cancell the meeting. | True |
| m2m100-ct2-float32-t2 beam=1 | If it rains, we cancell the meeting. | True |
| opus-ct2-float32-t4 beam=1 | If it rains, we cancel the meeting. | True |
| m2m100-ct2-int8-t4 beam=4 | If it rains, we cancell the meeting. | True |
| opus-ct2-int8-t2 beam=4 | If it rains, we cancel the meeting. | True |

## zh-not-yet

原文：我还没吃饭。

审阅要点：保留尚未吃饭，而非已吃或习惯性不吃。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | I haven't eaten yet. | True |
| opus-torch-cpu-t4 beam=1 | I haven't eaten yet. | True |
| opus-torch-mps-float32-fallback beam=1 | I haven't eaten yet. | True |
| m2m100-ct2-int8-t4 beam=1 | I haven’t eaten yet. | True |
| m2m100-ct2-float32-t2 beam=1 | I haven’t eaten yet. | True |
| opus-ct2-float32-t4 beam=1 | I haven't eaten yet. | True |
| m2m100-ct2-int8-t4 beam=4 | I haven’t eaten yet. | True |
| opus-ct2-int8-t2 beam=4 | I haven't eaten yet. | True |

## zh-long

原文：会议改到下周二上午十点半，请不要邀请爱丽丝。

审阅要点：保留下周二上午十点半和不要邀请。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | The meeting will be rescheduled to 10:30 next Tuesday. Please don't invite Alice. | True |
| opus-torch-cpu-t4 beam=1 | The meeting is scheduled for 10:30 next Tuesday. Please don't invite Alice. | True |
| opus-torch-mps-float32-fallback beam=1 | The meeting is scheduled for 10:30 next Tuesday. Please don't invite Alice. | True |
| m2m100-ct2-int8-t4 beam=1 | The meeting will be changed to Tuesday at 10:30, please don't invite Alice. | True |
| m2m100-ct2-float32-t2 beam=1 | The meeting will be changed to Tuesday at 10:30 p.m., please do not invite Alice. | True |
| opus-ct2-float32-t4 beam=1 | The meeting is scheduled for 10:30 next Tuesday. Please don't invite Alice. | True |
| m2m100-ct2-int8-t4 beam=4 | The meeting will be changed to Tuesday morning at 10:30, please don’t invite Alice. | True |
| opus-ct2-int8-t2 beam=4 | The meeting is scheduled for 10:30 a.m. next Tuesday. Please don't invite Alice. | True |

## zh-contrast

原文：他不在上海，在北京。

审阅要点：保留不在上海、在北京的对比。

| 配置 | 实际输出 | 生成完成 |
| --- | --- | --- |
| opus-ct2-int8-t2 beam=1 | He's not in Shanghai, in Beijing. | True |
| opus-torch-cpu-t4 beam=1 | He's not in Shanghai, in Beijing. | True |
| opus-torch-mps-float32-fallback beam=1 | He's not in Shanghai, in Beijing. | True |
| m2m100-ct2-int8-t4 beam=1 | He is not in Shanghai, in Beijing. | True |
| m2m100-ct2-float32-t2 beam=1 | He is not in Shanghai, in Beijing. | True |
| opus-ct2-float32-t4 beam=1 | He's not in Shanghai, in Beijing. | True |
| m2m100-ct2-int8-t4 beam=4 | He is not in Shanghai, in Beijing. | True |
| opus-ct2-int8-t2 beam=4 | He's not in Shanghai, in Beijing. | True |

