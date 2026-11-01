# 中文输入质量选型：解码器、候选与数据

核查日期：2026-10-30。

本文服务于 Gogaku 中文输入选型，沿用[产品需求](product.md)及[候选边界](input-engine-candidates.md)。首阶段 Intel Mac，必须小鹤双拼，不能用小鹤音形或全拼效果代替。本文主体为最初的源码与官方资料核查快照；后续本机运行的具体版本、数据、许可材料与成绩以[首轮实测](input-engine-benchmark.md)为准，下面标为未验证的历史缺口不应覆盖较新的实测证据。其他解码库及前端已补查至 libpinyin、SunPinyin、Google 开放拼音、OpenVanilla，详见[新增路线](research-ime-alternatives.md)。
「证据」表示固定源码或上游声明；「推断」表示待检验的判断或建议；「未验证」表示尚无运行或产物核验。源码能力不等于 Gogaku 已实现。

## 决策结论

- **推断：三家均应进入实测，目前不能排性能与质量名次。** 优先比较青简的静态及本地重排配置、librime 的现代生产配置、libime 的出厂词库与语言模型。Fcitx 拼音使用 libime，不能算第四个解码器。
- **证据／推断：最简 schema 与现代生产配置不能混比。** 官方小鹤加朙月词库可作机制基线；不能以其输给青简产品包，推出 librime 质量落后。雾凇、万象是数据与方案组合，也不能算新引擎。[r-base][ice][wx]
- **推断：中文数据仍是高风险环节，但尚不能断言是唯一或最薄弱环节。** 覆盖、读音、频率、上下文概率、用户学习与搜索剪枝共同影响结果；必须用消融区分词库缺词、正确路径被剪、排序错误和交互成本。
- **资料更新：新增候选已核查接口，尚未完成同机实测。** libpinyin 源码有小鹤入口，优先补测；SunPinyin 次选，Google 开放拼音保留备选。具体模型包授权、当前 Intel 装配和宿主能力仍需逐件确认，不能记成质量或速度失败。 用户再次明确任何技术栈/框架均可、实际输入性能第一；继续核查其他可复用解码库、原生前端与运行时路线，达到相同小鹤、质量与提交正确性门槛后加入对照。神经插件单列探索项，不因支持大模型就晋升默认配置。

## 固定证据版本

| 组件 | 本次审阅版本／产物边界 |
| --- | --- |
| 青简 | `379139671d191a5c9dc21972a54e15bc1edd9e17`；沿用[既有源码审计](research-qingjian.md)，不代表本机安装版。 |
| librime | `56737cd29a4d393a104a2098ece3697aa2810465`；官方小鹤方案 `01a13287cbd27819be1c34fa1ddc1b3643d5001b`。 |
| octagram | 插件 `57d18b9f58e5284bd891d559f6bdd16cf60341e9`；八股文数据 `8ceef1b42eb77e86501382a52e85c309c0f2f04c`。 |
| Rime 生产方案 | 雾凇 `da1fbe602e38f26db846fa10120ee64c2b0324c0`；万象 `53f839595e38405c295f51e102e6a9662278c1f7`，数据仓库 `6ea60e43339de4257bf815529e0fccac0704670a`。 |
| libime | `5be1300ea00e899b3f2c46d1e9f6bca21139cdeb`；Fcitx 拼音插件 `e8d930f402e359cfd76a101ee3e46815d1331d83`。 |
| Rime 神经探索 | ai-predict `e40ab6b3f0bc033abb66271c24cc24cd81b54c2d`；rime-llm-reranker `700ad82ec5c5a4983652183238b77f38cfdaf85a`。 |

## 三家的质量机制与实际取舍

