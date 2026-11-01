# Rime 对 Gogaku 首阶段的支撑边界

目标是核实 macOS 中英双向学习输入、选词直接上屏、用户英语波浪线及小鹤双拼是否有可用接缝，不在首阶段决定采用 Rime 或青简作为正式底座。

本文仅为官方源码与文档研究，未实现产品，未运行输入法测试。源码位于 `/tmp/gogaku-validation/`，没有引入 Gogaku。没有读取或修改用户输入法配置、词库、日志，也没有操作已安装进程。

## 证据版本与结论等级

- librime 固定为 `56737cd29a4d393a104a2098ece3697aa2810465`，Squirrel 固定为 `46962d2efae5be70389c778d0a6c52f669072827`，双拼方案固定为 `01a13287cbd27819be1c34fa1ddc1b3643d5001b`。下文链接均固定 commit。
- 「源码确认」只证明该版本存在相应接口或行为，不等于 Gogaku 已实现或宿主应用兼容性已验证。「建议」是后续验证方向。
- 主代理提供的本机事实是 `/Library/Input Methods/Squirrel.app/Contents/Frameworks/rime-plugins/` 已有 `librime-lua.dylib`、`librime-predict.dylib`、`librime-octagram.dylib`。本研究没有重复检查安装目录或运行库。
- 上游 Squirrel 发布脚本下载的是 librime `1.17.0`、短 hash `33e7814` 的预构建包，不是上述 librime HEAD。不能把本报告的全部 HEAD 行为当作本机行为，隔离测试须使用匹配头文件及实际库。[构建脚本第 5–13、33–37 行][build]

## 1. 小鹤双拼和候选提交存在官方接缝

- 源码确认官方 `double_pinyin_flypy` 方案名为「小鶴雙拼」，以朙月拼音为基础，声明 `stroke` 依赖。[schema 第 4–14 行][flypy] 配方另外明确依赖 `luna-pinyin`，不是只复制一个 YAML 就能运行。[README 第 18–24 行][double-readme]
- schema 的 `engine` 已配置 processor、segmentor、translator、filter。`speller/algebra` 将拼音映射到小鹤键位，`translator/dictionary: luna_pinyin` 与独立 `prism: double_pinyin_flypy` 负责查词和编码映射。[第 27–96 行][flypy] 这是小鹤双拼，不是小鹤音形或形码能力承诺。
- 源码确认 C API 提供 `get_schema_list`、`select_schema`、`process_key`、`get_context`、`get_commit`、`free_commit` 和 `commit_composition`，候选还有遍历接口及全局索引、当前页索引两种选择接口。[API 第 324–360 行][api-main] [第 441–469 行][api-candidates]
- `select_candidate*` 调用 `Context::Select`，不是向宿主应用写字。[实现第 1085–1094 行][api-select] 选中末段且 `_auto_commit` 为真时，引擎才自动 commit；小鹤 schema 使用的 `express_editor` 将该选项设为真。[engine 第 341–363 行][engine-select] [editor 第 41–44、205–218 行][editor]
- 限制是多段输入选中较短候选可能只确认当前段，仍有剩余编码。不能据「调用选择 API 成功」保证每一次选词都立即提交全部内容。[engine 第 341–363 行][engine-select]
- 建议把小鹤同时纳入普通中文和中→英路径。检查双拼组词、短候选、翻页、退格及剩余编码。英→中则使用独立的英语捕获路径，不能让英语字母按小鹤拼音解释。这里只确认接缝，运行结果由主代理隔离实验另记。

## 2. 扩展点与 Lua 必须按构建区分

- 源码确认 processor 接受按键并返回消费、拒绝或继续，translator 按输入和 segment 生成候选流，filter 变换候选流。schema 中的名称由引擎按组件注册表创建。[processor 第 18–32 行][processor] [translator 第 22–31 行][translator] [filter 第 22–31 行][filter] [engine 第 558–595 行][engine-init]
- Lua 不是上述 C++ 接口本身。`librime-lua` 官方 README 明确提供 processor、segmentor、translator、filter 扩展，作为动态插件加载。[README 第 1–9 行][lua-readme]
- 上游 Squirrel 当前 Xcode 构建明确把 Lua、octagram、predict 三个 dylib 复制到 `rime-plugins`。发布记录也明确安装包包含这三项。因此「Squirrel 默认没有 Lua」不适用于本次证据。[工程第 104–114 行][plugin-copy] [CHANGELOG 第 182、211 行][changelog]
- 但从原始 librime 源码构建时，`ENABLE_EXTERNAL_PLUGINS` 默认是 OFF，`BUILD_MERGED_PLUGINS` 默认 ON。插件文件存在、引擎能加载、schema 实际启用 Lua 是不同检查项。[CMake 第 18–34 行][cmake] 不能把某个 Squirrel bundle 的结果推广到所有 librime 构建。

