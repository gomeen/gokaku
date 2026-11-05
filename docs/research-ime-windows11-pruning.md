# Windows 11 CTF/TSF 剔除第三方输入法的机制调研

- 日期：2026-11-06（纯研究任务，未改代码）
- 问题：自研 TSF 输入法（C++ COM in-proc，HKLM 注册完整、镜像微软拼音结构、Activate 正常）被 Win11 从「已启用输入法」列表剔除：`Set-WinUserLanguageList` 加入后 6 秒存活，几分钟后注册表值消失；`Set-WinDefaultInputMethodOverride` 读回为空。
- 结论先行：**没有公开文档描述一个专门的「剔除进程」**。社区证据一致指向「启用列表是**整表重写**语义 + 多进程快照竞态」，任何持有陈旧快照的系统组件做一次回写，都会把不在它快照里的 TIP 洗掉；叠加登录恢复、设置同步、默认输入法动态调整、以及接纳性校验失败（禁用）四种放大器。我们 VM 实验的时间线（设置 override 后才被剔）指向第 2、1 条组合。

## 1. 谁在校验/同步「已启用输入法」列表

先分清三层数据（Keyman wiki 的地图，证据 [1]）：

| 存储位置 | 内容 | 谁写 |
|---|---|---|
| `HKLM\SOFTWARE\Microsoft\CTF\TIP\{clsid}\LanguageProfile\…` + Category 键 | 机器级「注册」（Registered） | regsvr32 / `ITfInputProcessorProfileMgr::RegisterProfile`（需提权） |
| `HKCU\Control Panel\International\User Profile\{lang}` `InputMethodTips` + `HKCU\Software\Microsoft\CTF`（含 Assemblies，profile GUID 为键）+ `HKCU\Keyboard Layout`（legacy） | 用户级「安装/启用」（Installed/Loaded） | `InstallLayoutOrTip`（= `Set-WinUserLanguageList` 的底层）、设置 UI、输入法厂商安装器的用户态步骤 |
| `HKCU\Control Panel\International\User Profile System Backup`（及 `HKEY_USERS\.DEFAULT\…`） | 语言设置备份，登录时参与恢复 | 系统 |

参与的系统组件与已知行为：

1. **`Set-WinUserLanguageList` / `InstallLayoutOrTip` 本身就是「剔除器」候选之一**——它们是包装关系（[1]：Set-WinUserLanguageList is a wrapper for InstallLayoutOrTip），两者都**按进程内快照整体重写当前用户的整个输入法配置**；「changes made by other processes may be lost」「cmdlet do not refresh their in-memory lists without a parent PowerShell process restart… can lead to the Set-WinUserLanguageList cmdlet deleting input methods that it cannot find」。所以：任何进程用陈旧快照再调一次这两个接口（PowerShell、设置 UI、语言组件安装器、别的安装器），都会洗掉我们的条目。
2. **ctfmon.exe**（CTF Loader，由计划任务 `Microsoft\Windows\TextServicesFramework\MsCtfMonitor` 登录时拉起）：TSF 会话宿主；负责把默认输入法 override 应用到会话。TSF 对其他进程改动的刷新是异步的（Keyman 观测：`WM_ACTIVATEAPP` → `MSCTFIME_UI` 辅助窗口设合并定时器触发刷新 [1]）。我们 VM 实验：设置 `Set-WinDefaultInputMethodOverride` 指向自己后立刻触发剔除 → **ctfmon 应用默认输入法时对我们 TIP 校验失败 → 禁用并从列表剔除**（VM 内部证据，v6 实验）。
3. **TextInputManagementService + TextInputHost.exe**：现代输入体验宿主。官方文档：该服务（Win11 25H2 前叫 Touch Keyboard and Handwriting Panel Service）被禁用时 ctfmon 无法启动、输入法框架不初始化、无法切换输入法 [6]。它是「能不能用」的门槛，不是已证实的「剔除者」。
4. **explorer.exe**：任务栏输入指示器与 Win+Space 列表在 **explorer 启动时读入内存**；改注册表、广播 `WM_SETTINGCHANGE`/`WM_WININICHANGE` 都不刷新，需重启 explorer（水杉 PR #1218 实测 [7]）。
5. **LanguageComponentsInstaller 计划任务**（`\Microsoft\Windows\LanguageComponentsInstaller\{Installation, Uninstallation, ReconcileLanguageResources}`）：语言特性安装/调和，会改写语言配置。我们 VM 取证：ReconcileLanguageResources 上次运行早于当日全部添加/剔除动作，**当日不是它**；但语言特性安装、更新后仍是候选。
6. **官方确认的「动态调整」**：「In Windows 10, language settings are dynamically configured based on the user's language list. Individual settings, such as the display language, default input method, and user locale may be reset dynamically」[5]——默认输入法会被系统动态重置，与 `Set-WinDefaultInputMethodOverride` 读回为空的现象吻合。
7. **登录恢复**：`User Profile System Backup`（及 `.DEFAULT` 副本）在登录时参与恢复语言设置；不在备份里的新增条目重启/重登后被抹掉（SO 61370537 的解法就是同时清理这两个键 [8]；hky.moe 实测只删 User Profile 键无效 [9]）。
8. **设置同步/漫游**：语言列表属于 Windows 备份「记住我的偏好设置」的同步范围，会跨设备覆盖本机；MDM 政策键 `DisableLanguageSettingSync` 可关 [10]。MS Q&A 24H2 案例（微信输入法被系统「偷偷移除」、默认输入法每次重启重置）的官方回复第一条就是关这个同步 [11]。
9. **Windows Defender**：被判恶意/不符合规范的 IME 会被直接移除（官方原文 [3][4]）。