| 维度 | 青简 | librime | libime／Fcitx 拼音 |
| --- | --- | --- | --- |
| 小鹤、音节与不完整输入 | **证据：**双拼先解为带边界拼音；末尾单键作前缀，仅整串无已配音节时退回逐键简拼。不能承诺任意双拼简拼混排；双拼关闭中文拼写纠错。[q-sp] | **证据：**小鹤由 algebra 和 prism 映射；音节图支持多路径、简拼与补全，具体能力取决于方案规则及 translator 开关。[r-base][r-syl] | **证据：**内置 Xiaohe；双拼解析取表中最长合法匹配，`PartialSp` 可补单键边；双拼解析明确去掉 `AdvancedTypo`。不能套用全拼高级纠错结论。[i-sp][i-parse] |
| 连续长句与歧义 | **证据：**词图、Viterbi／束搜索、统计模型与个人 n-gram 插值；静态未知词用词频回退。默认格候选 6、简拼格 20、beam 8，存在覆盖与剪枝取舍。[q-sent] | **证据：**script translator 查词、用户词及组句，Poet 从词图组成句子；可接 grammar。不是只能逐词选，也不能把普通组句当作神经生成。[r-script][r-poet] | **证据：**音节图、lattice、语言模型与 n-best 解码，接口暴露 beam、frame、nbest 等限制；增加搜索规模的收益与成本未测。[i-ctx][i-ime] |
| 局部选词与修订 | **证据：**部分选择可暂存，整段完成再提交；退格撤销暂存。选择不等于立即输出全部内容。[q-held] | **证据：**选中短候选可能只确认当前段，仍留编码；可重新分段与撤销。候选可只覆盖输入前缀。[r-engine] | **证据：**`select`、`selected`、`cancel` 与 `learn` 分开；局部候选和完整选择是不同状态。[i-ctx] |
| 标点与自定义 | **证据：**有标点与自定义短语管线，短语权重可盖过普通候选；需测数字、小数、引号和剩余编码边界。[q-src] | **证据：**punctuator、key_binder、词典及脚本由 schema 装配；生产方案含额外规则，最简方案结果不可外推。[r-base][wx-schema] | **证据：**libime 给编码、词典和上下文；Fcitx 插件另外处理按键、标点及自定义短语，不能把插件体验全归给库。[i-addon] |
| 用户学习 | **证据：**词频加分、个人二／三元插值与衰减；官方仍列“拼出的整句反复选后首选未必改变”的已知问题。[q-sent][q-readme] | **证据：**提交时学习原始 Phrase、更新用户词典；用户词和静态词混合排序。是否记住某整句取决于组句、记忆和方案规则。[r-memory][r-script] | **证据：**用户词典、HistoryBigram 与用户语言模型；学习由调用方触发。仅调用候选查询不代表已学习。[i-ctx][i-user] |
| 候选重排 | **证据：**支持统计排序、同步／异步 SentenceScorer；异步缺分时先给静态序，结果到达后重新查询，重排与直接生成是两种路径。[q-rescore] | **证据：**grammar 可参与组句及有前文的候选加权；当前 contextual translation 分批读取，按覆盖范围／候选类型分组排序，并非全候选任意全局重排。[r-context][r-grammar] | **证据：**静态语言模型与用户历史参与解码；本轮没有核实可直接用作生产默认的神经重排配置。[i-user] |
| 增量处理 | **证据：**SpanCache 复用词图格子，按键增加时复用未变跨度。[q-sent] | **证据：**分段复用、候选惰性求值；不等于所有查词和组句都只计算新增字符。[r-engine][r-script] | **证据：**上下文更新合并音节图、保留有效 lattice；编辑导致的失效范围仍需逐键测。[i-impl] |

**推断：**三者都有复用机制，不能按“是否增量”二分，更不能凭语言、API 返回快慢或框架层数选冠军。扩大 beam、候选数和补全范围可能提升召回，也可能加重延迟和干扰排序；学习与模型增益必须一起报告候选稳定性。

## 现代语言模型：Rime 的边界

- **证据：**octagram 接入统计语言模型，不是神经大模型；官方八股文称数据由开放互联网语料自动精炼。模型与词典词汇、分词和得分尺度不匹配时，不能预设开启就变好。[oct][oct-data]
- **证据：**万象标准方案包含 grammar，支持 `/flypy` 小鹤；不是必须启用形码辅助的方案。实测应明确固定标准版、小鹤映射、词表和实际下载的 gram，而非只记录“用了万象”。[wx-schema]
- **证据：**ai-predict 使用 CTranslate2、后台推理与刷新协议，默认 AI 候选位于第二位；是新增预测候选与候选合并机制，不能称为单纯对现有候选打分。[ai][ai-trans]
- **证据／未验证：**其预编译包仅 arm64，README 给出 Intel 源码构建路径；本轮未验证 Intel 运行、延迟和资源。模型输入构造直接使用去空格后的 raw input，未核实将小鹤编码还原全拼的适配，不能直接用于本项目中文主赛。[ai][ai-context]
- **证据／未验证：**rime-llm-reranker 文档推荐 oMLX／MLX 模型，其推荐路径不能证明 Intel 可用或达到交互预算；保留未验证，不进入首轮主赛。[llm]
- **推断：**神经生成需另测错音、漏字、添字和续写侵入；原候选重排则受原候选召回上限约束。异步结果需同时记录首次可见与最终稳定的质量，不能等待任意久后只报高分。

