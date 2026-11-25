# 变更记录

人类可读的版本变更说明。版本规则见 [docs/versioning.md](docs/versioning.md)；验收状态以 [docs/validation/native-development.md](docs/validation/native-development.md) 为准，本文不重复验收结论。

### 0.5.2（目标版本）

- macOS「检查更新」正确解开并校验出厂数据 `.pkg`；同构建号数据指纹缺失或过期时，可只修复数据。手动数据包不再依赖 Python，回滚只还原数据目录。
- 修复 macOS Lite 安装包遗漏输入源身份，导致主包无法通过安装校验的问题。
- 扩展词库页调整留白，增加四本按需安装的 THUOCL/MIT 入门推荐（IT、财经、医学、法律）。两端共用推荐配置，词库不预装。

### 0.5.1（2026-11-24，stable 定版）

更新交互关于页化：检查更新入口从独立窗口移入「关于」页，检查与下载安装分离——手动和自动检查都只读取并验签更新元数据，不静默预下载；发现新版后 macOS 点击「下载并更新」才下载并就地安装，Windows 由「下载更新」「安装更新」两步走系统安装向导；「查看更新说明」为只读窗口。Windows 设置应用新增「关于」页（完整版九页、Lite 六页）。检查失败或限流时清除旧的可操作候选；自动检查偏好保存失败回滚开关。发布记录见 [release-0.5.1.json](docs/validation/release-0.5.1.json)。

### 0.5.0（2026-11-24，stable 定版）

扩展词库：引擎多词典挂载、本地导入转换与官方精选词库渠道一次发布。发布记录见 [release-0.5.0.json](docs/validation/release-0.5.0.json)，词库渠道见 [catalog-1.json](docs/validation/catalog-1.json)。

- 完整版与 Lite 新增「扩展词库」。支持本地导入、启停、删除及内存估算。启用或停用后，挂载变更在组合结束后生效。
- 官方词库入口由用户点击后联网，客户端核验签名清单与资产哈希。首批上架 12 本非空词库，每本独立使用递增的数字修订号。
- 验证：fast 7/7（核心 ctest 14/14、Swift 341 项）、release 14/14（含十万序列 ASan／UBSan）；两本真实搜狗 `.scel` 样本经共享核心转换、召回与停用验证。**host 未运行**（用户 2026-11-24 书面豁免）；Mac 真实输入源、Windows 运行与在线更新 E2E 仍未验收。测试证据见 [扩展词库验收](docs/validation/dictionaries-0.5.0.md)。

### 0.4.1（2026-11-22，stable 定版）

更新窗口信息修复。发布记录见 [release-0.4.1.json](docs/validation/release-0.4.1.json)。

- 应用内「更新说明」与 GitHub 发布正文拆开：清单 `notes` 只放应用内短纯文本（发布侧自动压缩或 `--update-notes-file` 手写，上限 12 行／1200 字，含 Markdown 记号被门禁拒绝）。实测说明区 779pt → 320pt。
- 按 2026-11-19 裁决去掉更新窗口里的构建号（两端同口径）；数据包说明不再列出内部文件名与数据版本指纹。
- 验证：fast 7/7、release 14/14（含十万序列 ASan／UBSan）；`test_delivery_pipeline` 31 项（新增 3 项）。**host 未运行**（用户书面豁免）。
- 发布流程改进已验证生效：tag `v0.4.1` 一次指向发布提交 `fa09421`（0.4.0 曾因未传 `target_commitish` 钉错提交）。
- 时序说明：0.4.0 的清单已签名发布，其 notes 仍是旧 markdown；构建号隐藏要在 0.4.2 才能真正进入窗口（读清单的是已安装的旧客户端）。

### 0.4.0（2026-11-21，stable 定版）

发布内容：Windows 安装即启用、候选窗去掉页码。发布记录见 [release-0.4.0.json](docs/validation/release-0.4.0.json)。

- 构建号 b125（0.3.2 已占用 b124；并行线曾写成 b123，属倒退，已修正并重新构包与验证）。
- 发布后修正 tag：首次发布时 tag `v0.4.0` 因 `publish-release.py` 未传 `target_commitish` 而指向旧提交 `839c3c9`；0 下载时点按用户裁决删除并重建至 `507b78c`，Release 退回 Draft 后重新发布。脚本已修（显式传 `target_commitish` ＋ 发布前校验提交已在远端）。
- 验证：fast 7/7、release 14/14（含十万序列 ASan／UBSan）。**host 未运行**（用户书面豁免，见发布记录）。Windows 真机验收未做。

### 变更（2026-11-21：更新窗口信息可读化，已并入 0.4.1）

- **应用内「更新说明」与 GitHub 发布正文拆开**。此前 `publish-release.py --notes-file` 把同一份 markdown 同时喂给 GitHub 正文和签名清单的 `notes`，而更新窗口用的是纯文本控件（SwiftUI `Text(String)`、Win32 `EDIT` 都不解析 Markdown）——用户看到的是 `# Gogaku 0.4.0`、`## 更新内容`、`**粗体**` 和下载表格的管道符。现在清单 `notes` 只放应用内短纯文本：发布侧从正文自动压缩（去标题／表格／粗体，`- ` 转 `· `，`## 下载` 之后丢弃，上限 12 行／1200 字），也可用新增的 `--update-notes-file` 手写一份（含 Markdown 记号会被门禁拒绝）；发布门禁校验清单 `notes` 与派生结果逐字一致，含记号直接失败。
- **按 2026-11-19 裁决去掉更新窗口里的构建号**：`当前版本 0.4.0（构建 125）` → `当前版本 0.4.0`，`新版 0.4.1 构建 126` → `新版 0.4.1`，状态行「已是最新（0.4.0 构建 125）」→「已是最新（0.4.0）」。macOS 与 Windows 两端同口径。
- **数据包说明去掉内部身份**：不再显示数据包文件名与 16 位数据版本指纹，只报体积与「本地已有同版本数据时不重复下载」。
- 实测效果：0.4.0 的说明区从 779pt 降到 320pt（离屏渲染，不再需要滚动 2–3 屏）。
- 验证：fast 7/7（核心 11/11、Swift 327 项）；`scripts/test_delivery_pipeline.py` 31 项（新增 3 项：markdown 压缩、显式纯文本优先与记号拒绝、行数／字数上限）。

### 变更（2026-11-20：候选窗去掉页码，工作区已并入 0.4.0）

- 候选窗不再绘制页码（用户裁决）。原因：页码原先独占页脚一行（约 17–20pt），只在多于一页时出现，于是候选跨过「一页」门槛时面板凭空长高一行——最典型的是竖排每页 9 个时，9 个候选（单页、无页码）与 10 个候选（两页、第一页仍是 9 行）内容完全相同、框高却差一行；0.3.2 的粘锚定边只解决了顶边下塌，没解决这个纯装饰性的高度跳变。
- 三条渲染路径同步：共享位图渲染器（`panel_render.cpp`，默认路径）、macOS 系统渲染（`PanelLayout` 竖排与横排）、Windows 系统渲染（`appearance.cpp`）。横排原先为页码预留右缘宽度、必要时按页码左缘丢弃候选，现在不再预留、不再丢候选。
- 翻页能力不变：`.`／`,`、Page Up／Page Down、↑↓ 跨页、Control＋n/p、数字选当前页候选全部保留；`GC_PANEL_HIT_PAGE_PREV/NEXT` 不再产生命中区（枚举值保留，两端点击处理仍兼容旧命中表）。无障碍标签仍报「第 N/M 页」。
- 主题的「页码」颜色字段保留（已导出主题不受影响），只是当前没有绘制对象；文档已注明。
- 验证：fast 7/7（核心 ctest 11/11、Swift 327 项，新增 3 项：多页无翻页命中区、单页与多页等高、横排不再按页码丢候选）；渲染探针 53 项全过（含新增的「单页与多页等高」像素断言）。

### 变更（2026-11-20：Windows 安装即启用，工作区定 0.4.0）

- **安装器自动登记用户输入法列表**：不再要求用户安装后手动走六层设置路径启用。`ssPostInstall` 新增 `EnableUserProfile()`，以 `ExecAsOriginalUser` 静默、幂等地执行 `GogakuAgent.exe --register-profile`，把本通道条目（`0804:{CLSID}{ProfileGUID}`）写进当前用户的 `HKCU\Control Panel\International\User Profile\*\InputMethodTips`。实现是「已包含就不写」＋单次 `input.dll!InstallLayoutOrTip(tip, 0)`＋失败不重试：不设默认输入法、不写 `Set-WinDefaultInputMethodOverride`、不改其它语言条目。标准用户借管理员凭据安装时写的是原用户 hive。
- **设置应用启用状态卡片**（普通输入页顶部，每次进入只读重查）：已启用时给「重启资源管理器…」（确认框说明影响后才 `taskkill /f /im explorer.exe` 并重启它）；未启用时给「立即启用」（进程内调同一启用逻辑）与「打开系统设置」（`ms-settings:regionlanguage` 深链＋两步图文）。向导完成页的「打开 Gogaku 设置」翻转为默认勾选。
- **共享身份头**：新增 `windows/gogaku-ids.h`，CLSID／stable 与 dev 档案 GUID／LangID 与条目串拼接只有一份实现，TSF 注册与用户级启用共同引用（纯移动，GUID 值不变）。
- 验证：交叉编译（x64 TSF／代理／设置／核心、x86 TSF）与 Inno 实际编译通过；`build-win-app.py --self-test` 新增 `EnableUserProfile`／`ExecAsOriginalUser` 与默认勾选断言；新增只读自检 `windows/tests/enable_test.cpp`（身份条目串格式、通道区分、整条匹配）；fast 7/7。**真机验收未做**：启用是否落地、30 分钟后的剔除复查、静默安装与重复安装幂等均需 Windows 11 x64，清单见[原生验收记录](docs/validation/native-development.md)与[dev-b123.json](docs/validation/dev-b123.json)。

### 变更（2026-11-20：慢速网络下载超时自适应，工作区）

- 修复检查更新下载在慢速网络永远超时：GitHub 资产域名实测可低至 ~80KB/s（2026-11-20 用户 0.3.0→0.3.2 升级：主包 11MB 能下完，36.7MB 数据包需 ~7 分钟，超过固定 300s 资源超时；无字节级续传，重试从头下载导致永远超时）。下载总超时改为按资产大小自适应（50KB/s 保底估算，下限 300s：36.7MB→~734s）；空闲断流上限独立固定 60s（不再随总预算放大，连接挂起仍能及时报错）。新增 UpdateTests.downloadTimeout 纯函数与传输层超时断言。
- 临时解救：本次用户升级的数据包已从本地构建产物填入缓存（哈希与清单一致），重试更新即命中「本地已有同版本数据」不再下载。
- 验证：fast 7/7（Swift 327 项，新增 1 项）。

### 0.3.2（2026-11-20，stable 定版）

- 候选框高度收缩沉底修复：同一锚点下候选变少、面板高度收缩时，旧实现粘性复用左下角 origin，顶边下塌、面板整体沉底、离光标越来越远；现改为粘「锚定边」——光标下方时顶边贴光标不动、高度向底部伸缩（上翻时保持底边），重算尺寸越界仍回退重算位置，粘边高度用未取整布局尺寸避免像素对齐飘移。新增 CandidatePanelStickyTests 覆盖下方／上方两分支与真实布局路径。
- 验证：fast 7/7（Swift 324 项）；host 真实宿主档由用户裁决豁免，真机验收随用户升级进行。

### 0.3.1（2026-11-20，stable 定版）

- 检查更新一步化：更新窗口收敛为「检查更新」单按钮状态机，点击后自动完成检查→下载→校验→就地安装→完成；无新版显示「已是最新」，失败变「重试」。唯一第二步场景是就地安装工具链缺失时自动转系统安装器。自动检查发现新版后静默预下载，只显示「一键更新到 X」。
- 学习中→英预译时序修复：去掉 0.25s 防抖，首键即发预译；空格提交时同一源文预译在飞则挂起提交等结果直接上屏（上限 400ms，超时回退自发请求），消除同一句话重复发两个翻译请求、弹框常无英文的时序问题。
- 验证：fast 7/7（Swift 321 项）；真机按键链路与更新流程验收由用户升级时进行。

### 变更（2026-11-19：就地热更新＋数据／代码包分离，工作区，定 0.3.0 主题）

