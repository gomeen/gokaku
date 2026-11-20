# Windows 安装体验优化调研

调研日期：2026-11-20。范围是 Windows 11 终端用户从获取安装包到能打出字的完整旅程：获取 → 信任 → 安装 → **启用** → 升级／卸载。开发机构包流水线（交叉编译、Wine/Inno、固定依赖）的复杂度不在本文范围。

证据口径：与既有调研一致——「官方」指 Microsoft Learn、jrsoftware.org 等一手文档；「源码证据」指 Weasel／水杉等实现的可核对写法（已由两个独立来源交叉印证的结论会注明）；商店页标价为厂商自述。本文没有修改或运行任何代码，调研结论不等于宿主验收。

## 结论摘要

当前安装旅程最大的痛点不是向导本身，而是**安装完成后还要用户自己走六层设置路径启用输入法**，其次是**无签名导致的 SmartScreen／未知发布者门槛**。优化排序：

| 优先级 | 方案 | 解决的痛点 | 一句话结论 |
|---|---|---|---|
| P0 | 安装后自动登记用户输入法列表（水杉式） | 手动六层设置路径 | `ShellExecAsOriginalUser` 以原用户身份幂等调 `InstallLayoutOrTip`；设置页/语言栏即时生效，任务栏需重启 explorer（提示即可） |
| P0 | 代码签名 | SmartScreen 拦截、未知发布者、官方 IME 合规 | 作者在美/加则 Azure Artifact Signing（$9.99/月）；否则 Certum 开源证书（€49/年）；并行免费申请 SignPath Foundation |
| P1 | 首启引导 | 自动启用失败/被剔除时的兜底；explorer 缓存 | 设置应用检测启用状态，未启用时深链 `ms-settings:regionlanguage`＋两步图文；无第三方 IME 直达深链 |
| P1 | winget 分发 | 获取门槛 | 照 Git.Git／Weasel 模板提交 winget-pkgs：GitHub Releases 直链＋Inno 静默开关；不豁免 SmartScreen，与签名互补 |
| P2 | 卸载/重装用改名退避代替「要求全部退出」 | 卸载前要手动关应用、切输入法、退代理 | 已加载 DLL 改名退避后返回成功，延后删除；微软 DLL Updates 官方背书此模式 |
| P2 | 应用内更新静默化 | 一键更新仍弹完整向导 | 启动安装器前已二次校验哈希，可传 `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`；产品决策项 |
| 排除 | MSIX、per-user 免 UAC、EV 证书、Restart Manager 管系统宿主 | — | 微软 Q&A 明确 TSF IME 不能纯 MSIX；TIP 注册硬性要求 HKLM 提权；EV 个人不可办且已无 SmartScreen 即时豁免；RM 官方明说关键系统进程停不了 |

## 1. 现状旅程与摩擦点（仓库事实）

| 阶段 | 现状 | 证据 |
|---|---|---|
| 获取 | GitHub Releases 手动下载 55.8MB Setup.exe | `dist/gogaku-win/` |
| 信任 | 无 Authenticode 签名，UAC 显示未知发布者，可能触发 SmartScreen | [windows-testing.md](windows-testing.md) |
| 安装 | 标准 Inno 向导＋UAC（摩擦小） | `windows/packaging/gogaku.iss.in` |
| **启用** | **安装器刻意「只注册、不激活」；用户手动：设置→时间和语言→语言和区域→中文→语言选项→键盘→添加 Gogaku** | `windows/packaging/README.md`、`gogaku.iss.in` 头部注释 |
| 刷新 | 输入法列表可能不刷新，「可自行注销再登录」 | [windows-testing.md](windows-testing.md) |
| 引导 | 设置应用无任何启用检测/引导 UI，全靠读文档 | `windows/GogakuWindows/settings.cpp`（无相关代码） |
| 升级 | 新版本目录＋ActiveRoot 指针＋DLL 改名退避，已基本无感 | `gogaku.iss.in`（RetireLoadedDll） |
| 重装/卸载 | 文件被占用时中止并要求用户手动关闭应用/退代理/切输入法后重试，不强杀 | `gogaku.iss.in`（LockMessage）、[windows-testing.md](windows-testing.md) |
| 应用内更新 | 一键更新启动的仍是交互式向导（`/NORESTART; never /SILENT`） | `windows/GogakuWindows/update.cpp:871` |