## 2. 社区已知案例与解法清单

同类「装了但不在列表/被系统改掉」的一手案例（按证据质量排序）：

| 案例 | 现象 | 根因/解法 | 链接 |
|---|---|---|---|
| **Weasel PR #1959** | 安装/升级 Weasel 会改变系统显示语言、或把已删除的微软拼音恢复回来 | 安装器调 `InstallLayoutOrTip` 引发系统整表调整；改为：升级时保留 TSF 注册不拆装 + 用户态 PowerShell（Get→改→Set-WinUserLanguageList）只做增量、无变化不写 + legacy IMM 迁移 TSF + 迁移 default override | [2] |
| **水杉输入法 PR #1218** | HKLM 注册了但当前用户列表里没有；显示名不生效 | `RegisterProfiles(bEnabledByDefault=TRUE)` 只写 HKLM `Enable`，**不会进用户键盘列表**；提权进程写 HKCU 写的是管理员 hive——必须以原用户身份调 `InstallLayoutOrTip`（Inno `ShellExecAsOriginalUser` 跑 `--register-profile`，幂等只写 HKCU） | [7] |
| **TypeAnything #13** | 装完 Win+Space 找不到输入法；`HKCU\...\CTF\Assemblies` 里搜不到 CLSID | 同上：提权安装器只写 HKLM，漏了「把 IME 加进交互用户列表」；需用户态补 `InstallLayoutOrTip` 或 PowerShell | [12] |
| **neural-weasel #29** | 真机安装阻断 | COM InprocServer32 注册在 HKCU 不行，TSF 宿主要求机器级 COM 注册；profile 需 `InstallLayoutOrTip` 注册且不动默认输入法 | [13] |
| **SO 61370537** | 删掉的键盘重启后回来；列表与设置 UI 显示不一致 | 系统从 `User Profile System Backup` 恢复；解法：同时清理 User Profile 与 System Backup（含 `.DEFAULT`）+ Preload | [8] |
| **MS Q&A（24H2）** | 24H2 上微信/搜狗等第三方输入法被移除、默认输入法每次重启重置为微软拼音 | 关「Windows 备份→记住我的偏好设置」同步；高级键盘设置覆盖默认输入法；`Set-WinUserLanguageList` 重设 | [11] |
| **Keyman #15507** | Win11 装/卸键盘后列表出现幽灵条目（重启后消失） | Win11 特有列表churn，「Issue is not observed with Windows 10」 | [14] |
| **hky.moe** | 想删微软拼音，直接删 User Profile/System Backup 注册表无效 | 「删完了重启…实际上并没有效果」；只有 Get/Set-WinUserLanguageList 有效 | [9] |
| **Weasel issues**（#872/#929、rime/home#1461） | Win11 下切换不到 rime/候选框异常 | 多为 ctfmon 未起（升级后未重启）、22H2 Chrome 兼容；重添加键盘/重启可缓解 | [15] |

对「我们的 TIP 被剔」的最可能解释（按证据强度）：