- **检查更新一步化（用户裁决）**：更新窗口收敛为「检查更新」单按钮状态机——点击后自动完成 检查→（有新版）下载→校验→就地安装→完成，各阶段在按钮文案与状态行体现（「检查中…」「下载中 45%」「安装中：替换文件」「已更新到 X，下次打字生效」）；原「下载安装包」「就地更新（不弹安装器）」等分离按钮全部合并。无新版按钮回「检查更新」、状态行「已是最新」；任一步失败按钮变「重试」（保留失败处凭据：下载失败续传下载、安装失败就地重装），错误行显示原因。唯一可能出现第二步的场景是就地安装工具链缺失（installerUnavailable）：自动转系统安装器路径，按钮变「打开安装器」（系统安装器被关闭可再次点开），状态行说明原因；旧 open pkg 方法仅为该 fallback 保留，UI 不再单独暴露。自动检查（若开启）发现新版后直接静默预下载（含数据包缓存复用），UI 只显示「一键更新到 X」单按钮，点击即装；仍不自动安装、不自动重启。
- **预译时序修复（用户裁决 A＋B 组合）**：诊断确认学习 zhToEn「输入四键＋空格」全流程常 <1s，旧 0.25s 防抖＋火山 RTT 使预译几乎总在提交之后才回来——弹框从未显示英文，而空格提交链自发请求照常上屏，且同一源文重复发出 eager＋commit 两个请求。修复：①去掉 0.25s 防抖——applyNormal 重建 backlog 后立即泵预译队列，pumpEagerBacklog 对「源文与在飞相同」去重，连续输入不放大请求量（裁决 A）；②提交合并——空格提交时若同一源文预译正在飞，挂起提交（复用 PendingTranslatedCommit 缓冲后续按键）等待 eager 结果直接上屏（结果处理置于渲染 guard 之前），超时 400ms（CommitMergeWindow.waitLimit 兜底）仍无结果回退自发 commit 请求（裁决 B）。等待窗口提取为 GogakuKit.CommitMergeWindow，新增 CommitMergeWindowTests 覆盖源文匹配等待／超时回退两分支；结果入 memory、失败计次（eagerAttempts）与「仅高亮候选显示英文」裁决不变；现有预译测试（EagerAnnotationTests）不依赖防抖，无需同步。
- 验证：fast 档全绿（核心 ctest＋Swift 全量）；真实按键链路与真实点击更新待输入源／宿主验收。
- 不递增 version.json（发布期由主代理定版 0.3.1／122）；不动 scripts/、shared/、windows/。

### 变更（2026-11-19：就地热更新＋数据／代码包分离，工作区，定 0.3.0 主题）

- **就地热更新（Mac，用户裁决）**：「安装更新」不再打开系统 Installer——客户端自己完成 pkg 解包（xar → Scripts gzip+cpio → Gogaku-apps.zip ditto）→ stage 双 App 校验（bundle ID／构建号／TIS 身份／codesign --deep --strict）→ ditto 备份 → 事务替换 → transaction.txt 状态机（installing/success，与 pkg postinstall 同格式同位置，中断可恢复）→ lsregister。任一步失败恢复备份、可重试；工具链缺失时自动回落旧的 open-installer 路径。输入法交接：安装成功后发 `org.gogaku.inputmethod.restart`（DistributedNotificationCenter），GogakuInput 启动早期注册监听，结束在途组合（草稿落盘）后 1.5 秒 `NSApp.terminate` 正常退出，imklaunchagent 按需拉起新版；绝不 SIGKILL。更新窗口显示「就地更新（不弹安装器）」与解包→校验→替换→重启输入法→完成的阶段进度，完成后显示「已更新到 X.Y.Z；输入法将在下次激活时使用新版」。
- **数据／代码包分离（用户裁决）**：Mac 构包拆两个 pkg——`Gogaku-<版本>.pkg`（代码包，zip 剔除双 App 的 EngineData，且剔除发生在签名之前，使代码包密封不覆盖数据）＋ `Gogaku-Data-<版本>.pkg`（数据包，只含 EngineData，同 postinstall 机制落位、逐文件 SHA-256 校验、事务备份替换；Lite 同理）。更新清单升 schema 2 并采用**双清单**：每版同时发 `update-manifest.json`（schema 1，只含主包，0.2.0 及更早旧客户端照常升级）与 `update-manifest-v2.json`（schema 2，dataPackage 必填）；新客户端优先拉 v2、404 回落 v1。数据内容指纹（排序 (路径, sha256) 清单的 SHA-256 前 16 位）作为 `dataVersion`，数据未变的版本之间相同：发布侧经 `--previous-state` 复制上一版数据包资产引用（不重发资产），客户端按 dataVersion 命中 `~/Library/Caches/Gogaku/updates/data/<dataVersion>/` 缓存不再下载——稳定态代码更新下载量约 50MB→15MB。数据包安装失败为部分成功态：主包照常更新、词库回退旧版（核心兼容旧数据），UI 明示。
- **旧客户端兼容**：schema 1 清单永不携带 dataPackage；主包 postinstall 与就地安装器都会把备份里的旧 EngineData 结转进新包，仅装主包的旧客户端升级后输入法仍可用。Windows 本轮保留整包（Inno 拆包与 update.cpp 的 schema 2／数据链路待跟进，Windows 客户端继续读 schema 1 清单不受影响）。
- 验证：Swift 全量测试 315 项通过（新增 UpdateInstallerTests——真 xar/cpio/ditto/codesign 的最小 bundle 夹具覆盖校验拒绝、事务中断恢复、成功全流程、数据包成功/哈希拒绝/部分成功；UpdateTests 扩 schema 2 解码、双清单回落、数据包下载缓存与绑定校验）；交付管道 unittest 28 项通过；`make-update-manifest --self-test` 扩双清单生成、上一版引用复用与无数据包拒绝；数据包 postinstall 在沙箱 HOME 完成成功/失败恢复实测。真实替换双 App 的宿主验收、客户端在线更新 E2E 仍未做，见 docs/update.md「本轮边界与已知限制」。
- 不递增 version.json（发布期由主代理定版 0.3.0／b121）；不动 bsdiff 路线（二进制 delta 已证伪）。

### 变更（2026-11-19：设置界面整理＋竖排每页数量，工作区，定 0.2.0 主题）

- 用户裁决（四项）：删除设置侧栏顶部「Gogaku」标题与底部页脚（本机开发版／Gogaku 标签、版本号、「检查更新」按钮）；新增「关于」页（侧栏最后一页，所有安装形态都有），版本号与「检查更新」移入其中——产品名＋版本号（复用包内 build-identity.json 的 displayVersion）、dev 通道加「本机开发版」标注、检查更新按钮打开既有更新窗口并保留有可用更新的绿点提示，包内构建身份存在时另附 commit 前 8 位＋dirty 的只读完整身份行。
- 竖排每页候选数量可配置（4–9，默认 9）：设置新增 `verticalPageSize`（共享契约 `settings_contract.cpp` 同步 knownKeys/defaults/钳制，schemaVersion 仍为 2）；普通输入页「横排每页数量」行改为通用「每页候选数量」，在两种排列下都显示并跟随排列读写对应字段。共享核心新增附加导出 `gc_normal_set_vertical_page_size`（4–9 钳制，默认 9），不改任何已有结构与函数签名，ABI 版本不升；Mac（EngineHub／InputController）与 Windows（agent／appearance）消费点同步改为竖排读 `verticalPageSize`。
- 验证：共享核心契约与普通会话测试新增向量（缺键默认 9、超范围钳制、非法类型丢弃；竖排 5/页翻页、默认 9 不变、非法值钳制、与横排互不干扰）；Swift 侧新增 verticalPageSize 编解码／钳制、effectiveNormalPageSize 两分支、关于页在五页集合（完整／Lite 两形态）断言；ASan quick 冒烟通过；Windows 侧交叉编译 x64／x86、full／lite 形态验证。
- 不发布不装本机：本条只改代码与验证，不递增版本号、不构包、不发布、不安装；对外发布由主代理统一发 0.2.0。

### 变更（2026-11-19：对外命名只用版本号，构建号降级为纯内部计数器，工作区）

- 用户裁决：对外一切只用版本号，构建号不再出现在任何安装包文件名、tag 或用户可见 UI；发布记录按版本号命名（如 `release-0.1.8.json`）。
- 安装包文件名去掉 `-b{构建号}`：stable 如 `Gogaku-0.1.8.pkg`／`Gogaku-0.1.8-windows-x64-setup.exe`，dev 通道只留 `-dev` 后缀（如 `Gogaku-0.1.8-dev.1-dev.pkg`）。dev 发布 tag 同步改为 `v<版本>-dev`；Windows 安装器内部 `versions\<版本>-<通道>` 目录照旧带构建号（非对外标识）。发布期工作目录习惯改为按版本号（如 `dist/release-0.1.8/`）。
- 版本递增规则改为三档：修复或小改进递增小版本（0.1.7 → 0.1.8）；新功能递增中版本、末位归零（0.1.x → 0.2.0）；重大／破坏性更新递增大版本。**发布即占用**：对外发布过的版本号永久占用；未发布出去的包（构包失败、验证失败、签名错误等重试）不算发布、不占号，只递增构建号——原「定版失败只递增构建号」规则整体替换。
- `buildNumber` 保留在 `version.json`：仍单调递增、每次对外构包前递增，用途只剩内部对账（update-manifest 的 `buildNumber` 字段、客户端更新比较、包内 `build-identity.json`、收据、诊断输出），明确不得出现在安装包文件名、tag 与面向用户的默认 UI。客户端更新逻辑（比构建号）不变。
- 改动范围：打包与发布脚本（`package-macos-pkg.py`、`build-win-app.py`、`publish-release.py`、`make-update-manifest.py`、`verify.py`）的文件名模板与期望名、交付管道自测、版本与发布／更新文档。历史 `release-b*.json` 与已发布 Release（v0.1.6／v0.1.7）的资产不改名，git 历史可考。本条为发布工具行为，不影响已发布客户端。

### 变更（2026-11-18：侧栏版本标签不再把 stable 误标为开发版，工作区）

- 用户报告：设置侧栏页脚无条件显示「本机开发版」与「0.1.7 构建118」，stable 用户会误读自己装的是开发版。根因是该标签是硬编码文案，从不判断实际通道。
- 修复：页脚按 bundle ID 判断通道——dev 通道（Gogaku Dev，`.dev` 后缀）才显示「本机开发版」，stable 显示「Gogaku」；版本行去掉「构建 N」尾巴只留纯版本号。构建号仍保留在安装包文件名、检查更新页与诊断输出中（展示规则见[版本管理](docs/versioning.md)）。
- 验证：fast swift-tests 288 项通过；新增 `BuildIdentityLabelTests`；本机 stable 安装后辅助功能树实测侧栏显示「Gogaku／0.1.7」。

### 0.2.0（2026-11-19，stable 定版）

- 设置侧栏去掉顶部产品名标题与底部版本页脚；新增「关于」页（侧栏最后一个 tab），版本号、「本机开发版」标注（仅 dev 通道）、构建身份与「检查更新」入口移入该页。所有安装形态（完整、完整版内 Lite、Gogaku Lite 独立包）均显示。
- 竖排候选窗每页数量可配置（4–9，默认 9）：新增「每页候选数量」设置，跟随竖排／横排排列分别生效；双端共用同一共享核心实现（附加导出，ABI 仍为 4）。
- 完整版设置页现为八页（普通输入、学习翻译、自定义词语、皮肤、快捷键、学习与隐私、学习片段、关于）；Lite 观感为五页（四功能页＋关于）。
- 验证：fast 7/7（Swift 293 项）、release 14/14、ASan/UBSan 冒烟、Windows 交叉编译；真机外观与竖排分页实际输入行为待验收。
- 已发布：Release 450899262，tag `v0.2.0`（构建提交 ae5b9f1），发布记录见 [release-0.2.0.json](docs/validation/release-0.2.0.json)；公开清单签名已远端验证。host 未运行（豁免理由见发布记录）。发布后未自动更新本机，由用户手动检查更新验证升级链路。

### 0.1.8（2026-11-19，stable 定版）

- 修复设置侧栏版本标签：stable 安装不再误显「本机开发版」与构建号，显示「Gogaku」＋纯版本号；「开发版」标签仅 Gogaku Dev（dev 通道）显示。构建号同步从安装包文件名、tag、对外清单文件名中移除（`Gogaku-0.1.8.pkg`），降级为纯内部对账字段；版本号递增规则改为三档（修复→小版本、新功能→中版本、重大→大版本）＋「发布即占用」——未发布出去的重构包不占版本号，规则见[版本管理](docs/versioning.md)。历史发布资产与记录不改名。
- 验证：fast 7/7（Swift 288 项）、release 14/14；交付自测（更新清单、Windows 组装、交付流水线 25 项）通过。
- 已发布：Release 450807351，tag `v0.1.8`（构建提交 523db17），发布记录见 [release-0.1.8.json](docs/validation/release-0.1.8.json)。首採新命名（资产名无构建号）；公开清单签名已远端验证。host 未运行（豁免理由见发布记录），宿主验收欠账待补。

### 0.1.7（构建 118，stable 定版，2026-11-18）

- 完整版新增「Lite 模式」：首次打开设置时可选择完整／Lite 使用模式，侧栏底部可随时切换。Lite 下隐藏学习三页与学习快捷键、英文释义置灰、⌃⇧K／⌃⇧J 交还宿主；学习数据与凭据保留，切回即恢复。独立安装包 Gogaku Lite 行为不变。Windows 设置 UI 待跟进（设置字段已由共享契约规范化）。
- 新增六种双拼方案：自然码、微软、智能、紫光、拼音加加、国标（连同小鹤双拼／全拼共八种），双端设置页同步；键位映射由 libime 内置方案唯一提供，词库、调频、模糊音共用不变。修复 Windows 代理把方案当布尔传参的问题；微软／紫光的 ing 在分号键，组合中命中本方案键位时按拼音键继续。
- 已发布：Release 449797293，tag `v0.1.7`（构建提交 974643f），发布记录见 [release-b118.json](docs/validation/release-b118.json)。四包哈希与公开清单签名已远端验证；host 未运行（豁免理由见发布记录），新增功能真机验收待补。