「只注册、不激活」是当年刻意的保守决策（避免触发用户语言表整表重写竞态，见 [Windows 11 剔除调研](research-ime-windows11-pruning.md)）。本调研确认了既自动启用、又不放大竞态的可行路径（§2）。

## 2. 自动启用（P0）

### 2.1 注册与启用是两层

Keyman wiki 的分层模型（[1]）：

| 状态 | 存储 | 写入方式 | 权限 |
|---|---|---|---|
| Registered（机器级注册） | `HKLM\SOFTWARE\Microsoft\CTF\TIP\…` | `regsvr32`／`ITfInputProcessorProfileMgr::RegisterProfile` | 提权 |
| Installed（用户已启用，出现在键盘列表） | `HKCU\Control Panel\International\User Profile\<语言标签>\InputMethodTips` 等 | `InstallLayoutOrTip`／`Set-WinUserLanguageList`／设置 UI | 用户上下文 |
| Loaded / Activated | 进程内 | TSF 激活 | — |

Gogaku 现在只做到第一层。`ITfInputProcessorProfiles::EnableLanguageProfileByDefault` 也只写 HKLM 的 Enable 值，**不会**把 IME 加进用户键盘列表（水杉 PR #1218 实测 [7]）——所以 HKLM 层无论怎么注册，都替代不了用户级一步。

### 2.2 两个已验证的同路实现

- **水杉输入法 PR #1218**（已合并 [7]）：Inno Setup `ssPostInstall` 阶段用 `ShellExecAsOriginalUser` 运行自家设置程序 `--register-profile`：先查当前用户键盘列表，没有 Gogaku 条目才调 `InstallLayoutOrTip("0804:{CLSID}{ProfileGUID}")`，幂等、只写 HKCU、失败仅记日志。**实测：系统设置和语言栏立即出现；任务栏输入指示器和 Win+Space 不刷新（explorer 启动时读入内存），广播 `WM_SETTINGCHANGE`/`WM_WININICHANGE` 均无效，重启 explorer 立即生效**；作者拒绝从进程内杀 explorer，只在设置页说明。
- **Weasel PR #1959**（已合并 [2]）：`WeaselLanguageProfile.ps1` 用 PowerShell `Get-WinUserLanguageList` 读现表→幂等增量→**仅当有变化**才 `Set-WinUserLanguageList -Force`；退出码 0=未变／1=已改／2=目标语言不存在（此时弹窗引导用户去设置添加语言）。可顺带迁移 legacy IMM 条目和默认输入法 override。注意 Weasel 的脚本继承安装器提权令牌，标准用户借他人管理员凭据安装时会写错 HKCU——水杉的 `runasoriginaluser` 姿势更正确。

两个反例（TypeAnything #13 [12]、neural-weasel [13]）的共同教训：**提权安装器直接写 HKCU 写的是管理员 hive，当前用户看不到**；必须以原用户身份执行用户级步骤。`InstallLayoutOrTip` 是 `input.dll` 导出、无导入库、标志常量不在公开头文件（需自行 `#define`），Vista 起可用、Win10/11 实测仍可用（[19]、mozc `input_dll.h` [2]）。

### 2.3 对 Gogaku 的建议方案