## 数据、频率与许可：可替换不等于无损替换

| 数据／组件 | 已核实的一手边界 | 对选型的影响 |
| --- | --- | --- |
| 青简字词与读音 | **证据：**THUOCL 为 MIT、Unihan 为 Unicode License v3；规范字表和常用词表的转录来源存在未附许可项。领域 DF 是文档频率，不是统一词频；各域 DF 不可直接横比。[q-data][q-land] | **推断：**必须检查读音、同音权重与领域词惩罚，不能以词条总数评价质量。新词目录存在不等于已有新词，`04_internet_slang` 明示预留无数据。[q-data] |
| 青简统计模型 | **证据：**维基与 LCCC 来源分别列 CC BY-SA 4.0、MIT；百科与对话风格不同。[q-land] | **推断：**需分日常口语、专业词和新实体测覆盖，避免百科词频支配口语。 |
| 青简神经权重 | **证据：**下载选择含 `zhiyi-v1.0.0`、`hanzhang-tongbian-v1.0.0`；源码分别声明知意 Apache-2.0、含章打包 GPL-3.0-or-later；通变训练语料许可口径有差异，详见[既有审计](research-qingjian.md)。 | **后续更新：**首轮 data-v8 包内附带的通变 small 文件已下载并列账，但未加载；知意独立权重及神经小鹤效果未验收，不能把统计配置成绩算作神经能力。重排器与直接生成器应分别测。 |
| librime 与官方基线数据 | **证据：**引擎 BSD-3-Clause；小鹤 schema GPL v3，朙月词库 LGPL v3；octagram 插件 BSD-3-Clause，八股文数据 LICENSE 为 LGPL v3。[r-license][r-base][oct][oct-license] | **推断：**代码、映射、词库、语言模型逐件列账。八股文来源说明不构成完整训练语料清单。 |
| 雾凇 | **证据：**仓库 LICENSE 为 GPL v3，词库及方案见固定提交。[ice] | **未验证：**未完成其全部第三方词库及具体模型分发审计；不能以 librime 的 BSD 覆盖。 |
| 万象／万象数据 | **证据：**项目声明 CC BY 4.0；数据仓库 NOTICE 明示第三方保留原许可。README 的“海量语料优化”不是可复现语料清单。[wx][wx-data][wx-notice] | **后续更新：**首轮已下载并固定具体 LTS gram 哈希，保留对应许可与 NOTICE；完整训练来源和最终分发审计仍未完成，仓库授权不能自动覆盖所有外链模型。 |
| libime 出厂词库与模型 | **证据：**REUSE 声明数据 LGPL-2.1-or-later；构建固定 `dict-20260907.tar.zst`、`lm_sc.arpa-20260629.tar.zst` 及 SHA256，分别生成词库、语言模型与预测数据。[i-reuse][i-data] | **后续更新：**首轮已下载、核对源码预期哈希、转换数据并保留 REUSE 声明及依赖许可；完整分发审计仍待完成。日期仅为产物标识，不证明语料新鲜或新品牌覆盖。 |
| Rime ai-predict 权重 | **证据：**插件 BSD-3-Clause，README 指向约 300 MB 的 `zh-base-ct2-int8` 简体中文模型。[ai] | **未验证：**权重训练来源、独立授权和固定 release／哈希未核实，不把插件许可证外推到权重。 |

