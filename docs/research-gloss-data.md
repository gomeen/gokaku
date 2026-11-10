# 英文释义词性数据调研

更新：2026-11-10。本文记录数据源、许可义务和生成路线；当前 `resources/gloss.tsv` 已实际生成并随验证包使用，当前条目数与哈希以[释义审阅记录](validation/gloss-simplification-review.md)和 `resources/gloss-sources.json` 为准。

## 结论速览

| 来源 | 可随包分发？ | 词性覆盖 | 规模（实测） | 角色 |
| --- | --- | --- | --- | --- |
| Wiktionary／enwiktionary（经 wiktextract，kaikki.org 提取） | **可以**；派生数据文件本身须按 CC BY-SA 4.0 发布，应用代码许可不受影响 | 最好：n/v/adj/adv/pron/intj/conj/classifier/name/character 等 12 类 | 首轮实测 177,531 行／163,236 词头；当前生成表 200,858 条记录（含 jieba／CC-CEDICT 补缺） | **主源，已落地** |
| CC-CEDICT | 可以（CC BY-SA 4.0） | **无词性**（官方明文禁止） | 125,330 条；txt.gz 3.98 MB | 中英对照补全（覆盖更全） |
| Chinese Open Wordnet (COW 1.1) | 可以（自定义宽松许可，须保留声明） | WordNet 粒度 n/a/v/r/x，中文虚词／量词无独立词性 | 82,660 词条；tar.xz 2.9 MB；97% 可连 Princeton WordNet 得英文释义 | 词义关系补充，暂不作主源 |
| Unihan `kDefinition` | 可以（Unicode License V3） | 无词性、仅单字 | 23,310 个码位有英文释义 | 单字补字 |
| wiktextract 工具本体 | MIT | — | — | 提取工具；MIT 不覆盖输出数据 |

**结论：Wiktionary 提取数据是唯一同时满足「公开分发且词性覆盖最好」的来源**；无词性数据可用时核心自动退回只显示译文（`gloss.tsv` 缺省即可降级，`normal_session.cpp` 与 `NormalEngine.swift` 均已支持）。

## Wiktionary 路线（主源）

- **正确数据集**：英文维基词典中的中文语言条目（中文词头＋英文释义＋词性），不是中文维基词典版（`kaikki.org/zhwiktionary/` 的释义是中文，实测 353,456 条中仅 27,224 条带英文翻译）。
- **获取**：kaikki.org 的后处理文件 `kaikki.org/dictionary/Chinese/kaikki.org-dictionary-Chinese.jsonl`（实测 1,214,688,531 B，328,919 行）**已标记 DEPRECATED**（wiktextract issue #1178，将移除）；官方推荐路径是英文版原始转储 `kaikki.org/dictionary/raw-wiktextract-data.jsonl.gz`（实测 3,082,185,963 B ≈ 2.87 GiB）按 `lang_code == "zh"` 过滤（实测 332,735 行）。
- **实测统计**：CJK 词头＋英文释义 177,531 行／163,236 词头；词性分布 noun 85,229、verb 33,888、name 18,109、character 13,941、adj 11,074、phrase 9,275、adv 3,196、pron 594、intj 501、conj 373、classifier 151；9,042 个词头多词性（多义项用 `·` 分隔与规格一致）。以 CC-CEDICT 简体多字词为参照，覆盖率 60.2%（简→繁映射来自 `forms` 的 Simplified-Chinese 标签与 soft-redirect，实测 125,054 条）。
- **质量抽查**：首轮调研中抽看「會議 n. meeting; conference」等条目结构；后续已完成固定种子 50 条审阅，并按 v8.2 规则生成当前产物。当前哈希和条目数见[释义审阅记录](validation/gloss-simplification-review.md)。

## 许可义务（打包前逐项登记到[第三方许可](third-party.md)）

### CC BY-SA 4.0（Wiktionary 文本、CC-CEDICT、wordfreq 数据）

