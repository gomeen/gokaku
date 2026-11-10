# 原生工程实施验收记录

## 0.1.3 b110 stable 定版发布（2026-11-10，未运行 host）

- **已发布**：Release 440156339，tag `v0.1.3`（提交 9d12dea），[发布记录](release-b110.json)。Mac pkg SHA-256 `74112c15…dc3bd9b`，Windows Setup `23cdbf6b…e4069edbf`；公开清单签名用随包公钥验证通过。仍用 dev 签名密钥，ad-hoc，无公证／Authenticode。
- **已通过**：fast 7/7、release 14/14（十万序列 ASan／UBSan 8 片并行约 11 分钟，release 档总计约 18 分钟）。
- **未运行 host（用户决定直接发布）**：真实宿主矩阵、逐键性能、Orca Shift、浸泡均未在本构建跑完。b109 上的尝试暴露并修复两处探针缺陷（浏览器目标字段按元素 id 聚焦；跳过的宿主未关闭而占住前台），之后仍有 Chrome 测完留在前台、Safari 切不到前台的问题，未解决。host 的性能项与面板状态需要 `build.py --validation` 验收构建，与对外正式包不是同一二进制，此缺口待处理。GUI 短档在 b109 上用辅助功能树核对过七页×浅深（无截图），b110 未复核。
- **发现的规格漂移**：设置窗口最小宽 1000（皮肤页定稿），product.md 原写 900×620／760×520，已改。

## Orca 终端候选窗钉顶部：组合中索引 0 回退与临时锚点（2026-11-10，dev b105 真机部分验证）

用户报告：Orca 终端新开 tab 在顶部输入 `pi`，pi 打开后输入框在底部，候选窗却在顶部；Shift＋Enter 换行后第一组词位置也错，第二组正常；另有首次输入偶发在左上角。

- **诊断（b104 验收构建，`GogakuInput.diag` 同时用多种索引读矩形）**：首键前按文档绝对位置读到 pi 启动前 shell 行的陈旧矩形 (359, 1318)（屏幕顶部），组合内索引 0 为 (326, 145)（底部输入行）。组合期间索引 ≥1（组合内相对位置、末尾、绝对位置）全为零，只有索引 0 有效；复查全读零，面板冻结在陈旧 pre-read，瞬移过滤器从未运行。无组合时索引 0 在相邻字符格间循环，不可用。与 IMKTextInput 契约一致（索引相对 inline session）；2026-11-02 撤销的组合起点回退传的是 `markedRange.location`（绝对位置），与索引 0 不同。
- **修复**：`Host.m` 组合中按插入点读不到有效矩形时回退索引 0；首键 pre-read 与 `AnchorFallback` 结果标为临时锚点，`AnchorPlausibility.classify(previousProvisional:)` 让组合内首个有效读数直接取代。插入点矩形有效的宿主不额外读索引 0。HostTests／AnchorPlausibilityTests／AnchorFallbackTests 32 项通过，核心 ctest 10/10。
- **真机（b105 验收构建，Orca 1.4.255）**：用户目测通过。日志 28 次组合均只用一个锚点，陈旧 pre-read（含顶部 shell 行与 (0, 1410) 左上角）都在首次绘制前被取代；191 次过滤判定全为采纳。**未测**：Orca 聊天框、Chrome 网页输入框（曾因组合起点回退钉左上角）、企业微信、备忘录；两次 pre-read 与组合内读数相差两行（34pt）的情况未确认哪行正确。

## 企业微信兼容：候选窗无锚点回退与 Shift 释放沿兑底（2026-11-09，dev b101 已发布）

用户报告：企业微信里打一段话，前几个词有候选窗，后面没有，但空格上屏中文一直正常；Shift 切换也无提示。中文上屏正常说明组合／提交链路健康，问题锁定显示层：①候选窗锚点获取失败——词首 pre-read 是全组合唯一锚点机会，该类宿主对插入点的矩形查询随段落增长／中文提交后返回无效值且组合中不恢复（同 Orca 零矩形行为），一次失败即整词隐藏（round-build6「缺可信定位就隐藏」裁决的边缘后果）；②Shift 单击链断裂——企业微信投递按下沿但释放沿无产出，旧兑底「全程无 flagsChanged 才代发」守卫被按下沿事件满足，兑底与事件通路一起静默。用户裁决：普通模式必须始终有候选窗，进行兼容。

- **无锚点回退（`GogakuKit.AnchorFallback` 纯函数＋单测）**：词首 pre-read 无效时依次回退同字段上一组合锚点（`carriedAnchorRect`，连续输入偏差最小）＞鼠标位置光标矩形（与切换提示同语义）；全部不可得维持隐藏。字段证据丢失（`hidePanelKeepComposition`，新增 `hiddenByFieldLoss` 标记）期间不回退——旧锚点可能属于别的输入框；复查恢复字段一致即清除标记。组合中读到真实矩形后由既有位置复查＋瞬移过滤器纠正。换字段／失焦／配置复位时清 `carriedAnchorRect`。覆写 round-build6 的「隐藏保留组合」裁决范围：仅对「字段证据在但矩形不可得」的宿主生效，Orca（词首可读到锚点）行为不变。
- **Shift 释放沿兑底重写（`ShiftTapPoller`）**：物理单击先按同一规格立案，是否代发改在 200ms 确认期按「释放沿证据」（`noteReleaseHandled`，仅释放沿形态 flagsChanged 算）判定：证据在按下后出现＝事件通路已负责，取消；缺失＝释放沿被吞／以杂修饰形态判死，代发。正常宿主与 Orca 双投递的释放沿证据恒在，不双发；代发后 `shiftTracker.expirePress()` 失效残留按下沿，防迟到释放沿二次触发。`ShiftClickTracker.press` 增加超 600ms 残留按下沿自愈（按下沿缺释放沿宿主原先会卡死单击注册）。
- **验证边界**：`AnchorFallback` 纯函数 7/7 断言通过（fast 档 AnchorFallbackTests 套件实跑通过）；fast 7/7 全绿（核心 ctest 10/10、Swift Release 221 项），报告绑定双端包哈希（b102：`report-fast-20261109-120932.json`；b101：`report-fast-20261109-111202.json`，环境阻塞已解除：Xcode 在位经 DEVELOPER_DIR 选用、libime 锁由 prepare-dependencies.py 重建）。**企业微信真机验收未执行**（需用户空闲时段：真实段落输入候选窗持续可见、Shift 提示回归、Orca/Bob/记事本回归不回退）。
- **企业微信真机验收（2026-11-09 傍晚，诊断构建实测通过）**：装诊断版后用户在企业微信真实打字（更新→上去），`/tmp/gogaku-diag.log` 实测：①企业微信组合期间所有矩形查询返回零（比 Orca 更极端，全程 `refresh rect={{0,0}}`）；②但每个词首的 pre-read 均返回正确光标矩形且随打字右移（436→470→531→…→692）；③ b102 每词建立锚点并渲染弹框，用户确认两组词弹框均出现；④ `hidden=false` 全程无字段校验失败。**遗留待确认**：Shift 单击提示尚未在真机复测。诊断工具（`GogakuInput.diag` 写 `/tmp/gogaku-diag.log`，仅 GOGAKU_VALIDATION 生效）保留为宿主排障工具——系统统一日志会脱敏 NSLog 内容（`log show` 无 `--private`，动态内容全渲染为 `<private>`），文件直写是唯一可靠的诊断通道。
- **菜单重名真根因（b102 真机后半夜发现，双存储＋LS 污染三叠加）**：①macOS 26 输入法菜单有**两套存储**——旧版 `AppleEnabledInputSources`（重登后由系统重写，第三方条目已迁移）＋现代 `com.apple.inputsources` → `AppleEnabledThirdPartyInputSources`；dev 通道卸载只清了旧版，现代存储残留 dev 幽灵条目→菜单渲染多一条「Gogaku」（已手工清除）。② LS 数据库累积 **223 条死注册**：`/private/tmp/gogaku-fakehome*`（b87 验证夹具）、约 200 条 `validation.host` 探针（每轮 host 测试遗留）、dist／staging 路径——同名 bundle 多重注册导致菜单解析歧义（已全部 `lsregister -u` 清理，输入法仅剩 stable 安装位 1 条）。③会话级 TIS 克隆（当日反复注册累积）仅能靠注销重登清。产品整改待办：a) manage-install 卸载需同时清现代存储；b) manage-install 安装后需 `lsregister -u` staging 路径；c) verify.py host 探针结束后需注销探针 App 注册；d) 打包 Info.plist 补 `InputMethodConnectionName`（鼠须管有、Gogaku 无——imklaunchagent「unrecognized 'InputMethodConnectionName'」拒绝的对应声明，本轮以代码派生连接名绕过）。
- **b101 真机跟进缺陷（已随 b102 修复发布）****：本机装 b101 后 dev 输入源「看不到、选中即回弹」。逐层排查（TIS 启用／HIToolbox 偏好表／LS 注册均修过后仍回弹）后定位：IMKServer 连接名硬编码 `Gogaku_Connection`，双通道同名；stable 旧进程（前一晚起一直在跑）占名后，dev 端点注册被 imklaunchagent 拒绝（日志 `Refusing connection name for bundle: unrecognized 'InputMethodConnectionName' value`），dev 进程拉不起、选源回弹。历史 dev 可用仅因当时 stable 输入源未启用、无进程占名。修复：连接名按 bundle ID 派生（b102，Release 438733764 已发布）。本机 b102 验证：dev 选中后保持不回弹（两次核对），无拒绝日志；进程首次打字时懒拉起。发行记录：b101（`release-b101.json`，tag 曾因 main 未先推而误指旧提交，事后强移修正）、b102（`release-b102.json`，main 先推，tag 同点）。本机另修：HIToolbox 偏好表中 dev／stable 条目重装后不会自动恢复，已直接写入（register 只做 TIS 注册不启用）。
- **b102 真机后续：输入菜单入口问题的真根因（LS 数据库污染）**。b102 修复连接名后 dev 选源不再回弹，但用户仍看不到菜单入口。逐层排查发现：① 第三方输入法的菜单列表不读 `AppleEnabledInputSources`（补 dev 条目到该键只能让 stable 出现），菜单读 TIS 运行时启用列表；② TIS 启用列表中 dev.Hans 挂在死注册上——LS 数据库被 b87 时代验证夹具残留污染：`/private/tmp/gogaku-fakehome{,2-7}/Library/Input Methods/Gogaku Dev.app` 共 7 个死路径注册，外加 dist／staging 注册，导致同名 bundle 的解析歧义。清理：`lsregister -u` 逐个注销 9 个死／多余注册（保留两个安装位）→ 重新 TISEnable → 菜单出现「Gogaku Dev」（AppleScript 读 UI 实证）。③ 会话内同时产生大量重复「Gogaku」菜单项（当日反复注册的 TIS 会话残留），注销重登即清；正式入口完整性以登录会话重建后的菜单为准。**产品整改待办**：验证探针的 fakehome 安装结束后必须 `lsregister -u` 清理，避免污染用户真实 LS 数据库（本轮未改探针代码，只清理了本机）。
- **b101 双端包已发布 dev 通道**（Draft→published，Release 438705074，tag `v0.1.1-dev.2-b101-dev`；公开清单签名用随包公钥远端验证通过，[发布记录](release-b101.json)）；b102 同链路已发布（[发布记录](release-b102.json)）。前一轮环境阻塞记录保留在 `report-fast-20261109-105354.json`。