### 0.1.6（构建 117，stable 定版，2026-11-18）

- 新增 Gogaku Lite：Mac／Windows 独立安装包，保留普通输入、英文候选、自定义词语、皮肤和横竖排切换；移除学习模式、学习相关设置页与普通模式英文释义。完整版与 Lite 共用用户数据，同机并发写入仍为已知受限项。
- 完整版与 Lite 支持横排候选窗；新增「渲染引擎：自绘／系统」，两端自绘共用 C++ 位图渲染器，失败自动回退系统路径。
- 修复 Mac 普通中文状态按住 Shift 连续输入大写字母时，从第二个字母开始无法输入的问题。
- 修复大背景图主题在每次重绘中重复处理完整主题的性能问题；共享核心持有不可变主题快照，两端复用。离屏五组输入的输出像素保持一致；8MiB 背景图的热态 p95 从约 81.89ms 降至 1.13ms。
- 已知限制：8MiB 背景图的主题准备加首帧仍约 159ms，首次加载未达目标；离屏与构建验证不代表真实宿主输入性能。Windows 字体未命中后需重启进程才能识别新装字体。
- 修复 Windows Lite 构包静态检查遗漏产品形态参数、错误拒绝 Lite 编译收据的问题；错误形态仍被拒绝。
- 修复发布验证工具：干净工作树执行 Swift 测试前会显式构建 EngineBridge 并固定仓库构建根；包检查先对临时副本去除调试符号再扫描诊断标记，保留对真实诊断字符串的拒绝。此项不改变产品行为。
- 更新签名公钥轮换为生产密钥 `gogaku-prod-2026-11`。
- 已发布：Release 449677317，tag `v0.1.6`（构建提交 721e8a3），发布记录见 [release-b117.json](docs/validation/release-b117.json)。四包哈希与公开清单签名均已远端验证。host 未运行（桌面锁屏豁免，理由见发布记录），待解锁后补录。

### 变更（2026-11-18：补齐常用双拼方案，工作区）

- **行为变化：内置输入方案从两项扩到八项**。小鹤双拼（默认）与全拼之外新增自然码（`ziranma`）、微软双拼（`mspy`）、智能ABC（`abc`）、紫光双拼（`ziguang`）、拼音加加（`pinyinjiajia`）、国标双拼（`gb`），全局切换，模糊音／调频／英文候选／编辑键规则对所有方案一致。
- **实现位置**：键位表与方案枚举仍然只有一份——libime 的 `libime::ShuangpinBuiltinProfile`（`shuangpinprofile.h`：`Ziranma`／`MS`／`Ziguang`／`ABC`／`PinyinJiajia`／`GB`／`Xiaohe`）。共享核心只做枚举透传：`GcScheme` 追加六个值（`0`／`1` 旧值不变，未知数值与未知 ID 回退小鹤），`gc_normal_update` 按方案构造对应的 `libime::ShuangpinProfile`，全拼仍走 `setUseShuangpin(false)`。新增附加导出 `gc_scheme_id`／`gc_scheme_from_id` 作为 `settings.json` 的 `inputScheme` 字符串与枚举的唯一映射（未升 ABI，不破坏现有布局），`settings_contract.cpp` 的 `inputScheme` 白名单改用同一映射，未知 ID 仍回退 `xiaohe`。
- **修复：分号键在微软／紫光里是 `ing`**。组合中该键命中本方案键位集（`ShuangpinProfile::validInput`）时按拼音键继续组合，否则微软双拼与紫光双拼无法输入任何 `ing` 韵母；未使用分号的方案（如小鹤）保持「组合中标点上屏」原行为。
- **Windows**：设置页「输入方案」下拉改为八项（小鹤双拼／自然码／微软双拼／智能ABC／紫光双拼／拼音加加／国标双拼／全拼），显示名与 ID 同表维护，映射走共享核心；代理 `applySettings` 原先把字符串比较结果当 `bool` 传给 `scheme` 参数（只能区分小鹤与全拼），改用 `gc_scheme_from_id`。x64 交叉编译通过，设置页 UI 未运行。
- **Mac 待接**：`macos/Sources/GogakuKit/Settings.swift:191` 的 `InputScheme` 枚举与 `NormalInputPage` 单选列表仍只有小鹤／全拼；本仓库改动未触碰 `macos/`（并行改「完整版内 Lite 模式」）。接上时新增六个 case 并把 `InputController`／`EngineHub` 的 `Int32(GC_SCHEME_...)` 映射改为按 ID 走 `gc_scheme_from_id` 即可。
- **测试**：`normal_session_test` 新增 `shuangpin_schemes` 向量（六方案 × 你好／今天／平，含上屏与未知方案回退、分号键两种行为）；`settings_contract_test` 新增六个 ID 保留向量与 `gc_scheme_id`／`gc_scheme_from_id` 往返、未知 ID／数值回退断言。核心 ctest 10/10 通过。
- **未做**：用户裁决清单里的「吕氏双拼」在 libime 1.1.17 与公开双拼方案里都没有对应键位表（`ShuangpinBuiltinProfile` 只有上列八项）；自造键位表会变成第二份契约实现，因此本轮以紫光双拼与国标双拼替代，是否另加吕氏需用户提供键位来源。

### 变更（2026-11-18：完整版内 Lite 模式，工作区）

- **新增：完整版可在运行时切到 Lite 观感**。完整版（编译期无 `GOGAKU_LITE`）学习入口全隐藏、英文释义关闭，学习数据、凭据与用户偏好原样保留，随时切回；Gogaku Lite 独立安装包不参与本功能，行为不变（没有学习代码，不显示引导、不加开关）。三个用户可见行为：①首次打开设置应用时一次性「选择你的使用模式」（完整／Lite 两张卡片；选择后不再出现，未选择就关窗下次仍显示）；②设置侧栏底部常驻「Lite 模式」开关；③Lite 生效时设置只留四页（普通输入／自定义词语／皮肤／快捷键）、快捷键页隐藏「普通／学习」「学习方向」两项、普通输入页「显示英文释义」置灰并注明原因、⌃⇧K／⌃⇧J 交还宿主不切换、竖排注释与横排释义行同时关闭。
- **存储与契约**：`settings.json` 新增 `liteModeEnabled`／`modeOnboardingCompleted` 两个布尔字段（可选解码默认 `false`，`schemaVersion` 仍为 2）；读侧规范化仍只有共享核心一份（`shared/GogakuCore/settings_contract.cpp`：布尔类型校验、默认 false），`settings_contract_test` 新增缺键／显式保留／类型不符／schema 1 迁移四组向量。Lite 模式只改生效值：不覆写用户存储的 `glossEnabled`，切回完整模式即恢复；学习门禁收敛为 `Settings.learningEnabled`（学习翻译已启用且未处于 Lite 模式），输入法、共享学习会话与设置页共用这一处判断。
- **Mac 实现位置**：`GogakuKit/Settings.swift`（字段、`effectiveGlossEnabled`、`learningEnabled`、`ConfigurableCommand.uiCases(liteModeEnabled:)`）、`GogakuSettings/ModeOnboarding.swift`（引导视图与「只显示一次」判定）、`GogakuSettingsApp.swift`（`SettingsPage.visibleCases(liteModeEnabled:)`、侧栏开关、页头模式徽标）、`NormalInputPage`／`ShortcutsPage`、`GogakuInput/InputController.swift` 与 `EngineHub.swift`（门禁、竖排注释与横排释义行两处消费点、快捷键交还宿主）。
- **菜单**：Mac 输入法菜单自 2026-11-04 起只保留「设置…」入口，本来就没有学习模式切换项，因此本轮不新增也不隐藏菜单项；Lite 的学习快捷键是同一条门禁下的表现（交还宿主，不切换）。
- **测试**：Swift 新增 `LiteModeTests` 8 项（字段编解码与共享契约规范化、引导只显示一次、`visibleCases` 过滤、`uiCases` 过滤与冲突范围、学习门禁、释义生效值），Lite 形态下同组用例另跑一遍；fast 档通过。
- **文档与 Windows**：`docs/product.md`、`docs/feature-parity.md` 同步。Windows 本轮不改 UI：两个字段已经由共享契约规范化，设置页与代理仍按原七页、无 Lite 开关运行。
- **未验证**：真实输入源里的外观与交互（引导排版、侧栏开关、置灰行、释义消失、⌃⇧K 交还宿主）尚未在真机验收，本条目只代表实现与自动化测试通过。

### 0.1.5（构建 113，stable 定版，2026-11-12）

- **行为变化：皮肤支持编辑当前主题与内置主题原地修改**。新增「编辑当前主题」，直接打开正在使用的主题（当前为旧默认 `rime-macos-like` 或已应用主题失效回退到它时，打开 Gogaku），与列表选中项无关。内置主题不再只能「复制并编辑」：修改以相对出厂数据的 JSON Merge Patch（RFC 7386）存入 `settings.json` 顶层字段 `builtinThemeOverrides`，补丁之外的字段继续跟随出厂数据，可一键「恢复默认」；列表副标题对有覆盖的内置主题显示「内置 · 已修改」。
- 编辑正在使用的主题时保存按钮显示「保存并应用」，同一次写入设置 `candidateTheme`，保存后立即生效（从 `rime-macos-like` 保存 Gogaku 后切换到新主题渲染）；编辑其他主题仍只保存、不自动应用。草稿与出厂数据完全一致的保存等于恢复默认。「复制并编辑」复制列表中看到（已套用补丁）的版本。
- **实现位置**：合并与求差只在共享核心（`gc_themes_effective`／`gc_theme_override_make`，`shared/GogakuCore/theme_contract.cpp`，附加导出、未升 ABI），读侧规范化在 `settings_contract.cpp`（非对象整体丢弃、非内置 ID 丢弃、剥除 `id`、空补丁丢弃）；两端只做 JSON 搬运与本端校验。套用后超出本端范围的单条内置主题回退出厂版本，旧默认 `rime-macos-like` 始终用出厂配色与历史渲染。Mac 输入法渲染取缓存的 `Settings.resolvedCandidateTheme`，Windows 取缓存的 `effectiveBuiltinThemes`。
- **测试**：共享核心 `theme_contract_test` 新增空补丁逐字节相同、改名／改色／改 visual、`dark:null`、为单色主题添加 `dark`、`id` 与未知 ID 忽略、非法 JSON 与参数错误，以及求差往返、最小补丁、数值 14 与 14.0 等值；`settings_contract_test` 新增覆盖字段规范化向量。Mac `CandidateThemeTests`／`SettingsStoreTests`／`SkinEditorSessionTests` 覆盖套用、非法回退、别名不受影响、读改写字段保留与原地编辑 dirty。Windows 交叉编译通过（x64 设置程序、x64／x86 TSF 链接）；新增 `probes/build-windows-theme-fixture.py` 构建 `resolvedTheme` 夹具，自检包新增 `settings_contract`／`theme_contract` 两项。
- **文档**：`docs/skin-themes.md`、`docs/product.md`、`docs/feature-parity.md` 同步；定稿原型未改。
- **验证**：fast 档 7/7（ctest 全量＋swift 测试）、完整 release 档与双端安装包见发布记录；共享核心改动后补 ASan／UBSan 冒烟（2000 序列 ×8 片）通过。
- **验证边界**：host 档按用户 2026-11-12 决定豁免，未运行真实宿主注入；Windows 夹具与设置页未在 VM 运行，Mac 设置页内手动检查（改色后「保存并应用」、恢复默认、从 `rime-macos-like` 切换到 Gogaku、复制已修改的内置主题）尚未执行。豁免理由与未运行 host 的事实同时写入发布说明与 `release-state.json`。

### 0.1.4（构建 112，stable 定版，2026-11-11）

- **修复：设置应用关窗即退出，不再常驻 Dock**。从输入菜单打开设置后关窗只关窗口，SwiftUI `Window` 应用默认不因最后窗口关闭而退出，进程与 Dock 图标一直留着（本次实测到跨夜驻留的旧进程）。现在关掉最后一个窗口即终止；退出前置 `.terminateLater`，等 `SettingsStore.flushForTermination` 把 300ms 合并中的文本改动落盘再退，2 秒兜底保证不退卡住。
- **修复：模式切换提示浮层位置**。中／英、学习·中→英、普通、译文失败提示改走 `ToastAnchor`，与候选窗首键同一套规则：屏幕外／非有限的宿主读数作废（否则几何层只会把它钳到屏幕左上角）；与同一输入框上一组合锢点跨多行跳变时判为陈旧读数；回退顺序与 `AnchorFallback` 同序（本次读数 ＞ 上一组合锢点 ＞ 鼠标位置）。修 Orca 终端里提示被甩到屏幕左上角／无关位置（该宿主无组合时按选区读到的是 shell 行或垃圾坐标）。
- **行为变化**：自动检查更新只在设置窗口打开期间按 24 小时节流尝试（关窗即进程结束）；需要检查更新就重新从输入菜单打开设置。
- **验证边界**：fast 档 7/7（报告绑定双端安装包），release 档通过；host 档位按用户 2026-11-11 书面豁免未运行（与 b110 同图：宿主探针需占用桌面、浏览器宿主探针仍未跑通），发布说明与 `release-state.json` 已写明。真实宿主由用户在 dev 0.1.4-dev.1 b111 上确认：Orca 终端里首次与连续切换提示均回到光标上方，设置应用关窗后不再残留 Dock 图标。

