# macOS 输入法专项选型调研

核查日期：2026-10-30。

## 范围与证据状态

Gogaku 当前只有需求/设计文档、浏览器流程原型和隔离组件探针；没有已实现的 macOS 输入法。普通中文、小鹤、中英方向、选择即提交、按应用记忆模式和英→中自有区域标记是需求，不是交付能力。[产品方向](product.md)；既有青简/Rime及模型详报见[可行性](feasibility.md)、[青简源码核查](research-qingjian.md)、[Rime 支撑边界](research-rime.md)，本文不重复引擎细节。

证据标识：**官方契约**=Apple公开API文档/本机公开SDK声明；**源码行为**=下述固定上游版本；**工程判断**=建议或风险假设，须实测。上游版本固定为 Squirrel `46962d2efae5be70389c778d0a6c52f669072827`，fcitx5-macos `3466612499c149d5002b1aab37b92bb257da1a75`。源码行为不代表 macOS 或其他 IMK 客户端保证。
本轮只读公开资料、源码及SDK；未注册/启用输入源、启动GUI、运行模型、性能或宿主测试。Apple JS文档已通过公开 `tutorials/data/documentation/*.json` 核对 abstract/primaryContentSections；源码阅读不构成运行验收。文末 SDK 索引列出完整本机路径。

## IMK 事件、文本协议与范围