## Windows 挂起 Shift 补发与宿主受限项（2026-11-08，dev b99）

[修复说明与复现源码](dev-b99-fix/README.md)、[机器汇总](dev-b99-fix.json)。默认英文应用（code.exe 等）的恢复 Shift 点击若落在会话可用前会被静默丢失；b99 挂起该点击并在下一次按键 600ms 内补发，失焦清除。Chrome 切框、密码 `nihc `、记事本「你好」三轮无回归验证通过（模块身份 b99，PE 1794128481）。

VS Code／Electron 类宿主矩阵记为受限项：激活后立即输入按预期以临时英文直通，恢复 Shift 点击可整对落在 TIP 激活完成前（TSF 固有窗口，输入法收不到即无法补发）；GetForeground 轮询不可作就绪探针；3 秒稳定等待后按键进入窗口但编辑器缓冲为空（首启 UI 抢占焦点，夹具目标状态问题）。Windows Terminal 未安装（wt.exe 不存在）。此两项未通过，需专用 VS Code 诊断另立轮次；b98 及之前的矩阵结论不受影响。

- **Mac 通道后续**：b100 发布后本机 Mac 更新至 b100（进程重启后冒烟 14/14），随后按用户要求**卸载 dev 通道**——移除 Gogaku Dev／设置应用与全部 dev 备份（285MB），保留 stable 构建 86、共用用户数据与签名密钥；重装方式见 README。
- **正式安装与本机更新**：b99 默认升级返回 0，71 个文件与双架构 COM 匹配，上一根指向 b98；用户授权下 `manage-install.py --channel dev install` 更新本 Mac，重装后按文档 `register` 刷新输入源注册，[14 项 IMK 冒烟](imk-host-smoke-dev.json)全部通过。
- **检查与清理**：[fast 7/7](verify/report-fast-dev-b99.json)；[ASan／UBSan quick](verify/report-asan-ubsan-quick-dev-b99.json) 2,000 序列通过，整体 release gate 未过。发布门禁在「随包更新源未配置」处按设计拒绝（收据／许可／报告校验已过），真实 Draft 待仓库决策与 Token／私钥。本地测试目录 `local/` 已按用户要求移除，源码／测试指纹不变，档案证据均在 docs/validation。

**仍未完成**：完整 Windows Terminal（未安装）／VS Code／Electron／真实 32 位应用矩阵、性能／稳定性、真实翻译／在线更新、安装故障恢复／卸载。完整双端验收仍未通过。以下历史章节保留当时失败与边界。

## Windows 三个输入缺陷修复与限定矩阵（2026-11-08，dev b98）

[修复说明与复现源码](dev-b98-fix/README.md)、[机器汇总](dev-b98-fix.json)。依次修复并复测：

1. **跨字段旧提交资格**（b95）：`OnCompositionTerminated` 撤销代理旧组合、刷新字段身份；临时文本存储仅在候选窗显示编码。修前合成负例失败，修后双架构通过；b95-b98 各轮矩阵持续通过。
2. **InputScope 滞后吞首键**（b97 修复）：宿主复用上下文切换字段后新 scope 延迟生效，首次读取若为「允许」时 40ms 复核，不一致则本键放行；读取瞬时失败沿用上一键结论。b96 密码轮 `ihc ` 失败证据保留，b98 密码 3/3 通过 `nihc `。
3. **调频落盘阻塞请求**（b98 修复）：代理曾持全局锁逐 30 秒做模型序列化＋写盘，打字中请求响应超过 TSF 截止，已处理按键被放行宿主重复出字。改为管道空闲 3 秒才落盘，单键截止 200→400ms。b97 `hc你好` 失败证据保留，b98 basic 4/4 通过。

- **正式安装与身份**：b98 默认升级返回 0，71 个文件与双架构 COM 匹配，上一根指向 b97。打字前设置与数据哈希未变；最终正式 b98 代理运行，临时任务已清理，安全防护保持开启。
- **限定矩阵 13/13**：正式 b98 DLL／代理，两次 Chrome 切框、四次新宿主首组、三次密码采样、记事本两暖／两冷全部通过；逐轮模块身份为 b98（内存 PE timestamp 1794123559）。冷启动第 2 轮复活代理已独立核验哈希；第 1 轮路径由夹具记录。
- **环境新发现**：旧 DLL 宿主会按自身模块路径复活旧代理（explorer 持 b91 时代诊断副本、msedge 持 b97）；混合版本态由此持续存在。新代理持互斥量期间僵尸秒退，冷启动停止窗口存在竞态；夹具已放宽为停止全部 GogakuDev 自有代理并复查复活，文档同步记录。
- **检查与清理**：[fast 7/7](verify/report-fast-dev-b98.json)；[ASan／UBSan quick](verify/report-asan-ubsan-quick-dev-b98.json) 2,000 序列通过，整体 release gate 未过。b95/b96/b97 失败证据全部保留，未宣称覆盖全部历史间歇个案。

