# 确认集盲测比较材料

模型名称已隐藏（A/B）。每条请选出更合适的译文，或标注两者都不合格；
允许同义表达；评分规则见 `validation/translation-confirm-set.json`。
`〔安全回退→显示原文〕`不是译文：该侧加固层未放行任何候选，产品会保留用户输入原文。
`variants` 是该侧放行候选的变体数，大于 1 表示五轮输出不完全一致。

## 方向 en-zh

| # | 用例 | 源文 | A | B | 变体 |
| ---: | --- | --- | --- | --- | --- |
| 1 | `cf-e-phrase-02` | a little tired | 〔安全回退→显示原文〕 | 有点累了 | A:0 B:1 |
| 2 | `cf-e-phrase-09` | in advance | 〔安全回退→显示原文〕 | 提前 | A:0 B:1 |
| 3 | `cf-e-phrase-05` | right now | 现在, 立即 | 现在 | A:1 B:1 |
| 4 | `cf-e-name-07` | Teacher Wang | 老师 华 | 〔安全回退→显示原文〕 | A:1 B:0 |
| 5 | `cf-e-sent-03` | Please do not turn off the lights when you leave. | 请不要关掉灯光,当你离开的时候。 | 请不要在离开时关闭灯。 敬请谅解。 | A:1 B:1 |
| 6 | `cf-e-time-04` | at 6 p.m. | 下午6点 会议 | 下午6点。 | A:1 B:1 |
| 7 | `cf-e-name-01` | Paris | 巴黎 | 巴黎人 | A:1 B:1 |
| 8 | `cf-e-name-03` | Emma | 艾玛 | 〔安全回退→显示原文〕 | A:1 B:0 |
| 9 | `cf-e-name-05` | New York | 纽约 | 纽约总部 | A:1 B:1 |
| 10 | `cf-e-word-03` | weather | 天气 | 天气系统 | A:1 B:1 |
| 11 | `cf-e-phrase-01` | long time no see | 〔安全回退→显示原文〕 | 久不见 | A:0 B:1 |
| 12 | `cf-e-name-04` | David | 戴维 | 大卫·泽西 | A:1 B:1 |
| 13 | `cf-e-phrase-07` | well done | 〔安全回退→显示原文〕 | 好做 | A:0 B:1 |
| 14 | `cf-e-word-05` | hospital | 医院 | 医院介绍 | A:1 B:1 |
| 15 | `cf-e-name-08` | Huangshan | 华盛顿 | 〔安全回退→显示原文〕 | A:1 B:0 |
| 16 | `cf-e-word-09` | airport | 机场 | 机场班车 | A:1 B:1 |
| 17 | `cf-e-time-07` | last winter | 冬天 | 上一个冬天的 | A:1 B:1 |
| 18 | `cf-e-time-03` | yesterday afternoon | 昨天下午 上 | 昨天下午 | A:1 B:1 |
| 19 | `cf-e-phrase-06` | be careful | 要小心 | 〔安全回退→显示原文〕 | A:1 B:0 |
| 20 | `cf-e-name-06` | Professor Li | 李教授 | 〔安全回退→显示原文〕 | A:1 B:0 |
| 21 | `cf-e-phrase-10` | on time | 〔安全回退→显示原文〕 | 时间 | A:0 B:1 |
| 22 | `cf-e-phrase-11` | keep in touch | 保持接触 联系 | 保持联系 | A:1 B:1 |
| 23 | `cf-e-phrase-08` | see you later | 以后见面 | 〔安全回退→显示原文〕 | A:1 B:0 |
| 24 | `cf-e-word-02` | ticket | 彩票注册 | 票 | A:1 B:1 |
| 25 | `cf-e-brand-04` | USB cable | 〔安全回退→显示原文〕 | 〔安全回退→显示原文〕 | A:0 B:0 |
| 26 | `cf-e-word-07` | calendar | 日历 | 电子邮件 | A:1 B:1 |
| 27 | `cf-e-word-01` | station | 站 | 联系方式 | A:1 B:1 |
| 28 | `cf-e-time-05` | in ten minutes | 十分钟后 开始 | 十分钟内 | A:1 B:1 |
| 29 | `cf-e-sent-01` | The train leaves at 7:30. | 火车7:30开机 出发 | 火车在7:30点离开。 | A:1 B:1 |
| 30 | `cf-e-phrase-03` | really tasty | 真的好吃的 | 真的很美味 | A:1 B:1 |
| 31 | `cf-e-brand-01` | GitHub | 〔安全回退→显示原文〕 | 〔安全回退→显示原文〕 | A:0 B:0 |
| 32 | `cf-e-word-06` | subway | 地铁 | 地铁服务 | A:1 B:1 |
| 33 | `cf-e-brand-02` | iOS | 〔安全回退→显示原文〕 | 〔安全回退→显示原文〕 | A:0 B:0 |
| 34 | `cf-e-name-02` | Tokyo | 东京 | 东京都 | A:1 B:1 |
| 35 | `cf-e-word-08` | wallet | 钱包 | 〔安全回退→显示原文〕 | A:1 B:0 |
| 36 | `cf-e-phrase-12` | good luck | 好运 | 好运来娱乐 | A:1 B:1 |
| 37 | `cf-e-phrase-04` | turn left | 转左转 | 转向左 | A:1 B:1 |
| 38 | `cf-e-word-10` | neighbor | 邻居 | 邻居介绍 | A:1 B:1 |
| 39 | `cf-e-brand-05` | Microsoft Teams | 〔安全回退→显示原文〕 | 微软团队 | A:0 B:1 |
| 40 | `cf-e-sent-04` | She will arrive in Beijing tonight and stay for a week. | 她今天晚上到北京,留下一周。 | 她今晚将抵达北京,并停留一周。 | A:1 B:1 |
| 41 | `cf-e-brand-03` | Wi-Fi | 无线上网 | 〔安全回退→显示原文〕 | A:1 B:0 |
| 42 | `cf-e-sent-06` | Remember to bring your ticket tomorrow. | 请记住明天拿出你的门票。 | 记得明天带上你的票。 | A:1 B:1 |
| 43 | `cf-e-brand-06` | Send it via WeChat | 〔安全回退→显示原文〕 | 〔安全回退→显示原文〕 | A:0 B:0 |
| 44 | `cf-e-time-06` | every morning | 每一天早晨 | 每天早上都灵 | A:1 B:1 |
| 45 | `cf-e-sent-05` | We are out of coffee, please buy some more. | 我们没咖啡了,请再买点。 | 我们已经出发了咖啡,请买更多。 | A:1 B:1 |
| 46 | `cf-e-time-01` | tonight | 今晚的节目 | 今晚 | A:1 B:1 |
| 47 | `cf-e-time-08` | the day after tomorrow | 明天之后,就 | 明天之后的日子 | A:1 B:1 |
| 48 | `cf-e-time-02` | this weekend | 本周末 | 这个周末的节目 | A:1 B:1 |
| 49 | `cf-e-word-04` | breakfast | 电子邮件 | 早餐 | A:1 B:1 |
| 50 | `cf-e-sent-02` | I forgot my umbrella at home. | 我把雨伞忘在家里了 | 我在家里忘记了我的伞。 | A:1 B:1 |