### 变更（2026-11-11：切换提示浮层锚点参照候选窗方案重做，Orca 终端不再跑偏，工作区）

- 用户报告：候选窗定位修好后，Orca 终端里的「中／英」「学习·中→英」提示浮层仍会跑到屏幕左上角或其他位置。原因同上一轮候选窗那次：该宿主**无组合**时按选区读到的矩形是陈旧值（pi 启动前 shell 行，屏幕顶部），而组合期才可用的索引 0 读数在无组合时不可靠（Host.m 按契约只在组合中使用它），提示又恰好在无组合时触发。
- 修复：新增纯函数 `ToastAnchor`，与候选窗首键**逐条对齐**：屏幕外／非有限的宿主读数一律当作「没有读数」（候选窗遇到这种锚点由 `PanelPlacement` 返回 nil 直接不显示，提示必须显示，于是退回下一个来源）；回退顺序与 `AnchorFallback` 同序：本次读数 ＞ 同一输入框上一组合锚点（换字段／失焦即清）＞ 鼠标位置；本次读数与上一锚点相差跨多行时按 `AnchorPlausibility` 判为陈旧并保留上一锚点。`InputController` 的四处提示改走 `toastAnchor()`，组合中不再多读一次宿主；屏幕几何统一走 `GogakuInputController.screenFrames()`。
- 边界：本输入框尚无已验证锚点（换字段后第一件事就是切换）时仍只能信任宿主读数（与候选窗首键同待遇）：屏幕外的垃圾坐标已拦住，屏幕内但陈旧的读数仍会偏；同一应用内换输入框后未打字就切换，提示可能停在上一个输入框。
- 测试：`ToastAnchorTests` 7 项（陈旧跳变被拒、同行前进采纳、屏幕外读数回退、零读数回退、屏幕外参照被忽略、全不可得不显示）；fast 档 swift-tests 233 项通过。

### 变更（2026-11-11：设置应用关窗即退出，不再常驻 Dock，工作区）

- 用户报告：设置页长时间挂在 Dock 栏。实测本机设置进程从前一晚起一直在跑、无任何窗口——从输入菜单打开设置后关窗只关 NSWindow，SwiftUI `Window` 应用默认不因最后窗口关闭而退出，进程与 Dock 图标一直留着。
- 修复：`SettingsAppDelegate` 关闭最后一个窗口即终止应用（`applicationShouldTerminateAfterLastWindowClosed`）。退出前用 `.terminateLater` 等一次落盘，把 300ms 合并中的文本改动写完再退出（新增 `SettingsStore.flushForTermination`，无待保存改动也回调），2 秒兜底保证不会卡在退出中；皮肤草稿的离开门禁不变。
- 行为变化：自动检查更新只在设置窗口打开期间按 24 小时节流尝试（关窗即进程结束）；关窗后再从输入菜单打开设置会重新启动设置应用。
- 验证：源码 release 构建实测关窗 3 秒内进程消失、退出请求正常结束、无残留进程；新增 `SettingsStoreTests.testFlushForTerminationWritesPendingThenCallsBack`，fast 档 swift-tests 226 项通过。装成 `.app` 后从输入菜单再次打开未复测（下次构建安装后核对）。

### 变更（2026-11-10：项目自身许可定为 MIT 并致谢青简／Rime，工作区）

- 新增仓库根 `LICENSE`（MIT，Copyright (c) 2026 gomeen）；README 许可节改写并新增致谢段：青简输入法＝候选窗样式与学习交互的设计对照参考，Rime＝开源输入法社区的先行实践，均未复制其代码、词库或数据。
- 同步清除「许可尚未决定」表述：`AGENTS.md`、`docs/third-party.md`（公开分发前待办清单去掉「自身许可决定」，其余义务不变）、`docs/product.md`、`docs/versioning.md`、`docs/input-selection-decision.md`、`docs/validation/engineering-readiness.md`。
- MIT 不改变第三方义务：libime／Fcitx5Utils／KenLM 等 LGPL-2.1-or-later 组件的源码提供与重链接材料、CC BY-SA 4.0 数据的署名与相同方式共享照旧；已构建安装包内的 THIRD-PARTY.md 副本为历史快照不追溯修改，下次构包自动更新。

### 0.1.3（构建 110，stable 定版，2026-11-10）

- 首次 stable 定版，含普通应用临时英文 Esc 修复、Orca 终端候选窗定位修复、双通道 IMK 连接名修复。
- 发布流程：取消 rc，定版号固定、失败只递增构建号；host 分短档／完整档；release／host 报告按 Mac 平台指纹沿用；ASan 分片并行；验证期间防睡眠；定版可经书面理由豁免 host（本版即如此，发布说明已写明）。
- 未运行 host 真实宿主验证，边界见 [验收记录](docs/validation/native-development.md)。

### 变更（2026-11-10：Orca 终端打开 pi 后候选窗钉在顶部，构建 105 dev，真机待验证）

- 诊断构建 104 实测（Orca 终端，`/tmp/gogaku-diag-b104.log`）：首键前按文档绝对位置读到的是 pi 启动前 shell 行的陈旧矩形（屏幕顶部）；组合期间索引 ≥1 全为零，只有索引 0（IMKTextInput 契约：相对 inline session，0＝组合起点）落在真实输入行；面板因此全程冻结在顶部。无组合时索引 0 读数在相邻字符格间循环，不可靠。
- 修复：`Host.m` 组合中按插入点读不到有效矩形时回退读索引 0；首键 pre-read 与无锚点回退标为临时锚点，组合内首个有效读数直接取代，不经瞬移过滤。插入点矩形有效的宿主（原生文本框）行为不变。
- HostTests／AnchorPlausibilityTests 32 项通过；Orca 终端／聊天框、Chrome、企业微信、备忘录真机待用户验证。

### 变更（2026-11-10：普通应用临时英文不再被 Esc 切回中文，工作区）

- 用户报告：Shift 切临时英文直输后按 Esc，输入法立刻弹「中」切回中文且吞键。根因在共享核心 `GC_EV_ESC`：无组合时只要当前中英态偏离应用默认就无条件复位，把普通应用的手动临时英文（Temp）也切回中文——超出 product.md 编辑键行的授予范围（「Esc 回默认」只属于按应用默认英文的应用）。该分支自基线提交就存在，核心测试只覆盖了 Raycast 场景故未暴露。
- 修复：核心复位条件收窄为「按应用默认英文应用且未在默认态」，普通应用临时英文下 Esc 透传宿主、状态不变（退出临时英文仍只有 Shift 单击一条路）；两端共用同一实现，Windows TSF 经 shouldClaim 吃键后按 core `consumed=false` 放行，无需平台侧改动。
- 核心回归：普通应用「Shift→Temp→Esc 状态不变且透传→Shift 回中文」入 `esc_misc` 轨迹；应用默认英文场景断言不变。核心 ctest 10/10、fast 档位 7/7（含 Swift Release 221 项）通过；真机体验待用户验证。

### 变更（2026-11-09：修复双通道 IMK 连接名冲突，构建 102 dev）

- b101 真机发现：IMKServer 连接名硬编码 `Gogaku_Connection`，stable 与 dev 两通道同名。stable 进程存活时 dev 端点注册被 imklaunchagent 拒绝（`Refusing connection name for bundle: unrecognized 'InputMethodConnectionName' value`），表现为 dev 输入源选中即回弹、进程拉不起、输入菜单无可用入口；此前 dev 能用只是因为 stable 输入源未启用、无进程占名。
- 连接名改为按 bundle ID 派生（`org.gogaku.inputmethod[.dev]_connection`），两通道可长期并存。本机 dev 选中验证：选中后保持不回弹，无拒绝日志。
- 企业微信兼容内容与 b101 相同（候选窗无锚点回退＋Shift 释放沿兑底）；详见[原生验收](docs/validation/native-development.md) 2026-11-09 节。

### 变更（2026-11-09：企业微信兼容——候选窗无锚点回退与 Shift 释放沿兑底，构建 101 dev）

- 企业微信里打长段落：前几个词有候选窗，后面消失但空格上屏一直正常，Shift 切换也无提示。两个根因都在显示层：词首定位是全组合唯一锚点机会，该宿主对插入点矩形查询随段落增长返回无效且组合中不恢复（同 Orca 零矩形形态），一次失败整词隐藏；Shift flagsChanged 只投按下沿，旧轮询兑底「全程无事件才代发」守卫被按下沿满足，与事件通路一起静默。
- 候选窗：词首 pre-read 无效时按「上一组合锚点＞鼠标位置」回退显示（新增 `AnchorFallback` 纯函数；字段证据丢失期间不回退），组合中读到真实矩形即由既有位置复查与瞬移过滤器纠正；换字段／失焦清回退锚点。Orca 等词首可读到锚点的宿主行为不变。
- Shift：轮询兑底改「释放沿证据」确认制（200ms 确认窗），释放沿被吞／以杂修饰判死时代发；事件通路按下沿缺释放沿导致的单击注册卡死增加超窗自愈；代发后失效残留按下沿防迟到二次触发。正常宿主与 Orca 双投递不双发。
- AnchorFallback 断言 7/7 通过（swiftc 独立验证）；企业微信真机验收待用户空闲时段执行；详见[原生验收](docs/validation/native-development.md) 2026-11-09 节。

### 变更（2026-11-08：Windows 冷启动与版本目录升级，构建 94 dev）

- TSF 激活阶段预热代理，最多等待 5 秒连接与握手；逐键路径不新增启动等待，不缓存或重放按键。增加独立延迟假代理的双架构连接回归。
- Inno 将程序、数据和许可放入受管理版本目录，保留固定安装根和卸载入口；双架构注册失败时恢复旧注册与路径指针，迁移已启用的既有自启动项。新 TSF 从受保护的当前／上一根解析代理，旧版本文件保留。
- b94 双端包重建、fast 7/7；Windows 默认升级在旧 b93 DLL 保持加载时成功，71 个文件、注册、迁移与数据保留通过。双架构各两次冷启动及各一次暖启动提交“你好”，七页设置回归通过。完整恢复／卸载矩阵与其它宿主未验收，Mac b94 本轮未安装；详见 [b94 证据](docs/validation/dev-b94.json)。

### 变更（2026-11-08：双端开发安装包重建，构建 93 dev）

- `.gitignore` 补充本地凭据、私钥／证书及 IDE 用户文件规则；构建缓存、安装包和本机数据继续留在忽略目录，现役源码和验证证据保留。
- 退役早期 `input-flow.html` 及 10 张旧／重复截图；保留输入习惯、设置和皮肤三份定稿原型及输入习惯生成链，补充 `prototypes/README.md` 说明边界。
- 重建双端 b93 安装包；Mac PKG 实际安装、安装后包检查和 dev 通道 14 项 IMK 冒烟通过。Windows 在独立目录安装，71 个清单文件核对通过，双架构新建 Edit 暖启动和七页设置检查通过。fast 7/7、核心 10 项、Swift Release 217 项通过。
- Windows 冷启动第一组仍失败，默认目录升级因旧宿主占用返回 7，均保留失败证据；完整 release／host、在线翻译／更新及升级恢复／卸载未验收，未公开发布。详见[原生验收](docs/validation/native-development.md)。

### 变更（2026-11-08：退役旧选型与修补验证门禁，工作区）

- 删除旧引擎／本地翻译模型的比较、下载转换、排名、运行结果和展示页；保留 libime 采用理由、固定依赖消费者、通用双向考题和现役输入法测试。当前火山结果归位 `probes/results/volcengine/`。
- fast／release 退役旧评测和 quickmt worker 检查，改为通用翻译数据及验证门禁正负例；发布报告须匹配策略版本、必需清单、源码／测试身份和当前双端包。CTest 跳过／零测试、缺 GUI、测试期间源码变化均不能冒充通过。host 目前仅支持 stable，dev 明确 blocked。
- 生产火山客户端新增离线 HTTP 异常回归，覆盖认证／限流／服务错误、空／坏／超大响应、超时／断网、凭据热读和重定向拒绝。空 TranslationList 明确返回 emptyOutput。
- 修复迁移后的渲染模块／构建路径、隔离构建根与 Windows CI 路径；离屏光标断言更新为当前字形排版。fast 七项、Swift Release 217 项与渲染 53 项通过；完整 release、真实 host、Windows 运行、安装升级和真实在线调用未执行，不标完整发布通过。详情见[清理与测试审查](docs/validation/testing-cleanup-audit.md)。

### 变更（2026-11-07 追加：仓库按 shared／macos／windows 分层重组，dev）