**证据／推断：**三家都可替换或转换词表，但权重语义、平滑、未知词代价、读音与词 ID 不等价；替换词表后仍保留原语言模型，不构成严格同数据对照。生产赛道比较可交付体验；受控赛道隔离因素，不能把差额全部归因于解码器。
**推断：**确认“数据最薄弱”需要逐条归因：目标是否有正确读音词条→是否能组成路径→是否进入搜索候选→是否排进可见页→用户能否低成本选到。新词可逐字组出，缺整词不等于无法输入；但会增加按键和选择成本。

## 首轮实测组合与退出条件

| 组合 | 配置建议（均为推断） | 退出或降级条件（待实测） |
| --- | --- | --- |
| Q0／Q1 | 青简小鹤＋推荐静态词库／统计模型；Q1 仅增加知意本地重排。通变生成另作 Q2，不与知意混开。固定包版本、搜索参数、前文权限。 | 权重包不可固定或许可不能满足分发，移出交付候选；Q1 没有稳定质量收益或增加明显候选跳动，则退 Q0。 |
| R0 | 官方小鹤＋朙月，作为机制和回归基线。 | 不因输给现代产品包淘汰 librime；只据此定位词表、模型或规则差异。 |
| R1／R2 | R1 雾凇小鹤推荐配置；R2 万象标准版小鹤＋其配套词库和 grammar。逐项记录实际加载插件、纠错、补全、英文混输及模型，不随意删到最简。 | 某包缺少可核验模型、许可或 Intel 可运行产物，则明确缺项、暂缓该配置；不能记为引擎质量失败。 |
| I0 | libime Xiaohe＋出厂 `sc.dict`／`zh_CN.lm`＋用户模型；固定解码参数。Fcitx 使用相同 libime／数据时只作为交互路径补测。 | 找不到可接受质量与延迟的参数组合再淘汰；不能因某前端标点策略失误直接淘汰解码库。 |
| N0 | Rime 神经插件待 Intel 构建、小鹤条件输入、权重来源和候选刷新验证后再加入。 | 任一前提未核实则保留未验证，不占首轮主赛、不替代 R1／R2。 |

**推断：**所有组合默认离线，关闭云联想；统一简体输出、小鹤键位、候选页大小及可用选择键。生产配置原始行为另保留一次结果，披露为公平比较所做的开关变动。先冻结测试集和预算，再测，避免为某家反复调参后只报最佳值。

## 公平质量评估：按完整任务，而非一次 API 调用

1. **推断：分两赛道。** 生产赛道保留各自推荐词表／模型；受控赛道统一合法词表、读音、频率来源和小鹤映射，先禁用用户学习及神经模型，再分别加入语言模型。不能统一的组件明确列出，避免伪称纯引擎排名。
2. **推断：冻结分层目标。** 覆盖高频口语、长句、同音歧义、多音字、零声母、小鹤末尾单键、简拼、姓名／新品牌／术语、中英数字、标点和错误输入；记录句长与领域。训练集和评测集分离，不从参赛词库抽题；多种合理答案预先标注。
3. **推断：首选与 Top-k 分开。** 同一确定输入状态，报告 Top-1、Top-5、Top-10、整句精确命中及字错误率；去重，并区分覆盖全段的整句候选和只消费前缀的词候选。多个短候选能拼成目标，不算该整句 Top-k 命中。
4. **推断：测完成目标的总按键。** 固定操作策略，统计编码、空格／数字确认、移动、局部选词、翻页、退格、更正和分隔符，给出每个目标总量及每汉字按键数。最优候选选择的 oracle 下界与实际用户操作分开，不把全串一次输入强加给本来适合分段的方案。
5. **推断：测候选稳定性。** 记录相同输入无新按键时异步更新的 Top-1 翻转、Top-5 位次变化、稳定所需时间；对连续按键只比较仍解释相同已输入前缀的候选。另测翻页、悬停／选择及退格重输期间目标索引是否跳动，避免把正常新增输入导致的换首选算错误。
6. **推断：质量与延迟绑定。** 在同一事件时间线记录首次可见、固定 50／100／200 ms 截止点及最终稳定候选质量；这些是观察点，不是已批准的产品 SLA。计时必须包含实际候选生成和翻页所需惰性枚举，报告冷／热 p50、p95、p99、超时率及资源；不能只测 `process_key` 返回。
7. **推断：学习单独测。** 使用全新隔离用户目录，再回放同一选词训练轨迹，测首次、重复若干次、重启、隔日衰减与删除后的变化；同时测近音／同音常见词退化、一次误选污染、恢复所需操作、学习写盘延迟。不可使用私人历史给某家加分。
8. **推断：按质量—成本前沿退出。** 预先约定可接受的长尾延迟、内存、完成率与任务按键预算；某配置被另一配置在质量、按键和延迟上稳定支配才退出。使用配对样本与置信区间；新词、长句等关键分层失败不能被总体均分掩盖。