## 3. 替换候选文本可以改变 commit，但学习风险有条件

- 源码确认 `Composition::GetCommitText` 拼接选中候选的 `text()`，不是 `comment()`。只把译文写进 comment 默认不会译词上屏。[composition 第 103–122 行][composition]
- 官方 simplifier 已示范用 `ShadowCandidate(original, type, text, comment)` 保留原候选并换文字。由此推断，快速本地词典可用相似包装让译文成为提交文本，同时保留原文作说明。[simplifier 第 95–122 行][simplifier] 这证明文字替换机制，不证明翻译质量。
- 不能笼统说「filter 换文字必污染拼音词库」。`Memory::ProcessSegmentOnCommit` 用 `GetGenuineCandidate` 取原始 `Phrase`，`GetGenuineCandidate` 会解包一层 shadow。沿用官方包装路径时，学习通常仍针对原中文 phrase，而不是包装后的英文。[memory 第 111–135 行][memory] [candidate 第 11–29 行][candidate]
- 风险来自直接修改原 `Phrase`、构造可学习的译文 phrase、额外写入用户词典，或自定义包装不能正确解包。`ScriptTranslator::Memorize` 确实写入 user dictionary，不能假定修改任意候选类型都安全。[第 351–355 行][memorize] 多层包装也须单独验证。
- 即便英文没有写入，中文来源候选的频次仍可能被学习。这和 Gogaku 的学习片段记录不是同一系统。建议首次验证隔离 user data，并使用独立 `user_dict` 或关闭 `translator/enable_user_dict`，分别检查普通中文学习及译文不入拼音词典。[user dictionary 第 595–617 行][userdict]

## 4. 不要在同步 filter 中等待慢翻译

- 源码确认 `TranslateSegments` 直接调用 translator 并挂接 filter，`Menu::Prepare` 在生成候选时同步调用候选流的 `Peek/Next`。Squirrel 的按键路径调用 `process_key` 后紧接 `rimeUpdate` 读取候选。[engine 第 282–313 行][engine-translate] [menu 第 22–35 行][menu] [前端第 95–118、401–411 行][frontend-keys]
- 因此推断，在 filter 的执行或惰性候选求值中等待本地模型、网络、锁或 future，会拖住按键处理或候选更新。Lua coroutine 不自动等于脱离该同步链的后台任务。离线模型也可能阻塞。
- 建议只在同步候选链做有界、快速的缓存查询和轻量变换。慢翻译由外部任务执行，结果携带 session、应用、方向、输入版本和候选来源，回到所属执行线程后核对版本再刷新。过期结果丢弃，后台线程不直接并发改同一 engine/context。
- 上游当前有 `_refresh_ui` property 供插件请求前端重绘，但它本身不执行推理、不保证候选重算，也不提供取消与版本协议。[ReservedProperty 第 7–14 行][reserved] [前端第 294–307 行][frontend-properties] 不能据此宣称异步翻译已解决。
- 选词直接上屏应建立在可用译文已经作为候选存在的前提上。没有结果时保留输入，明确提供原文上屏，不先提交中文再异步改写宿主正文。这是产品要求与建议，不是上游现成能力。

## 5. 英→中不能等同于 ASCII 模式

- 源码确认 `ascii_mode` 为真且没有 composition 时，`ascii_composer` 返回 `kRejected`，引擎停止正常 processor 链，Squirrel 将未处理事件交还宿主应用。[ascii composer 第 242–245 行][ascii] [engine 第 167–181 行][engine-keys] [前端第 36–38、119–123 行][frontend-keys]
- 这条路径不会形成英语翻译候选。即使某条临时西文路径留有 composition，也有空格或回车直接提交原文的分支，不能用 ASCII 开关代替学习方向。[ascii composer 第 209–220 行][ascii-inline]
- 建议显式拆开普通模式、学习模式和学习方向。英→中保持输入在 Gogaku 自有缓冲区或专门英语 processor/schema 内，定义大小写、空格、标点、词界和句界。不要仅靠 `ascii_mode=false`，否则英语仍可能进入拼音 speller。
- Squirrel 默认配置对多款应用设置 `ascii_mode: true`，`vim_mode` 还可能在 Escape 等按键后开启 ASCII。验证英→中时必须覆盖这些旁路，而不是覆盖用户现有配置。[配置第 393–442 行][app-defaults] [前端第 413–419 行][frontend-keys]

## 6. 前端负责宿主提交、应用模式和波浪线