**仍未完成**：完整 Windows Terminal（未安装）／VS Code／Electron／真实 32 位应用矩阵、性能／稳定性、真实翻译／在线更新、安装故障恢复／卸载。完整双端验收仍未通过。以下历史章节保留当时失败与边界。

## Windows 组合终止修复与限定回归（2026-11-08，dev b95）

[修复说明与复现源码](dev-b95-fix/README.md)、[机器汇总](dev-b95-fix.json)。`OnCompositionTerminated` 原先未通知代理撤销旧组合，新回调使用旧范围与 cookie 清理、失焦并刷新字段身份。Chromium 临时文本存储会先确认 DOM 预编辑，再交付终止通知，因此这类存储仅在浮动候选窗显示编码，明确选词才写正文；原生持久存储仍遵循字母设置。上下文无法确认原字段时，不向新字段暴露旧草稿恢复。

- **修前／修后回归**：同一生产回调的合成 COM 夹具，用旧回调时失败，修后 Windows x64／x86 各两条路径通过；覆盖清理成功／拒绝、代理资格撤销、身份更新、重复／无关／自身通知与引用释放。它不等于真实宿主矩阵，也未加入 fast 自动项。
- **正式安装与版本身份**：双端 b95 包重建，Windows 默认升级返回 0，71 个文件、双架构注册及当前／上一根一致。打字前用户文件哈希均未变。Mac b95 未安装，仍保留 b93 的历史实装结论。
- **同版本正式安装件限定回归 11 次通过**：Chrome 两次切字段（原框空、新框仅一个空格，无候选／旧草稿）、四个新宿主首组“你好”、一次合成密码原样 `nihc ` 且无候选；记事本两次暖启动、两次确认代理进程缺席后的新进程首组均提交“你好”。逐轮记录正式 b95 DLL 路径及内存 PE timestamp `1794117231`。
- **失败仍保留**：首轮 b95 DLL＋长期运行的 b94 代理在原框留下 `i`、新框只有空格，已停测并记录。随后正式 b95 代理复测和新启动 b94 代理的诊断对照通过，不能证明失败由混合版本导致，也不能宣称首组间歇异常已修。记事本旧进程仍加载 b94 时，驱动在发送按键前拒绝；备份会话并正常关闭后才重新测。冷启动夹具曾将已终止但仍在快照中的进程误判为异常，未发送输入，修正存活检查后重测；不把工具阻塞当产品通过。
- **检查与清理**：[fast 7/7](verify/report-fast-dev-b95.json)，核心 CTest 与 Swift Release 217 项通过；[ASan／UBSan quick](verify/report-asan-ubsan-quick-dev-b95.json) 2,000 序列通过，整体 release gate 未过。首次旧目录 CMake 缓存失败保留。最终正式 b95 代理运行、双架构注册恢复、临时安装与已识别探针任务清理；设置和自启值未变，全部用户文件保留，中文调频随合成提交变化。Windows 安全保持开启。

**仍未完成**：间歇首组异常根因、完整 Windows Terminal／Electron／真实 32 位应用矩阵、性能／稳定性、真实翻译／在线更新和安装故障恢复／卸载。完整双端验收仍未通过。以下历史章节保留当时失败与边界。

## Windows 扩大宿主验收不通过（2026-11-08，dev b94）

[本轮说明与复现](dev-b94-acceptance/README.md)、[身份与机器汇总](dev-b94-acceptance.json)。Chrome 连续两次在第一个字段输入 `ni`、切到第二个字段后按空格，实际第一个字段留下 `ni`、第二个字段收到 `你`，构成跨字段提交阻塞项。已按产品要求停止后续输入兼容性测试；隐藏候选窗不能替代取消旧提交资格。Chrome 首组输入还曾出现 `nih次`，新开浏览器复测为“你好”；记事本首轮 `ni好` 的驱动含 mode 尾空格，不能算代理冷启动测试通过，修正后四次限定复测为“你好”。原因尚未确定。

Chrome 合成密码字段保留原样 `nihc ` 且没有候选，仅该项通过。Windows Terminal、Electron、真实 32 位应用及其余输入矩阵未完成。隔离安装回滚夹具在读取 A.exe 哈希时被 Defender 隔离，`mutationStarted=false`、`runtimeExecuted=false`；未运行安装／回滚／卸载，不据此标通过。临时安装任务已清理，夹具未安装，防护保持开启，用户设置哈希未变，b94 代理运行。先前默认升级和受控 Edit 证据仍只适用于原场景。

## Windows 冷启动与默认升级修复（2026-11-08，dev b94）

当前 `0.1.1-dev.2 / b94 / dev` 双端安装包已重建，[汇总与身份](dev-b94.json)和 [fast 7/7](verify/report-fast-dev-b94.json)绑定同一源码／测试指纹及安装包哈希；核心 CTest 10/10、Swift Release 217/217。工作区为 dirty 开发状态，未公开发布。Mac b94 本轮只构包，未安装，不继承以下 b93 IMK 结果。

- **修前复现**：[b93 新建 x64 Edit](dev-b94/windows-b93-cold-baseline.json)在移除自有代理后首组输入留下 `nihc`，候选不可见，且实际加载 b93 TSF。不是根据旧报告推断失败。
- **冷启动修复**：`TSF Activate` 提前启动代理，最多等待 5 秒建立管道和 `hello`；不在预热阶段调用字段／焦点／组合操作。逐键连接不新增启动等待，不缓存或重放按键，超时正常返回并保留后续重试。独立假代理回归的 [x64](dev-b94/windows-rpc-x64.json)／[x86](dev-b94/windows-rpc-x86.json)检查启动等待、默认连接立即返回、120ms 截止和后续重连。
- **新安装件真实冷启动**：专属原生 Edit 的 [x64 第一次](dev-b94/windows-cold-x64-1.json)／[第二次](dev-b94/windows-cold-x64-2.json)、[x86 第一次](dev-b94/windows-cold-x86-1.json)／[第二次](dev-b94/windows-cold-x86-2.json)均先确认代理不存在，再激活并立即输入 `nihc`＋空格；全部候选可见、正文为“你好”，每步按键未泄入正文，150ms 后正文不变。激活分别耗时 656、734、703、750ms；记录了实际 b94 DLL、代理路径和 PID。[双架构暖启动](dev-b94/windows-warm-x64.json)／[x86](dev-b94/windows-warm-x86.json)也通过，激活耗时 15／0ms。这是受控真实文本宿主证据；当前未复验记事本、Chrome、Windows Terminal 或 Electron，激活耗时也不等于逐键 p95 达标。
- **默认升级通过**：[安装日志](dev-b94/windows-default-upgrade.log)返回 0；未传 `/DIR`，未迁走占用文件，未关闭用户宿主。测试进程确实加载 b93 DLL，写入探针确认文件被占用，安装完成后该进程仍存活。[71 个文件与注册检查](dev-b94/windows-installation.json)全部匹配，双架构 COM、`ActiveRoot` 指向 b94，`PreviousRoot` 指向 b93。b93 曾以诊断目录 `C:\Program Files\GogakuDev\versions\b93` 安装，b94 保留这个既有安装根并自动创建其 `versions\0.1.1-dev.2-b94-dev` 子目录；这次没有再手动旁置。后续升级继续使用固定安装根。
- **保留与回归**：升级后、打字前，原有用户文件哈希全部未变；用临时的“原已启用”Run 值验证自启动路径迁移成功，再恢复用户原先关闭状态。输入测试后，[最终检查](dev-b94/windows-final-state.json)确认设置哈希未变、全部数据文件保留、代理运行自 b94；中文调频模型因合成提交发生预期变化。[同一构建重装](dev-b94/windows-same-build-blocked.json)在 b94 文件仍被占用时返回 7，活动根指针不变。[七页设置与大小图标](dev-b94/windows-settings.json)通过，200% 下[最小皮肤预览](dev-b94/windows-settings-skin-minimum.png)九条可见；[翻译页截图](dev-b94/windows-settings-translation.png)归档。