- **目录按功能分层**：双端共享的契约核心迁至 `shared/GogakuCore`（连带 `shared/third_party`、`shared/licenses`）；Mac 全部 Swift 源码（含 `Package.swift`、`Tests`、libime 桥 `EngineBridge`、pkg postinstall）集中到 `macos/`；`GogakuTsf`、`GogakuWindows`、Inno 安装器模板与 `Gogaku.ico` 迁至 `windows/`。`native/`、根级 `packaging/`、根级 `assets/` 取消。
- **消除一名三义**：Swift 包装层 target 由 `GogakuCore` 改名 `GogakuKit`（目录、target、测试 target 同步改名），此后「GogakuCore」只指共享 C++ 核心与其 C ABI（`CGogakuCore`）。测试 target 更名 `GogakuKitTests`。
- **引用同步**：构建与验证脚本、CI 路径过滤、Windows 侧相对 include 与 `app.rc` 图标路径、探针与文档指针全部更新；Swift `swift build`／`swift test` 需带 `--package-path macos`。历史研究记录（`docs/research-translation-quality-*`、`probes/results/**`）与历史变更条目保持原样，不改写。
- **行为不变**：本变更只移动文件与更新指针，不改动任何契约逻辑与产物形态；构建输出仍在仓库根 `.build/`（native／core／swift 三个子目录），dist 产物布局不变。

### 变更（2026-11-07 追加：设置与主题契约进共享核心，dev）

- **设置契约只有一份实现**：新增共享核心 `settings_contract.cpp` 与 C ABI `gc_settings_normalize`／`gc_contract_free`（附加接口，不升 ABI 版本）。读侧规范化（默认值、类型饱和、schema 1→2 迁移、未知字段保留）两端统一；Mac `Settings.load` 与设置合并基线改走契约，Swift 侧迁移分支删除；Windows `platform.cpp` 的默认值字面量与迁移删除，四个二进制（双位数 TSF、代理、设置应用）以静态方式编入同一实现。修复三处真问题：清除的快捷键不再被回退复活；缺 `appDefaultEnglish` 不再丢出厂清单；超范围整数不再回绕落盘。
- **内置主题只有一份数据**：新增 `theme_contract.cpp` 与 `gc_themes_builtin`，四套内置主题（Gogaku／Claude／Grok Bot／女巫魔药）的调色板与排版仅此一份；Mac `BuiltinCandidateThemes` 与 Windows `themes.cpp` 改为消费契约，「Exact semantic palettes from …」式注释对照删除。锚点色（含产品规格 #12996a）由两端共跑的 `theme_contract_test` 冻结。
- **对拍向量双端共跑**：`settings_contract_test`（35 组）与 `theme_contract_test` 进入 Mac ctest 与 Windows 单文件自检包，同一份 C++ 源码。共享第三方 `json.hpp` 上移 `native/third_party` 供核心与 Windows 共用。
- **计划裁决**：更新清单验签与火山签名的抽取经用户裁决不执行，两端各自实现维持；已在[实施计划](docs/implementation-plan.md)登记为「共享实现规则」的已登记例外。
- **外围收敛**：删除 74 个零引用文件（一次性脚本、判废探索原型与截图、退役后端探针），`docs/validation/verify` 按「引用＋档位最新」保留策略收敛（删除 279 个零引用历史运行，文档引用的 18 个与 host 全家族保留）。
- **验证**：fast 7/7；core ctest 10/10（含两组契约向量）；Swift Release 207 项；x64 交叉编译四产物齐全、DLL 导出表核对；ASan／UBSan 2,000 序列冒烟无错误。**Windows VM 运行自检与真实读盘重验待用户执行，未跑前双端不标统一。**

### 变更（2026-11-06 追加：英→中首键即显回归修复，构建 88 dev）

- **用户报告**：学习英→中输入 hello，打到 o 附近候选窗才弹出（开头输入像没被记录）。缓冲与翻译链路完整（核心轨迹测试保证），是面板显示回归：`refreshDisplayPosition` 残留首键即显之前时代的守卫「en→中候选为空就不显示」——首键矩形不可用时 publish 跳过渲染、位置复查拿到矩形也被拦，要等首条译文才显示。
- **修复**：以显式「宽限隐藏已执行」标志取代旧守卫；首键即显后位置复查正常补显与跟随，译文到达原地补候选，停下且无译文仍按 0.7s 宽限收起。fast 验证 6/6。

### 变更（2026-11-06 追加：Windows 记事本兼容与设置展示，构建 91 dev）

- Windows 设置改为七项侧栏、固定页头／状态栏、DPI 缩放和微软雅黑 UI，补齐程序／安装器图标；200% 缩放下七页和最小窗口九条预览有运行证据。
- 修复旧连接迟到失焦清空当前组合、启动时词表监控误触发重置；普通模式不再初始化未使用的学习会话。
- 缺少 InputScope 时新增受限原生 RichEdit 兜底，修复新版记事本无候选；保留焦点／文档归属、密码／只读／禁用检查。新增双连接焦点和双架构字段安全探针。
- [构建 91 证据](docs/validation/windows-desktop-b91.json)记录记事本候选与“你好”提交、双位数 Edit、设置和图标；**冷启动第一组输入仍有失败，不是稳定版**。安装前曾人工迁走占用文件，不代表普通升级验收。

### 变更（2026-11-06 追加：Windows 实际安装 EXE，构建 88 dev）

- 补齐 Mac 上 MinGW-w64 双位数 TSF 与 x64 代理／设置／核心的交叉编译链；Wine 仅运行官方 Inno Setup 编译器，生成实际安装向导 EXE，无外装 Python／GCC／Visual Studio 运行要求。
- Windows TSF 经当前用户／会话／通道命名管道连接代理；接通普通设置、自定义词、持久化、提交确认、非激活候选窗、主题渲染、火山请求、系统拼写、全局模式与方向、托盘和检查更新；普通词库与许可随包。
- 安装器核对 Windows 11 x64、双架构注册退出码、文件占用、原用户可选自启与卸载清理；保留用户数据，不设置默认输入法、不强杀宿主或自动重启。
- 新增[Windows 使用说明](docs/windows-testing.md)，同步[功能状态与缺口](docs/feature-parity.md)及[构包证据](docs/validation/windows-setup-build.json)。按用户确认，本轮不执行 Windows 程序、不做 VM／真机验证，安装运行交用户。当前包仍有多候选预译、随包 WebP 解码、版本化升级恢复等实现缺口，不能称为双端完整功能通过。
- 关键回归 fast 7/7（Swift Release 193 项）；ASan／UBSan 2,000 序列冒烟无错误，完整 release gate 未执行。

### 变更（2026-11-06 追加：学习英→中两处修复，构建 88 dev）

- **拼写波浪线接通**：拼写结果此前只写控制器本地快照，逐键发布（以及译文到达重发布）会用会话视图覆盖丢失，且译文未就绪阶段不渲染——波浪线实际上不可见。修复：结果经引擎队列 `setIssues` 写入共享学习会话（核心按同修订 stamp 拒绝过期结果，编辑使旧范围失效），随 `publishLearning` 渲染；拼写 helper 路径与翻译共用同一解析规则（`LearningTranslation.serviceConfiguration().executable`）。根因佐证：`CompositionSession.setIssues` 自首次提交起无任何调用方（死代码），`--spell` helper 本机实测正常（`helo metting ` 判出两处 issue）。
- **学习中→英 Enter／⌘Enter（用户裁决落地）**：Enter 改为选就绪目标（不再提交剩余原编码；译文就绪即上屏英文，未就绪先上屏中文源文再异步换译）；⌘Enter 明确原文上屏（中文源文不换译直接上屏，此前交还宿主）。英→中 Enter 选就绪中文／⌘Enter 原文上屏行为不变（规格表本来就一致，未改代码）。
- **验证**：fast 档 7/7（Swift Release 193 项含新增 `CompositionSession` 拼写范围合同用例：setIssues 入视图、编辑不清空、过期 stamp 拒绝、方向守卫）；构建 88 dev 已本机安装（manage-install dev 通道）。**真实宿主按键／波浪线显示未验收**（host 档需空闲时段执行）。

### 变更（2026-11-06 追加：双端功能统一——火山收敛、事务安装、检查更新）

- **文档与合同（P0）**：新增[双端功能对照](docs/feature-parity.md)、[检查更新合同](docs/update.md)，重写[实施计划](docs/implementation-plan.md)、[发布流程](docs/release.md)、[版本管理](docs/versioning.md)、[第三方边界](docs/third-party.md)、[开发版说明](docs/native-development.md)与 README；明确 Mac 只交付 pkg、不再生成 DMG，Windows 目标 Inno Setup，自动检查默认关闭，本地模型退出产品链路。
- **翻译收敛（P1）**：移除 quickmt／small100／Python 后端、beam、模型准备与下载入口；新增随包 `GogakuTranslator --volcengine`（CryptoKit HMAC-SHA256 V4 签名＋URLSession）与 `Sources/GogakuCore/Volcengine.swift`；设置页改为火山凭据保存／移除、连接测试、状态与本机字符统计。设置 schema 升 2：旧本地模型配置迁移为**关闭学习翻译**，已启用火山配置保留启用、凭据与用量；新安装默认关闭。请求体与签名用 Python 参考 worker 固定向量逐字节比对；缓存命中带 `cached` 标记，不重复计入本月字符统计。
- **安装（P4，Mac）**：`package-macos-pkg.py` 改为打包阶段注入输入源身份并由内向外签名（Developer ID 或 ad-hoc），再打 zip；新增 Developer ID Installer 签名、notarytool 公证、stapling 与 `spctl` 评估参数；安装器增加完成页。`scripts/pkg-postinstall.sh` 只校验包内身份／构建号／签名，不再重签（保留 Developer ID 签名），事务式备份／替换／失败恢复，状态留 `~/Library/Application Support/Gogaku/install/transaction.txt`。`manage-install.py` 改为 staging＋备份＋失败恢复并校验构建号；`recover` 读取事务记录。删除 `package-macos-dmg.py` 与 DMG 产物／指引。
- **检查更新（P5，Mac）**：新增 `UpdateContract/UpdatePreferences/UpdateTransport/UpdateEngine/UpdateDownloader` 与设置更新窗口：Ed25519 清单验签、GitHub 列表分页／ETag／限流、通道与构建号比较、平台／架构／minOS、HTTPS 主机白名单、下载大小／SHA-256／原子缓存、取消、安装交接；自动检查默认关闭、24 小时节流、只在设置应用运行。随包 `resources/update/config.json` 带开发公钥；发布脚本 `update-signing.swift`、`make-update-manifest.py`、`publish-release.py`（Draft→上传→真实 asset id→签名清单→人工发布）。
- **Windows 组装（P4，脚手架）**：新增 `packaging/windows/gogaku.iss.in`（Windows 11 x64、双位数 TSF 注册、Program Files、HKCU 自启、卸载默认保留数据、不强杀宿主）与 `scripts/build-win-app.py`（产物检查、staging、身份哈希、iss 渲染、iscc 调用；缺产物明确失败）。
- **验证**：Swift Release 192 项全过（新增 Volcengine、Update、设置迁移用例）；`make-update-manifest.py --self-test`、`build-win-app.py --self-test` 通过；火山签名／请求体与 Python 固定向量一致；更新协议用注入传输覆盖分页／304／限流／坏签名／通道隔离／架构与 OS 不支持／下载校验。**未验证**：真实火山凭据实测、真实 GitHub Releases 链路、重打包 pkg 真实安装／升级、Windows Setup 编译与安装、Windows 检查更新、完整宿主矩阵与性能门槛。历史 DMG 条目仅作记录，当前交付不再包含 DMG。

### 变更（2026-11-06 追加：中→英预译防抖加固，构建 87/88 dev）

- **用户报告**：学习模式中→英输入停止后译文（高亮候选的英文注释）有时不出现。排查确认防抖定时本身正常，缺陷在三处周边结构。
- **修复**：① 预译结果改为先把注释写入组合视图（只受代次门控），坐标不可用时位置复查恢复显示即带出译文——此前渲染只有一次机会，失败后泵按缓存判定完成，译文永不显示（主因）；② 预译泵遇在飞请求加 0.25s 兜底重泵（上限≈10s），消除慢结果／丢结果导致的无限期停摆；③ 预译失败按源文计次（同组合内超 2 次不再自动重发），消除失败无限重试的 busy loop；④ 组合结束（suspend）复位预译泵状态，残留 inFlight 不再阻断新组合。
- **顺带**：预览口径勘误——仅高亮候选行内注释显示英文（覆盖五点五「状态行显示」旧表述），映射抽为纯函数 `CompositionView.annotatingHighlight` 并新增 5 项回归测试；`TranslationService` 排队请求可被同服务后发请求静默抹除的隐患已记录待评估。fast 验证 6/6 全过。

### 变更（2026-11-06 追加：TSF 首次 MSVC 编译成功＋VM 实装测试闭环）