Wiktionary 文本为 CC BY-SA 4.0 ＋ GFDL 双许可（kaikki.org 原文："This data is made available under the same licenses as Wiktionary - both CC-BY-SA and GFDL."）。**选 CC BY-SA 4.0 一支**（双许可任选其一）；GFDL 分支要求衍生材料同样 GFDL 并提供透明副本，不建议。

- ShareAlike 范围（CC 官方口径，[ShareAlike interpretation](https://wiki.creativecommons.org/wiki/ShareAlike_interpretation)）：SA 只约束**改造后的数据文件本身**；「Simply including an SA work unmodified alongside unrelated materials does not produce an adaptation」——把派生 TSV 作为独立数据文件随包分发，应用代码许可不受影响（mere aggregation）。CC FAQ 同口径：合集本身不必 SA。
- **§4(b) 数据库权陷阱**：若把大量派生内容并入我方主张 sui generis 数据库权的数据库（如自有 SQLite），该数据库整体成为 Adapted Material 须 SA。**缓解：注释数据保持纯文本文件（gloss.tsv），不装入主张数据库权的 SQLite**；Gogaku 的 SQLite 仅用于学习记录，与该数据无关。
- 署名（§3(a)(1)，TASL 建议）：保留「Wiktionary contributors, CC BY-SA 4.0」、指向许可的链接、指向免责声明的链接、可行的原文 URI（逐词条链接 `https://en.wiktionary.org/wiki/<词>` 或至少 kaikki.org 页面）、**声明已修改**（wiktextract 提取并改写）、随包附许可全文或 URI。
- CC-CEDICT（MDBG 官方页原文）：「…mention where you got the data from (attribution) and that in case you improve / add to the data you will share these changes under the same license (share alike).」无「不得用于…」类附加限制；官方 wiki 明文不收录词性，只能作中英对照底表。
- wordfreq（英文候选词频排序，见 [英文词表脚本](../scripts/build-english-wordlist.py)）：代码 Apache-2.0；内置数据 CC BY-SA 4.0，NOTICE.md 要求署名 **Robyn Speer**（不得用其他名字）及 SUBTLEX 作者；衍生 top-N 词表须同许可并附完整署名——无署名的纯文本导出即违规。

### SCOWL／ESDB（英文候选词表）

集体作品 MIT-like（README 原文："The combined work is freely available under a MIT-like license"）；逐来源含公有领域（Moby、12Dicts、ENABLE 等）与有条款来源（Princeton WordNet 2.1、Ispell affix、VarCon）。size≤60 不含 70／95 级，避免 UKACD 逐字全文义务；**义务**：随包保留 SCOWL 版权与许可声明、Ispell 声明、WordNet 声明，修改须标注；最省事做法是直接使用官方 zip 自带的 `README_en.txt`。**不要**使用 LibreOffice/dictionaries 的 en_US.dic（该目录 license.txt 为 GPL v2 全文，且 dic 无署名头）。

### COW 与 Unihan（如启用）

COW：自定义宽松许可，许可声明与免责声明须出现在所有副本（含内部修改版）；英文释义经 `omw-en:2.0` 连接 Princeton WordNet 3.0（Princeton WordNet License：保留声明、不得以 Princeton 名义背书）。Unihan：Unicode License V3。

## 当前落地状态

1. `scripts/build-gloss-data.py` 已从来源数据生成 `resources/gloss.tsv`，规则版本和来源哈希写入 `resources/gloss-sources.json`；当前清单记录 200,858 条。
2. 释义生成已完成固定种子审阅、键与长度不变量核查、缺包降级和哈希不一致拒包验证；详见[释义审阅记录](validation/gloss-simplification-review.md)。
3. `resources/gloss.tsv` 已进入普通输入资源链路；缺少该文件时核心继续运行但不显示注释，构建校验失败时拒绝打包。
4. CC BY-SA 4.0、Wiktionary、jieba 与 CC-CEDICT 的署名和许可入口已登记在[第三方许可](third-party.md)。

英文候选词表仍按 SCOWL／wordfreq 路线单独管理，不能把释义数据已落地解释为英文候选、翻译模型或真实宿主能力已验收。