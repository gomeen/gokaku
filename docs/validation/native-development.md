# 原生工程实施验收记录

更新：2026-11-03（翻译后端统一复测：quickmt 速度领先但质量未过，暂不替换；学习模式仍阻塞）。目标机器：Intel Mac、macOS 26.7.2。

## 翻译模型解堵：裁决落地与加固层第一片（2026-11-02，工作区，未定版）

按用户当日裁决（处置口径、宽松许可候选验证、死守 500ms）推进，全部证据入库；**学习模式交付仍保持阻塞**（质量门槛未重跑，以下为解堵路径的组成部分）：

- **调研与裁决落档**：三路线（换 NMT／小 LLM／加固层）＋快档补充调研见[模型解堵调研](../research-translation-model-unblock.md)（§六裁决记录、§七 quickmt 发现）；实施计划§四、[产品方向](../product.md)「已选工程路线与资源门槛」同步修订。
- **quickmt 速度探针**（[探针报告](../../probes/results/quickmt-speed/report.md)）：`quickmt-en-zh`／`quickmt-zh-en`（CC-BY-4.0，原生 CT2）在门槛机（CT2 4.6.0 int8、greedy、2 线程、12 轮热态）短表达 p95：en→zh 66.8ms／zh→en 41.6ms；短句 79.0／82.2ms——约为预算 1/6–1/8，比 small100 同参数快 2–2.8 倍；载入 0.9s；当时机械口径风险集 32/32、留存集 180/180 可用（未含加固层）。质量烟测：small100 四个固定失败点修复三个，但短语级新暴露重复／繁体漂移／截断／语义跑偏（beam 无关，模型固有）。脚本 `scripts/validate-quickmt-speed.py`。
- **统一后端复测（2026-11-03，[决定](../../probes/results/translation-backends/decision.md)）**：同一驱动、5 轮交错、2,400 条请求，分模型层／辅助进程层／加固层比较 small100 与 quickmt。quickmt 短表达 p95 43.4–83.6ms、短句 68.9–89.7ms，快约 1.6–3 倍；但加固后 en→zh 可用率仅 77.67%、固定风险 12 条未处置（短语级复读／截断／残片为主）；small100 为 95.15%／94.34%、固定风险 5 条。两者都未过质量门槛，**决定暂不替换、学习模式继续阻塞**；加固层另有时间区间／`am` 动词／合法三元组／URL 脚本四类误报待第二片。语义审阅见[记录](../../probes/results/translation-backends/semantic-review.md)。文档／基准改动后 fast 档复跑通过（`report-fast-20261103-094435.json`）。
- **自建短文本评测集**（[translation-short-expressions.json](../../validation/translation-short-expressions.json)）：双方向各 44 例冻结；短语／时间／人名／品牌／错拼／乱码陷阱；reference 草案待用户审阅。
- **翻译加固层第一片**（`native/GogakuCore/translate/`，附加 ABI，无 libime 依赖）：重复分类／繁→简归一（OpenCC 生成表 3616 字，`scripts/build-t2s-table.py`）／时间一致性／脚本校验／长度比率／专名保护扫描；`gogaku_core_translate_safety_test` 55 项断言；处置效果验证 [hardening-demo.json](../../probes/results/quickmt-speed/hardening-demo.json)：15 条真实失败样本中重复／时段／繁体／乱码四类被拦截或归一，**语义跑偏、多余尾部、短源截断、人名丢失、品牌改写五类未拦（需第二片：覆盖 QE／专名对齐）**，如实记录。
- **已验证**：fast 档全过（版本 b6 拒绝路径 7/7、资源哈希、核心 ctest 5/5 含 translate_safety 55 断言、Swift Release 96 项）；报告 `docs/validation/verify/report-fast-20261102-203457.json`。
- **未完成／待验证**：quickmt 已跑统一风险集语义审阅（2026-11-03）但质量未过，用户盲测仍未进行（不标替换）；加固层未接入翻译管线（当前为纯函数＋测试＋验证脚本）；评测集 reference 待用户审阅；host 档、GUI 人工验收、候选窗定位重构宿主回归、性能门槛未过——均不变。学习模式菜单仍置灰。

## 设置页原生落地与普通输入收尾（2026-11-03，工作区，未定版）

规格按用户裁决定稿写入[产品方向](../product.md)「设置页面规格（2026-11-03 定稿）」；六个中间风格方案（settings-a-*、settings-display-*、settings-n2-*）标为历史，不再作为实现依据。实现全部为原生 SwiftUI／AppKit，未嵌入 HTML。构建 5 起：