**边界**：注册失败恢复旧双架构注册／路径指针、健康上一代理兼容均已实现，但完整故障恢复与代理生命周期交接未在本轮逐项运行；卸载、旧版本自动清理、慢机超过 5 秒的首键、完整宿主／性能／稳定性、真实翻译与在线更新仍未验收。已打开应用可能继续持有旧 DLL，需要时由用户保存并重新打开。没有强杀用户宿主、自动注销或重启。以下保留历史发生时的结论。

## 双端开发安装包重建与限定宿主复验（2026-11-08，dev b93）

本轮在目录重组、旧选型清理和验证门禁修补后重建 `0.1.1-dev.2 / b93 / dev` 双端安装包，并实际安装。工作区仍为 dirty 开发状态，未上传 GitHub 或公开发布。[汇总与身份](dev-b93.json)、[最终 fast](verify/report-fast-dev-b93.json)绑定同一源码／测试指纹和双端安装包哈希。

- **构包与关键回归**：Mac Release 双 App／PKG、MinGW x64／x86 编译与 Windows Inno Setup 成功；fast 7/7、共享核心 CTest 10/10、Swift Release 217/217。包内依赖与资源检查通过。未执行完整 release／十万序列。
- **Mac 实际安装**：通过用户级 `installer -pkg` 安装 b93；输入法与设置 App 的签名、依赖闭包、构建身份和输入程序哈希通过[安装后检查](dev-b93/mac-installed-bundle-check.json)。实际运行路径为用户 `Library/Input Methods/Gogaku Dev.app`，加载随包核心。IMK 冒烟入口新增 `--channel dev`，在专属 AppKit 窗口完成 [14 项检查](dev-b93/mac-imk-smoke.json)，覆盖切源、普通输入、原文上屏、选区替换、字段切换、数字选词与翻页；结束后恢复 stable 输入源。这里只是限定冒烟；完整 host 档仍拒绝 dev，未执行完整矩阵、Orca 或性能／稳定性验收。
- **Windows 默认目录升级受阻**：旧代理及已打开宿主持有 b91 TSF，[正常安装返回 7](dev-b93/windows-default-upgrade-blocked.log)，拒绝覆盖占用文件。旧 b91 代理没有可用托盘窗口，曾仅停止自有代理；它随后被既有宿主重新拉起，因此该动作没有解决覆盖障碍。未关闭用户的记事本／Explorer／浏览器，也未人工迁走 Program Files 文件。
- **Windows 独立目录安装**：使用安装器已有 `/DIR` 参数安装到 `C:\Program Files\GogakuDev\versions\b93`，[返回 0](dev-b93/windows-versioned-install.log)。71 个清单文件的大小／SHA-256 全部匹配；双架构 COM 注册和实际代理路径均指向 b93。设置文件哈希未变，现有数据文件保留；中文调频模型因合成上屏测试发生预期变化。这是旁置目录安装成功，**不是默认目录升级／失败恢复通过**，版本化升级管理尚未实现。
- **Windows 新宿主暖启动**：[x64](dev-b93/windows-warm-x64.json)与 [x86](dev-b93/windows-warm-x86.json)专属原生 Edit 均明确加载 b93 安装目录 DLL，显示候选并将 `nihc`＋空格提交为“你好”。[七页设置与大小图标](dev-b93/windows-settings.json)通过，200% DPI 最小皮肤预览九条可见；[翻译页](dev-b93/windows-settings-translation.png)与[皮肤页](dev-b93/windows-settings-skin-minimum.png)截图归档。该结果不继承 b91 记事本证据，也不代表完整 Windows 宿主／GUI 矩阵。
- **Windows 冷启动仍失败**：[移除自有代理后第一次输入](dev-b93/windows-cold-first.json)，新 x64 宿主确实加载 b93 TSF，却没有候选，正文为 `nihc `，见[截图](dev-b93/windows-cold-first.png)。随后暖启动成功不能抵消该失败。冷启动第一组输入尚未修复，不能标为稳定版。

**后续阻塞**：Windows 冷启动输入、无干预默认目录升级／恢复／卸载、真实云翻译与 GitHub 更新、完整双端宿主／性能／稳定性矩阵。当前只完成构包、实际安装与限定测试取证，产品验收未闭环。以下历史章节保留各自发生时的状态。

## 旧选型清理与验证门禁修补（2026-11-08，工作区，未交付新包）

旧引擎／本地模型选型工具、研究、排名和结果已退役，保留简短采用理由、固定 libime 构建消费者、通用翻译考题及现役产品测试。数据检查和门禁负例进入 fast；发布报告按当前策略与源码／测试指纹核对，拒绝缺项、跳过、旧策略、运行中身份改变；缺 GUI 明确 blocked，host 目前仅支持 stable，dev 不复用 stable 验收。

本轮 [fast 七项通过](verify/report-fast-20261108-095255.json)，共享核心 CTest 10/10、Swift Release 217/217；验证与交付门禁单测合计 32 项通过，生产火山客户端的双向成功、HTTP／网络异常、凭据热读、空结果和重定向拒绝均有离线回归。迁移后的离屏渲染单项 53 项通过，完整 release gate 因其它项跳过仍为 false。工具修改与证据见[清理与测试审查](testing-cleanup-audit.md)。

未跑完整 release／十万序列、真实 host、Windows CI／VM、真实在线翻译或安装升级；未重新构包或发布，旧安装包不再绑定当前源码。Windows 冷启动失败、双端完整宿主、正式性能、升级恢复及在线更新等既有未验收项继续保留。

## 构包与更新审查整改（2026-11-06，当前工作区，未交付新包）

审查记录见 [构包与更新审查报告](../../.build/reviews/delivery-pipeline-review.md)。本轮让 Windows x86／x64 编译写出源码／版本／通道和产物哈希收据；Win Setup 与 Mac pkg 在打包前核对当前源码及 App／DLL 来源并写安装包收据；发布入口要求两个安装包收据与 fast 验证报告哈希一致，rc／定版还需 release 报告。Draft 创建和发布分两段：`release-state.json` 绑定 Release ID，续发时核对远端四份资产，只 PATCH 原 ID。安装包收据不替代代码签名或真实安装验收。

Mac 更新引擎改为仅缓存验签通过的逐页清单，304 根据当前构建号重新判断，列表分页不因首个通道不符就停止；小资产 GET 走允许主机白名单。Windows 自动发现新版只在设置窗口显示提示，不激活输入焦点。离线证据：Swift `UpdateTests` 25/25、Windows 打包 self-test、更新清单 self-test、`scripts.test_delivery_pipeline` 七项通过；重定向测试改测同一白名单判定函数（直接传未启动的 URLSessionTask 在本机测试进程 SIGSEGV）。

**实际双端重建（dev b92，当前未提交工作区）**：本机固定 Windows 源码／MSYS2 输入经摘要校验，静态 libime 编译通过（未在全新机器复验下载）；setup 准备时发现并修正 KenLM 许可路径；x64/x86 MinGW 编译、Windows `--check` 与 Inno 6.7.4 编译通过。Mac Release 双 App、核心 ctest 8/8 与用户级 pkg 构建通过；重复构包时清除了暂存出厂数据继承的 `uchg` 问题。中间 b91 仅用于内部构包验证，最终交付候选递增为 b92。[最终 fast 报告](verify/report-fast-20261106-210721.json) 7/7，Swift Release 201 项通过，报告与双端收据的源码、版本、通道和安装包哈希一致。Mac pkg `17f35a9de9675b6d41c64ef4be96dee063c0ad5ea30f5f0d3dfc58aeea8e2e8e`；Windows Setup `8537b80c2087a44e8f6aa91b6c7f147dc5fb96bb5fb1889f646dd08b00b01665`。两包在 `dist/`，非正式签名版；Windows 编译器显示 `Non-commercial use only`，商业分发前须另核授权。

**仍未验收**：本轮 b92 包未在 Mac/Windows 真机安装升级、未在 Windows VM 点过更新提示；更新源 owner/repo 为空，`publish-release.py --dry-run` 在配置门槛处按预期拒绝；无真实 GitHub Draft／发布／下载闭环。构建 91 的早期 VM 记录不能继承到 b92 源码指纹。

## Windows 记事本、设置与图标复验（2026-11-06，工作区，构建 91 dev）

