# 青简源码核查

目标是验证 Gogaku 首阶段 macOS 输入与离线能力的可复用基础，明确包含小鹤双拼。本报告只核查青简，不代替真实系统 API、宿主应用与 Rime 运行验证。

## 版本与证据范围

- 官方仓库为 [qingjian-team/qingjian](https://github.com/qingjian-team/qingjian)，README 列出官方发布渠道。[r1]
- 本次浅克隆目录为 `/tmp/gogaku-validation/qingjian`，固定提交为 `379139671d191a5c9dc21972a54e15bc1edd9e17`，提交时间为 `2026-10-30T09:22:01+08:00`。
- 本机仅只读查询 `~/Library/Input Methods/Qingjian.app/Contents/Info.plist`。短版本为 `0.3.2-dev-dfdf8408+`，构建号为 `709`，不能把当前源码结论视为该安装版本的运行表现。
- 以下“已有”均指固定提交中的源码或官方文档证据，不代表本次实际执行成功。测试里的样例仅作代码证据。
- 未启动、切换、退出或重装青简，未读取输入日志、配置、个人词库或正文。没有调用其他代理，没有把青简源码复制进 Gogaku。

## 小鹤双拼到中文输出

- **已有小鹤方案。** `Scheme::Xiaohe` 对应配置键 `xiaohe` 和“小鹤双拼”标签，不是待开发方案。[r2]
- **组句共用管线。** `query_phonetic` 先 `decode(keys)` 得到全拼，再切分、查词和生成候选。双拼解码后的音节间有分隔，不能直接把原始双拼串喂全拼翻译逻辑。[r3]
- **简拼有限制。** 两键配音节，末尾单键按前缀处理。只有整串未配出任何音节时才退回“每键一个声母”的简拼，不能承诺任意双拼与简拼混排都成立。[r4]
- 源码测试给出小鹤 `kdfa → 开发`，预编辑 `kai'fa`，`kdf` 可得“开放”。输入框与候选窗各有原始按键显示开关。[r5][r6]
- **中文提交路径。** macOS `commit_index` 取候选，调用 `engine.commit`，非空返回值才通过 `client.insert_text` 上屏。部分选择可能暂存在组句，默认并非每次选词立即提交。[r7][r10]
- **双拼 english-tail 明确禁用。** `split_english_tail` 在 `self.shuangpin.is_some()` 时直接返回 `None`。不能拿全拼的“拼音头 + 英文尾”例子证明小鹤混输能力；整段英文候选是另一条路径。[r11][r44]

## 选中文候选后只提交英语的接缝

- **现有普通键仍提交中文。** 普通候选提交走 `commit`，译词提交另走 `commit_translation(candidate, sense)`，两条不能混为学习模式。[r7][r8]
- **已有不先上屏中文的译词路径。** `commit_translation` 取第 `sense` 条译词，复用中文候选的学习与拼音消耗，但返回译词。macOS `commit_translation_at` 直接把此返回值交给 `insert_text`。[r8][r9]
- 该函数找不到释义时返回 `None`，在取词失败前不消耗输入。macOS 吞掉译词键而不提交猜测文字。[r8][r9]
- **接缝判断。** 可评估将学习模式下的候选确认分派到译词路径，保留普通模式的中文路径。这只是接缝建议，尚无 Gogaku 模式、快捷键或菜单实现。
- **复用风险。** `commit_translation` 同时记录候选学习并调用 `take_held()`，可能把前面暂存的中文一起输出。不能只把 `commit_index` 中一个函数名替换掉，就声称整段稳定只出英语。[r8][r10]
- 词典命中译词可直接提交；自由句子未必有词条释义。按词翻译不能证明整句翻译准确或拼接自然。[r15][r17]

## 英文、双向词级释义与拼写

- **英文直输与英文候选是两种状态。** macOS 按应用白名单控制英文候选。未允许时字母直接插入，允许时进组词缓冲并显示候选。[r14][r30]
- 英文模式的查询在双拼解码之前分流，因此小鹤配置不等于禁用英文模式。中文模式的整段英文查词、条件补全也没有双拼总开关阻断。[r12][r44]
- `english::suggest` 按精确词、前缀补全、一处编辑建议生成候选。纠正仅对至少 4 个纯字母的输入尝试，含数字或符号不猜。它不是完整拼写诊断器，更不是语法检查。[r13]
- macOS 实际按键代码为空格选高亮并继续交出空格，数字选候选，回车和标点保留原输入；不要依赖 `english/mod.rs` 顶部仍写“空格原样”的旧注释。[r14]
- `annotate` 对英文候选调用 `english_translator`，对中文调用学习语言 `translator`。英文键会尝试转小写，两方向不是把一张释义表反转。[r8]
- `Translator` 明确要求纯查表、不可联网；`LayeredTranslator` 先个人表再随包表。官方分别提供 `glossary-en.tsv` 与英文候选的 `glossary-zh.tsv`。[r15][r16][r17][r18]
- 中文拼音纠错在双拼下直接禁用；这与英文模式自身的一处编辑建议不同。未找到针对用户英语、按完成边界检查、可点击说明的波浪线诊断实现。[r19][r13][r28]
- **产品差异。** 现有“给纠正候选”不能直接等同 Gogaku 的“保留英语原输入，只标疑似问题、不提供纠正操作”。

## 异步翻译与过期保护

- macOS 当前装配 `CloudPredictor` 与 `CloudGlossFiller`，云开关关闭则装配无操作实现。选区翻译入口也先检查云服务状态，不构成离线句子翻译实现。[r20][r21]
- Core 已有 `translation_predictor` 可选接口，但接口存在不代表 macOS 已接本地实现。选区翻译与候选句翻译共享请求机制，不能从名称推断后端离线。[r22][r20]
- 请求携带递增 `sequence`。待处理表只保留相关请求，取消时清表，`poll_prediction` 丢弃没有待处理记录的结果。候选重生成另按请求序号与候选快照处理。[r22][r23]
- **保护边界。** 普通选区翻译的 macOS `TranslationJob` 仅存 `range` 与 `result`，没有宿主应用标识、源文字快照或输入版本；不能把 Core 序号保护当成 Gogaku 完整焦点和原文一致性保护。[r24]
- 现有选区翻译需用户再按回车、空格或 1 替换原选区，Esc 放弃。这是“选中已提交正文再翻译”的流程，不是 Gogaku 默认“中文选词后英语一次上屏”。[r21][r25]
- 译词查表不需要异步翻译。自由句子本地翻译、超时退路、应用切换后的目标绑定仍待实现与真机验证。

## macOS 预编辑、候选 UI 与模式

- `TextClient::set_marked_text` 当前传普通 `NSString`，不是带错误范围的富文本。`insert_text` 把文本提交给宿主。这里没有给宿主已提交正文添加波浪线或点击说明的实现。[r25]
- 候选窗是自绘 `NSPanel`。输入框行内预编辑与候选窗预编辑可分别显示；只在候选窗显示时，宿主仍放零宽 marked text 维持组句状态。[r26][r27]
- 当前 macOS 预编辑样式只有 `Typed`、`Rest`、`Struck`，纠错显示删除线，不是英语错误波浪线。候选自绘区可作为新样式和点击命中的改造点，但需要新增错误区间、命中与说明逻辑。[r28]
- **边界判断。** 自有候选区比宿主正文可控；行内富文本样式仍需宿主兼容性验证。源码不能证明所有 App 都支持同样的下划线、鼠标交互或正文装饰。
- macOS 模式是 Caps Lock，或可选单击 Shift 切中英；`ModeSwitch` 持有单个 `english` 状态，不是按 bundle 保存学习模式。[r29]
- 按 App 已有的是英文候选开关。官方“按应用记住中英模式”标明 Windows，不能套用到 macOS，更不能等同学习模式及翻译方向记忆。[r30][r33]
- 菜单已有云联想、模糊音、符号面板、设置和日志入口，没有普通与学习模式、翻译方向切换项。译词、选区翻译有独立快捷键通路。[r31][r9][r21]
- 停用时源码会 `commit_raw`，取消请求并隐藏窗口；单击 Shift 切英文也可能原样提交组句。因此不能直接满足 Gogaku“切换时不自动提交、丢字或串应用”的约束。[r32][r29]

## 源码、数据与模型许可

- **代码。** 官方声明 GPL-3.0-or-later，名称与 logo 不在代码授权内。复制或组合分发前需确定 Gogaku 的许可策略，不能默认闭源复用。[r34]
- **UI 组件。** `qingjian-render` 为 GPL-3.0-or-later 或商业许可，商业授权不覆盖 themes 素材，不能推导整款输入法都可任选商业授权。[r35]
- **中文词库。** THUOCL 为 MIT，读音 Unihan 为 Unicode License v3；规范字表与常用词表的转录仓库未附许可证。官方来源清单自己已标出这一缺口，不能统称“词库都是 GPL 或 MIT”。[r36]
- **英文词库与频率。** ESDB 为 MIT-like 且含 WordNet 声明，CSpell 为 MIT，typos 双许可中采用 MIT；须保留原文。wordfreq 代码 MIT、数据有 CC-BY-SA 等，频率衍生物仍需按具体产物核对。[r37][r36]
- **双向释义表。** `assets/glossary/README.md` 声明各表 GPL-3.0-or-later，英译词由 LLM 离线生成。这里“离线生成”指预先生产数据，不是设备有离线翻译模型，也不保证词义准确。[r17][r18]
- **统计语言模型。** 官方将中文维基与 LCCC 统计来源分别列为 CC BY-SA 4.0 与 MIT。它用于中文候选概率，不是中英互译。[r36]
- **含章权重。** `pack-model.sh` 将权重许可写成 GPL-3.0-or-later。通变是拼音到汉字，知微是候选重排且官方记录已下线，都不能当翻译模型。通变脚本写维基 CC-BY-SA-3.0 与 GFDL，来源表写 4.0，两者口径不同，分发前还须核对具体语料与权重包。[r38][r43][r36]
- **知意权重。** 加载器注明自 2026-10-20 为 Apache-2.0，功能为选词评分。它与另一份 `zh.ngram` 三元模型不是同一产物；后者官方记录 LGPL-2.1-or-later，且要求分发前核对 NOTICE 与来源。[r39][r41]
- 当前 macOS 下载选择为 `zhiyi-v1.0.0` 与 `hanzhang-tongbian-v1.0.0`。本次未下载模型包、核验内部 LICENSE、NOTICE 或哈希，因此不作模型再分发许可已全部验收的结论。[r40]
- **小鹤双拼不等于小鹤音形。** 小鹤拼音方案已有代码，但官方资料指出小鹤“形码部分”无开放许可，不能由双拼支持推导可打包音形词库。[r2][r42]

## 结论与未运行部分

源码支持把小鹤中文引擎、双向词级查表和一次译词提交列为复用候选。离线自由句翻译、点击英语波浪线、macOS 按 App 学习模式仍没有被本报告证明。
源码核查阶段没有编译或运行青简。随后主代理在上述固定提交实际运行 `qingjian-core` 的名称筛选测试，双拼相关 38 项通过，翻译相关 21 项通过。日志及范围见[可行性验证](feasibility.md)。这些是核心单元测试，不是完整 macOS 输入法、真实模型、延迟、内存、断网质量或宿主兼容性验收。
本次遵循 Prove It Works，逐项核对真实源码并固定提交，不用 API 名称或注释代替实际装配证据。源码核查阶段只写入本报告，后续探针和测试记录另行整理。

## 固定提交证据


[r1]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/README.md#L37-L49
[r2]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/shuangpin/scheme/mod.rs#L13-L79
[r3]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/query/phonetic.rs#L19-L57
[r4]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/shuangpin/layout.rs#L270-L340
[r5]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/tests/shuangpin.rs#L5-L27
[r6]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/tests/shuangpin.rs#L29-L145
[r7]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/imk/controller/commit.rs#L19-L36
[r8]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/commit/mod.rs#L27-L106
[r9]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/imk/controller/translate.rs#L78-L108
[r10]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/held/mod.rs#L10-L34
[r11]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/query/english_tail.rs#L43-L64
[r12]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/query/mod.rs#L97-L124
[r13]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/english/mod.rs#L10-L67
[r14]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/imk/controller/text.rs#L8-L130
[r15]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/translator.rs#L1-L17
[r16]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-translate/src/layered_translator.rs#L35-L49
[r17]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/assets/glossary/README.md#L1-L14
[r18]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/assets/glossary/README.md#L88-L99
[r19]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/correcting.rs#L6-L18
[r20]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/host/config/mod.rs#L115-L141
[r21]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/imk/controller/translate.rs#L10-L78
[r22]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/prediction/mod.rs#L242-L394
[r23]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/host/cloud/mod.rs#L104-L159
[r24]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/host/presenting/translation_job.rs#L1-L11
[r25]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/imk/client.rs#L36-L84
[r26]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/imk/controller/display.rs#L10-L90
[r27]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/candidates/mod.rs#L1-L24
[r28]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/candidates/preedit/style.rs#L1-L26
[r29]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/host/mode/switch.rs#L30-L151
[r30]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/host/presenting/mod.rs#L81-L98
[r31]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/menubar/menu.rs#L32-L99
[r32]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/macos/src/imk/controller/mod.rs#L162-L187
[r33]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/docs/user/input/english-mode.md#L45-L57
[r34]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/README.md#L69-L69
[r35]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-render/LICENSE.md#L1-L14
[r36]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/docs/design/landscape.md#L33-L47
[r37]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/assets/lexicon/05_english/README.md#L33-L39
[r38]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/tools/release/pack-model.sh#L16-L44
[r39]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-neural/src/zhiyi/mod.rs#L1-L5
[r40]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/apps/settings/src/jobs/model_download/pack.rs#L28-L60
[r41]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/docs/notes/crate-notes.md#L342-L348
[r42]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/docs/design/aux-code.md#L130-L137
[r43]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/docs/notes/model-identities.md#L1-L10
[r44]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/extras.rs#L130-L204