- **设置外壳与保存**：六页外壳（200pt 侧栏、内容滚动区、固定底部状态栏，默认 900×620／最小 760×520，青绿强调色跟随明暗）。普通选项、应用列表、有效快捷键改动立即提交，连续文本输入合并 300ms，失焦／关窗提交剩余改动；串行写入协调器（`GogakuCore.SettingsStore`）每次落盘前重读磁盘并按顶层字段差异合并，仅成功落盘后发送 `settings.changed`，失败保留待保存改动并在状态栏重试（不伪报成功、不无限重试）。设置应用与输入法进程走同一协调规则。协调器行为回归：立即保存＋通知、合并提交取最新值、写失败保留与重试、双实例合并不回滚、过期基线不覆盖外部写入。
- **应用列表**：按应用默认英文（每行启用开关＋移除，关闭后保留该行）、快速添加排除、学习与隐私排除共用图标＋名称列表与可搜索添加弹层；后台索引 `/Applications`、`/System/Applications`、`~/Applications`（本机实测 101 个应用，图标与名称来自系统），按 bundle ID 去重，支持文件选择器添加任意位置 `.app`；未安装或无法解析的应用保留记录、显示通用图标并以标识回退名称（实测旧配置中未安装的 VS Code 行）。三个列表绑定独立，回归断言互不串值。
- **快捷键**：三个可配置命令（普通／学习、学习方向、快速添加）统一纳入 VS Code 式表格；录制使用设置窗口内事件捕获（含 F 键与带修饰键的标点；无修饰键可打印字符与单独修饰键拒绝绑定；Esc 取消、Delete 清除、恢复默认）；冲突检查覆盖可配置命令与固定输入操作（取消组合 Esc、学习原文上屏 ⌘Return、普通模式 Ctrl 编辑键等），冲突草稿只提示不替换最后有效绑定；全部／我修改的／冲突筛选与搜索。快捷键模型 v2（`GogakuCore.KeyCombo`）兼容读取旧 `key/modifiers`；明确禁用状态持久化，重启不复活；默认值不写新字段，旧二进制仍可解码（回归覆盖）。输入法匹配改用同一规范化逻辑（`KeyCombo.from(event:)`），F 键按 keyCode 匹配；普通模式 Command／Option 组合改为纯宿主透传，不再把学习「原文上屏」语义带入普通模式（产品规格表）。
- **自定义词语**：保留原生增删改、启停、排序、自动读音与校验（TSV v1 不迁移）；紧凑单行列表（内容＋编码／读音＋启用状态，长内容省略）；顶部短码短语／拼音词分段＋搜索框＋新增按钮；编辑／删除／上移／下移放选中行工具栏与右键菜单，双击打开既有编辑表单；搜索覆盖内容、编码、读音，搜索时禁用排序；行标识绑定存储行，筛选后不错行（模型回归覆盖）；排序改为同类内移动；写入成功后直接通知重载，不再为发通知保存整份 settings.json。
- **语言资源页**：移除 Apple Translation 查询与安装入口；展示实际随包资源（sc.dict／zh_CN.lm／english-words.txt／gloss.tsv 及大小）与「学习功能尚未开放」状态。
- **候选窗定位重构**：宿主光标矩形三态（未读取／有效／无效，`GGHostSnapshot.rectangleRead`）；移除鼠标位置与虚构屏幕尺寸回退；锚点身份与显示位置分离（`displayRect`）；marked text 更新后合并刷新读取最新位置，组合中以 100ms 复查处理滚动与窗口移动，无组合或失焦立即停止；同一坐标不重复布局，旧代次刷新不使已关闭面板复活；无有效坐标隐藏面板但保留组合，恢复有效且字段一致后重新显示；放置几何纯函数（`PanelPlacement`）默认插入点右下、空间不足上翻、重算高度后不越界，负坐标与多屏支持；额外宿主读取计入 `hostReadNs` 性能测量。离线几何单测覆盖边缘、上翻、钳制、负坐标、零宽矩形、无效与全零锚点、无屏幕、超大面板；离线渲染探针新增屏内可布局／屏外不布局断言（51 项）。
- **已验证**：fast 档全过（核心 ctest 4/4、Swift Release 87 项含新增设置模型／协调器／快捷键／行模型／几何回归）；渲染检查 51 项；GUI 真实启动冒烟：六页逐页截图（[语言资源](settings-page-resources.png)、[普通输入](settings-page-normal-input.png)、[自定义词语](settings-page-custom-words.png)、[快捷键](settings-page-shortcuts.png)、[学习与隐私](settings-page-privacy.png)）、[添加应用弹层](settings-app-picker-sheet.png)（真实目录索引、已添加计数、已添加项禁用）；[立即保存往返](settings-immediate-save-fuzzy.png)：真实点击模糊音开关后 1 秒内 settings.json 落盘 `z-zh`，关回后恢复空；验证后配置文件已还原。
- **未完成／待验证**：完整 release 档本轮运行（干净构建／包检查／质量／数据可靠性／十万序列插桩）；host 档（两轮宿主矩阵、Orca Shift 专项、万次性能、两小时稳定性）入口已真实化但需用户空闲时段执行；原生 GUI 验收（两种窗口尺寸 × 浅／深外观 × 键盘导航／VoiceOver）无自动化探针，需人工验收后归档 `docs/validation/verify/native-gui-acceptance.json`；候选窗定位重构的真实宿主回归未跑；1000 条词条滚动／搜索压测未跑。学习模式、Windows、模型替换不变。