- **里程碑**：GogakuTsf.dll（Windows 输入法接入层）首次在 VM 内用 MSVC 编译链接成功（/MT 静态 CRT，无 redist 依赖）；核心 DLL（HEAD＋rename/fsync 注入）同步构建；VM 内组装运行目录（TIP＋核心＋4 个 MinGW/msys 运行库＋词库数据）并 regsvr32 注册成功；自动化打字测试闭环（交互会话计划任务＋SendKeys＋候选窗探测＋截图）建立。**实测：TIP 在应用内激活成功（DLL 加载、核心会话创建 OK）**。
- **修复**：键盘类别 GUID 误记（真值 {34745C63-B2F0-4784-8B67-5E12C8701A31}，原误记 {34745CFF...}）；结构镜像微软拼音（Description/IconFile/IconIndex/10 项类别）；接口名勘误（SDK 无 ITfFocusSink，文档焦点通知用 ITfThreadMgrEventSink 双参数 OnSetFocus）。
- **未解阻塞（下一步主攻）**：Windows CTF 持续把 Gogaku 从用户启用列表剔除（添加后数分钟内消失，Win+Space 永远轮不到）。已排除：TIP 激活失败（实测激活 OK）、注册表结构（已镜像）、COM 注册 API 参数（E_INVALIDARG 全变体）、老接口（现代系统 E_NOINTERFACE）。候选路径：人工 UI 添加验证、CTF 事件日志取证、对 Squirrel 运行时注册做逆向对照。

### 变更（2026-11-06 追加：Windows 落地决策＋TSF 工程就绪）

- **用户裁决四项**：翻译后端与 Mac 同源同栈（嵌入式 Python＋同哈希 small100 模型随包，否决 ONNX 重写）；设置应用 Win32 原生；安装包直接做安装向导（Inno Setup）；不签名。已记入实施计划。
- **TSF 前端补齐至可编译**：新增 COM 入口与注册（dllmain.cpp——CLSID/CTF TIP/zh-CN 语言档案/键盘类别，regsvr32 对称装卸）、导出定义（.def）、CMake 工程（MSVC/utf-8）；连同此前骨架（按键路由/焦点汇/组合管理/候选窗/核心桥）共 10 文件，待 VM 内 MSVC 就绪后编译。

### 变更（2026-11-06 追加：输入源幽灵注册根治，构建 86）

- **用户报告**：添加输入法列表出现两个同名「Gogaku」且「键盘布局不可用」。根因：① dist 产物携带输入源身份键，仓库副本被 LaunchServices 周期扫描注册成同 ID 输入源遮蔽真身（`lsregister -u` 数分钟内被扫回，点目录同样被扫描）；② pkg 的 Scripts 目录里的 .app 被安装沙箱扫描注册，安装后留死路径幽灵。
- **根治（`scripts/_gogaku_dist.py` 共享约定）**：dist 一律中立（剥离 8 个身份键）；安装时目标位注入身份＋ad-hoc 重签——manage-install（哈希按同一逻辑重算校验）／pkg postinstall（随包 Info-tis plist，App 改 zip 携带）／DMG command 三链路一致；check-bundle 按 bundle ID 重建身份；修 dev 通道中文显示名错位。**TIS 实测：org.gogaku 系输入源注册恰好一套，dist 副本零注册**。已卸载双通道并重装构建 86（配置/学习数据完整保留）。

### 变更（2026-11-06 追加：标准安装包——pkg＋DMG）

- **`scripts/package-macos-pkg.py`（推荐）**：用户级 .pkg 安装器（Squirrel 同款路线）——双击向导安装、免管理员密码、无隔离标记；postinstall 落位 `~/Library/Input Methods/`＋`~/Applications/` 并重注册 LaunchServices，升级保留学习数据；内置 welcome/readme（含「添加输入源」引导与未签名说明）。
- **`scripts/package-macos-dmg.py`（备选）**：DMG＋双击安装 command（去隔离＋重注册）。
- 工程坑：productbuild 手写 distribution 的 choice 结构会静默产出 2KB 空壳，必须 --synthesize 基线＋补丁；脚本内置体积断言防带病产物。构建 85 pkg 在本机 `installer` 实装验证通过（构建号/签名/多通道并存核对）。

### 变更（2026-11-06 追加：双通道安装——stable 与 dev 并存）

- **构建／安装／验证三脚本支持 `--channel dev|stable`**：dev 通道装为 `Gogaku Dev.app`（bundle ID 带 `.dev` 后缀 → 独立输入源「Gogaku Dev」），与 stable 并存互不覆盖；用户数据与 Darwin 通知两通道共用同一份（用户裁决）；清单与构建身份分通道文件；跨通道覆盖由 `own()` 哈希校验拦截；`--purge-data` 显式警示影响另一通道。稳定通道建议装 rc／定版，dev 通道装开发构建。

### 变更（2026-11-06 追加：发布与更新流程总览）

- **新增 [docs/release.md](docs/release.md)**：把版本规则、Mac 构建（build.py＋manage-install.py）、Windows 构建（核心 DLL 交叉构建 ✅／TSF MSVC 🚧／设置与安装器 ⬜）、四个交付等级的门槛、发布 checklist、应用更新流程（现状无自动更新；远端仓库＋GitHub Releases＋Ed25519 签名为待裁决决策点）串成一条流水线总览。当前缺口：远端仓库未建（阻塞 CI 与更新分发）。

### 变更（2026-11-06 追加：单文件自检 exe，发现两个 Windows 移植 bug）

- **单文件自检 exe**：`scripts/build-win-selfcheck-exe.sh` 产出全静态单文件 `gogaku-selfcheck.exe`（62MB，零外部依赖），数据目标文件嵌入、运行时解包到 %TEMP%；核心从 git HEAD 隔离副本构建（排除并行会话未提交 WIP）。Windows 11 VM 内**六项全绿**（ABI／翻译加固／普通轨迹／学习轨迹 144 项／质量回归 120 条／随机冒烟）。
- **发现两个真实 Windows 移植 bug**（修复以构建时注入落地，产品化方案随 WIP 合入后上游化）：① MinGW `std::rename` 不覆盖已存在目标（EEXIST），`atomic_write` 第二次起静默失败——删词复活、userlm 重建失败、写失败恢复落盘均由此起；② `fsync→_commit` 对 O_RDONLY 句柄失败而写入路径把 fsync 失败当致命。两 bug 由自检 exe 在 VM 上从「4 项持久化用例失败→插桩定位（errno=17）→修复→全绿」的完整闭环抓出。

### 变更（2026-11-06 追加：普通输入十项整改，ABI v4）

- **上屏安全与数据可靠**：宿主插入异常后不再丢失字母跟踪（残留可清理）；调频只在宿主插入确认后学习（新事件 GC_EV_COMMIT_CONFIRMED）——学习模式中→英、上屏失败不再污染普通排序；清空调频真正清空运行中引擎（新接口 gc_normal_clear_user_data）且失败不再伪报成功；自定义词读取失败（权限/I/O）与「文件不存在」区分（gc_custom_words_read 返 2、新增只读 peek），设置页读取失败暂停保存避免覆盖。
- **日常输入正确性**：短码／拼音词／英文补全被高亮时按标点或 0/超页数字提交「候选＋标点/数字」（不再输出原编码）；单双引号独立配对；同音自定义拼音词按设置页顺序排列。
- **设置生效**：英文候选开关即时生效（gc_normal_update 新增参数）；自定义词保存失败后底栏「重试」真正重写词表。
- **按键**：Ctrl+Enter 暂时去掉输入法消费，普通组合中交还宿主（用户裁决）；快捷键页文案同步。
- **验证口径**：核心 ctest 6/6＋新增专项用例、Swift Release 158 项、ABI4 行为向量 23 项、宿主异常注入夹具 3 轮，隔离环境全过；真实宿主验收未开始，详见验收记录 2026-11-06 节。

### 变更（2026-11-05 追加：Windows 交叉构建＋共享核心自检包）

- **Windows 交叉构建流水线＋核心自检包**（计划 T2.1 的「无本地 Windows」路线）：`scripts/prepare-win-cross.sh` 在 Mac 上用 mingw-w64（GCC 16.2）交叉编译共享核心与依赖（同 pin；POSIX 垫片解包 MSYS2 clang64 包到本地 sysroot；libime 补丁 `scripts/patches/libime-win-cross.patch` 使 Boost iostreams 条件化）；核心从隔离副本构建并注入两项 Windows 兼容修正（fsync→_commit、WIN32 输出目录自引用修正——待核心活跃改动合入后上游化）。`scripts/package-win-selfcheck.py` 打包为一键自检 zip（核心 DLL 链＋6 个测试 exe＋出厂数据＋run.bat 产出机器可读 JSON 报告，不含原文文本）。**Windows 11 VM 内全绿**：ABI／翻译加固 76 项／普通轨迹／学习轨迹 144 项／质量回归 120 条／2000 序列冒烟，run.bat 双击路径复验通过；KenLM／词库格式兼容（Mac 产物在 Windows 加载）直接验证。证据：`docs/validation/win-core-selfcheck/`；口径：VM 为功能级验证，T2.1 验收仍以 CI 绿为准，包发给朋友真机为真实硬件证据。

### 变更（构建 82 追加：学习规则迁入共享 C++ 核心，ABI v3）

- **学习组合状态机／三状态按键语义／翻译调度合同／拼写问题结构迁入共享核心**（`native/GogakuCore/learning_session.cpp`，计划 G1 的 T1.1/T1.2/T1.3）：Swift `CompositionSession` 改为薄封装（事件编组＋epoch→组合 UUID 映射＋候选稳定 ID），行为合同不变；翻译传输（TranslationService／worker）仍在平台侧。英→中英文缓冲、中→英字面/编码片段推导、候选追加不重编号、导航冻结、⌘Return 原文上屏、失败保留输入、拼写问题存取均由核心负责；C ABI 升到 v3（版本 1/2 函数与结构布局不变）。内核拒绝（如撇号开头片段）与历史 decode 抛异常同源走引擎错误路径；回格按字素簇删除（与 Swift `String.removeLast` 同语义：组合标记／VS／肤色／ZWJ 粘接／区域指示符对整簇回退；v1 局限：Tag 旗标不延伸）。共同事件轨迹向量新增学习用例（`tests/learning_session_test.cpp`，144 项检查，与 Swift 行为合同同源出厂数据逐字对齐）；核心插桩构建下学习测试通过。fast 档全过（core ctest 100%、Swift Release 117 项）；ASan 冒烟 2000 序列无错误。Windows 侧验证仍待环境（T2.1）；同轮启动 T2.1 脚手架：MSYS2 Clang64 依赖准备脚本（与 Mac 同 pin 同源数据）＋CMake preset＋windows-core CI workflow——仓库无远端，流水线未经真实 CI 运行，全绿前不标 Windows 验证通过。

## 0.1.1-rc.1（构建 7）— 2026-11-02

相对 0.1.0-dev.1（构建 6）的变更：普通输入修复（Orca Shift 单击、候选窗锚点）、设置页布局重排、翻译加固层第一片入共享核心、菜单图标字形放大；学习模式交付仍保持阻塞（模型质量门槛未重跑）。

- **行内容垂直居中微调（构建 10）**：降部修复后行内不对称变得可见（墨迹中心比率 0.58，偏下约 2pt），序号／汉字／注释三段边距各上移 2pt（indexTopMargin 8→6、wordTopMargin 6.5→4.5），离线渲染墨迹带 34–59 于行高 60px 内上下各 18/17px 居中；渲染回归 58 项、fast 档全过。

### 变更（构建 11 追加：注释清洗规则 v3）

- **候选窗英文注解过长（如「你 you (the person spoken to or written to) · your」）**：注解来自 Wiktionary 逐字定义，旧规则单条 ≤64 字符上限太宽松、正文内括号消歧说明全保留，全库 11% 注解超 60 字符。清洗规则 v3（用户裁决「尽量显示全、不遗漏重要信息」，规则编码在 scripts/build-gloss-data.py 可复现）：① 义项正文内长括号消歧说明（含括号 >18 字符）整体移除、短括号保留；② 单条上限 64→36，超长改词边界截断加 …（替代旧「整条剔除」——截断显式标记不制造完整释义假象，覆盖词条 143,777→160,321）；③ 拼接总长 ≤46 字符（440pt 面板可容纳），超长只保留第一条。效果：「你 you (the person spoken to or written to) · your」→「you · your」；长度分布 p50=25/p90=35/p99=45/max=46。规则版本与产物哈希登记 gloss-sources.json（cleaningRules.v3）。

### 变更（构建 12–16 追加：清洗规则 v3.1→v7）

- **分号同义枚举收紧**：Wiktionary 义项常把同义词全排开（君 sovereign; monarch; ruler; chief; prince; lord），候选窗里是噪音——分号枚举 ≥3 项只保留前 2 项加 …（君 → sovereign; monarch …；菌 bacterium; germ 不变）。另修复 …（U+2026）不在 presentable 允许字符表导致主义项被整条丢弃的回归（词条 147,881→160,347）。

### 变更（构建 13 追加：清洗规则 v4）

- **行内省略号即行尾**：主义项被截断（以 … 结尾）时不再追加后续义项，消除「equal; uniform … · all」这类省略号夹在行中的混乱语序（用户报告）。
- **专名词不再显示 name 前缀**：浚县/均县的「name Xun County」读感差——音译/专名自明，name 前缀与 character 条目不显示词性的口径一致（用户报告）。剩余以 name 开头的行（152 条）均为释义正文（name of a river）。

### 变更（构建 13 追加，无二进制变更：翻译评测第二轮补齐）