用户在构建 88 安装后授权连接其 Windows 11 x64 VM 排查。本节是后续新增的限定运行证据，不继承早期前端的通过结论；[机器记录与截图](windows-desktop-b91.json)、[本轮构包报告](windows-setup-build.json)绑定构建 91 和安装 EXE 哈希。

- **记事本兼容**：实测 `Microsoft.WindowsNotepad_11.2607.14.0_x64` 的 `RichEditD2DPT` 不提供可用 InputScope，旧兜底只允许 `Edit` 因而拒绝。新增受限 RichEdit 兜底：当前线程／进程、焦点属于该 TSF 文档、已知原生控件、非密码／只读／禁用；显式 private／password scope 仍拒绝。读取进程内 PE 时间戳确认加载正式安装目录的本轮 DLL。五次后续新建测试标签页均显示候选，`nihc`＋空格保存为“你好”；已有文档不覆盖。实际[候选窗截图](windows-desktop-b91/notepad-candidate.png)保留。
- **焦点与设置时序**：构建 90 修复非激活连接迟到失焦清空当前组合，`probes/windows-session-focus.cpp` 双连接反例修前失败、修后保留 `nihc`；构建 91 保留修复。设置／词表监控以启动时文件状态为基线，避免第一次定时扫描把初始词表当作热更新而重置组合；不把暖启动成功推断为冷启动可靠。
- **原生控件**：安装目录的 x64／x86 TSF 分别在合成 Edit 中显示候选并提交“你好”。`probes/windows-field-safety.cpp` 两架构各 13 项通过，含普通／RichEdit、文档子控件、兄弟控件拒绝、未知类、密码、运行时密码、只读及禁用；这是生产兜底函数的回归，不替代完整 TSF 密码宿主矩阵。
- **设置与图标**：200% DPI 下七页切换、窗口大小图标、最小皮肤预览九条完整可见；安装目录的设置／代理／双位数 TSF 大小图标资源可提取，开始菜单设置链接指向随包 EXE。仅覆盖该 DPI／尺寸，不是所有主题字体矩阵。
- **安装与身份**：安装器返回 0，63 个 payload 文件与身份清单哈希一致，双架构 COM 路径正确，Windows 桌面 EXE 与 Mac 产物 SHA-256 一致。为保留已打开宿主，本次安装前人工把占用的旧产品文件迁至临时备份，因此不是普通升级／恢复的通过证据。无 Authenticode 签名。
- **关键回归**：[构建 91 fast 7/7](verify/report-fast-20261106-192914.json)，Swift Release 193 项及交付合同通过；共享核心未在本轮修改，沿用先前 ASan／UBSan quick 2,000 序列冒烟。未执行完整 release gate。

**已知未解决：冷启动第一组输入。** 代理完全退出后，正式安装版记事本第一次输入没有候选、保存为 `nihc `；合成 Edit 也有同类失败。代理就绪后的重复成功不抵消该失败；把启动调用提前到激活阶段的诊断尝试也未通过，未纳入本包。使用时可先启动代理、稍候并在空白文档确认候选，但不能称为稳定版。构建 89／90 出现过错误词或空提交，也不能只据后续成功回写为全部通过。

真实火山／GitHub 更新、完整宿主、性能、长时稳定性、无干预升级／恢复／卸载、双端完整功能仍未验收，见[功能对照](../feature-parity.md)。

## Windows 最终 EXE 构建（2026-11-06，工作区，构建 88 dev）

本轮按用户确认只构建安装 EXE，不执行 Windows 产品程序，不进行 VM／真机验证；安装与运行验证交用户。当前 Windows 前端重写不继承历史 VM 证据。

- **真实编译**：Mac 上 MinGW-w64 GCC 16.2；x64 核心 DLL、用户代理 EXE、七页设置 EXE、TSF DLL，以及 x86 TSF DLL 均已编译／链接。两位数 TSF 都经同用户／会话／通道私有管道连接 x64 代理；最终 PE 只依赖 Windows 系统库。
- **集成**：普通输入配置、自定义词、Windows 原子持久化、提交确认、焦点／字段校验、非激活候选窗、Direct2D／DirectWrite 主题、异步火山签名请求、后台系统拼写、全局模式／方向、托盘与更新窗口已接通。它们只有编译与静态检查证据，未在 Windows 运行。
- **实际构包**：Wine 仅运行官方 Inno Setup 6.7.4 编译器；双位数 TSF、x64 代理／设置／核心、约 46 MB 普通输入数据、更新配置、第三方许可与逐文件构建身份进入 Setup.exe。产物、SHA-256、组件哈希与检查结果见 [windows-setup-build.json](windows-setup-build.json)。不运行生成的安装器。
- **关键回归**：[fast 7/7](verify/report-fast-20261106-151839.json)，核心 ctest、Swift Release 193 项、评测与 worker 协议 26 项断言和交付合同通过。[ASan／UBSan quick](verify/report-release-20261106-151933.json) 2,000 随机序列无错误；该报告按 `--only` 跳过其它项目，整体 release gate 为未通过，不能改写为全量发布通过。
- **未完成／未测**：多候选预译、共享学习等待／缓冲协调、随包 WebP codec、旧 `settings.txt` 迁移、SQLite 历史片段管理、跨通道调频和版本化升级恢复仍是实现缺口；Windows 安装／启用／宿主／UI／翻译／升级卸载与真实 GitHub 更新均待用户验证，详见[功能对照](../feature-parity.md)与[使用说明](../windows-testing.md)。


## 学习英→中波浪线与中→英 Enter／⌘Enter（2026-11-06，工作区，构建 88 dev）

用户真机反馈（dev b87）：① 错误单词波浪线不显示；② Enter／空格上屏语义与预期不符，要求统一为 Enter 上屏译文、⌘Enter 原文上屏（两方向）。根因与修复：

- **波浪线**：拼写结果只写控制器本地 `displayed`，逐键 `publishLearning` 用会话视图覆盖（会话从未收到结果，`setIssues` 为死代码）；译文未就绪阶段 onResult 提前返回不渲染。修复：onResult 经引擎队列 `setIssues(issues, stamp:)` 写入共享会话后 `publishLearning`；核心 SET_ISSUES 按同修订 stamp 守卫（编辑使旧范围失效，规格原文）。拼写 helper 路径改用与翻译同一解析规则。
- **中→英**：Enter 原走普通核心 `.enter`（提交剩余原编码＝原样上屏拼音，违反规格表「选就绪目标」）→ 改为 `.space` 路由（译文就绪即上屏英文，未就绪先中文源文再异步换译）；⌘Enter 原交还宿主 → 改为 `.space` 且 `swapTranslation=false`（中文源文直接上屏，不换译）。英→中未改码（Enter 选就绪中文／⌘Enter 原文本已实现；用户观察到的「Enter 原样上屏」无对应代码路径，推断来自中→英路径或无候选态 ⌘Enter，待真机复验确认）。

**已验证（隔离／离屏）**：

- `python3 scripts/verify.py --profile fast`：7/7 通过；Swift Release 193 项含新增拼写范围合同用例（`setIssues` 入视图、编辑推进修订不清空、过期 stamp 拒绝、中→英方向守卫）；报告 `docs/validation/verify/report-fast-20261106-113359.json`。
- `--spell` helper 运行时实测（本机已装 stable b86 与 dev b87 两个 helper）：`helo metting ` 返回 location 0/length 4 与 location 11/length 7 两处 issue，JSON 协议 round-trip 正常。
- 构建 88 dev 本机安装（`manage-install.py install --channel dev`），哈希核对通过。

**未验证**：真实宿主按键路径（Enter／⌘Enter 上屏内容、波浪线实际显示、点击解释）——host 档需空闲时段执行；待下轮 `--profile host` 一并回归。

## 双端统一第一轮（2026-11-06，工作区，构建 87 dev）

按[双端功能统一、安装包与检查更新计划](../implementation-plan.md)推进 P0／P1／P4（Mac）／P5（Mac 客户端）。工作区同时含并行会话的 `version.json`（0.1.1-dev.2／构建 87）与 `probes/` 改动；本记录只覆盖本轮文件。**未做真实宿主、真实安装器、真实火山凭据或真实 GitHub 验收。**