## 自定义拼音词与自动读音修复（2026-11-02，构建 4，包含构建 3 修复）

用户报告「极视角」自动读音失败，手填 `ji'shi'jiao` 后小鹤 `jiuijn` 也没有候选。已通过真实出厂词典及共享核心 C ABI 复现：初载和重载时，双拼、全拼均遗漏该自定义词；自动读音连「极」「视」「角」「会议」也返回失败。新增真实词典回归修前 311 项断言中 30 项失败，修后 311 项全过。

- **候选缺失根因**：把 libime 相加的词条分数当作待最小化的代价，给自定义词 `-18` 导致词条在解码阶段被剪枝。改为正向提升后，「极视角」在双拼、全拼及初载、重载四种情况下均为首选，空格一次上屏，且能参与「我想看极视角」的组句；自定义候选不进入调频快速添加记录。
- **自动读音根因**：按 TSV 解析 libime 实际的空格分隔文本，导致单字读音表为空；同时多音字取最小分数方向错误。改为空白分隔、最大分数优先，「极视角」返回 `ji'shi'jiao`，「角」返回 `jiao`，真实缺字／缺文件仍明确失败。
- **设置应用资源**：自动读音改用 `Paths.engineData/sc.dict`；构建为设置应用单独复制经依赖锁哈希校验的 `sc.dict`，不依赖开发缓存。包检查新增 `settingsAutoPinyin`。
- **编辑表单根因**：首次点击拼音词「编辑」实际弹出空白短码表单。独立的词条状态与布尔弹窗状态未同步；改为 `.sheet(item:)` 由当前编辑请求驱动，并在初始化时设置草稿。构建 4 真实界面已核对首次编辑「极视角」、新增拼音词空表单、切换新增短码表单；清空读音后点击「自动读音」，从弹窗的读音字段读回 `ji'shi'jiao`，随后取消，未保存测试数据。
- **已完成验证**：fast 档 4 项全过（核心 ctest 4/4、事件 311 断言、Swift Release 51 项、版本与资源检查）；报告见 `verify/report-fast-20261102-110938.json`。构建 4 Release 编译及核心 ctest 4/4 通过；已安装两个开发包并核对运行时哈希，安装件签名、动态库闭包、随包资源及 `settingsAutoPinyin` 均通过。直接调用安装件共享核心，双拼 `jiuijn`／全拼 `jishijiao` 的初载与重载四项均以「极视角」为首选。证据保存在 `local/custom-pinyin-fix/`（`build-4.log`、`bundle-4-installed.json`、`candidates-4-installed.log`、`gui-auto-pinyin.json`、`gui-new-shortcode.json`）。
- **未完成范围**：本轮完整 release 档未完成，不能沿用历史 release 报告标记通过；真实输入源宿主矩阵及性能本轮未跑，不据共享核心与设置界面回归标为通过。

## 工程化与普通输入收尾（2026-11-02）

本轮完成[工程化检查](engineering-readiness.md)与整改、Git 基线与单一版本来源（`version.json`，见 [versioning.md](../versioning.md)）、统一验证入口 `scripts/verify.py`（fast／release／host 三档，机器可读报告）。普通输入修复：

- **Shift 提交不更新最近上屏字符（已修，核心）**：组合中 Shift 上屏后 `lastChar` 停留在组合前字符，下一标点错误沿用数字后半角例外——这正是上一轮 Terminal「Shift 确认＋句号」得半角 `.` 的根因（彼时归因平台层，实际在核心；此前“离线核心两路径都输出「。」”的验证走的是 Enter 路径，未覆盖 Shift 路径）。修复后 Shift 与 Enter／空格／选词提交同规则；新增「数字 → 字母组合 → Shift → 句号／冒号」反例与写失败反例组回归（事件轨迹 257 → 275 项断言）。**该结论待真实 Terminal 短测复验后才能标宿主通过。**
- **Orca Shift 单击未提交（待追踪）**：维持上一轮判定——释放事件存在但插字 0 次、组合疑似先被取消；与 Terminal 不同因。待验证构建＋`verify.py --profile host`（含 Orca Shift 专项：逐事件核对按下／释放、组合变化、插字次数、PTY 字节），本轮未运行。
- **释义精简（已生成并随验证包打包；拒包／降级两分支实测）**：`character` 不作词性、结构化标签不透传、强语域剔除、单条 ≤64 字符不截断；词条 161,839 → 143,777；固定种子 50 条审阅见 [gloss-simplification-review.md](gloss-simplification-review.md)。中文质量首选 109/120、前十 112/120 未降（quality 回归本轮通过）。
- **Hyper（fn）不触发 Shift 单击**（平台层判定排除 `.function` 修饰）。