- **评测缺口修复＋独立确认集（只评测，不接生产）**：修复第一轮缺口——88 条专项短文本集纳入 `all` 默认加载并加数量断言；按输入长度分桶；延迟门槛改读真实结果（缺数据标未完成，超预算记录逐条保留）；候选放行／语义合格／安全回退／错误放行分开统计；缺失审阅不得报完成。新增每方向 50 条独立确认集（`validation/translation-confirm-set.json`，评分规则运行前冻结）与确认集盲测比较材料（模型名盲化）。两个模型全部应译样例语义审阅完成：small100 放行候选合格率 70.8%（确认集 67.4%，固定风险仍 5 条错误放行），quickmt 确认集仅 20.3%（词级失败 88.1%）。**维持 small100 优先、quickmt 仍为性能对照，学习模式继续阻塞**；最终报告见 final-selection.md（旧报告已退役，见 Git 历史）。评测管线回归断言 7 项接入 verify fast 档（`scripts/validate-translation-eval.py`）。
- **同日复核勘误（无二进制变更）**：更正最终报告两处事实错误——§3.3 分类型表误把 4 条回退但审阅通过的用例计入判审（已按放行口径更正，合计 255/360、145/316 不变，结论不变）；`Gogaku v3.2.1`→「古巴 v3.2.1」实际五轮全部放行进入候选（保护扫描未识别句首 `Gogaku`），原文「被拦截」与请求级数据不符。另补轮次完整性断言：残缺末轮的运行不得冒充完整评测（驱动记录 `completeRun`，汇总强制每用例恰好 `rounds` 轮请求行）。

### 变更（构建 14 追加：清洗规则 v5——分隔符统一）

- **义项内同义词的分号分隔统一为点号 ·**（用户裁决：不同词之间都用点分隔，与词库条目样式一致）：君 sovereign · monarch …、菌 bacterium · germ · fungus。另修复 ·（U+00B7）不在 presentable 白名单导致主义项被丢的回归（词条恢复 160,346）。

### 变更（构建 15 追加：清洗规则 v6 终版）

- **行内不再出现任何省略号**（用户裁决「希望可以显示全」）：同义枚举从「前 2 项＋…」改为只取首项（首项＝主义项）；超长静默词边界截断（拼接上限 46 内同样词边界）；R3 截断补词边界（修复 the en 半词切断）。效果：不 → not · cannot、布 → cloth · to announce（原 4 项噪音）、均 → equal · all；长度分布 max=46、无超限行。字条目（不/步/部/布等单字）无词性前缀为 Wiktionary 字条目数据本质（无词性标注，诚实省略优于猜测），多字词词性正常。

### 变更（构建 16 追加：清洗规则 v7 定稿）

- **括号内容一律移除**（含短括号与未闭合残尾，用户确认不显示括号）——(geography) 类消歧说明不再出现在候选行；**synonym of／alternative form of 等字形指代义项剔除**（并 的「synonym of 太原」不再出现）；截断态义项即行尾且截断点悬空虚词（a/of/the）一并去掉（屏 行 "…gate of a · wall" 不再出现）。fast 全过。

### 变更（构建 18 追加：翻译加固层第二片与组合策略首轮验收）

- **加固层第二片（共享 C++，`translate_safety_test` 76 项断言）**：时间检查改为逐条「数值＋时段」对比——合法区间（上午九点到下午四点）不再误判、英文动词 `am` 不再当午前标记、未被时间表达解释的数字必须保留且顺序不变（新增返回码 4）；合法叠词（看看／试试／哈哈／多多少少／一个一个）不再当复读；脚本校验与长度比率排除 URL 跨度；句首已知品牌（29 个无歧义专名）进入保护扫描，与审阅品牌表双向一致。ASan／UBSan quick 冒烟 2000 序列无错误。
- **组合策略首轮验收（只评策略，不接生产）**：固定路线「运行时保留判定 → 品牌映射 → 审核表达资源 → 双向时间模板 → small100 候选（短表达 beam=2／短句 beam=5，最多 2／3 候选）→ 结构检查 → quickmt 反向评分 → 排序」。新增 `resources/translation/`（CC-CEDICT 衍生审核资源：en→zh 180 条、zh→en 300 条，103 条复核改写；双向时间模板；品牌处理表；manifest 记录来源哈希与许可）、`probes/translation_strategy.py`、`probes/benchmark-translation-strategy.py`、`scripts/build-translation-expressions.py`、`scripts/select-translation-lambda.py`、`scripts/summarize-translation-strategy.py`，以及 worker 的多候选生成与 `score_batch` 反向评分协议。
- **结果：未通过，学习模式继续关闭。** 冻结验收集（每方向 100 条应译＋12 条未标注保留探针，运行前冻结并与四个开发集去重）上 en→zh 合格 46.0%、zh→en 53.0%（门槛 95%），错误放行 47／44 条；资源路径 8/9、模板 5/6、模型路径 86/176；短表达 p95 354ms、短句 p95 528ms（达标）；固定风险集 5 条意义破坏进入候选。反向评分只在 en→zh 有效（λ=0.25），zh→en 按预先规定的退出路径 λ=0。新发现受保护串污染语言／长度统计导致 5 条正确译文被误拒，本轮未追改封板证据。决定见 [翻译组合策略决定](docs/translation-strategy-decision.md)，证据见首轮验收报告（已退役，见 Git 历史）。
- **评测回归锁扩到 11 项**：资源哈希／署名／去重、品牌表与 C++ 扫描一致、验收集冻结与去重、验收证据自洽（缺标注即 blocked、门槛算术、风险集与轮次稳定性），已接入 verify fast 与 release 档。

### 变更（构建 22 追加：学习模式 quickmt 开发版后端）

- **学习模式最小闭环解锁（2026-11-03 用户裁决，仅本机开发版自用）**：翻译后端切换为 quickmt（CT2 INT8 双向两份权重，外置 Python 辅助进程 `venv/bin/python`＋`quickmt_worker.py`，位于 `~/Library/Application Support/Gogaku/translation/`，约 900MB 不进包）；显式替代「95% 质量门槛＋风险集处置」阻塞，已知风险（固定风险 12 条、en→zh 可用率 77.67%、beam1 重复句等）被接受，**双端交付门槛不变**。准备脚本幂等可重跑、权重 SHA256 不符即拒绝装配；worker 协议对齐 v1、无端口无日志无网络、常驻串行、按方向懒加载（beam1 逐句中位约 50ms）。
- **交互**：菜单「学习模式／学习方向」解除置灰（⌘⇧K／⌘⇧J 同款动作，按应用记忆）；中→英（小鹤解码→英译候选）与英→中（直输→中译候选）选择后一次上屏；候选带「quickmt 开发版」标注；失败／超时／缺模型保留输入并提示 ⌘Return 原文上屏；英→中拼写检查恢复。设置→语言资源页新增「学习翻译（开发版）」：启用开关（默认开）、beam 步进器 1–10（默认 1，变更重建辅助进程热生效）、后端状态与准备指引。学习记录与宿主安全矩阵仍关闭；关开关即回门禁态。

### 变更（构建 25 追加：学习交互与普通模式对齐）

- **中→英改为普通模式完整交互（2026-11-03 用户反馈裁决）**：走共享核心同一条路径——同一候选列表/释义/调频/数字 1–9/空格/Enter/标点上屏/Ctrl 编辑键/分页，唯一区别是中文提交文本在上屏时换成 quickmt 英语译文；纯非 CJK 提交（原编码、英文候选）原样上屏。组合期间预译高亮候选并在状态行预览「译文：…」；缓存未命中时缓冲后续按键防交错，译文失败上屏原文并提示。**快捷键不再单独定制**：学习模式去掉 ⌥数字等专用键表（覆盖 product.md 三状态按键表的开发版口径，见 docs/learning-quickmt-dev-decision.md §五点五）。
- **英→中保留独立英语缓冲**：数字 1–9 直接选词、Enter 选中文译文、空格保留为英文空格、⌘Return 原文上屏；候选行前缀去掉 ⌥。

### 变更（构建 28 追加：方向维持手动＋切换提示跟随输入位置）

- **方向识别维持手动（2026-11-03 用户裁决）**：评估了自动识别输入语言（拼音轨/英文轨逐键判定）后用户选择不做自动——维持 ⌃⇧J 手动切向（快捷键已可在设置自定义）。评估结论与歧义分析（mini＝小鹤「迷你」＝英文词等真歧义、Space 语义硬冲突）记录于 docs/learning-quickmt-dev-decision.md。
- **切换提示浮层跟随输入位置**：「学习／普通」「中→英／英→中」「中／英」及译文失败等提示不再固定在屏幕右上角，改为跟随当前插入点（优先光标上方，下方被候选窗占用时不遮挡，越界钳制；无有效锚点回退右上角）。浮层按文本自适应宽度（修复「中→英」被固定 44pt 截断）。PanelPlacement 新增 toastOrigin 纯几何＋3 项单测。

### 优化（构建 82 追加：候选窗首入错位更快自愈）

- **锚点可信度宽限窗（AnchorPlausibility）**：组合首键的显示锚点来自 setMarkedText 之前的一次宿主读取（pre-read），是全流程唯一无条件信任的矩形——宿主在点击／滚动／焦点切换后布局未跟上时报陈旧矩形，候选窗首入即错位，且瞬移过滤器（2026-11-03 构建 18）把「错误的首锚」也保护起来：真实新位置是跨行跳变，要等满 8 拍（约 0.8s）甚至更久才被采纳。修复：锚点确立后的前 6 次有效读数内，逃生门从 8 连拍降为 3 连拍——真实布局更新约 0.2–0.3s 纠正，Orca 瞬时误报一两拍内消失（构建 18 实测）连续 3 拍才采纳仍拦得住；零矩形冻结不消耗窗龄。窗龄与可疑计数独立，跨窗界沿用已累积 streak。纯函数扩展＋4 项新单测（宽限窗更快采纳、窗内瞬时误报仍冻结、按窗龄过期、streak 跨窗界沿用），fast 档全过。

### 修复（构建 8–10 追加）

- **候选窗注释英文降部被裁（g／y／j／p 尾钩只留短桩）**：`.usesLineFragmentOrigin` 绘制路径的墨迹裁切线在矩形底边，而基线位于字体 boundingRect 上升高度处——默认行框高度小于「基线＋降部」，尾钩被裁平（实测裁切边界不随行框高度变化，增大高度不超过基线＋降部时同样被裁）。修复：保持行框顶（基线不变），矩形高度扩到字体 boundingRect，裁切边界随之下移；离线 2x 渲染逐像素对齐验证基线零位移、尾钩完整；渲染回归 58 项、fast 档全过。

### 变更（移除快速添加功能，2026-11-04 用户裁决）

- **整功能移除（用户裁决「这部分功能没有用」）**：设置页「普通输入」页快速添加卡片（⌃⇧A 内联录制＋排除应用列表）、输入法侧快捷键监听、「键盘快捷方式」表格行，以及共享核心 `GC_EV_QUICK_ADD` 事件、60 秒记录窗口、排除应用（`gc_normal_set_excluded_apps`／`gc_normal_quick_add_available`）全部删除；`ConfigurableCommand` 收窄为两个可配置命令（普通／学习、学习方向），冲突检查与筛选随之收窄。自定义词语页与拼音词、学习与隐私排除、设置进程侧「写入失败不得伪报成功」防护不受影响。验证：fast 档全过＋ASan／UBSan 冒烟 2000 序列无错误；规格与验收记录同步（docs/product.md、docs/validation/native-development.md）。

## 0.1.0-dev.1（构建 6）— 2026-11-02

### 变更（模型路线与翻译加固，2026-11-02 裁决）

- **翻译模型路线解堵裁决落地文档**：主路线改为 small100＋翻译加固层（处置口径：修正或安全拦截含回退均算已处置）；解除「不扩模型名单」——宽松许可新候选开放验证（quickmt 双向为首选，Mac 门槛机速度实测 p95 41.7–82.2ms，约为预算 1/6–1/8，比 small100 快 2–2.8 倍；质量待门槛）；LLM／llama.cpp 出局（死守 500ms）；详见 模型解堵调研（已退役，见 Git 历史）、quickmt 速度探针（已退役，见 Git 历史）。
- **自建短文本评测集**（[validation/translation-short-expressions.json](validation/translation-short-expressions.json)）：双方向各 44 例冻结，覆盖短语／时间／人名／品牌／错拼／乱码／繁简陷阱；reference 为草案待用户审阅。
- **翻译加固层第一片入共享核心**（`native/GogakuCore/translate/`，附加 ABI 接口）：重复分类（含 181 Q 类乱码）、繁→简归一（内嵌 OpenCC 生成表 3616 字，脚本 `scripts/build-t2s-table.py` 可重生成）、时间一致性（时段翻转／丢半点）、脚本校验、长度比率、专名保护候选扫描；`gogaku_core_translate_safety_test` 55 项断言入 ctest。处置效果验证：hardening-demo.json（旧结果已退役，见 Git 历史）——15 条真实失败样本中重复／时段／繁体／乱码四类被回退或归一，语义跑偏、多余尾部、短源截断、人名丢失、品牌改写五类属第二片（覆盖检查／专名对齐）未拦住，已如实记录。