- **翻译收敛**：移除 quickmt／small100／Python 后端、beam、模型准备与下载入口；新增 `macos/Sources/GogakuKit/Volcengine.swift`（V4 HMAC-SHA256 签名、URLSession、凭据热读、尾部孤立标点剥离、错误映射）与随包 `GogakuTranslator --volcengine`；设置「学习翻译」页改为启用开关（默认关）、凭据保存／移除、连接测试、状态与本机字符统计。设置 schema 升 2：旧本地模型配置迁移为关闭学习翻译，已启用火山配置保留启用、凭据与用量。
- **安装事务**：`package-macos-pkg.py` 在打包阶段把身份注入 staged App 并由内向外签名（Developer ID 或 ad-hoc），再打 zip；`macos/packaging/pkg-postinstall.sh` 解包→校验包内身份／构建号／签名→备份→替换→核对安装后身份／构建号；失败恢复两者；事务状态 `~/Library/Application Support/Gogaku/install/transaction.txt`；`manage-install.py` 改 staging＋备份＋失败恢复＋构建号校验。删除 DMG 打包脚本与产物。
- **检查更新**：`UpdateContract/UpdatePreferences/UpdateTransport/UpdateEngine/UpdateDownloader`＋设置更新窗口；Ed25519 清单验签、GitHub 分页／ETag／限流、通道／构建号／平台／架构／minOS、HTTPS 白名单、下载大小／SHA-256／原子缓存、取消与安装交接；自动检查默认关闭、24 小时节流、只在设置应用运行。发布脚本 `update-signing.swift`、`make-update-manifest.py`、`publish-release.py`；随包开发公钥。
- **Windows 脚手架**：`windows/packaging/gogaku.iss.in`＋`scripts/build-win-app.py`（产物检查、staging、身份哈希、iss 渲染、iscc 调用；缺产物明确失败）。未在 Windows 编译。

**已验证（隔离／离屏）**

- `python3 scripts/verify.py --profile fast`：7/7 通过（版本拒绝路径 7/7、资源哈希与依赖锁、核心 ctest 6/6、Swift Release 192 项、评测回归、参考 worker 协议、交付合同自测）；报告 `docs/validation/verify/report-fast-20261106-111047.json`。
- 核心 ctest 6/6（abi、normal、learning、quality、translate_safety、fuzz 2000 序列）；无共享核心 C++ 改动。
- `check-bundle.py` 对构建 87 dev 双 App 通过：签名与依赖闭包、包内引擎小鹤上屏、设置自动读音、拼写 helper、`update-config.json`（schema 1、1 个可信公钥、仓库未配置）、火山 helper 无凭据返回 `credentials_missing` 且未联网；报告 `docs/validation/bundle-smoke-dev.json`。
- 火山签名／请求体与 Python 参考 worker 固定向量逐字节一致（`VolcengineTests`）；错误码映射、凭据 0600 往返、非法 host 拒绝；缓存命中标记 `cached` 且不重复计入本月统计（`TranslationTests`）。
- 更新合同：有效／篡改／未知 keyId 签名、schema、版本、通道、构建号、架构／minOS、重复资产、分页、304 缓存、限流、500、下载大小／哈希与缓存复用（`UpdateTests`）。
- 发布与打包自测：`make-update-manifest.py --self-test`（生成、哈希、签名、篡改拒绝）、`build-win-app.py --self-test`（双位数目录、身份、iss 渲染、缺产物检测）、`bash -n macos/packaging/pkg-postinstall.sh`。
- **pkg 打包阶段签名**：staged 输入法含 `TISInputSourceID=org.gogaku.inputmethod.dev`，`codesign --verify --deep --strict` 通过；zip 内签名保留；postinstall 不再重签。ad-hoc 包 `pkgutil --check-signature` 仍为 no signature，`spctl` 拒绝（开发测试包预期）。Developer ID／公证未跑（无证书）。
- **真实安装复验**：`installer -pkg dist/Gogaku-0.1.1-dev.2-b87-dev.pkg -target CurrentUserHomeDirectory` 成功；双 App 构建 87、身份正确、`codesign --verify` 通过、`phase=success`；安装后 helper 与 update-config 正常。当前输入源为 stable，dev 进程仍运行旧内存，切源后加载新构建。
- **pkg postinstall 事务实测（假 HOME，不触碰真实用户与输入源）**：
  1. 成功：旧双 App（构建 1）→ 新构建 87；两 App 身份／构建号正确；旧包备份为 `input.disabled`／`settings.disabled`；状态 `phase=success`。重打包产物 `dist/Gogaku-0.1.1-dev.2-b87-dev.pkg`（SHA-256 `5f40a471700c4c8258283da543adfe1697e20233cc415023356212a69d88978a`）再次通过成功路径。
  2. 失败：zip 缺少设置应用 → 退出 1，旧双 App 恢复为构建 1，状态 `phase=failed`，不提示成功。
  3. 中断恢复：预置 `phase=installing`＋旧备份＋新目标（构建 99），再跑失败安装 → 先恢复旧构建 1，最终仍为构建 1，未留下半装状态。
- 设置应用从 dist 启动进程存活（约 2.6s 后手动结束）；**屏幕捕获不可用，未取得新页面截图**。

**未验证**

- 真实 `installer -pkg` 升级／恢复与真实用户输入源切换／新进程加载（单次真实安装已通过，未做双构建升级矩阵）。
- Developer ID Application／Installer 签名、Apple 公证、stapling 与 `spctl` 通过路径（无证书）。
- 真实火山凭据的连接测试、TLS、计量与双向译文；未配置凭据时不发送已有 helper 级证据。
- 真实 GitHub Releases 获取／下载／校验／安装；仅注入传输测试。
- Windows Setup 的 MSVC／iscc 编译、x86 组件、安装／卸载与真实按键。
- 新设置页真实点击（凭据保存／移除、连接测试、自动检查开关、更新窗口）、候选窗与本轮 UI 变化。
- 完整宿主安全矩阵、逐键性能 p95≤5ms、两小时稳定性、十万序列插桩、朋友真机。

### 上一轮记录（普通输入十项整改）

2026-11-06：上屏失败残留、候选完整提交、独立引号、设置顺序、调频清空、英文开关热更新、自定义词读取／重试、延迟学习；ABI 升 v4。隔离验证全过，真实宿主验收未开始。目标机器：Intel Mac、macOS 26.7.2。

## 普通输入十项整改（2026-11-06，工作区，未定版）

针对 2026-11-05 普通输入十维度审查确认的问题逐项修复（用户逐项裁决：切换不恢复、目标不明确暂不上屏、候选窗跟随稳定、大写/无候选空格/Ctrl+Enter 保持现状；本轮另裁决：暂时去掉 Ctrl+Enter 消费）。基线 89afbf8；无真实按键注入、无用户数据写入。

- **ABI v4**（`gogaku_core.h`，破坏性变更两端同步重编译）：新增 `GC_EV_COMMIT_CONFIRMED`（平台确认宿主插入成功后才调频学习）；`gc_normal_update` 增加 `english_enabled` 参数；新增 `gc_normal_clear_user_data`（清空调频内存＋删持久化文件）；`gc_custom_words_read` 返回 2 区分读取失败与文件不存在；新增 `gc_custom_words_peek` 只读解析备份。
- **#14 延迟学习**：核心提交意图只捕获（词＋编码序列，与 libime learn 主路径同源），平台插入成功后发确认事件才写模型与已学习词；学习模式哨兵提交、上屏失败转草稿、Esc、focusSync、清空均使待确认内容失效。修复学习模式中→英与未上屏内容污染普通调频。
- **#3 上屏失败残留**：`insertCommit` 失败后恢复字母跟踪（markedShown/markedCaret），后续 `updateMarked("")` 与 suspend 仍能清除宿主残留；成功后发确认事件。
- **#5 候选完整提交**：数字 0／超页与组合标点路径对完整覆盖的短码、拼音词、英文补全同样提交「候选＋标点/数字」，不再回退原编码。
- **#6 独立引号**：单、双引号各自交替配对（先双后单时单引号从左引号开始）。
- **#7 设置顺序**：所有完整匹配的启用拼音词按设置页顺序提升为候选，不再只提升 libime 排序中的首个。
- **#10 清空调频**：设置页删除失败不再伪报成功（区分本来为空）；成功后广播 `org.gogaku.freqdata.cleared`，输入法进程在引擎队列上调用 `gc_normal_clear_user_data` 清内存＋删文件，旧数据不再写回。
- **#11 英文开关热更新**：`applyEngineSettings` 传入 `englishCandidatesEnabled`，已运行引擎即时生效（开/关双向）。
- **#12 自定义词重试**：词表写入失败向 SettingsStore 注册真正的重试闭包；底栏「重试」执行词表重写，不再只处理设置快照。
- **#13 词表读取失败**：核心区分「不存在＝空表」「读取失败＝rc2（含目录路径）」「损坏＝corrupt 备份」；重载遇 rc2 保留现有词表；设置页读取失败暂停保存并提示，损坏备份用 peek 无副作用解析、不再吞掉损坏标志。
- **Ctrl+Enter**：普通映射移除（交还宿主），快捷键页固定操作文案同步改为「交还宿主」。

