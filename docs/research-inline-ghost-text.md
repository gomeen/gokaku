# 行内灰字补全（ghost text）调研

调研日期：2026-11-11。范围是 macOS InputMethodKit／AppKit、Windows TSF、第三方系统级预测产品、VS Code Copilot，以及可随包分发的英文 bigram 数据。

证据口径：**「官方」指 Apple、Microsoft、VS Code 等一手文档；「厂商说法」指产品自己的网站，未做逆向验证；「源码证据」只证明某个实现的写法，不等于所有宿主都如此。** 本文没有修改或运行 Gogaku 代码，也没有把文档查阅写成真实宿主验收。

## 结论摘要

### 已证实

1. **macOS 自带 inline predictions 是独立于 Apple Intelligence 的系统功能。** Apple 的 macOS 26 帮助页仍提供「Show inline predictive text」，灰字用于补全当前词或短语，空格接受，继续输入则忽略；macOS Sonoma 更新说明已列出单词和多词预测。[Apple macOS 26 帮助](https://support.apple.com/guide/mac-help/typing-suggestions-correct-mistakes-mac-mchlp2299/26.0/mac/26.0)、[Apple Sonoma 更新说明](https://support.apple.com/en-euro/109035)
2. **官方资料没有把 Apple silicon 列为 inline predictions 的条件。** macOS 14、15、26 的同一帮助页均未出现这一硬件限制；Sonoma 更新说明会对其他功能明确标注「Mac with Apple silicon」，但 inline predictive text 条目没有。因此，不应把这项功能写成「Apple silicon 专属」。不过，官方也没有在这些页面给出一句「所有 Intel Mac 均支持」的保证，Intel 实机结论仍列在下方「需实测」。[macOS 14](https://support.apple.com/guide/mac-help/typing-suggestions-correct-mistakes-mac-mchlp2299/14.0/mac/14.0)、[macOS 15](https://support.apple.com/guide/mac-help/typing-suggestions-correct-mistakes-mac-mchlp2299/15.0/mac/15.0)、[macOS 26](https://support.apple.com/guide/mac-help/typing-suggestions-correct-mistakes-mac-mchlp2299/26.0/mac/26.0)
3. **IMK／Cocoa 的 marked-text API 在协议层面允许传入富文本和组合内部光标。** `setMarkedText` 接受 `NSString` 或 `NSAttributedString`；`selectedRange` 相对于传入字符串起算，文档没有要求光标必须在末尾。宿主另通过 `validAttributesForMarkedText` 声明它认识的属性。[Apple `setMarkedText`](https://developer.apple.com/documentation/appkit/nstextinputclient/setmarkedtext(_:selectedrange:replacementrange:))、[`validAttributesForMarkedText`](https://developer.apple.com/documentation/appkit/nstextinputclient/validattributesformarkedtext())
4. **marked text 不是悬浮装饰，而是宿主文本存储中的未完成文本。** Apple 明确说接收方替换其 text storage 的范围；纯 `NSString` 的可辨识外观也由接收方绘制。`NSTextView` 的 marked-text 属性支持文字颜色、背景色和下划线。[Apple `setMarkedText`](https://developer.apple.com/documentation/appkit/nstextinputclient/setmarkedtext(_:selectedrange:replacementrange:))、[`NSTextView.markedTextAttributes`](https://developer.apple.com/documentation/appkit/nstextview/markedtextattributes)
5. **TSF 有「未提交组合＋显示属性」机制，但没有查到独立的纯视觉 ghost-text 通道。** `TF_DISPLAYATTRIBUTE` 可包含文字颜色、背景色、下划线样式／颜色／粗细；应用可以并应当读取组合显示属性并负责显示。[Microsoft Compositions](https://learn.microsoft.com/en-us/windows/win32/tsf/compositions)、[Providing Display Attributes](https://learn.microsoft.com/en-us/windows/win32/tsf/providing-display-attributes)
6. **Copilot 灰字是编辑器能力。** VS Code 文档把它定义为编辑器中的 ghost text；扩展 API 由 provider 接收 `TextDocument` 和 `Position`，返回预览／接受共用的 `InlineCompletionItem`，编辑器负责呈现和接受。这不是可供输入法向任意应用投字的系统 API。[VS Code Copilot 文档](https://code.visualstudio.com/docs/copilot/ai-powered-suggestions)、[VS Code `InlineCompletionItemProvider`](https://code.visualstudio.com/api/references/vscode-api#InlineCompletionItemProvider)
7. **本机实测推翻了 marked-text 灰字路线（重要更正）。** 本进程 NSTextView 直调 `setMarkedText` 能保灰；但真实 IMK 链路下，宿主实际收到的属性串被系统改写：自定义前景色被剥离，只剩系统统一的组合样式（下划线＋强调色），`hel` 与灰 `p` 被合并为同一属性段。证据为实测当时的截图与宿主属性日志（探针代码与截图未入库，已清理）。因此**输入法无法靠 marked text 强制灰色**，灰字只能走 overlay 贴字或退回建议条。

### 未证实

1. **「系统预测只支持 Apple 自带应用／输入源」未得到官方文档支持。** Apple 只写「in many macOS apps」，没有公布完整应用清单或「仅 Apple 输入源」条款。第三方邮件应用 Mimestream 的官方帮助明确描述其撰写窗口支持系统 inline predictions，这至少说明并非只限 Apple 应用；但**在 Gogaku 这类第三方 IMK 输入源下是否仍触发**仍未找到官方说明。[Apple](https://support.apple.com/guide/mac-help/typing-suggestions-correct-mistakes-mac-mchlp2299/26.0/mac/26.0)、[Mimestream 官方帮助](https://mimestream.com/help/user-guide/inline-predictive-text)
2. **不能认定灰色 `NSAttributedString` 属性会被每个宿主保留。** Apple 提供了协商机制，不等于保证执行。WebKit 直到 2023 年才专门补上 marked-text 前景色支持，恰好说明渲染能力随宿主及版本变化。[WebKit 一手变更记录](https://github.com/WebKit/WebKit/pull/10184)
3. **未找到 Microsoft 对「不进入 text store、只在光标后显示一段任意文字」的公开 TSF API。** 找到的是组合及显示属性，它们仍围绕 context／text store 工作。这里的「未找到」不是 Microsoft 对「不可能」的明确声明。
4. **TypeTab、Souffleuse 的具体绘制实现没有独立代码验证。** 两者官网都描述 Accessibility 读取字段并在 caret 处绘制灰字，指向自绘 overlay 路线，而不是 IMK marked text；本文只将其列为厂商说法。[TypeTab 厂商博客](https://typetab.app/blog/turn-on-predictive-text-mac)、[Souffleuse 官方指南](https://souffleuse.app/en/guides/autocomplete-every-mac-app.html)
5. **Norvig bigram 和 OpenSubtitles 的随包再分发权利均未核实到足够清晰的授权。** 不能因为文件可下载就默认可打包，详见第 6 节。

### 需实测

- 当前 Intel Mac／macOS 26：分别用 Apple 英文输入源与 Gogaku，在 TextEdit、Notes、Safari、Chrome、一个 Electron 宿主中检查系统灰字是否出现；同时检查是否和 Gogaku 自己的灰字重叠。
- marked-text 原型：整段显示 `help`、`selectionRange={3,0}`、只给最后一个 `p` 设置 `.foregroundColor`；先读取宿主 `validAttributesForMarkedText()`，再核对颜色、光标、候选锚点、退格、Tab 接受、Esc 清除、失焦和切字段后的最终正文。
- Windows：持久 text store 宿主中的自定义 display attribute 是否真被画成灰色；Chromium／VS Code 的 transitory context 不采用这条方案，直接验证 overlay。
- overlay：逐宿主验证字体、行高、baseline、滚动、缩放、深色模式、窗口遮挡和中英文混排；光标位于行中已有文字之前时，不应让灰字覆盖后文。
- 数据：用真实英文句子评估 bigram 的下一词命中率、误接受风险和延迟，不能只看语料规模。

## 1. macOS 系统 inline predictive text

### 1.1 版本、语言和交互

- Apple 的 Sonoma 更新说明列出「Inline predictive text shows single- and multi-word predictions that you can add by pressing the Space bar」。[官方更新说明](https://support.apple.com/en-euro/109035)
- macOS 26 帮助页的路径是「System Settings → Keyboard → Text Input → Edit → Show inline predictive text」。灰字可以完成当前词或短语，空格接受；并非所有语言可用。[官方帮助](https://support.apple.com/guide/mac-help/typing-suggestions-correct-mistakes-mac-mchlp2299/26.0/mac/26.0)
- Apple 的 Feature Availability 页面在「Predictive Typing: Inline Predictions」列出若干地区的英语、法语和西班牙语。应以该页的当前列表为准，不把「支持英语」扩写成所有键盘、所有地区都支持。[官方语言列表](https://www.apple.com/macos/feature-availability/#keyboard-inline-predictions)
- `NSTextView.inlinePredictionType` 和 `NSTextInputTraits.inlinePredictionType` 都从 macOS 14 起可用，说明宿主文本视图有开关／行为配置入口；这不是输入方法索取系统预测结果的 API。[Apple `NSTextView.inlinePredictionType`](https://developer.apple.com/documentation/appkit/nstextview/inlinepredictiontype)、[`NSTextInputTraits.inlinePredictionType`](https://developer.apple.com/documentation/appkit/nstextinputtraits/inlinepredictiontype)

### 1.2 Apple silicon：官方证据与边界

本次逐项检查了 macOS 14、15、26 的官方帮助页，均没有 Apple silicon 要求；macOS 26 页面把 inline predictions 与 Apple Intelligence 的 Writing Tools 分开描述。Sonoma 更新说明中，Presenter Overlay、Reactions、Game Mode 等条目会单独标注 Apple silicon，inline predictive text 没有这种标注。[macOS 26 帮助](https://support.apple.com/guide/mac-help/typing-suggestions-correct-mistakes-mac-mchlp2299/26.0/mac/26.0)、[Sonoma 更新说明](https://support.apple.com/en-euro/109035)

因此当前可写入产品判断的是：**没有依据把 macOS 自带 inline predictions 当作 Apple silicon-only；TypeTab、Souffleuse 等第三方工具的 Apple silicon 要求也不能套到系统功能上。** 但官方帮助页不是逐机型兼容矩阵，Gogaku 当前 Intel 机型仍须实测，尤其要把「英文输入源下可用」和「Gogaku 输入源下可用」分开。

### 1.3 应用和输入源覆盖

官方只说「many macOS apps」，没有给出完整白名单。Mimestream 是第三方应用仍支持该功能的厂商实例，所以「只有 Apple 应用」不成立；另一方面，第三方应用的实例也不能推出 Chromium、Electron 或任意自绘文本控件都支持。[Mimestream 官方帮助](https://mimestream.com/help/user-guide/inline-predictive-text)

**未找到** Apple 对「第三方 InputMethodKit 输入源激活时，系统预测是否运行」的公开保证。Gogaku 不应把系统预测当作实现依赖，也不应把用户看不到系统灰字直接归因为 Intel 硬件。

## 2. InputMethodKit 能否做出灰字

### 2.1 协议允许的原型

`NSTextInputClient.setMarkedText(_:selectedRange:replacementRange:)` 的一手文档给出三点：

1. 参数可为 `NSString` 或 `NSAttributedString`。
2. `selectedRange` 是插入字符串内部、从字符串开头计算的选区。
3. 接收方把字符串放进自己的 text storage；传纯 `NSString` 时，接收方负责绘制可辨识外观。[Apple DocC](https://developer.apple.com/documentation/appkit/nstextinputclient/setmarkedtext(_:selectedrange:replacementrange:))

所以协议层面的候选实现是：传入整段 `help`，给 `p` 加灰色属性，`selectionRange.location=3`，使 caret 留在 `hel` 后。本机 SDK 的 `IMKInputController.h` 还说明 `selectionRange` 默认在 marked text 末尾、可由输入法覆盖；这是 API 设计证据，不是宿主渲染验收。

旧版 Apple `IMKTextInput` 协议文档还明确要求输入法把富文本属性限制在 `validAttributesForMarkedText` 返回的数组内；当前 AppKit 文档说明该数组可以为空。[Apple 旧版协议文档镜像](https://leopard-adc.pepas.com/documentation/Cocoa/Reference/IMKTextInput_Protocol/IMKTextInput_Protocol.pdf)、[当前 Apple DocC](https://developer.apple.com/documentation/appkit/nstextinputclient/validattributesformarkedtext())

### 2.2 不能保证的部分

- **颜色**：`NSTextView` 文档证明文字颜色属于 marked-text 可支持属性，但不同宿主可以报告不同集合。WebKit 的 2023 年前景色补丁是宿主能力会变化的直接源码证据。[`markedTextAttributes`](https://developer.apple.com/documentation/appkit/nstextview/markedtextattributes)、[WebKit PR #10184](https://github.com/WebKit/WebKit/pull/10184)
- **光标**：协议允许组合内部选区，不等于 Chromium、Electron、终端等所有宿主都正确处理。
- **安全性**：`help` 整体是宿主中的组合文本，并非只存在于 Gogaku 的窗口。失焦、切换字段、宿主强制结束组合时，必须确保后缀不会意外提交、残留或进入新字段。
- **不可伪装**：如果宿主不支持前景色，不能把正常正文颜色的 `p` 当作 ghost 显示；应改用 overlay 或不显示。

### 2.3 系统专用预测接口不是通用替代方案

macOS 14 另有 `NSSpellChecker.showInlinePrediction(forCandidates:client:)`。SDK 头文件说明 candidates 应来自带 `NSTextCheckingGenerateInlinePredictionsKey` 的 `requestCandidates`，预测再交给 `NSTextInputClient` 显示。它面向文本客户端／系统候选流程，不是 IMK 向任意远程宿主发送自定义灰字的公开通道，也不是让 Gogaku 注入任意 bigram 结果的依据。[Apple DocC](https://developer.apple.com/documentation/appkit/nsspellchecker/showinlineprediction(forcandidates:client:))

**结论**：marked text 值得做受控原型，但只能按宿主能力白名单启用，不能承诺系统级一致效果。

### 2.4 本机探针：直调可行，真实 IMK 下被剥离（更正）

两组证据：

1. **本进程直调**：NSTextView／NSTextField 上 `hel`＋灰 `p` 保灰、无下划线、`selectedRange={3,0}` 被接受。
2. **真实 IMK 链路（独立探针输入源＋IMK 回归宿主）**：同一个带灰色属性的 `NSAttributedString` 经 IMK 送达后，宿主 `setMarkedText` 收到的属性只剩 `NSUnderline=2` 与 `NSUnderlineColor=controlAccentColor`（另一次含宿主字号的 NSFont），**自定义 NSColor 前景色被剥离，hel 与 p 合并为同一属性段**，渲染为全黑＋下划线。带有效 replacementRange、显式无下划线的变体结果相同。（探针输入源、截图与属性日志为当时实测记录，未入库保留。）

**结论**：本进程直调的成功不能外推到真实输入法。macOS 的真实 IMK 通道会按宿主组合样式重写属性串，输入法无法强制灰色。marked-text 灰字路线证伪；灰字只剩 overlay 贴字（TypeTab／Souffleuse 也正是这条路），或对兼容性要求低的建议条。

**架构含义**：若未来某宿主自行声明并渲染前景色（如 WebKit 2023 后的支持），灰色可能保留，但这取决于宿主而非输入法，不能作为产品承诺。overlay 则必须把当前词保持直输、自己画灰字，需解决宿主体字体／行高／滚动对齐。

## 3. Windows TSF 的「只显示、不提交」能力

Microsoft 将 composition 定义为临时输入状态，文本服务可以借此告诉应用和用户文本仍在变化。应用可以并应当取得组合的 display attribute；文字服务则通过 `ITfDisplayAttributeProvider`、`GUID_PROP_ATTRIBUTE` 等机制提供文字颜色和装饰。[Compositions](https://learn.microsoft.com/en-us/windows/win32/tsf/compositions)、[Providing Display Attributes](https://learn.microsoft.com/en-us/windows/win32/tsf/providing-display-attributes)

这意味着可以试验「组合内容为 `help`，caret 在 `hel` 后，后缀应用灰色 display attribute」，但要注意：

1. **它仍是 context／text store 中的组合文本**，不是独立于正文的纯视觉注释。
2. **显示责任在应用**。Microsoft 的措辞是应用可以并应当使用这些属性，不是文字服务自己强制把每个宿主画成灰色。
3. `ITfContextOwnerCompositionSink` 只是应用接收组合开始、更新、结束通知的 sink，不是 ghost-text 绘制接口。[Microsoft 接口文档](https://learn.microsoft.com/en-us/windows/win32/api/msctf/nn-msctf-itfcontextownercompositionsink)
4. `TS_SS_TRANSITORY` 的官方定义是文档预期具有短使用周期；项目已知 Chromium／VS Code 的临时文本存储限制来自仓库既有结论，本研究没有把它误写成 Microsoft 对所有 Chromium 行为的保证。[Microsoft `TS_SS_` 常量](https://learn.microsoft.com/en-us/windows/win32/tsf/ts-ss--constants)

**结论**：持久 text store 的原生宿主可把组合＋显示属性作为白名单实验；Chromium／VS Code 默认走自绘浮层。未找到可脱离 text store 的通用 TSF 行内灰字 API。

## 4. 第三方系统级预测产品怎么做

| 产品 | 官方公开的工作方式 | 权限与上下文 | 硬件限制 |
| --- | --- | --- | --- |
| TypeTab | 官网称灰字在光标处显示；其厂商博客进一步说这类工具用 Accessibility 读取聚焦字段，并「draw their suggestion next to your caret」。这是自绘 overlay 的厂商描述，未独立验证实现。[官网](https://typetab.app/)、[厂商博客](https://typetab.app/blog/turn-on-predictive-text-mac) | 要求 Accessibility，用于读取正在输入的字段；可学习词汇和表达。[官网](https://typetab.app/) | macOS 14+、Apple silicon；不适用于 Gogaku 当前 Intel Mac。[官网](https://typetab.app/) |
| Souffleuse | 官方指南明确说通过 macOS Accessibility API 读文本字段，并在 caret 处绘制灰色 continuation。[官方指南](https://souffleuse.app/en/guides/autocomplete-every-mac-app.html) | Accessibility 是核心权限；另列 Apple Events，Screen Recording 为可选、默认关闭。官网也明确说它需要读取用户所写内容。[隐私说明](https://souffleuse.app/en/privacy.html) | macOS 14+、Apple silicon；官网明确不支持 Intel。[官网](https://souffleuse.app/en/) |

对 Gogaku 的含义：

- 这两个产品的「全系统」覆盖依赖 **Accessibility 读前文＋独立应用自绘**，不是它们发现了某个更通用的 IMK marked-text 技巧。
- 它们的 Apple silicon 限制来自各自本地模型／应用，不能反证 Apple 系统预测也要求 Apple silicon。
- Gogaku 产品约束不允许为预测而申请全局监听或读取外部应用辅助功能树。因此可借鉴其 overlay 绘制方式，**不应照搬其上下文采集权限模型**。预测上下文优先来自 Gogaku 在当前 client 中自己观察到并短暂保存的最近输入；拿不到上下文就不预测。

## 5. GitHub Copilot 的 inline completion 为什么只出现在编辑器

VS Code 官方文档把 Copilot ghost text 描述为「Dimmed text at your cursor」，Tab 接受、Esc 忽略，并说明它使用当前文件及已打开文件作为上下文。[Copilot 官方文档](https://code.visualstudio.com/docs/copilot/ai-powered-suggestions)

扩展 API 更清楚地划分了责任：[VS Code API](https://code.visualstudio.com/api/references/vscode-api#InlineCompletionItemProvider)

- 扩展通过 `languages.registerInlineCompletionItemProvider` 注册 provider。
- VS Code 调用 `provideInlineCompletionItems(document, position, context, token)`，把编辑器文档和位置交给 provider。
- `InlineCompletionItem.insertText` 同时用于 preview 和 accept；`InlineCompletionList` 是在编辑器中展示的一组项目。

因此用户看到的灰字不是 Copilot 获得了「向 macOS／Windows 任意文本框叠加预测」的系统权限，而是 **Copilot 扩展与编辑器内部 inline-completion 渲染器协作**。Copilot 可以为其他 IDE 分别做插件，但 VS Code 这个 API 本身不能延伸到 TextEdit、浏览器或任意应用。Gogaku 要实现相同观感，必须另走 IMK／TSF 或自己的 overlay。

## 6. 英文 bigram／trigram 数据来源与许可

| 候选 | 数据与体积 | 许可证据与随包判断 |
| --- | --- | --- |
| **Peter Norvig `count_2w.txt`** | 约 25 万条小写 bigram，5.6 MB，体积和格式很适合做原型。[作者页面](https://www.norvig.com/ngrams/) | 页面只明确把 **代码** 以 MIT 提供；数据说明来自 Google Web Trillion Word Corpus／LDC，没有在该页给数据同样的 MIT 授权。**未找到足够明确的随包再分发许可，暂不能直接采用。** 原始 Google Web 1T 也是 LDC 数据，不应与 Google Books Ngrams 混为一谈。[LDC2006T13](https://catalog.ldc.upenn.edu/products/LDC2006T13) |
| **Google Books Ngrams** | 提供 1–5 gram、逐年计数，只保留语料中出现超过 40 次的 ngram。2020 英语 bigram 索引有 589 个 gzip 分片；本次对官方分片逐一 HEAD 求和约 **301.6 GiB 压缩体积**，必须离线筛选、按年代聚合、按左词保留 top-K，不能原样随包。[官方数据集说明](https://storage.googleapis.com/books/ngrams/books/datasetsv3.html)、[英语 bigram 分片索引](https://storage.googleapis.com/books/ngrams/books/20200217/eng/eng-2-ngrams_exports.html) | 官方明确为 **CC BY 3.0 Unported**，保留署名和许可链接后可作为首选合规原型来源。[官方许可](https://storage.googleapis.com/books/ngrams/books/datasetsv3.html)、[CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) 。风险是书籍语域与聊天／日常输入不同，需实测质量；trigram 体积更大。 |
| **OPUS OpenSubtitles 2018** | 论文统计英语约 4.41 亿句片段、32 亿 token，口语性比书籍更适合下一词预测。[ACL 论文](https://aclanthology.org/L18-1275.pdf) 官方英语 raw 下载本次 HEAD 显示约 **3.41 GiB gzip**，仍需离线构建小表。[官方下载](https://opus.nlpl.eu/legacy/download.php?f=OpenSubtitles/v2018/mono/OpenSubtitles.raw.en.gz) | OPUS 要求链接／署名 OpenSubtitles，同时声明它不拥有提取文本、只提供其认为可再分发的文件；该页没有给出足够清晰的通用商业再分发许可。[OPUS 官方页面](https://opus.nlpl.eu/legacy/OpenSubtitles-v2018.php) **在完成具体文件及上游权利核查前，不建议随包。** |
| **wordfreq** | 是单词频率表，不含可推导 `P(next|previous)` 的真实 bigram。其多 token 查询只是把多个词频组合，并明确假定这些 token 经常共同出现；对不常见组合会严重高估。[官方 README](https://github.com/rspeer/wordfreq/blob/master/README.md) | 代码为 Apache-2.0，数据带 CC BY-SA 4.0 及其他署名义务。[LICENSE](https://github.com/rspeer/wordfreq/blob/master/LICENSE.txt)、[NOTICE](https://github.com/rspeer/wordfreq/blob/master/NOTICE.md) 可继续服务现有 unigram 排序，**不能当作 bigram 数据源**。 |

建议先用 Google Books Ngrams 制作一个极小的 bigram 原型，许可最清晰；同时用真实日常句子评估语域偏差。若效果差，再为对话语料另找授权明确的数据，而不是默认把 OpenSubtitles 或 Norvig 文件打进安装包。首版只需 `P(next|previous)`＋现有 unigram backoff，不必一开始引入完整 KenLM 或大 trigram 模型。

## 对 Gogaku 的建议路线

### A. 共享核心只负责预测与生命周期

- 前缀补全继续使用现有 5 万词表；`hel → p` 不需要 bigram。
- 下一词预测使用共享 bigram 表、unigram backoff 和最低置信度；没有可靠上下文时不显示。
- 统一 `idle → visible → accepted/dismissed/invalidated` 状态机：仅灰字可见时占用 Tab；接受后经现有正式提交链路写入完整结果，其他情况 Tab 交还宿主。Esc、继续输入、退格、caret／字段／应用／输入源变化都使旧预测失效。
- 上下文只保留当前 client 内由 Gogaku 观察到的最近少量 token，失焦清理；不新增全局键盘记录或 Accessibility 阅读。

### B. 默认走「浮层贴字」，marked text 只做白名单增强

这是兼顾双端和现有安全约束的主路线：

1. **overlay 作为默认实验方向**：复用候选窗的插入点矩形，在无焦点、透明、不拦截鼠标的面板中，按宿主字体的 baseline 画灰色后缀。它不把预测文本交给宿主，天然避开 Windows transitory composition 风险。
2. **macOS marked text 白名单（已证伪，不再作为路线）**：真实 IMK 下自定义前景色被系统剥离（见 2.4），不再投入；如未来要利用个别宿主自身的前景色支持，须逐宿主实测，不能默认。
3. **Windows composition 白名单**：只对已验证的持久 text store 宿主试验组合＋display attribute；Chromium／VS Code 和无法确认行为的宿主直接 overlay。
4. **按应用配置渲染策略，而不是宣称全系统支持**：建议至少区分 `overlay`、`markedText`、`disabled`；初期仅对验收过的应用开放，再逐项扩展。

overlay 的固有边界也要明确：它不会让宿主重新排版。因此首版只在 caret 后空间足够、通常是行尾／文本末尾时显示；行中已有后文、字体或矩形不可信时隐藏，而不是覆盖正文。

### C. 不依赖 macOS 系统预测

系统功能可作为 Intel 上的对照实验，但不能替代 Gogaku 自己的实现：应用覆盖不透明、第三方 IMK 下行为未证实、无法接受 Gogaku 自定义 Tab 语义和词表。若两者可能同时出现，应在产品测试中记录冲突，不要求用户必须关闭系统功能才能使用基本输入。

## 未能核实的问题清单

1. Apple 是否有一句明确的一手声明，逐机型保证 Intel Mac 的 inline predictions；本次找到的是「官方未列 Apple silicon 限制」，不是实机验收。
2. Apple 是否正式支持在第三方 InputMethodKit 输入源激活时运行系统 inline predictions；未找到公开说明。
3. Apple 官方完整应用兼容清单；未找到。
4. Gogaku 当前 Intel Mac、当前 macOS 26 上，各宿主的系统预测、marked-text 颜色及组合内部 caret 行为；需真实宿主测试。
5. 当前 Chromium／各 Electron 版本对 marked-text 前景色和内部 caret 的实际支持；不能用旧版源码或 WebKit 的补丁替代测试。
6. Microsoft 是否另有未检索到的、脱离 text store 的 ghost-text API；本次未找到，不能证明绝对不存在。
7. TypeTab、Souffleuse 的二进制实现是否完全等同于其官网所述 overlay；未做逆向验证。
8. Norvig 派生 bigram、OpenSubtitles 具体英语文件能否以 Gogaku 的安装包形式再分发；许可未核实，不采用前不得视为已解决。
9. Google Books bigram 经过大幅裁剪后，对日常英文下一词预测是否足够好；需质量与包体积联合评估。