1. 首选**水杉式**：给 `GogakuAgent.exe`（或设置程序）加 `--register-profile`：读 `InputMethodTips`（注意 Win10/11 键名是语言标签如 `zh-Hans-CN`，不是 `0804`）或用 `ITfInputProcessorProfileMgr::EnumProfiles` 检测，未启用才调 `InstallLayoutOrTip` 一次；`gogaku.iss.in` 在 `ssPostInstall` 用 `runasoriginaluser` 调用（与现有 `--set-autostart` 的 `[Run]` 姿势一致，但要放在文件注册成功之后）。静默安装时跳过或仅记日志。
2. 与剔除竞态的关系：`InstallLayoutOrTip` 底层同样是整表回写语义（[1]），但「检测到未包含才执行一次＋失败不重试」把竞态窗口压到最小；这与 [剔除调研](research-ime-windows11-pruning.md) §7 的结论（启用步骤放原用户身份、幂等）完全一致。**不要**每次代理启动都检查并写。
3. explorer 缓存：不自动杀 explorer（水杉同款裁决）。向导完成页/设置应用提示「任务栏与 Win+Space 列表需重启资源管理器或注销后显示」；如要提供「重启资源管理器」按钮，必须明确征询。
4. 语言兜底：目标语言（zh-Hans-CN）不在用户语言表时（如英文系统未装中文语言包），走 P1 引导而不是自动加语言——Weasel 也只弹窗引导。

## 3. 首启引导（P1）

自动启用解决 95% 场景，引导是兜底（安装时非交互、语言缺失、被系统剔除、用户误删）。现状设置应用完全没有启用状态感知。

- **检测**：`ITfInputProcessorProfileMgr::GetActiveProfile`（当前活动 profile）/ `EnumProfiles`（全部已注册 profile，可查启用态）；或读 `HKCU\Control Panel\International\User Profile\zh-Hans-CN` 的 `InputMethodTips` REG_MULTI_SZ 是否含 `0804:{TSF-CLSID}{Profile-GUID}`；PowerShell 侧 `Get-WinUserLanguageList`（官方文档 [5]）。
- **深链**：`ms-settings:regionlanguage` 直达「设置→时间和语言→语言和区域」（官方 URI 列表 [20]）。**没有直达「某第三方 IME 的添加键盘」对话框的公开 URI**（`regionlanguage-chsime-*` 等均为微软自带 IME 专属），所以引导页仍需两步图文（添加键盘→选 Gogaku）。
- **形态建议**：设置应用首屏显示启用状态徽标（未启用/已启用/当前输入法）；未启用时给「自动启用」按钮（调 §2 的 `--register-profile` 逻辑）＋「打开系统设置」按钮（深链）＋两步图文；已启用未激活时提示 Win+Space。安装器 `[Run]` 默认勾选「打开 Gogaku 设置」已存在，正好承接。

## 4. 代码签名（P0）

### 4.1 为什么必须做

- 官方对第三方 IME 的要求清单明文「Must be digitally signed」[3][4]；未签名的直接后果是 SmartScreen「未知发布者/已保护你的电脑」与 Defender 查杀风险。
- 微软新的 SmartScreen 信誉文档 [21]：信誉＝发布者证书信誉＋文件哈希信誉双信号；未签名每个新版本从零开始，**同一证书签名可跨版本继承信誉**；OV 首签仍可能弹窗，随干净下载量数周内自动消失；**EV 不再即时豁免**；Win11 开启 Smart App Control 时未签名文件直接阻止执行。
- 签名同时改善：UAC 对话框显示真实发布者名、应用内更新启动安装器时的信任链、winget 审核观感。

### 4.2 方案对比（2026-11 价格与资格，均查自官方页）