- 源码确认 Squirrel 消费 `get_commit` 后调用 `client.insertText`，预编辑则通过 `setMarkedText`，候选文本与 comment 从 `RimeContext.menu` 分开读取。[前端第 437–445、530–558、562–605 行][frontend-ui] 这是「候选文字直接成为宿主正文」的参考路径，不需要先把源中文写入宿主。
- `app_options/<bundleIdentifier>` 是布尔选项表。前端在创建 session 及发现应用变化时应用它，不是自动把用户最后选过的模式按应用持久保存。[配置代码第 102–115 行][app-config] [前端第 46–49、362–392 行][frontend-apps] Gogaku 还需显式记录模式与方向、定义无配置应用的默认值。
- 快捷键可参考 `key_binder` 的 `toggle`、`set_option`、`unset_option`、`select` 分支。[第 199–218 行][keybinder] 系统输入法菜单目前是部署、同步、日志、设置、Wiki、更新，不是 Gogaku 学习模式与方向菜单。[前端第 242–265 行][frontend-menu] 原生菜单入口仍需增加，不能只展示 schema 开关菜单就算完成全部要求。
- 焦点切换不能照搬默认行为。Squirrel 的 `deactivateServer` 调用 `commitComposition`，后者取 `get_input` 并直接提交原编码再清空。[前端第 218–239 行][frontend-deactivate] 这和「切应用不误提交或丢失未完成学习输入」不是同一保证。
- 波浪线可由自有前端输入区域绘制，并映射用户英语的字符区间和点击说明。此为设计可行性判断，不是 Squirrel 已有能力。现有 `show` 只设置已转换及原文选择样式，没有拼写诊断区间或点击说明。[前端第 586–605 行][frontend-ui]
- engine-only 的标准 `RimeComposition` 只有纯文本、光标和选择区间，候选仅有 text、comment、reserved，不携带通用富文本诊断或点击事件。[API 第 120–163 行][api-shapes] 当前 `_comment_warning` 面向候选说明索引，也不是英语源文波浪线。[ReservedProperty 第 7–14、38–51 行][reserved]
- 建议由前端单独保存用户英语原文、词句完成状态及诊断，先只做拼写。中→英生成的英语不进入用户错误标记。提交后若原文区域已消失，必须另设计反馈载体，不能声称 engine 能给任意宿主已提交正文加波浪线。

## 7. 许可必须逐件处理

下表是所读上游版本的许可证，不是对本机安装包全部依赖的许可认证，也不是法律意见。

| 组件 | 官方证据 | 对复用的含义 |
| --- | --- | --- |
| librime 引擎 | [LICENSE 第 1–30 行][license-rime]，BSD-3-Clause | 保留版权、条件及免责声明，不冒用作者背书。不能因此给 Squirrel 也标 BSD。 |
| Squirrel 前端 | [LICENSE.txt 第 1–2 行][license-squirrel]，GPL v3；[README 第 19 行][squirrel-readme] | 复制或改造前端并分发时，须核对 GPL 对覆盖作品及对应源码的要求。独立前端仅参考 API 与复制 Squirrel 源码不是同一情况。 |
| `rime-double-pinyin` 官方小鹤 schema | [LICENSE 第 1–2 行][license-double]，GPL v3 | 不因文件是 YAML 就忽略许可，复制 schema 前须评估分发方案。 |
| `rime-luna-pinyin` 词库与方案 | [LICENSE 第 1–16 行][license-luna]，LGPL v3 | 与双拼 schema 分开列账，不能用引擎 BSD 许可覆盖词典数据。 |
| `rime-stroke` 反查数据与方案 | [LICENSE 第 1–16 行][license-stroke]，LGPL v3 | 官方小鹤所声明的反查依赖也需要审查。 |
| `librime-lua` | [固定版本 LICENSE 第 1–30 行][license-lua]，BSD-3-Clause | 插件代码、Lua 解释器及用户脚本是不同组件，脚本和解释器仍须按实际版本审查。 |
| `librime-octagram` | [固定版本 LICENSE 第 1–30 行][license-octagram]，BSD-3-Clause | 此为当前上游版本，不推定本机所带旧二进制同版。语言模型和语料另审，不能当作双向翻译模型。 |
| `librime-predict` | [固定版本 LICENSE 第 1–29 行][license-predict]，BSD-3-Clause | 插件许可不自动覆盖预测数据，且预测不等于翻译或拼写检查。 |

Squirrel README 另列 OpenCC、Sparkle、plum、Boost、LevelDB 等依赖及许可。[第 82–95 行][third-party] 该清单只是盘点入口，不代替逐件核对最终分发文件。翻译模型、拼写词典、语法规则、octagram 数据、Lua 解释器以及所有传递依赖尚未完成分发审计。Gogaku 许可证仍未确定。

