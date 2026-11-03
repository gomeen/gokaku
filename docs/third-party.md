# 第三方组件与本机开发版许可边界

Gogaku 项目许可尚未决定；当前包仅用于本机开发，不代表可公开分发。没有复制青简前端、词库或个人数据。

| 组件 | 固定版本/来源 | 许可与处理 |
| --- | --- | --- |
| libime | 1.1.17，`5be1300ea00e899b3f2c46d1e9f6bca21139cdeb` | LGPL-2.1-or-later；动态链接，保留声明、许可与可重建薄桥接 |
| 出厂中文词典/模型 | dict-20260907、lm_sc.arpa-20260629；哈希见 dependencies.lock.json | 上游 REUSE.toml 标为 LGPL-2.1-or-later；不导入其他输入法私人词库 |
| Fcitx5Utils | 5.1.20，`dfb1278cce616a771eb51a99a468bbd69f02613f` | LGPL-2.1-or-later；Unicode 数据另为 Unicode-DFS-2016 |
| KenLM | `4cb443e60b7bf2c0ddf3c745378f76cb59e254e5` | 保留 COPYING、COPYING.3、COPYING.LESSER.3 及辅助文件许可；不一概改写为单一许可 |
| ECM | `7dd28cc56c339c3f8fb356f7c53c0e8f61433d81` | BSD-3-Clause；只用于构建 |
| Boost | 本机 1.92.0_1 | BSL-1.0；头文件及实际链接的 `libboost_iostreams.dylib`、`libboost_random.dylib`，保留官方Boost许可 |
| zstd | 本机 1.5.7_1 的 `libzstd.1.dylib` | 选择上游BSD-3-Clause许可，保留LICENSE，不把双许可的GPL文本当作唯一选择 |
| GNU gettext libintl | 本机 gettext 1.0 的 `libintl.8.dylib` | 安装头文件明确LGPL-2.1-or-later；保留作者声明与LGPL全文，未打包GPL命令行程序 |
| XZ liblzma | 本机 5.8.4 的 `liblzma.5.dylib`，由Boost间接链接 | 该版本COPYING明确liblzma为0BSD，保留COPYING与COPYING.0BSD |
| SQLite、Apple 框架 | 操作系统提供 | 不打包系统实现、翻译权重或伪造其哈希 |
| Fira Code WenKai（候选窗字体） | 用户已安装（`~/Library/Fonts`，OFL） | 仅按字体名引用，不随包分发；缺失时回退系统字体，不产生分发义务 |
| SCOWL／ESDB en_US 词表 | scowl-2020.12.07 官方发布包（SourceForge wordlist 项目；tarball sha256 `5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc`），经官方 `mk-list -d final en_US 60` 生成 | 集体作品 MIT-like（保留版权与许可声明）；逐来源含公有领域与 Princeton WordNet／Ispell affix 等有条款来源，声明全文随包附 `Licenses/SCOWL-Copyright.txt` |
| wordfreq 英文词频 | rspeer/wordfreq 3.1.1，`top_n_list('en', 200000)` | 代码 Apache-2.0；内置数据 CC BY-SA 4.0；衍生词表同许可分发，署名 Robyn Speer 及 SUBTLEX 作者（van Heuven et al. 2014），见随包 `Licenses/DATA-ATTRIBUTION.txt` 与 `Licenses/CC-BY-SA-4.0.txt` |
| 英文释义词性数据（gloss.tsv） | Wiktionary 英文版中文词条，经 wiktextract 提取（kaikki.org Chinese 提取文件；具体文件哈希见 `resources/gloss-sources.json` 与 gloss.tsv 文件头） | CC BY-SA 4.0（双许可取 CC 一支）；署名 Wiktionary contributors、许可／免责链接、逐词条原文 URI、声明修改（wiktextract 提取并改写）；ShareAlike 只约束该数据文件本身，纯文本独立分发不并入主张数据库权的 SQLite；全文随包附 `Licenses/CC-BY-SA-4.0.txt` |
| 词性标注层（gloss.tsv） | jieba `jieba/dict.txt`（github.com/fxsjy/jieba，master 2026-11-03 拉取；哈希见 `resources/gloss-sources.json`） | MIT（版权 2013 Sun Junyi）；保留版权与许可声明，全文随包附 `Licenses/MIT-jieba.txt`；仅提取词性标注（单字＋多字词）为衍生数据，不改标语义 |
| Wiktionary 缺失词补义项（gloss.tsv） | CC-CEDICT 当前 dump（`www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz`，2026-11-03 拉取；哈希见 `resources/gloss-sources.json`）；覆盖 Wiktionary 缺失的单字与词组（拼音词库高频词组覆盖 92%→95%，总词条 164k→201k） | CC BY-SA 4.0；署名 CC-CEDICT（MDBG）贡献者、声明修改；ShareAlike 约束同上，全文随包附 `Licenses/CC-BY-SA-4.0.txt` |
| 翻译表达资源（`resources/translation/expressions.tsv`，尚未随包分发） | CC-CEDICT 当前 dump（`~/Library/Caches/Gogaku/kaikki/cedict_ts.u8.gz`，2026-11-02 版本 125,356 条；哈希见 `resources/translation/manifest.json`）；选词用 jieba 词频（MIT）与既有英文词频表 | CC BY-SA 4.0 衍生数据：署名 CC-CEDICT 贡献者、声明修改（按义项组数与唯一性规则筛选、逐条人工复核）、按 CC BY-SA 4.0 分发；只含词／短语级表达，不含句对；学习模式与生产翻译辅助进程仍未接入，本文件不进入当前安装包 |

构建将实际许可证据、哈希与上游声明复制到每个 app 的 `Contents/Licenses/`。`scripts/prepare-dependencies.py` 从固定提交构建，`native/EngineBridge/` 是完整桥接源码；动态库可替换并重新进行本机签名。固定源码与数据留在 `~/Library/Caches/Gogaku/libime-1.1.17/`。后续公开分发前仍需完成适用源码提供、重链接/替换说明、全部间接依赖署名和 Gogaku 自身许可决定，不把本机 ad-hoc 签名称为 Developer ID 签名或公证。

`native/licenses/Boost-LICENSE.txt` 对照Boost官方 `https://www.boost.org/LICENSE_1_0.txt`；libintl声明对照本机gettext 1.0的 `libintl.h`，LGPL-2.1全文取本机XZ随附的同一标准许可文本。实际包内共享库、可执行文件及资源的最终哈希在 `dist/bundle-manifest.json`，运行依赖闭包实测见[包检查结果](validation/bundle-smoke.json)。没有复制Homebrew命令行工具；构建时可使用Homebrew，运行时只引用系统或包内库。

当前不含 Tatoeba、ECDICT、small100 权重、tokenizer 或其他释义词性数据（Tatoeba 因本机无副本、许可与署名无法核对，本轮翻译资源未引入句对）；英文词表（SCOWL×wordfreq）与 Wiktionary／jieba／CC-CEDICT 释义词性注释已按上表登记并随包。引入新数据时必须逐项记录文件、revision、许可、署名、来源及质量审阅结果。Apple 语言包由系统授权界面管理，项目不复制权重。
