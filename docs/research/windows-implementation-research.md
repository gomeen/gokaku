# Windows 端实现调研（2026-11-06）

> **状态（2026-11-07）：本页未写完，仅作历史调研保留。** C 线（安装向导／设置应用／翻译部署）结论已并入[发布与构包](../release.md)；A 线（Weasel TSF 注册对照）与 B 线（CTF 剔除机制取证）仍缺后续章节，不作为已完成结论引用。

三路并行调研的汇总文档：C 线（安装向导/设置应用/翻译部署）已完成；A 线（Weasel TSF 注册对照）与 B 线（CTF 剔除机制取证）进行中，完成后补充。

---

## C 线：安装向导 / Win32 设置应用 / 嵌入式翻译部署（已完成）

调研日期：2026-11-06。全部体积数据为实测（macOS 侧下载 win_amd64 wheel 解压统计），安装脚本结论来自 Rime Weasel 仓库源文件直读。

### 一、安装向导

**先例：Rime Weasel（小狼毫）用 NSIS**（`output/install.nsi` 直读确认）：
- NSIS + MUI2，Unicode，SOLID lzma，`RequestExecutionLevel admin`
- 安装流：写 InstallDir 注册键 → 释放文件 → `WeaselSetup.exe /s` 注册 IME（**不用 regsvr32**——install.bat 里的 regsvr32 被注释掉，因为除 COM 注册外还要注册键盘布局/TSF profile）→ 卸载键 → `WeaselDeployer.exe /install` 部署方案 → Run 自启动 → 启动 WeaselServer
- **升级关键细节**：备份 data 目录；注释原话 "Keep TSF profiles during upgrades so Windows does not add a default IME"（升级保留 TSF profile 注册，避免 Windows 重新加默认 IME）；先停服务；DLL 常驻所有进程，升级锁死是 TSF 固有难题，解法是提示重启
- **卸载**：反注册 → 删 Run/卸载键 → 只删安装目录文件；**用户目录（%APPDATA%\Rime）完全不动**——「卸载保留用户数据」的先例写法：数据放用户目录，卸载器根本不碰

**三工具对比与推荐**：

| 维度 | Inno Setup | NSIS | WiX/MSI |
|---|---|---|---|
| 上手/脚本量 | 最低 | 中 | 高 |
| regsvr32 | 内建（Flags: regserver） | 手写 | SelfReg 表（微软不推荐） |
| 卸载保留用户数据 | 天然成立 | 基本天然 | 显式控制 |
| 先例 | 大量独立软件 | **Weasel 直接先例** | 企业生态 |

**推荐 Inno Setup**（需求每条有内建机制、脚本量最小）。要点：
1. `PrivilegesRequired=admin`（TIP 的 CLSID/CTF 注册写 HKLM 不可避免）；数据放 `%LOCALAPPDATA%\Gogaku`
2. `DllRegisterServer` 必须完成 COM CLSID + TSF category + profile 注册的全部工作（MS 文档要求）；安装器端 `Flags: regserver`
3. 升级时杀常驻进程；锁定文件用 `restartreplace` + 重启提示
4. 无签名体验：SmartScreen「更多信息→仍要运行」；EV 证书已不再即时免黄条（DigiCert 确认）；微软对第三方 IME 明确要求 digitally signed（正式分发时的决策点）
5. 备选免提权路径：`InstallLayoutOrTipUserReg`（写 HKCU、per-user，但第三方 IME per-user 注册存在版本兼容坑，首发走 admin）

来源：Weasel install.nsi / install.bat / WeaselSetup.cpp；TSF 注册文档；keyman wiki（Windows Layout Registration）；微软第三方 IME 兼容性文档；Inno Setup 帮助。

### 二、Win32 原生设置应用

**先例：Weasel 两套 UI 均无 MFC/无 .NET**：
- WeaselSetup.exe：ATL（CAppModule + InstallOptionsDlg 对话框）
- WeaselDeployer.exe（日常设定入口）：**纯 Win32 资源模板对话框 + 手写 Dialog 过程**（Configurator、DictManagementDialog、UIStyleSettingsDialog 等）

**推荐：纯 Win32 对话框**（与 /MT 静态 CRT 工程链一致，单 EXE 零依赖）。写法二选一：.rc 对话框模板 + DialogBoxParam（WeaselDeployer 式，零框架）；或 ATL CDialogImpl（WeaselSetup 式，/MT 可静态链接）。

**不推荐 WinUI3/XAML Islands**：为十几个开关的表单引入 Windows App SDK 运行时（数十 MB、首启解包）与输入法「稳定、轻」诉求相悖。

控件清单：方案 ComboBox、模糊音 CheckBox 矩阵、英文候选/调频 CheckBox、清空用户数据 Button+二次确认、版本区（.rc VERSIONINFO 从 version.json 注入）；必加 Per-Monitor V2 DPI 清单 + Microsoft YaHei UI 字体。