## 推荐与不可保证的边界

推荐把 Rime 当作可比较的中文编码及候选引擎参考，保留小鹤路径。快速词典转换可验证 filter 或独立 translator，慢翻译和英语诊断放到独立任务与前端。是否依赖 librime、改造 Squirrel 或采用青简，留待隔离运行、宿主兼容性和许可评估后决定。

本报告不能保证离线翻译质量或延迟、Lua 已在某次 session 中加载、选中局部候选就提交全部输入、按应用自动记忆用户选择、切应用不误提交、可点击波浪线已存在，或任意宿主应用都接受同样的 marked-text 属性。

本次应用 **Prove It Works** 原则，只把读到的固定版本源码作为证据，区分本机转述、源码确认与推断，并核对报告引用及行数。没有把源码接缝写成已经验证的产品能力。

[flypy]: https://github.com/rime/rime-double-pinyin/blob/01a13287cbd27819be1c34fa1ddc1b3643d5001b/double_pinyin_flypy.schema.yaml#L4-L96
[double-readme]: https://github.com/rime/rime-double-pinyin/blob/01a13287cbd27819be1c34fa1ddc1b3643d5001b/README.md#L18-L24
[build]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/action-install.sh#L5-L37
[api-main]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime_api.h#L324-L360
[api-candidates]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime_api.h#L441-L469
[api-select]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime_api_impl.h#L1085-L1094
[engine-select]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/engine.cc#L341-L363
[editor]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/editor.cc#L41-L218
[processor]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/processor.h#L18-L32
[translator]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/translator.h#L22-L31
[filter]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/filter.h#L22-L31
[engine-init]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/engine.cc#L558-L595
[lua-readme]: https://github.com/hchunhui/librime-lua/blob/6da5d6cedb853380ed1b5b9b6979cb1a9c028353/README.md#L1-L9
[plugin-copy]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/Squirrel.xcodeproj/project.pbxproj#L104-L114
[changelog]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/CHANGELOG.md#L182-L211
[cmake]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/CMakeLists.txt#L18-L34
[composition]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/composition.cc#L103-L122
[simplifier]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/simplifier.cc#L95-L122
[memory]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/memory.cc#L111-L135
[candidate]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/candidate.cc#L11-L29
[memorize]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/script_translator.cc#L351-L355
[userdict]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/dict/user_dictionary.cc#L595-L617
[engine-translate]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/engine.cc#L282-L313
[menu]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/menu.cc#L22-L35
[frontend-keys]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelInputController.swift#L36-L432
[reserved]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/ReservedProperty.swift#L7-L51
[frontend-properties]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelInputController.swift#L294-L307
[ascii]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/ascii_composer.cc#L242-L245
[ascii-inline]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/ascii_composer.cc#L209-L220
[engine-keys]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/engine.cc#L167-L181
[app-defaults]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/data/squirrel.yaml#L393-L442
[frontend-ui]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelInputController.swift#L437-L605
[app-config]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelConfig.swift#L102-L115
[frontend-apps]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelInputController.swift#L46-L392
[keybinder]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime/gear/key_binder.cc#L199-L218
[frontend-menu]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelInputController.swift#L242-L265
[frontend-deactivate]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelInputController.swift#L218-L239
[api-shapes]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/src/rime_api.h#L120-L163
[license-rime]: https://github.com/rime/librime/blob/56737cd29a4d393a104a2098ece3697aa2810465/LICENSE#L1-L30
[license-squirrel]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/LICENSE.txt#L1-L2
[squirrel-readme]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/README.md#L19
[license-double]: https://github.com/rime/rime-double-pinyin/blob/01a13287cbd27819be1c34fa1ddc1b3643d5001b/LICENSE#L1-L2
[license-luna]: https://github.com/rime/rime-luna-pinyin/blob/56b934b099dfbeab842320f13aa8b461a6ab3e42/LICENSE#L1-L16
[license-stroke]: https://github.com/rime/rime-stroke/blob/1e8fff9b9494ddec23b0cbc526bcfd8171a6fd48/LICENSE#L1-L16
[license-lua]: https://github.com/hchunhui/librime-lua/blob/6da5d6cedb853380ed1b5b9b6979cb1a9c028353/LICENSE#L1-L30
[license-octagram]: https://github.com/lotem/librime-octagram/blob/57d18b9f58e5284bd891d559f6bdd16cf60341e9/LICENSE#L1-L30
[license-predict]: https://github.com/rime/librime-predict/blob/920bd41ebf6f9bf6855d14fbe80212e54e749791/LICENSE#L1-L29
[third-party]: https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/README.md#L82-L95