### 变更（用户裁决）

- **组合中 Shift 改为原样上屏后切英文直输**（替换 2026-10-31「上屏后不切中英」旧规则）：暂存中文＋剩余原编码一次上屏，同一事件进入临时英文；后续字母、空格、标点原样直输（标点保持半角）；再单击 Shift 回中文；按应用默认英文的应用同样适用，应用默认只由无组合 Esc 或切应用恢复；左右 Shift 等价。真机探针黄金表同步重写（`nihc→Shift→abc.→nihcabc.`、往返场景）。
- **原编码／非已学习提交使快速添加失效**（补齐规格「原编码上屏…不可添加」）：Shift／Enter／未处理字符／数字 0 原编码前缀上屏，以及选到英文或自定义词的提交，都使快速添加记录失效；已学习中文候选提交仍可快速添加。

### 修复

- **候选窗被 Bob 等高层级宿主浮窗遮挡**：宿主桥接新增 `IMKTextInput.windowLevel` 读取；候选窗目标层级＝max(popUpMenu, 客户端层级＋1)（无效或 ≤0 用普通基准，钳制上限防异常值），渲染时层级变化才重新排序（不逐键置前，不常态抬高）；宿主选区未知时不再用字符索引 0 的矩形冒充光标，缺少可信定位信息隐藏面板保留组合。
- **快捷键编辑器录制／清除／恢复默认不生效**：写回原走无消费者的可选回调，已改统一走绑定（一次操作恰好一次提交一次保存）；冲突草稿上报页面，「冲突」筛选与计数能看到真实冲突；快捷键搜索支持「cmd k」「⌘K」「ctrl+shift+a」等组合规范化匹配。

### 变更（构建 6 第二轮：普通输入整改收尾）

- **Orca 组合中 Shift 单击无效修复**：真机侧车证据（`log show/stream` 对 GogakuInput 的 NSLog 不可见，改用文件侧车）发现 Orca（Chromium 系）对每个修饰键过渡**双投递 flagsChanged**（同边沿 2ms 内两条同 raw 事件），重复的 Shift 按下落入「按住期间有其他按键」分支把单击资格判死。修复：修饰键按下沿幂等化（重复按下保持资格），释放沿判定不变；TextEdit 真机严格场景（单击上屏原编码／Shift 后英文直输／临时英文回中文）全过，用户实测 Orca、微信正常。
- **ShiftTapPoller 轮询兜底**：25Hz 采样 `CGEventSource.flagsState`（共享内存读取，无需权限），仅当整个按住窗口＋120ms 宽限内没有任何 flagsChanged 事件时才代发单击——与事件通路互斥、永不双发，作为不投递修饰键事件的宿主的保险。
- **候选窗锚点策略裁决（2026-11-02 二次裁决）：完全信任宿主锚点**。期间实测 Orca 终端 TUI 锚点在真实位置与陈旧位置间跳变（pi 重渲染后锚点回到顶部旧位置，偏差 697–800pt）且 Orca 不向输入法转发 mouseDown；尝试过实时鼠标／最近点击位置可信度校验（并修复 CGEvent 左上原点与 Cocoa 左下原点混算的坐标 bug），均无法可靠区分「正确锚点」与「陈旧锚点」，按用户裁决移除校验代码。Orca 终端偶发顶部错位属上游缺陷待其修复。
- **设置页布局重排**（用户 2026-11-02 三项裁决）：快捷键页去标题行、筛选胶囊与搜索同行；普通输入页「输入方案」与「模糊音」拆分为独立分组；全部分组卡片改为内容区平铺（标题＋间距＋hairline 分割，去圆角卡片背景）。
- **菜单切换图标字形放大**：系统对所有输入法图标统一做模板渲染，真实差异是字形太小太靠左；放大并居中后与鼠须管／青简填充度对齐（`check-menu-icon` 墨量窗口按新字形重标定）。

### 变更（设置页）

- 设置页按 [prototypes/settings-final.html](prototypes/settings-final.html) 逐项还原：19 个浅／深色 token（窗口／侧栏／卡片／描边／分隔线／强调色体系）、自绘侧栏导航、卡片与行度量、键帽／录制态样式、快捷键页搜索与筛选分行、四列表格（命令名称→键帽→来源→操作）统一列宽；删除实现自加的路径与重复说明文案；英文释义开关改名「显示英文释义」＋帮助「候选词的英文词义参考，不随中文上屏」。
- 系统输入源切换浮层图标修复：实证根因为 TextInputSwitcher 进程内 NSImage 缓存跨安装不失效（TIS 映射、磁盘缓存、包内资源均正确）；安装流程现在重启该 HUD 代理（失败仅提示），菜单图标光栅校验增加键帽边带与字形镂空守卫。
- 菜单「恢复草稿」改名「恢复未完成输入」，字面文本项改「恢复未发出文字」。

## 0.1.0-dev.1（构建 5）— 2026-11-03

### 新增

- **设置页原生落地**（按 [prototypes/settings-final.html](prototypes/settings-final.html) 已选视觉，规格定稿见[产品方向](docs/product.md)）：六页外壳（200pt 侧栏、内容滚动区、固定底部状态栏）；普通输入页字号 12–16 整数滑块带刻度、显示内容分段控件、模糊音三列九项；应用列表（按应用默认英文／快速添加排除／学习与隐私排除共用图标＋名称列表与可搜索添加弹层，后台索引系统应用目录，未安装应用保留记录并显示通用图标）；快捷键页 VS Code 式表格（三个可配置命令统一录制／清除／恢复默认，搜索与全部／我修改的／冲突筛选，固定操作按真实语义展示不可编辑）；自定义词语紧凑列表（分段＋搜索，选中行工具栏与右键菜单操作，双击打开既有编辑表单）；语言资源页不再提供 Apple Translation 查询与安装入口，展示实际随包资源状态。
- **设置立即保存**：串行写入协调器（最新改动胜出），每次落盘前重新读盘并按顶层字段差异合并，避免旧整份快照覆盖其他页或输入法写入的偏好；连续文本输入合并 300ms，失焦／关窗提交剩余改动；仅成功落盘后发送变更通知，失败保留待保存改动并在状态栏重试。自定义词语写入成功后直接通知重载，不再「为发通知再保存整份 settings.json」。
- **快捷键模型 v2**：规范键标识（含 F 键、带修饰键的标点）＋修饰键＋明确禁用状态；无修饰键可打印字符与单独修饰键不可绑定，录制中 Esc 取消、Delete 清除；冲突检查覆盖三个可配置命令及适用状态下的固定输入操作，冲突草稿只提示不写入；兼容读取旧 `key/modifiers`（缺省非禁用），明确清除不复活；新字段默认不写入，保持旧二进制可读。
- **验收入口真实化**：`verify.py --profile host` 从文字计划改为真实参数数组调度——连续两轮宿主矩阵、Orca Shift 专项、万次事件性能、两小时稳定性浸泡（新增 `probes/stability-soak.py`：逐轮报告＋输入法进程内存趋势）；每项核对用例结果、完成数量与安装件身份，缺证据记 blocked；原生 GUI 验收证据归档项（`native-gui-acceptance.json`）。

### 修复

- **候选窗定位重构**：宿主光标矩形显式三态（未读取／有效／无效），移除鼠标位置与虚构屏幕尺寸回退；锚点身份与显示位置分离，marked text 更新后合并刷新读取最新位置；组合中以 100ms 复查处理滚动与窗口移动，无组合或失焦立即停止；同一坐标不重复布局，旧代次刷新不会使已关闭面板复活；无有效坐标时隐藏面板但保留组合（不丢文字），恢复有效且字段一致后重新显示；放置几何改为纯函数（默认插入点右下、空间不足上翻、重算高度后不越界，负坐标与多屏支持），带离线几何单测。
- **普通模式 Command＋Enter 误上屏**：Command／Option 组合按宿主快捷键规则交还宿主，不再把学习模式的「原文上屏」语义带入普通模式。
- 自定义词语排序改为同类内移动（跳过其他类型行），搜索时禁用排序；筛选后编辑／删除按稳定存储行标识执行，不错行。

## 0.1.0-dev.1（构建 4）— 2026-11-02

### 修复

- 自定义词语首次打开编辑／新增时，表单可能使用上一条或默认短码类型；改为由当前词条驱动弹窗，并在初始化时设置草稿，避免拼音词误开成空白短码短语。
- 包含构建 3 的自动读音与自定义拼音候选修复。

## 0.1.0-dev.1（构建 3）— 2026-11-02

### 修复

- 安装后校验永远失败：`build.py` 写入的 `bundle-manifest.json` 路径相对于 dist，而 `manage-install.py` 用绝对路径前缀过滤，导致一个条目都匹配不上、全部安装文件被报为「清单外文件」。前缀改为与同一基准（相对 dist）计算后，两个应用各 49／41 个文件逐哈希核对通过。
- 应用图标最外层多一圈白框：`qlmanage` 缩略图把 SVG 透明边距压成不透明白色，dock 与启动切换器里图标外出现白边。图标改为全出血圆角方块（透明四角、无烘焙阴影描边），渲染管线改用 NSImage 直出各尺寸（`scripts/render-svg.swift`），重建重装后生效。
- 自定义拼音词的 libime 分数方向错误，导致「极视角 / ji'shi'jiao」等词被解码剪枝；修正后小鹤 `jiuijn` 与全拼 `jishijiao` 均置顶，新增与重载均生效，并能参与长句组句。
- 自动读音按制表符误解析 libime 的空格分隔词典，且多音字权重方向取反；修正后「极视角」得到 `ji'shi'jiao`，「角」优先 `jiao`。
- 设置应用随包携带经哈希校验的 `sc.dict`，自动读音使用包内资源，不再依赖开发缓存；随包检查新增设置应用自动读音回归。

## 0.1.0-dev.1（构建 2）— 2026-11-02

工程化与普通输入收尾（未定版；0.1.0 需验收通过＋用户试用确认）。

### 新增

- `version.json` 单一版本来源；构建读取并生成包内／外部两层构建身份（完整版本、构建号、提交、dirty、架构、工具链、依赖与数据哈希、产物哈希）。`CFBundleVersion` 改为真实构建号，不再恒为 1。
- `scripts/verify.py` 统一验证入口：`--profile fast`（日常提交）、`release`（交付门槛，不接管桌面）、`host`（真实宿主／性能／稳定性，需 `--yes` 显式确认）。机器可读报告＋摘要，必需项全过才算门槛通过。
- `CHANGELOG.md` 与版本管理说明。
- 设置应用侧栏显示完整预发布版本与构建号（读包内 build-identity.json）。

### 修复

- **Shift 提交不更新最近上屏字符**（核心缺陷）：组合中 Shift 上屏后，下一标点错误沿用数字后半角例外（Terminal 实测「Shift 确认＋句号」得半角 `.`）。修复后与 Enter／空格／选词提交同规则；补「数字 → 字母组合 → Shift → 句号／冒号」核心反例回归（事件轨迹 257 → 265 项断言）。
- **安装备份以旧 `.app` 形式暴露**：备份改为 `*.app.disabled` 并只保留最近 3 份，历史 `.app` 备份自动改名；消除 LaunchServices 索引旧备份导致输入法随机启动旧二进制的隐患（此前曾发生 76 个旧备份包）。安装后自动核对实际安装路径全部文件与 dist 清单哈希。
- 出厂数据拷入包改 `copyfile`：macOS `copystat` 会把 `uchg` 不可变标志带进包，导致重装删除失败；出厂 `sc.dict`／`zh_CN.lm` 加 `chflags uchg` 文件系统级保护（重新生成依赖前需 `nouchg`）。
- 依赖准备移除对 `/tmp` 旧探针缓存的隐式迁移；本机工具（git／cmake／ninja／clang）缺失时明确报错；干净构建改用独立构建根（`GOGAKU_BUILD_ROOT`）。
- 文档错误更正：收尾复测「5.55ms 低于 5ms」表述（5.55ms 高于 5ms 门槛）；开发说明中的 Debug 测试命令统一为 Release 配置；过时的 Apple Translation 使用说明改为历史证据定位。

### 变更

- **释义精简**（离线生成规则收紧，消费接口不变）：`character` 类别不再显示为 `char.` 词性；结构化词典标签（`(hakka)` 等）不再透传；`(Classifier: …)` 量词搭配表剥离；俚语／粗俗等强语域义项整条剔除（不再降级透传）；单条义项 ≤64 字符（超长整条剔除，不截断）；键必须为纯 CJK 表意字符。词条 161,839 → 143,777。来源清单、哈希与署名同步更新；固定种子 50 条抽样审阅见 `docs/validation/gloss-simplification-review.md`。
- Hyper（fn）修饰不再触发 Shift 单击判定。

### 已知阻塞（不计入本轮完成）

- IMK 主线程性能未达标（10,035 事件 p95 10.35ms／p99 15.38ms，门槛 5ms／10ms；归因：长单行文档的必要同步宿主写入本身超预算）。
- 最终宿主连续两轮矩阵、十万序列插桩、两小时稳定性／内存／冷启动未完成；Spotlight／Raycast 未验收。
- 学习模式保持关闭（模型质量门槛未通过）；Windows 未开始。