**验证证据（隔离，非真实宿主）**：当前源码隔离核心（依赖 commit 与 dist 身份一致：libime 5be1300、fcitx5 dfb1278；库 sha256 85538d56…）核心 ctest 6/6（普通轨迹＋新增延迟学习/候选提交/设置顺序/清空调频/读取失败用例；质量回归含确认事件后全过；fuzz 冒烟 2000 序列无错误）；Swift Release XCTest 158/158（新增英文热更新、延迟学习落盘、清空调频、读取失败区分、自定义重试、宿主异常桥接 6 项；隔离 xctest 方式运行，本机依赖缓存缺失 dependencies.lock/source 属环境问题，不计为代码故障）；ABI4 核心行为向量 23 项全过（`/tmp/gogaku-review-keys-sZ1HRH/fixed_verify.py`）；宿主异常注入夹具 3 轮全过。**未验证**：真实输入源／宿主矩阵（含候选窗跟随、读屏、卡顿、宿主兼容与延迟）、设置页真实点击、安装包构建与包检查；标准 fast 档在本机因依赖缓存缺失无法运行（非代码问题）。修复后工作区含并行会话的 Windows 交叉构建改动（未覆盖、未回退）。

## Windows 交叉构建与核心自检包（2026-11-05，工作区，未定版）

按计划 T2.1 的「无本地 Windows」路线推进：Mac 上用 Homebrew mingw-w64（GCC 16.2）交叉编译共享核心，产出 Windows x64 DLL＋测试 exe，打包为一键自检包供真实 Windows 硬件验证。

- **交叉构建流水线**：`scripts/prepare-win-cross.sh`——ECM → 隔离 Fcitx5Utils → IMEPinyin／数据工具 → 共享核心，全部同 pin（libime 5be1300 等）；POSIX 垫片（dlfcn/gettext/libiconv/zstd/zlib）解包 MSYS2 clang64 包到本地 sysroot（与上游 libime Windows CI 同源依赖），.pc 路径改写本机绝对路径；libime 应用 `scripts/patches/libime-win-cross.patch`（Boost iostreams 条件化——MinGW GCC libstdc++ 保留 std::binary_function，无需 kenlm 补丁）。核心从隔离副本构建：副本注入两项 Windows 兼容修正（fsync→_commit；WIN32 输出目录自引用修正），不触碰共享工作区（当天有并行会话的延迟学习 ABI v4 未提交 WIP，中固态不可编译属预期；两项修正待其合入后上游化）。
- **自检包**：`scripts/package-win-selfcheck.py` → `local/selfcheck/gogaku-core-selfcheck.zip`（70MB）：核心 DLL 链（libgogaku_core/libIMECore/libIMEPinyin/libFcitx5Utils/libwinpthread/libdl/libintl/libiconv/libzstd，导入表逐一二核查）＋6 个测试 exe＋出厂数据（Mac 缓存产物，哈希记录；兼容性由测试本体在 Windows 上验证）＋run.bat 一键运行产出机器可读 JSON 报告（无任何原文文本；测试向量与 Mac 侧同一套）。
- **验证证据**（`docs/validation/win-core-selfcheck/`）：Windows 11 x64 VM（VMware Fusion；i9-9880H 宿主）内全绿——ABI 合同、翻译加固层 76 项、普通模式轨迹、学习模式轨迹 144 项、质量回归 120 条、2000 随机序列冒烟全部通过；run.bat 双击路径复验通过。**KenLM／词库格式兼容（Mac 产物在 Windows 加载）由此直接验证**。
- **口径**：VM 是功能级验证环境；T2.1 验收仍以 CI 绿为准（远端未建）；朋友真机结果为真实硬件证据。VM 后续用于 TSF（T2.3）本地调试。

## 单文件自检 exe（2026-11-06，工作区，未定版）

应用户「只发一个 exe」的诉求：`scripts/build-win-selfcheck-exe.sh` 在 DLL 自检包之后产出**单文件全静态 exe**（`.build/win-cross/static/combine/gogaku-selfcheck.exe`，62MB，无外部依赖），数据以目标文件嵌入、运行时解包到 %TEMP% 子目录（退出不清理，同 pid 复用），控制台输出结论并回车退出。核心从 **git HEAD** 提取构建（隔离副本），排除工作区里并行会话的未提交 WIP——与版本规则一致：包对应已验证的提交状态。

- **构建要点**：工具链 EXE 链接旗标直加依赖库搜索路径（`link_directories` 在 CMake 4 + Ninja 生成器下未进生成行）；静态归档小写名 `libgogaku_core.a`（`-lGogakuCore` 大小写不匹配，改显式路径）；`CMAKE_CXX_STANDARD_LIBRARIES` 补传递依赖（zstd/intl/iconv/dl/z）到对象之后。
- **静态链接发现两个真实 Windows 移植 bug**（DLL 构建因混入当天未提交 WIP 的不同写入路径而未暴露）：
  1. **MinGW `std::rename` 不覆盖已存在目标**（MSVCRT rename 语义，EEXIST）：`atomic_write` 第二次起静默失败（dirty 滞留）——删词后学习词复活、userlm 重建失败、写失败恢复落盘全由此起。副本注入先 `remove` 再改名；产品化应改 `MoveFileExA + MOVEFILE_REPLACE_EXISTING` 保持原子性，**待 WIP 合入后连同 fsync 项一并上游化到 `normal_session.cpp`**。
  2. **fsync 语义**：前一轮注入的 `fsync→_commit` 对 O_RDONLY 句柄在 Windows 上失败，而写入路径把 fsync 失败当致命错误——改注入为 no-op 内联函数（自检包关注功能兼容而非掉电顺序；正式上游化应对写句柄用 `FlushFileBuffers`）。
- **验证证据**：同一 VM（Windows 11 x64）全绿——ABI 合同、翻译加固层、普通模式轨迹（含 flush 持久化/损坏重建/删词不复活/写失败恢复）、学习轨迹 144 项、质量回归 120 条、随机序列冒烟，失败 0 项；修复前 4 项持久化用例失败→定位→修复→复验全过的完整闭环在本 VM 完成。调试插桩（rename errno=17 实证）已从正式版剥离。
- **口径**：VM 功能级验证；**朋友真机自检推迟（2026-11-06 用户裁决）：不再单独发自检 exe，待完整功能安装包就绪后一并真实测试**；TSF 前端（T2.3）随即启动。

## 候选窗皮肤（2026-11-05，未定版）

`gomeen/skin-native` 分支按最后原型完成原生主题选择、单／双色、二级固定预览编辑器、字体／布局／透明度／背景图及主题包导入导出；fast 档 6 项全过（Swift Release 152 项），ASan／UBSan quick 2000 序列无错误。隔离设置窗口验证了保存重开、两级高度、隐藏滚动条及预览像素不随左侧滚动变化。未安装此分支输入源，真实宿主热更新／背景图性能及完整发布门槛未验收。细节、截图与报告见[皮肤验收](skin-native-status.md)。

## 学习规则迁入共享核心（2026-11-05，工作区，未定版）

按[首阶段实施总计划](../implementation-plan.md) G1 的 T1.1–T1.3 推进：学习规则从 Swift 迁入共享 C++ 核心（ABI v3），为 Windows 前置；Mac 行为合同不变。