- **官方契约**：`IMKServer` 为 IMK 客户端会话创建 controller；`IMKInputController` 提供三种事件接收方式：键绑定命令+文本、拆开的文本/键码/修饰键、完整 `NSEvent`，应选一种实现。`handleEvent:client:` 返回 YES 表示处理、NO交还宿主；不要已插字又返回未处理导致重复。`recognizedEvents:` 默认只收 keyDown；只用默认掩码时，点击组合区外可触发 `commitComposition:`，不能假定只需实现失焦回调。[SDK-C]
- **官方契约**：`NSTextInputClient.setMarkedText(_:selectedRange:replacementRange:)` 设置预编辑文本和内部选区；未显式指定替换位置时，先替换现有 marked text，否则当前选区，再否则光标插入。`insertText(_:replacementRange:)` 是最终用户文本入口。`unmarkText` 只是解除标记，不能当删除/撤销。输入法一侧拿到的是 `IMKTextInput` 代理，不能当作宿主 `NSTextView` 直接改 textStorage。Apple：[setMarkedText JSON](https://developer.apple.com/tutorials/data/documentation/appkit/nstextinputclient/setmarkedtext(_:selectedrange:replacementrange:).json)、[insertText JSON](https://developer.apple.com/tutorials/data/documentation/appkit/nstextinputclient/inserttext(_:replacementrange:).json)；[SDK-T][SDK-I]。
- **官方契约**：IMK `replacementRange` 是宿主文档相对位置，`NSNotFound` sentinel请求当前选区/插入点；marked string 内的 `selectionRange` 相对该字符串。`selectedRange`、`markedRange` 可能不可用；不支持TSMDocumentAccess的客户端可忽略显式replacementRange。不能承诺任意宿主可靠替换选区或提供全文上下文。[SDK-I] `insertText:replacementRange:`、`setMarkedText:selectionRange:replacementRange:`、`selectedRange`、`markedRange`。
- **官方契约与实现要求**：这些NSString文本范围以UTF-16 code units计，不是Swift `Character`或UTF-8 byte；Apple [`NSString.length`](https://developer.apple.com/tutorials/data/documentation/foundation/nsstring/length.json) 明确单位。[SDK-T] 允许按grapheme调整查询范围；[SDK-I] `stringFromRange:actualRange:` 可因代理对返回不同范围。引擎UTF-8偏移、检查器NSRange、Swift索引须显式转换；emoji、ZWJ、组合音标、非BMP汉字和NSNotFound算术须检查，删除/移动按字素边界而非切断UTF-16单元。
- **工程判断**：把每个输入 session 的原文、marked text、方向、候选版本、宿主 bundle id 和提交状态分开保存。源文变动或会话失效时拒绝迟到译文；一次提交选中目标，不先提交中文再尝试异步改宿主正文。
- **官方契约/实现风险**：`cancelComposition()` 会取 `originalString` 并通过 `insertText` 发回宿主；不能把它视为“无提交丢弃”。`commitComposition:` 是宿主要求立即结束本次composition，SDK称收到后应视该session composition结束。宿主还可自行编辑/提交；API不提供跨应用原子事务或持久保留marked text保证。[SDK-C]
- **工程判断，尚未解决**：产品“切模式/应用不自动提交、不丢输入、不串应用”需验证能否同时满足。失活即撤销候选提交资格，取消异步任务、隐藏窗口；草稿只在内存绑定原session，不跨应用自动恢复。用独立generation区分同bundle多字段，bundle id不等于焦点身份。若已替换宿主选区，再清空marked text可能删掉原选区，须测取消/撤销/选区恢复；不要盲目重放或回滚宿主正文。

## 输入安全与权限边界

- **协议边界结论**：正常IMK输入会话收键/回传文字的公开API没有要求申请Accessibility或全局Input Monitoring权限，Gogaku基础输入应在两者均未授权时工作；这不扩展为“输入法进程做任何操作都免权限”的保证。读取其他应用AX树、全局监听/注入按键属于独立功能和权限路径，核心输入不应依赖它们。
- **权限区别**：Apple [`NSEvent`全局monitor](https://developer.apple.com/tutorials/data/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:).json) 只观察、不能拦截，键盘监听要求辅助功能信任。`CGEventTapCreate` 有主动过滤/被动监听、创建失败及超时停用，`CGPreflight/RequestListenEventAccess` 与 `CGPreflight/RequestPostEventAccess` 分别检查监听/注入权限。[SDK-G] 旧注释仍写assistive-device access；[Apple DTS](https://developer.apple.com/forums/thread/789896) 说明现代被动CG监听走Input Monitoring，发事件权限在Accessibility界面展示，也不等于完整AX访问。读取/控制别的应用AX树另看 `AXIsProcessTrustedWithOptions` [SDK-A]。不要笼统写“event tap都免权限”或“输入法一律要AX”。
- **官方边界**：[TN2150](https://developer.apple.com/library/archive/technotes/tn2150/_index.html) 与 [SDK-E] `EnableSecureEventInput` 保护按键免被全局interceptor获取；`IsSecureEventInputEnabled` 只说明任意进程启用，并不定位当前密码框。它不是可靠的逐字段分类器，也不能据此保证IMK始终收到/始终收不到密码按键。secure field是否选择输入法、停用组合或限制可用输入源，必须分别实测；禁止绕过保护或替其他进程关闭secure input。
- **工程判断**：密码和不确定安全状态不做学习辅助、上下文采集、记录或模型调用；停用辅助不能吞键，应保留可用直接输入退路。公开IMK代理没有一个覆盖所有自绘字段的通用密码标签，应用排除/手动暂停只是补充，不能宣称防漏已验收。默认仅记录学习片段，避免原文日志、崩溃转储和模型错误上报泄露；[SDK-I] `length` 可能昂贵，周边文本按需限量读取、容忍nil，禁止每键取全文。
- **特别边界**：输入法能控制仍处于 IME marked text 状态的组合及提交字符串；一旦 `insertText` 完成提交，普通 IMK 没有通用API让它重开宿主任意正文、附加自定义波浪线或持久跟踪字符。产品已确认波浪线先在 Gogaku 自有输入区，不承诺装饰其他应用已提交正文。[产品方向](product.md#已确认错误标记与翻译失败)

## 焦点、模式与键盘语义

- **源码行为，Squirrel固定commit**：`SquirrelInputController.handle` 区分 `.keyDown` / `.flagsChanged`，Command 快捷键返回未处理，让宿主执行；`deactivateServer` 调用 `commitComposition`，该实现提交引擎当前原编码。见 [controller](https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelInputController.swift)。
- **源码行为，fcitx固定commit**：`handle` 每次设置当前controller，源码注释记录Safari可见焦点与activate/deactivate不一致、Chrome初始化可缺activate；这是兼容性线索，非本轮复现。`getSecureInputInfo` 每键复查，部分判断用 `getSecureInputProcessPID`，后者读取IORegistry `kCGSSessionSecureInputPID` 且注明可能不准；不能当公开SDK保证的安全判据。[controller](https://github.com/fcitx/fcitx5-macos/blob/3466612499c149d5002b1aab37b92bb257da1a75/src/controller.swift)、[secure.swift](https://github.com/fcitx/fcitx5-macos/blob/3466612499c149d5002b1aab37b92bb257da1a75/src/secure.swift)。
- **工程判断**：明确普通/中→英的小鹤与英→中字符路径；`keyCode`不等于字母，用 `characters` / `charactersIgnoringModifiers` 配合修饰键，不能只取首个UTF-16单元。允许用户选择底层布局，覆盖ABC、Dvorak、非美式ISO/JIS及Option死键；参考 [SDK-I] `overrideKeyboardWithKeyboardNamed:`、[SDK-C] `IMKServer.lastKeyEventWasDeadKey`。测试Shift单击选区不误切模式、左右修饰键、CapsLock、重复按键、fn/地球键、Ctrl+Space、Command/Ctrl宿主快捷键与远程事件；未消费键交还宿主，不用全局tap兜底。
- **工程判断**：session 生命周期不等于应用生命周期或文本焦点生命周期。按应用记模式需以可信 bundle id 做偏好键，但在同应用多个窗口、不同字段/安全字段、窗口重用及焦点未激活时仍须验证。模式/方向切换要定义未完成 composition 的保留、取消或提交，不应让旧session结果写入新焦点。

## 候选窗、坐标与波浪线交互

- **官方契约**：`IMKCandidates.show:` 接受相对选区的定位提示，`setCandidateFrameTopLeft:` 接收屏幕坐标，`showCandidates` 本身不负责定位；`candidateSelectionChanged:`只是浏览，`candidateSelected:`才是最终选择。[SDK-P][SDK-C] `IMKCandidatesSendServerKeyEventFirst` 默认让候选窗先收键，`setSelectionKeysKeylayout:`改变编号键布局，默认US，须防与输入/快捷键冲突。
- **官方契约**：`IMKTextInput.attributesForCharacterIndex:lineHeightRectangle:` 索引相对inline session，无inline时0取当前选区；`firstRectForCharacterRange:actualRange:` 则是文档范围，返回首个逻辑屏幕矩形，可有负宽高并调整actualRange。[SDK-I][SDK-T] 两者不能混用偏移，不能凭单个caret矩形画跨行文字下的波浪线。`validAttributesForMarkedText` 限制宿主接受的属性，不保证拼写波浪线样式或可点击说明。
- **官方契约/工程判断**：AppKit屏幕坐标用points，位图用backing pixels；通过NSView/NSWindow的转换API，不把caret坐标直接乘Retina scale。按caret所在显示器定位，尊重 [NSScreen.visibleFrame](https://developer.apple.com/tutorials/data/documentation/appkit/nsscreen/visibleframe.json)（文档要求勿缓存）、Dock/菜单栏/刘海安全区，容忍负原点；坐标缺失/陈旧则隐藏或安全回退，不复用其他session坐标。屏幕变化、滚动、全屏、Spaces和混合scale仍待测。
- **源码行为**：Squirrel `SquirrelPanel` 使用nonactivating `NSPanel`、屏幕检测/裁剪、鼠标选择候选，窗口层级用 `CGShieldingWindowLevel`；不能据此认定该层级适合Gogaku。[panel](https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/sources/SquirrelPanel.swift)。fcitx固定版依赖的webview子模块 `7e8ef6cca003392783aa1d7df8abe0b60c22ad34` 中 `WebviewCandidateWindow::show` 先更新状态，JS resize后实际显示；须把这段绘制链纳入比较，不能按“Swift/C++前端”名称推断速度。[webview源码](https://github.com/fcitx-contrib/fcitx5-webview/blob/7e8ef6cca003392783aa1d7df8abe0b60c22ad34/src/webview_candidate_window.cpp)。
- **工程判断**：先以IMKCandidates做兼容性基线，自绘AppKit面板是另一个待测选项。`.nonactivatingPanel` 官方只保证不激活所属app，**不等于保证不成为key window/不改变first responder**。[Apple说明](https://developer.apple.com/tutorials/data/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel.json) 点击候选/波浪线/说明关闭后须核验焦点、session与版本；不调用makeKey激活输入法来显示提示。自绘层级参考 [SDK-I] `windowLevel`（文档建议客户端层级+1），另测全屏/Spaces/模态窗口；不用永久最高层覆盖安全界面。
- **工程判断/无障碍契约**：自有输入视图用TextKit布局将诊断UTF-16区间映射glyph，命中测试须经screen→window→view转换，处理换行/缩放/滚动和诊断失效；点击只显示说明，不更改用户英文。为候选和问题提供语义角色、标签、选中状态、动作、更新通知及键盘等价入口，颜色/波浪线不能是唯一提示。[Apple NSAccessibilityProtocol](https://developer.apple.com/tutorials/data/documentation/appkit/nsaccessibilityprotocol.json) 明确自绘控件须补这些语义；**向VoiceOver暴露自家UI不等于申请控制其他应用的AX权限**。VoiceOver、焦点顺序、Esc返回打字、对比度和点击区域仍须实测。

## 安装、注册、签名与模型包

- **官方契约**：[SDK-R] `TISRegisterInputSource(CFURLRef)` 支持 `/Library/Input Methods/`（全用户）与 `~/Library/Input Methods/`（当前用户）内的bundle，说明可通知系统重建缓存并随即枚举输入源；`TISEnableInputSource`让其可选，`TISSelectInputSource`才切换，均需检查OSStatus及能力。注册成功不保证现有进程/菜单立刻使用新二进制。稳定bundle id、连接名、controller类名与Info.plist须一致；[QA1810](https://developer.apple.com/library/archive/qa/qa1810/_index.html)是旧版输入源管理变更资料，不能代替当前OS安装测试。本轮未调用这些API。
- **源码行为与更新风险**：fcitx [README](https://github.com/fcitx/fcitx5-macos/blob/3466612499c149d5002b1aab37b92bb257da1a75/README.md)说首次安装注销、后续Restart；[update.sh](https://github.com/fcitx/fcitx5-macos/blob/3466612499c149d5002b1aab37b92bb257da1a75/assets/update.sh)保留部分文件、原位替换、移除quarantine、ad-hoc重签再killall。这不是Developer ID公证升级范本，也不证明断电安全。Squirrel [postinstall](https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/scripts/postinstall)停止进程后注册/部署/按登录用户启用选择，[INSTALL.md](https://github.com/rime/squirrel/blob/46962d2efae5be70389c778d0a6c52f669072827/INSTALL.md)仍警告直接安装可能需注销。注销/重启不是通用API契约，不能许诺升级永不需要用户重登。
- **官方分发要求**：Developer ID直接分发需有效代码签名；Apple公证要求 Developer ID、Hardened Runtime、安全时间戳及正确嵌套代码签名。公证不是App Review，也不验证模型质量。Apple [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution.md)。安装后的替换若改动已签 bundle 内容会破坏签名，更新器应完整验证后替换、失败回滚，并重新验证签名/公证适用范围。
- **工程判断**：模型包放签名app之外的Application Support，避免修改bundle；仅将纯数据与可执行插件分开更新，不能给“模型包”夹带未验签代码。可信公钥验签清单绑定版本、语对、格式/引擎兼容、文件大小/强哈希，检查解包路径穿越/符号链接/配额；HTTPS或无认证哈希本身不证明来源。临时同卷下载校验后原子发布不可变版本，完成加载自检再切active指针；旧任务持有旧版本，新任务才用新包，失败/崩溃可回退。需防恶意降级，允许明确的已验证旧包恢复；激活信息的崩溃一致性仍须故障测试。下载需用户明确发起，包缺失/断网保留输入，不静默联网或截断长文本。
- **待验证**：全量 bundle/嵌套动态库架构与签名、公证后首次运行、非管理员安装路径、升级/中断/磁盘不足/哈希错误/回滚、正在使用时更新、注销后输入源枚举刷新、旧版本配置和用户词典兼容。未完成前不宣称安装或更新可靠。

## 建议与必测宿主矩阵

**建议（工程判断，未选定底座）**：优先验证原生IMK薄前端、可替换中文引擎、独立翻译/检查worker。按键回调只做有界同步处理；加载模型、I/O、学习记录落盘和设置页面不占输入主链。取消/超时/worker崩溃时保留输入，不返回猜测或过期结果。后台设置与记录管理可选SwiftUI/AppKit或WebView，不因后台栈要求牺牲输入路径；原生或WebView候选链的快慢必须同条件实测。候选质量受引擎/词库/排序和译义影响，IMK不提供中文质量保证。验收计按键到候选实际显示、选择到宿主实际收字，单独记录冷加载与尾延迟；主报告制定预算，本文不给数值保证。

**必测宿主矩阵（全部仍待实测）**：

| 宿主类型 | 至少覆盖 | 主要验证点 |
| --- | --- | --- |
| Apple原生控件 | TextEdit、Notes、系统搜索/文件名字段 | marked/update/commit/cancel、选区覆盖、Undo/Redo、UTF-16 |
| Chromium/Electron | Chrome地址栏/textarea/contenteditable、VS Code、常用聊天框 | 焦点回调缺失、网页重排、候选坐标、Enter不误发消息 |
| WebKit | Safari地址栏/textarea/contenteditable | inline composition、失焦/导航、替换范围、网页脚本改值 |
| IDE/复杂文本 | Xcode、JetBrains编辑器与搜索框 | 大文档/多光标退路、菜单快捷键、多个字段切换 |
| 终端/远程 | Terminal、iTerm2、远程桌面会话 | Ctrl控制键、sudo/secure input、原文/组合提交、无composition直通 |
| 安全/异常输入 | NSSecureTextField、浏览器密码框、自绘登录框、锁屏恢复 | 不采集/学习/翻译；安全态改变不吞键，离开后正常恢复 |
| 多屏与无障碍 | Retina+外接不同scale屏、VoiceOver | 负原点、四边/跨屏/热插拔、全屏Spaces、读出/选择/说明返回 |

每类再覆盖普通/中→英/英→中、小鹤局部选词及剩余编码、英语大小写/空格/词句完成、候选翻页/鼠标/键盘、选区替换、emoji/组合符、死键、Shift单击、左右修饰键、CapsLock、重复键、fn/系统切源、睡眠唤醒、同app多窗口/同窗口多字段及连续失焦。另注入翻译迟到/取消/失败、模型缺失/更新、输入法重启、宿主关闭与焦点抢占，检查不夹中文、不重复/漏字、不串字段、不提交旧结果、不记录安全输入。
每格执行同一组步骤：①在 `A😀éB` 中选择 `é` 开始组合；②按当前方向输入、局部选词/翻页后确认，核对仅替换预期范围且只上屏一次；③重做并分别按Esc、点组合区外、切方向/输入源/应用，再让旧任务返回；④点击候选及波浪线说明、关闭后续打字；⑤进入/离开安全字段。核对实际正文、选区、焦点、候选所属session与记录，已提交正文不附加标记。
每格记录OS build、app与控件版本、布局/显示配置、事件回调顺序和最终实际文本/选区/焦点；输入内容使用合成样例，默认无AX/Input Monitoring授权。出现不支持能力即标明退路，不以“能上屏”视为整格通过；本轮矩阵全部未执行。

## 本机公开SDK与证据索引

以下为本次实际读取路径；简称 `[SDK-*]` 对应其后的方法及注释，不引用私有framework/tbd导出作为API契约。

| 简称 | 完整路径与重点方法 |
| --- | --- |
| [SDK-C] | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/InputMethodKit.framework/Headers/IMKInputController.h`：`handleEvent:client:`、`recognizedEvents:`、`commitComposition:`、`cancelComposition`、`activateServer:`/`deactivateServer:`；同目录 `IMKServer.h`：`lastKeyEventWasDeadKey` |
| [SDK-I] | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Headers/IMKInputSession.h`：`IMKTextInput`、`setMarkedText:selectionRange:replacementRange:`、`stringFromRange:actualRange:`、`windowLevel` |
| [SDK-T] | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Headers/NSTextInputClient.h`：`setMarkedText:selectedRange:replacementRange:`、`unmarkText`、`validAttributesForMarkedText`、`firstRectForCharacterRange:actualRange:` |
| [SDK-P] | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/InputMethodKit.framework/Headers/IMKCandidates.h`：`show:`、`showCandidates`、`setSelectionKeysKeylayout:`、`setCandidateFrameTopLeft:` |
| [SDK-E] | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Headers/CarbonEventsCore.h`：`EnableSecureEventInput`、`IsSecureEventInputEnabled` |
| [SDK-G] | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/CoreGraphics.framework/Headers/CGEvent.h`：`CGEventTapCreate`、`CGEventTapEnable`、`CGPreflightListenEventAccess`、`CGPreflightPostEventAccess` |
| [SDK-A] | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Headers/AXUIElement.h`：`AXIsProcessTrustedWithOptions`、`AXUIElementCreateApplication` |
| [SDK-R] | `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Headers/TextInputSources.h`：`TISRegisterInputSource`、`TISEnableInputSource`、`TISSelectInputSource` |

官方契约确认有输入会话/预编辑/提交、定位及注册接口；上游源码提供可研究的兼容处理；Gogaku的性能、候选质量、密码保护、焦点安全、可点击诊断和更新可靠性均仍待实现与实测。