1. **整表回写竞态**（最直接）：`Set-WinUserLanguageList` 写入成功（6 秒检查在同进程内，看到的是自己的写入）→ 几分钟后某系统组件（ctfmon 会话刷新/回写、TIMS、语言组件任务、设置同步之一）用陈旧快照做了整表回写，把我们洗掉。VM v6 时间线（设 override 后才被剔）与此吻合。
2. **ctfmon 应用默认输入法时校验失败 → 禁用+剔除**：校验内容疑与我们缺少**键盘布局关联**有关（VM 观察微软拼音 LanguageProfile 下有 `Assemblies`/KeyboardLayout=0x8040804 关联，我们没有）——此条是 VM 内部推断，待取证确认。
3. **登录恢复/同步覆盖**：跨重启场景的放大器（我们观察到的是分钟级，主因不在此，但重登后也会叠加）。
4. **接纳性校验失败**（官方规则层面）：签名/flags/类别——我们已满足注册结构且能激活，可能性低，但官方原文明确「不满足会被 block 并可能被 Defender 移除」[3][4]。

## 3. 事件日志 / 诊断渠道

- **TSF 自己的日志**：provider `Microsoft-Windows-TSF-msctf`（GUID `{4fba1227-f606-4e5f-b9e8-fab9ab5740f3}`，消息文件 `msctf.dll`）[16]，带 `Debug` 与 `Diagnostic` 通道（VM 实测存在，默认禁用；启用需事件查看器「查看→显示分析和调试日志」，或 `wevtutil sl` `/e:true`）。已在本机 VM 启用，等下次触发剔除后取证。
- 盘点命令：`wevtutil el | findstr /i "tsf ctf input language textservices"`
- 没有公开的「TIP 被禁用原因」专用 ETW provider；**注册表写入者取证靠 Sysmon/审计**（见 §5）。
- 附带：Application 日志看 ctfmon/TextInputHost 崩溃；System 日志看 TIMS 服务故障。

## 4. User Profile 键的写者与同步

- 写者：`InstallLayoutOrTip`（用户上下文，写 `User Profile` + `Software\Microsoft\CTF` + `Keyboard Layout` 三处，**整表重写**）、`Set-WinUserLanguageList`（前者包装）、设置 UI（SystemSettings.exe）[1]。
- 读/合并方：explorer（启动时）、ctfmon/TSF（`WM_ACTIVATEAPP` 合并定时器刷新）、登录恢复（System Backup）、同步（SettingSync）。
- 消失方式：**整个 `InputMethodTips` REG_MULTI_SZ 被快照重写**（delete+rewrite），不是精准删一个元素——与「6 秒后还在、几分钟后整个值没了/少了我们」的观察一致。SO 案例 [8] 与 hky.moe [9] 都表现为「整键/整值被系统改写回来」。

## 5. 可立刻执行的取证步骤

```powershell
# 1) 事件通道盘点与启用（管理员）
wevtutil el | findstr /i "tsf ctf input language textservices"
wevtutil sl Microsoft-Windows-TSF-msctf/Debug /e:true
wevtutil sl Microsoft-Windows-TSF-msctf/Diagnostic /e:true
# 触发剔除后查询（Debug 通道）
wevtutil qe Microsoft-Windows-TSF-msctf/Debug /c:200 /rd /f:text

# 2) 计划任务盘点（语言组件/CTF）
Get-ScheduledTask | Where-Object {$_.TaskPath -match 'LanguageComponents|TextServicesFramework'} |
  Select TaskPath, TaskName, State, LastRunTime

# 3) 关闭语言设置同步（排除漫游覆盖）
#    设置 → 帐户 → Windows 备份 → 关闭「记住我的偏好设置」
#    或 MDM: ./Device/Vendor/MSFT/Policy/Config/Settingssync/DisableLanguageSettingSync = 1

# 4) 抓「谁删的值」——SACL 审计（无需装软件）：
#    a. secpol.msc → 高级审核策略 → 对象访问 → 审核注册表 = 成功/失败
#    b. 对 HKCU\Control Panel\International\User Profile 加审计 ACE（Everyone / Set Value, Delete）
#       （可用 Set-Acl 或 regini）
#    c. 复现剔除后查：Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4657}
#       4657 的 SubjectUserName/ProcessName 就是剔除者
#    更强方案：装 Sysmon，REGISTRY 事件（Id 12/13/14）过滤
#       TargetObject contains "Control Panel\International\User Profile"

# 5) ProcMon 交叉验证：Filter = Path contains "Control Panel\International\User Profile"，
#    Operation is RegSetValue / RegDeleteValue / RegDeleteKey；复现后看 Image 列。

# 6) A/B 实验矩阵（每个变量单独做）：
#    - 同一账号关同步后：设置 UI 手动添加 vs PowerShell 添加，谁存活？
#    - 不设 override 时是否仍被剔？（隔离 ctfmon 校验失败假设）
#    - 注册时补键盘布局关联（HKL 0x08040804 / Assemblies 键）后是否存活？
#    - 添加后重启 ctfmon + explorer（刷新语义：Win+Space/任务栏只在启动时读）再看。
```