| 方案 | 价格 | 资格 | SmartScreen | 集成 | 备注 |
|---|---|---|---|---|---|
| Azure Artifact Signing（原 Trusted Signing） | $9.99/月 Basic（5,000 签名/月，超出 $0.005/签） | 组织限美/加/EU/英/澳/新西兰/日/韩/新加坡/瑞士/挪威/以色列且需 ≥3 年营业历史；**个人仅限美/加居民**（Quickstart 原文 [22]，本调研已复核） | OV 级信誉积累 | SignTool `/dlib`＋Inno `SignTool` 指令签 setup/卸载器/内嵌 DLL；官方 GitHub Action（仅 Windows runner） | 需付费 Azure 订阅；身份验证走 Authenticator Verified ID＋人脸 |
| Certum 开源证书（SimplySign 云端） | **€49/年**（店页已复核 [23]），限 5,000 签名/月 | 仅个人＋能公开证明关系的开源项目；证件＋3 个月内水电账单；证书 CN 带 “Open Source Developer” 前缀；**商业分发会被吊销** | OV 级，官方仅承诺 “less likely to see SmartScreen” | SimplySign 云端卡（FIPS 140-2 L3），支持时间戳，Linux/macOS 工具可签 | 全球可办，是大陆个人开发者现实最优解 |
| SignPath Foundation | 免费（含证书） | OSI 许可、无商业双授权、活跃维护、**要求可验证声誉**（新项目不保证过）、签名团队=源码维护团队、首页挂 code signing policy、每版人工审批 [24] | OV 级 | SignPath.io 服务端签名，Authenticode exe/dll/msi | 发布者显示为 “SignPath Foundation” 而非作者 |
| EV（SSL.com/Sectigo 等） | $349–498/年，仅组织 | 个人不可办 | **已无即时豁免** [21] | — | 排除 |

### 4.3 对 Gogaku 的建议

决策变量只有**作者所在地**：在美/加 → Azure Artifact Signing（月费低、CI 集成最好）；在中国大陆或其他地区 → **Certum 开源证书为主选**（€49/年、MIT 开源项目可过验证），**并行免费申请 SignPath Foundation**（过了就省 €49/年，代价是每版人工审批）。无论哪条路，Inno `SignTool` 指令可在构包时自动签 setup.exe、卸载器和全部随包 PE；注意 Gogaku 在 Mac 上用 Wine 跑 Inno，签名步骤应放到 CI 或发布脚本（Windows runner 或 macOS 上的 osslsigncode——**跨平台签名工具链需另行验证**，未确认）。

## 5. 分发渠道（P1）

- **winget 可行且先例齐全**：winget-pkgs 接受个人贡献者 PR（签 CLA，无需组织验证）；manifest 的 `InstallerUrl` 直接指向 GitHub Releases 资产；Inno 的社区标准静默开关即 `/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART`（Git.Git manifest 即此组合 [25]）；Rime.Weasel（小狼毫）已在 winget-pkgs（PR #116453 [26]），证明输入法形态可过审。新包首审较严（新域名挂 Validation-Domain 标签须管理员复审），一次通过后续版本走机器人自动校验。
- 流程：`wingetcreate new <release-url>` 生成 manifest → `winget validate/install --manifest` 本地验证 → 提 PR；此后每个 Release 一个 PR（可逐步接入 GitHub Actions 自动提交）。
- 与现有 [检查更新](update.md) 通道不冲突：更新源仍走自有清单＋Ed25519，winget 只是额外获取入口。winget **不豁免 SmartScreen**，与签名方案互补。
- 收益：`winget install Gogaku`／`winget upgrade` 一行命令；Windows 终端用户对「去 GitHub 下载 exe」的门槛消失。

## 6. 升级／重装／卸载占用（P2）

现有方案（版本目录＋指针＋`RetireLoadedDll` 改名腾位＋`RestartReplace` 兜底）已经等价于微软《Dynamic-Link Library Updates》[27] 官方推荐的改名三步法，升级路径无需大改。调研确认的改进点与边界：