本轮已验证（release 档，报告绑定提交与产物身份）：核心 ctest 4/4（275 断言）、Swift Release 49 项、干净构建＋包检查＋质量 109/112＋渲染 51 项＋40 轮数据可靠性＋十万随机序列 ASan/UBSan（100000 序列 / 1250029 事件，失败 0）＋安装预检，fast 档全过（版本拒绝路径 7/7、资源哈希一致）；报告见 `docs/validation/verify/report-release-*.json`。宿主矩阵、Orca Shift 专项与性能测量属 host 档（需用户空闲时显式运行），本轮未运行、不标通过。性能阻塞与试用停止状态不变：必要同步宿主写入在长单行场景超预算的结论未被本轮工作改变。

## 试用前收尾复测（2026-11-01，历史，仍为性能结论依据）

**正式性能未通过，已按计划停止交付试用。** Release 最终包 10,035 个真实 IMK 事件：主线程 p95 10.35ms／p99 15.38ms，超过 5ms／10ms；首次显示 p95 21.93ms／p99 24.44ms、AppKit 探针收字 p95 23.26ms 和 892/892 次回调内隐藏通过。当前结论和全部原始证据见[收尾复测报告](pre-user-test.md)。旧轮次“最终版已安装”“日志已移除”“宿主连续两轮全过”及性能“条件性达标”已逐项更正；Chrome 半角逗号仍待最终矩阵复验，不归因 Chromium。

本轮实现：空闲按键重锚、无效光标几何与宿主身份分离、提交同步隐藏与迟到渲染代次检查、面板预建、核心光标偏移传到宿主及面板、按需候选物化与英文索引、原码／字面文本草稿恢复、删除旧按键日志。

已完成：Release 构建安装并核对 23 个运行时文件哈希；核心 ctest 4/4（事件断言 257 项）；Swift 49 项；渲染 51 项；40 轮数据可靠性；中文质量首选 109/120、前十 112/120；安装件签名、依赖闭包、资源与日志检查。独立核心基准 p95 2.997ms，未达 1ms 优化目标；正式 IMK 结果如上，失败阻塞交付。ASan 十万序列、最终真实宿主连续两轮、内存／两小时稳定性／冷启动未完成；先前中止的插桩不计通过。验收开关、socket 与诊断进程已关闭，输入源恢复。Spotlight／Raycast 未测，学习模式保持关闭，Windows 未开始。

下方保留历史阶段记录。历史错误的 16,000 事件 p95 0.4µs 已作废；历史局部 AppKit 插字耗时、旧核心两小时浸泡不代表最终输入源通过。需求与当前状态以顶部及最新报告为准。

## 普通模式对齐＋自定义词语（2026-10-31 本阶段）

按六轮输入习惯裁决实现普通模式：行为规格迁入共享 C++ 核心（`native/GogakuCore`，ABI v2），Mac 端（IMK 控制器／面板／设置）改为薄调用。已验证：

- **事件轨迹测试**：`gogaku_core_normal_test` 195 项断言全过（ctest 2/2）。覆盖：小鹤／全拼、模糊音（z/zh、n/l 等）、标点表（含引号交替、数字后半角例外）、组合中标点一次上屏（完整／部分覆盖）、数字 0／超页、每页 9 个分页（`,`／`.`／PageUp／Down）、↑↓ 跨页、分段选择与退格撤回、Home／End／Ctrl＋a/b/e/f/n/p、Shift（组合中上屏原编码不切英文／未组合单击切中英带 toast）、大写原样段（Cpj→C盘、单字母空格原样上屏）、英文候选合并排序（中文不完整时排第一、完整时排第二、前缀补全≤3）、按应用默认英文（Raycast 等九应用、Shift 覆盖、Esc 回默认）、调频与 Control＋Backspace 删词、短码短语（精确匹配置顶／前缀不出现／暂存分段不出现）、拼音词完整匹配置顶、快速添加（可加／已存在／超 60 秒交还宿主／换输入框交还宿主／排除应用）、custom-words.tsv 读写转义与损坏备份、自动读音、持久化（model.userlm／learned.txt 原子写入）与重载。
- **ABI 合同**：`gc_abi_version()==2`，`nm -gU` 仅导出 ABI 函数；不引用 Apple 框架（纯 CMake 构建测试）。
- **性能**：`gogaku_core_normal_bench` 16,000 事件 p95 0.4µs／p99 0.5µs（对照门槛 5ms，出厂词典）。此为核心耗时；宿主链路延迟另测。
- **Swift 桥接**：`CGogakuCore`（system library）＋`NormalEngine` 薄封装；swift test 31 项全过（含桥接层合同与设置字段兼容旧 settings.json）。
- **Mac 平台层**：普通模式按键同步交共享核心（引擎队列 `sync`，万次事件 p95 < 1µs）；consumed=false 透传宿主；输入区字母默认 marked text 显示（可关，失焦／切换前先清空）；候选窗按裁决规格重绘（候选 14 号可调 12–16、注释 −1 序号 −3、行高 46×字号/21、注释琥珀 #7D5800／深色 #E3A82E、选中白字、页码「1/4」）；修饰键变化不再挂起组合，Shift 单击按「按住期间无其他键＋<600ms」判定；「中／英」提示浮层 0.8 秒；学习模式菜单置灰并注明原因；Control＋Shift＋A 快速添加与「已加入／已存在」提示；设置变更通知后热更新（方案／模糊音／调频开关／按应用列表／自定义词重载）。
- **设置页**：新增「普通输入」页（方案、模糊音九对、字号、英文释义、输入区字母、显示形态、调频开关与清空、英文候选、按应用默认英文列表、快速添加键与排除应用）与「自定义词语」页（两列表、增删改、启用、上下移、校验具体原因、自动读音、损坏恢复提示）。保存后经 settings.changed 通知 1 秒内生效（重载路径已实现）。
- **包**：`scripts/build.py` 增建 GogakuCore（CMake＋ctest）；`libgogaku_core.dylib` 进入两端 Frameworks；`check-bundle.py` 签名与依赖闭包通过（包内＋系统）。
- **真实宿主回归**：`probes/validate-imk-host.py --orca` 18 项全过（AppKit＋Orca：Gogaku／ABC 来回、预编辑不进宿主、空格一次上屏、单字符原文、切字段撤销旧候选、选区替换、快速连打、数字选候选、`.`／`,` 翻页、退格透传与逐键删除）。证据见 [imk-host-smoke.json](imk-host-smoke.json)。