- **范围**：学习组合状态机（英→中英文缓冲、中→英字面/编码片段源文推导、部分消费）、三状态按键语义、翻译调度合同（源表达式＋发布旗标＋接收/失败语义）、拼写问题结构（纯存取，偏移口径由平台定义）迁入 `shared/GogakuCore/learning_session.cpp`；C ABI 升到 v3，版本 1/2 函数与结构布局不变。内嵌小鹤解码内核与历史 ge_* 桥同语义（预编辑展开全拼、候选带解码下标与范围）。
- **Mac 切换**：`CompositionSession` 改为薄封装（事件编组、核心 epoch→组合 UUID 映射、候选稳定 ID、翻译请求回调触发）；`EngineHub` 直接按词典/模型路径创建；TranslationService／worker 传输不动；InputController 调用面无改动。候选追加不重编号（迟到结果不替换已显示编号）由封装按候选值键保持 ID 稳定。
- **行为对齐细节**：内核拒绝（撇号开头片段）与历史 decode 抛异常同源，走引擎错误路径（状态行「引擎操作失败」）；回格按字素簇删除，与 Swift `String.removeLast` 同语义（组合标记／VS／键帽 20E3／肤色修饰／ZWJ 粘接／区域指示符对整簇回退；v1 局限：Tag 旗标不延伸，注释在实现内）；学习翻页/导航不推进 revision、冻结迟到结果；全部消费不开启新组合身份。
- **验证**：核心事件轨迹向量新增学习用例（`tests/learning_session_test.cpp`，144 项检查：缓冲/调度/接收语义/失败路径/选择提交/原文上屏/512 标量上限/Unicode 字素/中→英推导/冻结分页/身份失效/拼写守卫/普通态引擎语义/非法请求），与 Swift 行为合同同源出厂数据逐字对齐；ctest 6/6 全过；同一测试在 ASan＋UBSan 插桩构建下通过。fast 档全过（core ctest 100%、Swift Release 117 项含既有 CompositionSession 行为合同与 worker 协议回归），报告 `docs/validation/verify/report-fast-20261105-092040.json`；ASan/UBSan quick 冒烟 2000 序列无错误（`report-release-20261105-092131.json`）。
- **未完成／待验证**：Windows 侧验证（同一测试集在 Clang64 构建）待 T2.1；学习记录（LearningStore）仍在 Swift，随双端正式方案再定；真实宿主手动清单未重跑（行为合同由 Swift 117 项回归覆盖，但体验级回归待下轮装机自测）；安装包重新打包前按版本规则递增构建号。
- **T2.1 脚手架（接口冻结后并行启动；未验证）**：共享核心接口随本轮冻结（ABI v3，两套轨迹测试向量就位），按计划并行启动 Windows 构建流水线脚手架——`scripts/prepare-libime-windows.py`（MSYS2 Clang64 依赖准备：与 Mac 同 pin、同源数据、同上游转换命令，产物哈希单独记录，KenLM/词库兼容性以 CI 核心向量全绿为验证口径）、`shared/GogakuCore/CMakePresets.json`（clang64 配置/构建/测试 preset）、`.github/workflows/windows-core.yml`（依赖→构建→全量 ctest→DLL 导出清单与 ABI 实跑→哈希证据）。CMakeLists 的 boost 查找增加 BOOST_INCLUDE 环境变量 HINTS（Mac 流程实测不受影响，ctest 6/6 全过）。**仓库当前没有远端，流水线未经真实 CI 运行**；首跑可能暴露工具链差异，按失败逐项修；全绿前不标「Windows 核心测试通过」。推送仓库／CI 归宿属用户决定（远端缺失）。

## 移除快速添加功能（2026-11-04，工作区，未定版）

用户裁决「快速添加（⌃⇧A 把最近上屏中文存为拼音词）没有用」，整功能移除；规格已从 [产品方向](../product.md)删除（「已确认的自定义词语」表不再含快速添加行，快捷键默认表与快捷键页描述同步改为两个可配置命令）。

- **移除范围**：设置页「普通输入」页快速添加卡片（内联快捷键录制＋排除应用列表）；⌃⇧A 快捷键监听与「键盘快捷方式」表格行（`ConfigurableCommand.quickAdd` 删除，冲突检查与筛选自动收窄）；共享核心 `GC_EV_QUICK_ADD` 事件、60 秒记录窗口（`QuickAddRecord`）、排除应用（`gc_normal_set_excluded_apps`／`gc_normal_quick_add_available` 删除）；`Settings.quickAddShortcut`／`quickAddExcludedApplications` 及迁移测试。自定义词语页与拼音词本身保留；设置进程侧「写入失败不得伪报成功」由 `SettingsStoreTests` 继续覆盖（核心侧写入路径原本仅快速添加使用）。
- **验证**：fast 档全过——核心 ctest 全过（事件轨迹测试删除快速添加向量）、Swift Release 112 项全过、版本与资源检查（`report-fast-20261104-115923.json`）；ASan＋UBSan quick 冒烟 2000 随机序列无错误（`report-release-20261104-120013.json`）。C++ 测试向量和 fuzz 事件分布同步收缩（fuzz 不再生成 `GC_EV_QUICK_ADD`）。
- **待验证**：真实宿主中菜单／候选窗回归未重跑（本次仅删除不新增交互路径）；安装包重新打包前按版本规则递增构建号。

## 旧本地翻译选型（已退役）

2026-11-06 起产品只保留用户配置的火山 NMT。此前 small100、quickmt 与组合策略实验均未形成正式质量／宿主验收，本轮删除其模型准备、排名、逐请求输出和重复研究；详细历史从 Git 追溯，不沿用其结论作为当前发布证据。

保留 `validation/`、`probes/translation-*.json` 的通用考题、`resources/translation/` 及共享核心安全规则测试；固定数据校验改由 `scripts/validate-translation-data.py` 执行。当前翻译行为与测试覆盖见[产品方向](../product.md)和[清理与测试审查](testing-cleanup-audit.md)。

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

按六轮输入习惯裁决实现普通模式：行为规格迁入共享 C++ 核心（`shared/GogakuCore`，ABI v2），Mac 端（IMK 控制器／面板／设置）改为薄调用。已验证：

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
- **G0 Mac 模型门槛**：Apple Translation 退出正式交付链路（原“Apple 优先、失败后 small100”顺序作废，既有 Apple 探针保留为历史证据）。唯一候选 small100 `8ab680e` 已完成 Mac 分词、转换、质量与速度验证：**技术可行性通过，模型质量门槛不通过**，双端学习交付保持阻塞，本段为当时状态，详报已随旧本地模型选型退役，Git 历史仍可追溯；不代表当前火山服务质量。
- **行为规格差异待调和**：本计划确认每页 5 个候选、数字 1…5 选择；现实现按用户青简配置使用每页 9 个（见下文第 4／6 条修复）。G1 迁移时以计划为准统一，迁移前不回改已验证的 Mac 行为证据。
- **更正（2026-10-31，追加）**：上一条“以计划为准统一为 5 个”方向写反了。用户经六轮输入习惯原型裁决后已确认**每页 9 个、数字 1–9**为准，计划文档已同步修正（见[实施总计划](../implementation-plan.md)§五与[产品方向](../product.md)普通模式行为规格）；本条及下方历史记录保留原样，不倒改。后续迁移以 9 为准，不再回改历史证据。
- 原 A–E 阶段证据映射：A→G2 Mac 部分、B→G0、C→G3、D→G4、E→G4。以下历史记录保持原样，不倒改。

## G1 前置：最小共享接口（2026-10-31）

新建 `shared/GogakuCore`：共享核心 C ABI 骨架（版本 1），含 `gc_abi_version`／`gc_abi_check` 版本合同与 `gc_utf8_scalar_count`（512 标量输入上限所用，明确 Unicode 标量而非 UTF-16 范围）。Windows DLL 导出宏已内置；库内分配由库释放、异常与 STL 不跨 ABI 的合同写入头文件。构建与测试：

```sh
cmake -S shared/GogakuCore -B .build/core -G Ninja -DCMAKE_BUILD_TYPE=Release
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