## 一手证据链接

[q-src]: https://github.com/qingjian-team/qingjian/tree/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src
[q-readme]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/README.md
[q-sp]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/shuangpin/layout.rs
[q-sent]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/sentence/mod.rs
[q-held]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/held/mod.rs
[q-rescore]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/crates/qingjian-core/src/engine/rescoring/mod.rs
[q-data]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/assets/lexicon/README.md
[q-land]: https://github.com/qingjian-team/qingjian/blob/379139671d191a5c9dc21972a54e15bc1edd9e17/docs/design/landscape.md
[r-base]: https://github.com/rime/rime-double-pinyin/blob/01a13287cbd27819be1c34fa1ddc1b3643d5001b/double_pinyin_flypy.schema.yaml
[r-syl]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/algo/syllabifier.cc
[r-script]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/script_translator.cc
[r-poet]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/poet.cc
[r-engine]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/engine.cc
[r-memory]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/memory.cc
[r-context]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/contextual_translation.cc
[r-grammar]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/grammar.h
[r-license]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/LICENSE
[oct]: https://github.com/lotem/librime-octagram/tree/57d18b9f58e5284bd891d559f6bdd16cf60341e9
[oct-data]: https://github.com/lotem/rime-octagram-data/blob/8ceef1b42eb77e86501382a52e85c309c0f2f04c/README.md
[oct-license]: https://github.com/lotem/rime-octagram-data/blob/8ceef1b42eb77e86501382a52e85c309c0f2f04c/LICENSE
[ice]: https://github.com/iDvel/rime-ice/tree/da1fbe602e38f26db846fa10120ee64c2b0324c0
[wx]: https://github.com/amzxyz/rime-wanxiang/tree/53f839595e38405c295f51e102e6a9662278c1f7
[wx-schema]: https://github.com/amzxyz/rime-wanxiang/blob/53f839595e38405c295f51e102e6a9662278c1f7/wanxiang.schema.yaml
[wx-data]: https://github.com/amzxyz/rime-wanxiang-data/blob/6ea60e43339de4257bf815529e0fccac0704670a/LICENSE
[wx-notice]: https://github.com/amzxyz/rime-wanxiang-data/blob/6ea60e43339de4257bf815529e0fccac0704670a/NOTICE.md
[i-sp]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/src/libime/pinyin/shuangpinprofile.h
[i-parse]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/src/libime/pinyin/pinyinencoder.cpp
[i-ctx]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/src/libime/pinyin/pinyincontext.h
[i-ime]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/src/libime/pinyin/pinyinime.h
[i-impl]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/src/libime/pinyin/pinyincontext.cpp
[i-user]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/src/libime/core/userlanguagemodel.cpp
[i-addon]: https://github.com/fcitx/fcitx5-chinese-addons/blob/e8d930f402e359cfd76a101ee3e46815d1331d83/im/pinyin/pinyin.cpp
[i-reuse]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/REUSE.toml
[i-data]: https://github.com/fcitx/libime/blob/5be1300ea00e899b3f2c46d1e9f6bca21139cdeb/data/CMakeLists.txt
[ai]: https://github.com/wyjrichhh/librime-ai-predict/blob/e40ab6b3f0bc033abb66271c24cc24cd81b54c2d/README.md
[ai-trans]: https://github.com/wyjrichhh/librime-ai-predict/blob/e40ab6b3f0bc033abb66271c24cc24cd81b54c2d/src/predict_translator.cc
[ai-context]: https://github.com/wyjrichhh/librime-ai-predict/blob/e40ab6b3f0bc033abb66271c24cc24cd81b54c2d/src/context_builder.cc
[llm]: https://github.com/FuJiK0/rime-llm-reranker/blob/700ad82ec5c5a4983652183238b77f38cfdaf85a/README.md