配置读写：settings.json（nlohmann/json 单头库）放 `%LOCALAPPDATA%\Gogaku\`；写临时文件 + ReplaceFile 原子替换；保存后走核心热更新机制；清空用户数据只删用户目录内容、不碰随包只读数据。

### 三、嵌入式 Python + CTranslate2 翻译部署

**Python embeddable 离线安装**（python-3.12.10-embed-amd64.zip 实测 11.1MB/解压 21.5MB，自带 vcruntime，不带 pip）：
1. 解压到 `<安装目录>\runtime\python\`
2. 编辑 python312._pth：加 `Lib\site-packages` + 取消 `import site` 注释（embed 包最常见坑）
3. 开发机预装 site-packages（ct2/numpy/pyyaml/sentencepiece）连同 python 目录打进安装包，目标机零安装零网络

**ctranslate2 wheel（4.8.5 win_amd64 实测 19.5MB/解压 61.4MB）**：纯 CPU 无需 CUDA/cuDNN；Python 依赖仅 numpy+pyyaml；运行时最小集 = ct2+numpy+pyyaml+sentencepiece（**不要打包 transformers，数 GB 级浪费**）。VC 陷阱：ct2 wheel 不带 msvcp140（numpy/sentencepiece 各自带私有副本），整包缺一份 msvcp140.dll → app-local 拷贝或静默装 vc_redist。

**INT8 跨平台「逐字一致」不能默认成立**：
- ct2 issue #1193：同 INT8 模型不同 CPU 输出不同（指令集路径累加顺序，Intel CNR 文档）；Mac ARM NEON vs Win x86 差异更大
- greedy 解码无随机源（#1757）✓；线程数影响归约顺序 → 固定线程
- 落地：固定 greedy + 固定线程；**验收标准改为「Mac 测试集在 Windows 跑 diff，token 级差异率设阈值」**（与实施计划既有口径「同一权重不同 CPU 后端不保证逐字一致，分别跑同一验收集并审阅差异」一致）

**体积估算（实测）**：运行时小计 ~45MB 压缩/~128MB 解压；small100 INT8 模型+分词器 ~328MB；**翻译管线合计 ~455MB**。词库 45MB 另算。

**替代方案**：ONNX Runtime 迁移不推荐（手写 encoder-decoder 生成循环 + 重新验收，抵不上省 100MB）；CT2 C++ API 直连去 Python 层属未来优化。

**进程形态（重要）**：**绝不能在 TSF 进程内 LoadLibrary Python**（CRT/DLL 全局状态冲突拖垮宿主）——独立 worker 进程 ✓ 现有架构正确。通信推荐 worker 常驻 + 127.0.0.1 loopback socket + JSON-lines（Python 标准库支持、不触发防火墙；命名管道需 pywin32 反而增依赖）。生命周期：Run 自启动或 TSF 首用拉起；模型加载 1-3 秒需预热；INT8 常驻内存 ~400MB 量级 → 空闲超时退出+按需重启（对齐「内存敏感路径」验收基调）。

**部署清单**：runtime\python\（embed+site-packages）、msvcp140.dll、models\small100-ct2-int8\（Mac 产物+SHA256+ct2 版本记录）、worker\ 脚本、自启动+loopback 服务、requirements 锁版本+diff 验收。

---

## A 线：Weasel TSF 注册对照（已完成，全文见代理输出归档）

要点：Weasel 不手写 HKLM CTF 注册表——DllRegisterServer = 手写 HKCR\CLSID（仅 COM 加载点）+ ITfInputProcessorProfileMgr::RegisterProfile（API 写）+ ITfCategoryMgr::RegisterCategory（API 写类别）；「加入用户已启用列表」= 旧接口 ITfInputProcessorProfiles::EnableLanguageProfile + EnableLanguageProfileByDefault（安装器）+ PowerShell Set-WinUserLanguageList（Get→幂等改→仅变化才 Set，同进程避免竞态）。

## B 线：CTF 剔除机制取证（已完成，正式记录见 docs/research-ime-windows11-pruning.md）

结论：无专门剔除进程——启用列表是「整表重写」语义＋多进程快照竞态；叠加四个放大器（默认输入法动态调整、登录恢复、设置同步、接纳性校验）。**我们的时间线（设 override 后被剔）与此吻合：ctfmon 应用默认输入法时校验失败→禁用＋剔除**。修复清单：①启用走 EnableLanguageProfile API（已打通✓）②启用步骤以原用户身份执行（提权 HKCU 是管理员 hive——已按此修正✓）③补键盘布局关联再测 override ④启用后重启 ctfmon/explorer（已纳入 v8 流程✓）⑤审计注册表写入者（SACL+事件 4657/Sysmon）锁定实际剔除者。