**本阶段未完成／未验证**（不得标为已实现）：英文候选与释义数据未生成未打包（SCOWL／wordfreq／Wiktionary 许可登记前置，见[释义词性数据调研](../research-gloss-data.md)；核心在数据缺省时自动降级）；输入区字母在真实宿主的显示／清理、Shift 单击真实系统事件、快速添加真实键事件、「中／英」提示浮层定位、候选窗跟随当前插入点（按裁决改为逐次跟随，尚未做离线几何比对）与 AppKit 2x 截图逐项比对；主线程万次事件 p95（含面板渲染与插字的全链路）；学习交互仍因模型门槛关闭。Windows 端未开始。

## 双端计划修订（2026-10-31）

用户已批准 macOS＋Windows 双端首阶段计划，替换原单 Mac 实施范围；门槛改为 G0–G4，见[实施总计划](../implementation-plan.md)。对验收状态的影响：

- **G0 Windows 环境**：未提供，Windows 构建、TSF、安装及双端闭环全部保持未开始／未通过。不以上游 libime 的 Windows 工作流代替自验。
- **G0 Mac 模型门槛**：Apple Translation 退出正式交付链路（原“Apple 优先、失败后 small100”顺序作废，既有 Apple 探针保留为历史证据）。唯一候选 small100 `8ab680e` 已完成 Mac 分词、转换、质量与速度验证：**技术可行性通过，模型质量门槛不通过**，双端学习交付保持阻塞，详见下方[small100 Mac 模型门槛](#g0small100-mac-模型门槛2026-10-31)与[语义审阅记录](../../probes/results/small100-gate/semantic-review.md)。
- **行为规格差异待调和**：本计划确认每页 5 个候选、数字 1…5 选择；现实现按用户青简配置使用每页 9 个（见下文第 4／6 条修复）。G1 迁移时以计划为准统一，迁移前不回改已验证的 Mac 行为证据。
- **更正（2026-10-31，追加）**：上一条“以计划为准统一为 5 个”方向写反了。用户经六轮输入习惯原型裁决后已确认**每页 9 个、数字 1–9**为准，计划文档已同步修正（见[实施总计划](../implementation-plan.md)§五与[产品方向](../product.md)普通模式行为规格）；本条及下方历史记录保留原样，不倒改。后续迁移以 9 为准，不再回改历史证据。
- 原 A–E 阶段证据映射：A→G2 Mac 部分、B→G0、C→G3、D→G4、E→G4。以下历史记录保持原样，不倒改。

## G0：small100 Mac 模型门槛（2026-10-31）

执行环境：Intel Mac i9-9880H、macOS 26.7.2、CTranslate2 4.6.0 INT8、greedy、batch=1、2 线程；模型 `alirezamsh/small100@8ab680e26a596d2e3d2d2d17ae0f68df1037328c`（MIT），下载哈希与产物见 `~/Library/Caches/Gogaku/models/small100-gate/manifest.json`；转换在含 PyTorch 的隔离环境 `OMP_NUM_THREADS=1` 完成，推理在无 PyTorch 环境、`HF_HUB_OFFLINE=1` 完成。脚本：`scripts/prepare-small100-gate.py`、`scripts/validate-small100-gate.py`。

**技术可行性通过**：分词与协议验证（目标语言 token 为编码器输入前缀，解码器从纯 eos 开始，非 M2M100 协议）；INT8 转换成功（model.bin 338,727,246 字节）；热态短表达 p95 125.5／111.2ms、短句 p95 218.7／198.9ms（门槛 500ms／2s）；HF 参考对照 6 句中 5 句逐字一致（分歧见下）；离线推理可用。

**模型质量门槛不通过**：机械判定全过（风险集 32/32、保留集 180/180 可用，空／重复／超时均为 0，应译可用率 100%≥95%），但固定风险集存在未处置的意义破坏：en-names 丢 Bob、en-long `10:30 a.m.`→`下午10点30点`、zh-long `十点半`→`10 a.m.`、en-phrase 输出繁体；保留集扫描另有 `9 a.m.`→`下午9点` 时段翻转、品牌 `Gogaku`→`古巴`、错拼／乱码编造（含 181 个重复 Q）。逐条审阅与判定见[语义审阅记录](../../probes/results/small100-gate/semantic-review.md)，数据与哈希见 [evaluate.json](../../probes/results/small100-gate/evaluate.json)、[artifact-hashes.txt](../../probes/results/small100-gate/artifact-hashes.txt)。

**处置**：按计划§4／§8 停止规则，双端学习交付保持阻塞；不改一端 Apple、不恢复 OPUS／M2M100、不扩模型名单；用户语义盲测未进行（前置质量条件不成立）。普通输入与共享核心工作继续。

## G1 前置：最小共享接口（2026-10-31）

新建 `native/GogakuCore`：共享核心 C ABI 骨架（版本 1），含 `gc_abi_version`／`gc_abi_check` 版本合同与 `gc_utf8_scalar_count`（512 标量输入上限所用，明确 Unicode 标量而非 UTF-16 范围）。Windows DLL 导出宏已内置；库内分配由库释放、异常与 STL 不跨 ABI 的合同写入头文件。构建与测试：

```sh
cmake -S native/GogakuCore -B .build/core -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build .build/core -j 2 && ctest --test-dir .build/core
```

16 项断言全过；`nm -gU` 确认 dylib 仅导出三个 ABI 函数。同一测试文件后续在 Windows（MSVC 加载 Clang64 DLL）运行。组合／调度／记录等规则未提前迁入，待 G1 按事件轨迹逐模块迁移。

---

**Mac 普通输入已在独立 AppKit 宿主和 Orca 终端完成限定场景验证；原单 Mac 首阶段与双端首阶段均未完成。** 已验证系统输入源切换、普通中文上屏、明确原文上屏、分页键和部分焦点撤销路径。完整宿主安全矩阵、学习交互、真实学习记录、语义与正式性能尚未验收。生产学习辅助与记录保持关闭。

执行门槛以[实施总计划](../implementation-plan.md)为准，使用方式见[开发版说明](../native-development.md)。

## 当前修复及真实证据

用户反馈候选窗上下选择时位置跳动、样式简陋、菜单图标与其他输入源不一致，并希望预留主题接口、支持 `,`／`.` 翻页。已修复并用真实宿主验证：

1. **候选窗跟随跳动**：`publish` 每次都用最新宿主光标矩形重新定位，宿主矩形微小抖动会带动整窗移动。现在面板锚点在组合开始时记录一次（`panelAnchor`），同一次组合内导航、迟到翻译、拼写结果都复用该锚点；插字前的宿主安全校验仍用当前目标，不受影响。证据：[选择前](native-candidate-panel-before.png)与[下移后](native-candidate-panel-after.png)离线渲染中，除选中行位置外全部几何一致，面板 origin 不变。
2. **候选窗按青简规格重写**：不再用 NSStackView 近似，改为按主题规格逐项自绘。默认主题镜像青简本机激活的 `rime-macos`（翠绿）的**生效规格**（经 `extends` 合并语义从源码算出）：窗口内边距 8、行高 46、序号 16pt（margin 上 8 左 5）、候选 21pt（margin 上 6.5 左 8）、注释 15pt（margin 上 8 左 8）、预编辑行上下 4、插入点 1.5pt、选中高亮右扩 4pt 圆角 4 实心 `#12996a` 白字、页码右对齐 16pt（多于一页才显示，如“1/2”）、窗口圆角 8、宽度按内容钳制 [180, 440]。字体引用用户已安装的 `Fira Code WenKai`（OFL，仅按名引用不打包，缺失回退系统字体）；未复制青简 GPL 代码或素材。每页候选 5 个（`CandidatePage.size`，桥接 `PageSize`、会话分页、面板与数字键共用）；修复重写时丢失的源文本赋值。设置模型 `candidateTheme` 字段兼容旧 settings.json，未知主题 ID 回退默认。验证：零事件离线渲染逐项实测——面板 180×297pt、行距 46.0、序号起始 x≈19pt、高亮 x8..176（内宽+4）高 46、预编辑 y9/x8、页码右对齐 x133.5..169.5，与规格一致；同组合内导航／翻页／内容变化时锚点 origin 不变。宿主交互检查待用户空闲时复跑。
3. **菜单图标与其他输入源不一致**：旧 16×16 页面内键帽仅约 11.5pt 高，在菜单里明显偏小；白色笔画曾被系统按模板染色后消失。现改为 22×16pt 页面（与青简同尺寸）几乎撑满的键帽，笔画用 even-odd 真实透明镂空。实测系统下拉菜单中 ABC、青简、Gogaku 三行图标宽度一致（约 40px@2x），Gogaku 字形镂空可见，见[真实菜单截图](native-input-menu.png)。
4. **`,`／`.` 翻页与每页候选数**：`pageDelta` 统一入口，`Page Up`／`Page Down` 与 `,`／`.` 同路径；`,`／`.` 仅在当前组合已有候选且无未完成编辑时作为翻页键，否则交还宿主。每页候选数与用户青简配置一致（`page_size = 9`，`CandidatePage.size` 与桥接 `PageSize` 共用）。真实宿主新增检查：数字选首页候选、`.` 下翻后数字选中新页候选、`.`+`,` 回翻后恢复首页选择。
5. **单字符原文提交被 keyUp 竞态否决（间歇性）**：`handle` 对非 keyDown 一律 `suspend()`，Return 的 keyUp 会在“确认后下一轮插字”窗口内把 focus 加一，插字被 focus==generation 校验误拒，'m' 以 marked text 滞留不上屏。修复：keyUp 直接透传；插字校验改为“目标字段未变且无未完成编辑”，不再依赖 generation。新增两项退格检查：空组合时退格透传到宿主；组合中退格逐键删除后提交正确。修复前 4 轮中 3 轮复现，修复后 4 轮全过，最终 18 项检查全部通过。
6. **字号与间距对齐用户青简配置**：用户青简 `config.toml` 覆盖主题字号（candidate 15、annotation 14、page_size 9），青简的行高按字号比例缩放（46×15/21≈32.9）。面板已按这些生效值重设：候选 15pt、注释/预编辑 14pt、序号 16pt、行高 32.9pt、每页 9 个。
7. **与输入习惯原型的待对齐项**：[输入习惯原型](../prototype-input-habits.md)（六轮迭代定稿，晚于本轮）裁决了 Gogaku 自身的候选窗规格：默认候选 14 号（12–16 可调）、序号 −3（11 号，明显小于候选词）、注释 −1、行高 46×字号/21、琥珀色「词性＋译文」注释默认常显、候选窗跟随当前光标（插入点右下）。原生面板当前仍按青简本机配置值（15／14／序号 16、起点锚点）且无琥珀注释——这些裁决尚未落到原生，待用户确认后另行实施；三项按键裁决（组合中标点一次上屏、组合中 Shift 上屏原编码不切英文、数字 0 先上屏高亮再输出）已并入[产品方向](../product.md)，同样未实现。

此前轮次已验证的历史修复：空菜单图标与缓存刷新；启动时重复 `TISEnableInputSource` 干扰切换（改为安装时注册、运行时只建 IMKServer）；Orca 丢弃显式替换范围（改用宿主当前选区插字）；单字符原文回车被 Chromium 转发（确认后暂存 marked text，下一主线程轮次复查并提交，PTY 字节无多余回车）；普通模式候选“每 · 中文”尾巴。

另一次“切换失灵且无法输入”的排查结论：Gogaku 与青简一度都不在系统启用列表，且选中状态残留已移除的鼠须管——是用户当日在系统设置编辑输入源所致，非代码回归。重新启用后程序化往返（Gogaku／ABC／青简）全部生效。诊断方法已记入项目技能：先查 TIS 运行时启用列表与 HIToolbox 偏好的一致性，再怀疑代码。

此前“合成事件不能验证系统快捷键”的结论同样撤回：持续运行的 AppKit 测试进程能正确发送修饰键事件并读回系统状态。一次性命令行探针中的状态和事件结果曾造成误判。

## 真实宿主回归

执行：

```sh
python3 probes/validate-imk-host.py --orca
```

探针构建独立 AppKit 应用，使用已启用的真实系统输入源与 CGEvent。Orca 部分新建专用 PTY 接收终端，逐字节读回合成输入；不向已有 agent 终端输入。结束时关闭测试终端并恢复先前应用和输入源。证据绑定已安装输入源的 SHA-256，见[imk-host-smoke.json](imk-host-smoke.json)。

**18 项检查通过：**

| 宿主 | 已验证场景 |
| --- | --- |
| AppKit | Control＋空格 Gogaku／ABC 三次来回；确认前正文为空；`nihc`＋空格只插入一次“你好”；`m`＋Enter 只插入一次原文；切字段撤销旧候选；`left old right` 的选区替换为 `left m right`；快速连按多字符和单字符原文提交；数字选首页候选；`.` 下翻后数字选中新页候选；`.`+`,` 回翻后恢复首页选择；空组合退格透传到宿主；组合中退格逐键删除后提交正确 |
| Orca 终端 | Control＋空格 Gogaku／ABC 三次来回；确认前 PTY 无字节；空格提交“你好”；回车仅追加原文 `m`；切输入源取消旧组合后，新输入仅提交一次“你好” |

这些是上述场景的通过证据。安全字段、相同选区位置的不同字段、Chrome textarea／contenteditable、其他终端、Notes、Safari、睡眠唤醒、VoiceOver、长时间并发和屏幕可见延迟仍需独立验收。

## 核心、桥接与服务回归

```sh
cmake --build .build/native -j 2
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release -j 2
```

**25 项测试，0 失败，运行时间 14.837 秒。** 该时间不是输入延迟。默认 CLT 缺 XCTest 时，仅为本次命令设置 `DEVELOPER_DIR`。（2026-11-02 注：本节为历史记录；命令现统一为 Release 配置，当前为 49 项 XCTest＋swift-testing。）

| 类别 | 数量 | 实际覆盖 |
| --- | --- | --- |
| EngineTests | 11 | 出厂 Xiaohe、非首项、部分选择与编码消费范围、分页编辑、Unicode 与字面片段、候选修订／模式／方向、编号与导航冻结、原文一次提交、512 标量、内存草稿、设置主题字段兼容旧 settings.json |
| HostTests | 4 | 当前选区插字、确认文本的暂存／提交、真实 NSTextView 选区替换、缺少 client 不报告调用成功 |
| SpellingTests | 2 | 真实 NSSpellChecker 完成词检查、emoji 前缀 UTF-16 范围及免标记过滤 |
| StoreTests | 3 | 去重、TTL、暂停／排除、删除墓碑、存储不可用 |
| TranslationTests | 5 | 受控 helper 的挂起超时、仅最新待办、失效、资源身份和超长保留，不代表翻译质量 |

摘要与相应源码哈希见[native-test-summary.json](native-test-summary.json)。尚无万次真实逐键轨迹或全量故障矩阵结论。

## 开发包与安装

`python3 scripts/build.py` 生成本机 ad-hoc 签名包，已更新安装到：

- `~/Library/Input Methods/Gogaku.app`
- `~/Applications/Gogaku Settings.app`

安装执行 `lsregister -f` 与 `TISRegisterInputSource` 刷新启动路径及图标元数据；不自动启用或设为默认。首次启用由系统设置流程完成。此前已解决 `ComponentInputModeDict` 缺失、LaunchServices 启动登记以及不稳定 IMK client 代理身份导致的逐键草稿问题。代理和 `uniqueClientIdentifierString` 实测不稳定，当前按应用、进程、选区及生命周期复查；这不能替代尚未通过的完整字段安全矩阵。

已从安装目录执行 `scripts/check-bundle.py`：两个包严格签名通过，实际九个非系统共享库均在包内，动态链接与 rpath 只引用包内／系统；菜单 PDF 渲染、包内 `nihc → 你好` 和拼写 helper 的 UTF-16 范围均通过。见[bundle-smoke.json](bundle-smoke.json)。检查未改名、卸载或删除 Homebrew。

SwiftPM 工程包含 `GogakuCore`、IMK 输入源、原生设置、管道 helper 和 C／Objective-C 桥接。libime 1.1.17、必要 Fcitx5Utils、数据与 KenLM 均固定版本，随包保留许可；不导入私人词库。第三方公开分发义务与项目自身许可仍待处理，见[许可说明](../third-party.md)。实际卸载恢复与完整安装矩阵尚未验收。

## 设置与语言资源

设置界面参考 Zakki：约 200pt 左导航、右侧平面分组、默认 900×620，四页已做原生切换与内容读回，隐私页滚动到底部且保存按钮可见。证据：[语言资源](native-settings.png)、[快捷键](native-settings-shortcuts.png)、[隐私页底部](native-settings-privacy.png)、[学习片段](native-settings-records.png)。最小尺寸、完整键盘／VoiceOver及语言包安装交互未验收。按双端计划，设置页将不再把 Apple 语言资源安装作为学习功能前置；现有入口保留为历史实现。

包内 helper 报告中文→英语、英语→中文均为 `supported`，未 `installed`。`scripts/validate-translation.py` 以退出码 2 返回 `blocked_missing_system_resources`，未运行质量评分、未下载系统资源。`supported` 不等于已安装，也不表示质量测试失败。该路径已随 Apple Translation 退出正式链路，仅作历史证据。

风险集 32 条、每方向 100 条保留集已在看后端输出前冻结，哈希为：

`ccaaf86909dd30980202bf4e3abfd6f36b6b9834c049d7d46913ebec23cffdac`

材料见[translation-holdout.json](../../validation/translation-holdout.json)。尚未打包 CC-CEDICT、Tatoeba、small100 或 tokenizer；词／表达包、容错白名单与 ≥95% 可用率均未通过。用户语义确认、真实学习记录和正式性能仍是独立门槛。

## 后续门槛（按双端计划重排）

1. G0：完成 Mac small100 门槛；用户提供 Windows 11 x64 环境后建立 Gogaku 自己的 Windows libime／C ABI 构建和小鹤烟测。
2. G1：建立共同事件轨迹向量，逐模块迁移共享 C++ 核心，Mac Swift 改薄调用；调和每页候选数差异（计划 5 个 vs 当前实现 9 个）。
3. G2：Mac 复验 IMK 路径；Windows 实现 TSF 闭环；分别跑真实宿主矩阵。
4. G3／G4：模型与词／表达包通过后接学习辅助与真实记录，完成双端安装恢复与最终验收。

原 A 普通输入完整安全矩阵、B 双向资源、C 学习交互、D 真实记录、E 完整矩阵与用户语义确认尚未同时通过；双端首阶段各门槛均未通过。