- **Restart Manager 帮不上 TSF DLL**：RM 官方明确关键系统进程（csrss、services.exe、svchost 等）不能停、其占用文件只能等重启 [28]；IME DLL 恰恰由 ctfmon/svchost 类宿主加载。Inno 的 `CloseApplications` 内部就是 RM（[29]），对系统宿主占用无效还可能弹吓人的「需要重启」提示——**维持现状 `CloseApplications=no` 是对的**；可选微调：RM 只对本产品 exe 生效、用 `CloseApplicationsFilterExcludes` 排除 TSF DLL 路径（收益小，非必须）。
- **卸载/同版本重装可用改名退避代替硬性要求退出**：微软官方背书「已加载 DLL 不能删但同卷可改名」[27]；weasel 升级同样是版本化目录＋占用文件静默跳过＋`SetRebootFlag` 提示重启 [30]。建议：卸载时反注册（HKLM）＋清指针＋停用用户条目（见下）后，被占用文件改名为 `.old-*` 并登记延后删除（下次安装时清），然后**返回成功**——用户不需要「先切输入法、退代理、关应用」再卸载；残留文件无注册表指向，无害。`PendingFileRenameOperations`（`RestartReplace`）仅作兜底且只对版本目录使用（现状已如此）——注意 Keyman 作者记录的坑：挂起删除＋用户不重启＋随即重装 → 重启后误删新装文件 [31]，版本化路径能显著缩小此风险但不应扩大挂起删除的使用面。
- **卸载时先停用用户条目**：以原用户身份 `InstallLayoutOrTip` 带 `ILOT_UNINSTALL`（或从语言表移除），再反注册 HKLM、再删文件——顺序见 Keyman 状态机 [1]。现状卸载只做 HKLM 反注册，用户列表里的 Gogaku 条目会残留成幽灵项（Win11 本就多见幽灵条目 churn [14]，自己清理可减少困惑）。
- **列表刷新**：广播无效、重启 explorer 有效（§2.2 水杉实测）；卸载后同理。提供明确征询的「重启资源管理器」选项，不自动杀。

## 7. 应用内更新静默化（P2，产品决策）

现状 `update.cpp:871` 刻意交互式（`/NORESTART; never /SILENT`），一键更新实际仍要点完整向导。调研未发现技术障碍：下载后已做大小＋SHA-256 校验、启动前二次校验（[update.md](update.md)），且安装器升级路径不要求关应用（版本目录）；传 `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` 即可做到「点一下、UAC 确认、装完重开」。UAC 仍会弹（TSF 注册需要管理员），这属于产品可接受范围。签名落地后此路径的信任链更完整。是否放开由产品裁决（与 [product.md](product.md)「一键更新」裁决相关）。

## 8. 明确排除的方向

| 方向 | 排除理由 |
|---|---|
| MSIX 包 | 微软 Q&A 明确：MSIX 清单无 TSF 注册扩展、packaged COM 无法声明 TSF 语言 profile，纯 MSIX 部署 TSF IME 不可行，官方推荐就是提权 MSI/EXE 安装器 [32] |
| per-user 安装免 UAC | TIP/profile 注册数据在 `HKLM\SOFTWARE\Microsoft\CTF\TIP`，`RegisterProfile` 需提权写 HKLM；weasel/Keyman/水杉全部机器级安装＋UAC，未见成功先例 [1] |
| EV 证书 | 个人不可办；微软官方文档明确 EV 不再即时豁免 SmartScreen [21] |
| 安装即抢占默认输入法/自动切换 | 官方口径「不要直接写注册表设默认键盘」；社区对商业输入法「抢默认」反感；`Set-WinDefaultInputMethodOverride` 还会参与系统动态重置与剔除竞态（[剔除调研](research-ime-windows11-pruning.md) v6 实验） |

## 9. 与既有研究的关系

- [Windows 11 CTF/TSF 剔除调研](research-ime-windows11-pruning.md) 的结论约束本方案：自动启用必须「原用户身份＋幂等＋仅在未包含时执行一次」，失败降级为引导（§2.3），不做默认输入法 override，不整表盲写。该调研中「explorer 启动时读入内存、广播不刷新」的判断与水杉实测互为印证。
- 本文的自动启用方案正是该调研 §7 修复方向排序里 ②「启用步骤放到原用户身份执行」的落地路径；该文档记录的 TSF 侧 E_NOINTERFACE 疑点（QI `ITfInputProcessorProfiles`）在实现 `--register-profile` 时会再遇到，Weasel 源码（`imesetup.cpp` 用旧接口＋`EnableLanguageProfile`）证明 Win11 上旧接口可用。