## 6. 官方「接纳」要求清单（Q5）

来源：Globalization IME 页 [3]、Windows apps IME requirements [4]、Compatibility Cookbook [17]：

1. **必须数字签名**（Authenticode；不签名会被警告，恶意判定会被 Defender 移除）。
2. **必须 TSF 实现**（IMM32 IME 被系统 block）；设置正确的 IME flags（app 兼容自声明 flag、`ITfThreadMgrEx::GetActiveFlags` 感知 `TF_TMF_IMMERSIVEMODE`）。
3. **App container 兼容**：词库放 Program Files/Windows（或显式 ACL）；不得绕过容器安全规则（会被当恶意软件）；更新走独立桌面进程。
4. **图标存于 DLL/EXE 资源**（注册时给 resource ID；不要独立 .ico）；模式图标经 `GUID_LBI_INPUTMODE`（16x16@96dpi）；无语言栏，只有输入指示器。
5. **不要直接写注册表设默认键盘**（官方原话）[4]。
6. 可选接口：`ITfFnGetPreferredTouchKeyboardLayout`（触摸键盘）、搜索集成（`ITfSearchCandidateProvider` 等）。
7. Windows 11 没有公布独立的新校验清单，但 24H2 的动态重置行为（[11]）与 Keyman #15507 的「Win10 无此问题」表明行为差异在扩大。

## 7. 对照标准答案：Weasel 在 Win11 的启用序列（源码已核）

- `WeaselSetup/imesetup.cpp` `enable_profile()`：`CoCreateInstance(CLSID_TF_InputProcessorProfiles, CLSCTX_INPROC_SERVER, IID_ITfInputProcessorProfiles)`（**旧接口在 Win11 上可用**）→ `EnableLanguageProfile` + `EnableLanguageProfileByDefault`；卸载走 `RemoveLanguageProfile`。注册本体走 `regsvr32 /s`（带 `TEXTSERVICE_PROFILE` 环境变量、Wow64/ARM 重定向处理）。
- `output/install.nsi` 安装 `WeaselLanguageProfile.ps1`；该脚本（master 已是 PR #1959 后版本）：`Get-WinUserLanguageList` → 幂等增删 tip → **仅当有变化**才 `Set-WinUserLanguageList -Force`（同一进程内完成，避开快照竞态）；目标语言不存在时 exit 2，提示用户在设置中添加语言；legacy IMM/Preload/override 一并迁移。
- 结论：我们的修复方向排序——①修好 `ITfInputProcessorProfiles` 的 QI（我们曾 E_NOINTERFACE，疑 GUID 用错；Weasel 证明旧接口+EnableLanguageProfile 是可行路径）；②启用步骤放到**原用户身份**执行（提权 HKCU 是错的）；③启用后重启 ctfmon/explorer 或提示注销；④用 §5 的审计手段抓出当前环境的实际剔除者。

## 参考链接

[1] https://github.com/keymanapp/keyman/wiki/Making-sense-of-the-Windows-Layout-Registration
[2] https://github.com/rime/weasel/pull/1959
[3] https://learn.microsoft.com/en-us/globalization/input/input-method-editors
[4] https://learn.microsoft.com/en-us/windows/apps/develop/input/input-method-editor-requirements
[5] https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-international-settings-in-windows
[6] https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/troubleshoot-ime-common-issues
[7] https://github.com/metasequoiaime/msime-windows/pull/1218
[8] https://stackoverflow.com/questions/61370537/overwrite-input-method-list-in-windows-10
[9] https://hky.moe/archives/340/
[10] https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-settingssync
[11] https://learn.microsoft.com/zh-cn/answers/questions/3861606/window1124h2-bug
[12] https://github.com/A-cat-with-carrots/TypeAnything/issues/13
[13] https://github.com/Yi-frank-phy/neural-weasel/issues/29
[14] https://github.com/keymanapp/keyman/issues/15507
[15] https://github.com/rime/weasel/issues/872 · /issues/929 · https://github.com/rime/home/issues/1461
[16] https://winevt-kb.readthedocs.io/en/latest/sources/eventlog-providers/Provider-Microsoft-Windows-TSF-msctf.html
[17] https://learn.microsoft.com/en-us/windows/compatibility/third-party-input-method-editors
[18] https://github.com/LiberNT/LiberNT/pull/110 （`InstallLayoutOrTip`/`SetDefaultLayoutOrTip`/`EnumEnabledLayoutOrTip` 的 Win11 语义重实现，可作内部行为对照）
[19] https://learn.microsoft.com/en-us/windows/win32/tsf/installlayoutortip