## 方向 zh-en

| # | 用例 | 源文 | A | B | 变体 |
| ---: | --- | --- | --- | --- | --- |
| 1 | `cf-z-name-04` | 艾玛 | 〔安全回退→显示原文〕 | Amy | A:0 B:1 |
| 2 | `cf-z-sent-03` | 他在图书馆学习。 | He studied at the library. | He studied in the library. | A:1 B:1 |
| 3 | `cf-z-word-01` | 车站 | The Station | Stations with a | A:1 B:1 |
| 4 | `cf-z-phrase-11` | 没关系 | Never mind the | No matter | A:1 B:1 |
| 5 | `cf-z-name-03` | 纽约 | New York | New York City | A:1 B:1 |
| 6 | `cf-z-time-08` | 后天 | The next day | The Day After | A:1 B:1 |
| 7 | `cf-z-time-01` | 今晚 | This evening | Tonight the cast | A:1 B:1 |
| 8 | `cf-z-time-04` | 下午六点 | Six p.m. on the 6 p.m. | at 6 pm | A:1 B:1 |
| 9 | `cf-z-brand-02` | 华为 | Huawei Spin | Huawei | A:1 B:1 |
| 10 | `cf-z-sent-02` | 我明天早上七点起床。 | I wake up at 7:00 am tomorrow morning. | I'll be up at 7am tomorrow morning. | A:1 B:1 |
| 11 | `cf-z-word-08` | 老板 | The boss | 〔安全回退→显示原文〕 | A:1 B:0 |
| 12 | `cf-z-phrase-01` | 好久不见 | Long time no see the cast. | Long ago not seen | A:1 B:1 |
| 13 | `cf-z-word-10` | 朋友 | and friends | Friend the Friend | A:1 B:1 |
| 14 | `cf-z-name-07` | 王老师 | Teacher Wang | The King Teacher | A:1 B:1 |
| 15 | `cf-z-phrase-05` | 准时 | Timely | On time to the | A:1 B:1 |
| 16 | `cf-z-word-04` | 地铁 | Metro Spin | The Metro | A:1 B:1 |
| 17 | `cf-z-brand-04` | 蓝牙 | Blue tooth | Bluetooth to the | A:1 B:1 |
| 18 | `cf-z-word-07` | 邻居 | Neighbors by the | Neighborhood | A:1 B:1 |
| 19 | `cf-z-brand-06` | 用蓝牙连接耳机 | Connect headset with Bluetooth. | Connect the headset with Bluetooth | A:1 B:1 |
| 20 | `cf-z-name-06` | 李教授 | Professor Lee | Professor Lee | A:1 B:1 |
| 21 | `cf-z-brand-01` | 支付宝 | Payment of Treasures | Alipay and Alipay | A:1 B:1 |
| 22 | `cf-z-phrase-08` | 提前 | Early Early Casting | Pre- | A:1 B:1 |
| 23 | `cf-z-word-03` | 医院 | 〔安全回退→显示原文〕 | Hospital | A:0 B:1 |
| 24 | `cf-z-phrase-12` | 别担心 | Don't worry about the | Do not worry. | A:1 B:1 |
| 25 | `cf-z-sent-04` | 这家餐厅的菜很好吃。 | The food at this restaurant is delicious. | The cuisine in this restaurant is delicious. | A:1 B:1 |
| 26 | `cf-z-sent-05` | 别忘了给妈妈打电话。 | Don’t forget to call my mom. | Don't forget to call your mom. | A:1 B:1 |
| 27 | `cf-z-phrase-10` | 真可惜 | It is sad. | 〔安全回退→显示原文〕 | A:1 B:0 |
| 28 | `cf-z-word-09` | 假期 | Holidays In The Box | vacation | A:1 B:1 |
| 29 | `cf-z-word-02` | 天气 | Weather in the World | The weather | A:1 B:1 |
| 30 | `cf-z-time-05` | 十分钟后 | 10 minutes later | The ten minutes after the | A:1 B:1 |
| 31 | `cf-z-name-02` | 东京 | Tokyo | Tokyo | A:1 B:1 |
| 32 | `cf-z-phrase-02` | 左转 | Left Turn | Left to the | A:1 B:1 |
| 33 | `cf-z-time-02` | 这个周末 | This weekend the | This weekend | A:1 B:1 |
| 34 | `cf-z-sent-01` | 请把空调打开。 | Please turn the air conditioning on. | Please open the air conditioning. | A:1 B:1 |
| 35 | `cf-z-phrase-04` | 做得好 | Well done to the | Doing well | A:1 B:1 |
| 36 | `cf-z-name-08` | 黄山 | Yellow Mountain | Yellow Mountain | A:1 B:1 |
| 37 | `cf-z-brand-05` | 二维码 | 2D Code Box | 2D code | A:1 B:1 |
| 38 | `cf-z-phrase-09` | 我请客 | I invite you to the | I am a request. | A:1 B:1 |
| 39 | `cf-z-time-07` | 去年冬天 | Last Winter | Last winter last year | A:1 B:1 |
| 40 | `cf-z-time-03` | 昨天下午 | Yesterday afternoon the | Yesterday afternoon | A:1 B:1 |
| 41 | `cf-z-sent-06` | 会议室在三楼。 | The conference room is on the third floor. | Conference Room is on the 3rd floor. | A:1 B:1 |
| 42 | `cf-z-word-05` | 钱包 | The Wallet | Wallets for the | A:1 B:1 |
| 43 | `cf-z-phrase-06` | 保持联系 | Keep in contact | Stay in touch with the | A:1 B:1 |
| 44 | `cf-z-name-05` | 大卫 | David | David by David | A:1 B:1 |
| 45 | `cf-z-time-06` | 每天早上 | Every morning | Every morning the | A:1 B:1 |
| 46 | `cf-z-phrase-03` | 小心 | Beware of the | Carefully | A:1 B:1 |
| 47 | `cf-z-phrase-07` | 祝你好运 | Good luck with the | Good luck to you. | A:1 B:1 |
| 48 | `cf-z-name-01` | 巴黎 | Paris | Paris by the Paris | A:1 B:1 |
| 49 | `cf-z-brand-03` | 小米 | Xiaomi | Rice | A:1 B:1 |
| 50 | `cf-z-word-06` | 机场 | Airports Inject | Airports | A:1 B:1 |