## 10. 落地依赖与待确认

- 签名工具链在 macOS 构包机上的可用性（osslsigncode／Certum SimplySign 桌面端是否支持 macOS；或在 GitHub Actions Windows runner 上签名）——**待验证**。
- `InstallLayoutOrTip` 的 `ILOT_APPLYTOALLTHREADS` 等标志是否需要（Learn 文档表未列，mozc/LiberNT 有对照实现）——实现时按需核对。
- Weasel winget manifest 的 `InstallerType: inno` 对 64/32 位双 TSF 注册的静默安装是否完整走通（Weasel 的 NSIS 与 Inno 参数不同，Gogaku 需自测 `/VERYSILENT` 下 `AfterInstall` 注册与回滚行为）——**待真机验证**。
- 微软 Q&A「Native TSF IME pure MSIX deployment」结论页（2026-09）为准；如后续 Windows 版本放开 MSIX-IME 支持，再重评。
- 本文所有「实测」均引用自 Weasel/水杉/Keyman 的一手记录，**Gogaku 自己的 Windows 宿主验收状态以 [原生开发验收](validation/native-development.md) 为准**。

## 参考链接

[1] https://github.com/keymanapp/keyman/wiki/Making-sense-of-the-Windows-Layout-Registration
[2] https://github.com/rime/weasel/pull/1959 （含 `WeaselSetup/WeaselLanguageProfile.ps1`、`imesetup.cpp`、`output/install.nsi`）
[3] https://learn.microsoft.com/en-us/globalization/input/input-method-editors
[4] https://learn.microsoft.com/en-us/windows/apps/develop/input/input-method-editor-requirements
[5] https://learn.microsoft.com/powershell/module/international/get-winuserlanguagelist
[7] https://github.com/metasequoiaime/msime-windows/pull/1218
[12] https://github.com/A-cat-with-carrots/TypeAnything/issues/13
[13] https://github.com/Yi-frank-phy/neural-weasel/issues/29
[14] https://github.com/keymanapp/keyman/issues/15507
[19] https://learn.microsoft.com/en-us/windows/win32/tsf/installlayoutortip （另见同目录 setdefaultlayoutortip、enumenabledlayoutortip；https://github.com/LiberNT/LiberNT/pull/110 Win11 语义对照；https://github.com/google/mozc 的 `src/win32/base/input_dll.h`）
[20] https://learn.microsoft.com/en-us/windows/uwp/launch-resume/launch-settings-app
[21] https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation （另见 /code-signing-options）
[22] https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart （另见 /how-to-change-sku、https://azure.microsoft.com/en-us/pricing/details/artifact-signing/、https://github.com/Azure/trusted-signing-action）
[23] https://shop.certum.eu/open-source-code-signing-on-simplysign.html （另见 https://support.certum.eu/en/code-signing-required-documents/）
[24] https://signpath.org/ 及 https://signpath.io/solutions/open-source-community
[25] https://github.com/microsoft/winget-pkgs （Git.Git manifest 示例：`manifests/g/Git/Git/…/Git.Git.installer.yaml`；https://github.com/microsoft/winget-create）
[26] https://github.com/microsoft/winget-pkgs/pull/116453 （Rime.Weasel 入库 PR）
[27] https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-updates （另见 /winbase/nf-winbase-movefileexw）
[28] https://learn.microsoft.com/en-us/windows/win32/rstmgr/about-restart-manager （另见 critical-system-services、RmShutdown）
[29] https://jrsoftware.org/ishelp/topic_setup_closeapplications.htm （另见 CloseApplicationsFilter、RestartApplications、Files 段 restartreplace）
[30] https://github.com/rime/weasel/blob/master/output/install.nsi
[31] https://marc.durdin.net/2011/09/why-you-should-not-use-movefileex-with-movefile_delay_until_reboot-2/
[32] https://learn.microsoft.com/en-us/answers/questions/5995922/native-tsf-ime-pure-msix-deployment
