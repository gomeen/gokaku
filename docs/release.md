# 发布与构建流程（Mac＋Windows）

构建、发布、更新的完整流程总览。版本号规则见 [versioning.md](versioning.md)；验收门槛细则见 [native-development.md](native-development.md)；本文只讲「从代码到可安装包」的流水线和各阶段的守门条件。

**状态标注**：✅ 已验证可用；🚧 部分就绪；⬜ 未开始。

## 0. 总览：四个交付等级

| 等级 | 版本形态 | 给谁 | 门槛 | 产物 |
| --- | --- | --- | --- | --- |
| 开机构建 | `0.1.x-dev.N`（构建号递增） | 自己 | `verify.py --profile fast`（约 2 分钟） | Mac 两 App＋Windows 包（T2.6 后） |
| 功能交付包 | dev 版＋Windows dev zip | 自己＋朋友（测试用途） | fast＋Windows VM 全绿证据 | dist＋zip（含构建身份与哈希） |
| 候选版 rc | `0.1.x-rc.N` | 朋友正式试用 | **工作区干净**＋`--profile release` 全量（约 2.5 小时，后台）＋双端 VM/真机证据 | 双端安装包＋身份记录＋验证报告 |
| 定版 | `0.1.x`＋标签 `v0.1.x` | 归档 | rc 全过＋用户试用确认 | 标签一经创建不移动 |

每次**对外提供安装包前递增 `version.json` 的构建号**；rc／定版构建由脚本强制要求干净工作区，标签不可重建。构建身份（包内 `build-identity.json`＋外部 `dist/build-identity.json` 含 SHA-256）必须与验收报告绑定，报告不回写源码。

## 0.5 双通道安装（stable＋dev 并存）✅

2026-11-06 裁决：日常使用与开发测试隔离，用户数据共用。

| | stable（日常） | dev（测试） |
| --- | --- | --- |
| 输入法包 | `Gogaku.app`（`org.gogaku.inputmethod`） | `Gogaku Dev.app`（`org.gogaku.inputmethod.dev`） |
| 设置包 | `Gogaku Settings.app` | `Gogaku Settings Dev.app` |
| 输入源菜单 | Gogaku | Gogaku Dev |
| 用户数据 | `~/Library/Application Support/Gogaku/`（**两通道共用**：学习词、自定义词、设置、备份） | 同左 |

- 构建：`python3 scripts/build.py --channel dev`（dist 产物名区分；清单与身份文件分通道：`bundle-manifest-dev.json`／`build-identity-dev.json`）。
- 安装：`python3 scripts/manage-install.py install --channel dev`；卸载/诊断/恢复同参数。跨通道装错会被 `own()` 哈希校验拒绝。
- 验证：`python3 scripts/verify.py --profile fast --channel dev`。
- 通道检测由 bundle ID 后缀派生（无配置文件）；Darwin 通知（settings.changed 等）两通道共用——数据共用下跨通道热更新是预期行为。
- 稳定通道建议装 rc／定版；dev 通道装开发构建。**卸载任一通道的 `--purge-data` 会删掉共用数据，影响另一通道**（脚本有显式确认）。
- Windows（TSF 后）：同一约定——独立 CLSID／档案名「Gogaku Dev」＋`%LOCALAPPDATA%\GogakuDev`，待 T2.3 落地时实现。

## 1. Mac 构建流程 ✅

```
python3 scripts/build.py                     # 全流程（见下）
python3 scripts/verify.py --profile fast     # 验证门槛
python3 scripts/manage-install.py install    # 当前用户安装（可选：uninstall/recover/diagnose）
```

`build.py` 单命令流水线：读 `version.json`（非法即拒绝）→ 菜单图标检查 → `prepare-dependencies.py`（libime 等依赖缓存，同 pin）→ EngineBridge／GogakuCore CMake 构建＋核心 ctest → Swift 构建（Release）→ 组装 `dist/Gogaku.app`＋`dist/Gogaku Settings.app` → 生成 `bundle-manifest.json`（逐文件 SHA-256）＋`build-identity.json` → `lsregister -u` 注销 dist 产物（防双注册）。

选项：`--configuration debug`（开发诊断）、`--validation`（验收状态接口）、`--prepare`（强制重建依赖）。

`manage-install.py install` 语义：备份旧版（保留 3 份，`.app.disabled` 防 LaunchServices 误启动）→ 按清单哈希逐文件校验安装结果 → 刷新 HUD 图标缓存；不触碰其他输入源，不自动切换输入法。更新＝重跑构建＋install，学习数据在 `~/Library/Application Support/Gogaku/` 不受影响。

**签名现状**：ad-hoc（无 Apple 开发者账号），仅本机安装；公开分发与公证不在本轮范围。

### 输入源身份与 dist 中立化（2026-11-06 事故根治）✅

输入法身份键（`TISInputSourceID`／`ComponentInputModeDict` 等 8 键）**只允许出现在安装目的地**：dist 产物一律中立（剥离身份键），被 LaunchServices 扫描注册也只是普通 App，永不进输入源列表；安装时在目标位注入身份＋ad-hoc 重签（manage-install／pkg postinstall／DMG command 三链路共用 `scripts/_gogaku_dist.py` 的键集合与重建逻辑）。事故经过与两个根因（dist 扫描幽灵＋pkg 沙箱幽灵）见该模块 docstring 与提交 41d5dff。后果约定：仓库里 `dist/*.app` 不能直接当输入法运行（缺身份键）——安装必须走三条链路之一；`check-bundle` 检查时按 bundle ID 重建身份。

### 标准安装包（2026-11-06）✅

给「双击就能装」的正常体验，构建后打两种包（`scripts/package-macos-pkg.py`／`package-macos-dmg.py`）：

- **pkg（推荐，Squirrel 同款路线）**：`dist/Gogaku-<版本>-b<构建号>.pkg`——双击 → 安装器向导（欢迎页＋说明页）→ 完成，无需管理员密码（用户级：`domains` 限定当前用户主目录，payload 为空、postinstall 落位＋`lsregister` 重注册）。pkg 装出的文件**不带隔离标记**（DMG 拷出会带，会拦输入法进程——这是输入法普遍用 pkg 而非 DMG 的原因）。落位与 manage-install 一致：输入法 → `~/Library/Input Methods/`，设置 → `~/Applications/`；升级不删学习数据。postinstall 若检测到当前输入源正选着 Gogaku 会提示切换一次加载新版。实测：`installer -pkg … -target CurrentUserHomeDirectory` 成功、构建号/签名/多通道并存全部核对。
- **DMG（备选）**：内置「安装 Gogaku.command」双击即装（拷贝→去隔离→重注册→打开系统设置键盘面板）＋安装说明；给偏好 DMG 形态的场景。
- 工程坑记录：productbuild 手写 distribution 的 `choices-root` 结构会**静默产出无组件的 2KB 空壳**——必须 `--synthesize` 生成基线再补丁（domains/welcome/readme/title），脚本内置体积断言（<10MB 拒绝放行）。

## 2. Windows 构建流程 🚧

四个部件，三条构建线，最后组装：

| 部件 | 构建线 | 工具链 | 状态 |
| --- | --- | --- | --- |
| A. 共享核心 `gogaku_core.dll`（＋依赖 DLL 链） | **Mac 交叉编译** | mingw-w64 Clang64（GCC 16.2），同 pin 依赖 | ✅ VM 全绿（2026-11-05/06） |
| B. TSF 前端 `GogakuTsf.dll` | **Windows VM（或将来 CI）** | MSVC＋Windows SDK（计划硬约束，C ABI 调核心） | 🚧 开发中 |
| C. 设置应用 | Windows VM | Win32／MSVC | ⬜ 未开始 |
| D. 组装安装器（T2.6） | Mac（Python 打包脚本） | — | ⬜ 未开始 |

**A. 核心 DLL（Mac 上跑）**：`scripts/prepare-win-cross.sh`——POSIX 垫片解包 MSYS2 clang64 包到本地 sysroot → ECM → 隔离 Fcitx5Utils → IMEPinyin／数据工具 → 共享核心，全部同 pin（libime 5be1300 等）；产物哈希记录在案。副产物：一键自检 exe（`build-win-selfcheck-exe.sh`，从 git HEAD 构建，含两个 Windows 移植修复注入）。

**B. TSF（VM 里跑）**：VM 安装 VS Build Tools（一次性）；开发闭环＝Mac 写代码 → 同步源码到 VM → VM 内 CMake＋MSVC 构建 → VM 内注册（`regsvr32`）→ 真实按键测试（SSH 自动化）。将来 CI 上用同一套 CMake（GitHub Actions windows runner 自带 MSVC）。

**C/D. 设置＋安装器（待建）**：目标是收敛成一个 `scripts/build-win-app.py`：输入＝交叉构建产物（bin）＋EngineData 资源（`sc.dict`／`zh_CN.lm`／`english-words.txt`／`gloss.tsv`，跨平台已验证）＋TSF DLL＋设置应用；输出＝`dist/gogaku-win/<版本>/` 安装 zip（bin＋data＋注册/卸载脚本＋设置）＋`build-identity.json`（哈希对齐 Mac 侧格式）。学习模式翻译代理（small100 模型＋worker）作为独立可选组件后置（阶段 3），不阻塞普通输入包。

**验证门槛**（Windows 侧）：核心 ctest 全绿（VM）→ TSF 安装→切换→真实按键→上屏→卸载冒烟（VM）→ 安装器双击路径复验（VM）→ 朋友真机（真实硬件证据）。

## 3. 发布 checklist（每次对外提供包都走一遍）

1. **递增构建号**：编辑 `version.json` `buildNumber`＋1（对外提供安装包前必须）。
2. **fast 档**：`python3 scripts/verify.py --profile fast`；改动涉共享核心／内存敏感路径时加 `--profile release --only asan-ubsan --quick`。
3. **核心有改动时（Windows）**：重跑交叉构建 → VM 跑核心 ctest／自检包全绿。
4. **Mac**：`build.py` → `manage-install.py install` → 真实打字冒烟（完整 host 档仅在空闲时段）。
5. **Windows**：`build-win-app.py`（建成后）→ VM 安装→打字→卸载冒烟。
6. **提交证据**：验证报告、`docs/validation/native-development.md` 对应小节、CHANGELOG、构建身份文件入库。
7. **rc 级**：确认工作区干净（脚本会拒绝 dirty）；全量 `--profile release` 后台跑（约 2.5 小时，不阻塞日常）。
8. **分发**：把安装包＋构建身份（或哈希清单）发给测试者；记录发放对象与版本。
9. **定版**：全部验收＋用户试用确认后打 `v0.1.x` 标签（不移动）。

## 4. 应用更新流程

### 现状（诚实口径）

**没有自动更新**——产品方向明确本轮不含自动更新、不公开分发。现在的「更新」语义：

- **Mac**：重跑 `build.py`＋`manage-install.py install`（有备份、哈希校验、可 `recover` 回滚）。
- **Windows**（建成后）：重新跑安装器覆盖（安装器需先卸载或支持原地覆盖＋用户数据保留）。

### 数据兼容约束（更新时必须保持）

- 应用版本、核心 C ABI 版本、用户数据格式版本三者独立管理；升版本不构成改 ABI／改存储格式的理由。
- 学习记录（`user_dir` 下 `model.userlm`／`learned.txt`）、`custom-words.tsv`（带版本行，两端共用格式）、`settings`：新版本必须能读旧数据；丢弃或迁移都要在验收记录里写明。

### 更新机制的决策点（当前未定，需要裁决后才开工）

1. **前置：建远端仓库**（当前无远端 → CI 没跑过、更新分发也无依托）。建议 GitHub 私有仓库，一个动作同时解锁 CI 和 Releases。
2. **分发渠道**：GitHub Releases（先例：MyGo 用 Releases＋Ed25519 签名清单做更新检查，无 Apple 开发者账号可行）——App 内「检查更新」按钮拉清单 → 下载 → 校验签名与哈希 → 交给本机安装流程。
3. **Mac 端形态**：轻量自研检查器（设置页按钮＋下载后调 `manage-install`）即可满足本轮；Sparkle 框架是后续公开分发时再评估的选项。
4. **Windows 端形态**：dev 阶段＝重跑安装器覆盖；更新器小工具不在本轮范围。
5. **签名的现实约束**：包不签名（Mac ad-hoc／Windows 无证书）→ 测试者首次运行会遇 Gatekeeper／SmartScreen 提示，属预期行为，交付时附说明；正式签名要等账号与项目许可决定。

## 5. CI 的角色（现状）

- `windows-core.yml`：脚手架，**从未真实运行**（仓库无远端）。建远端后首跑预期要修：MSYS2 工具链差异、libc++ 兼容开关、路径形态、tar zstd——本地交叉构建已踩过大部分坑，有现成答案。CI 绿是 T2.1 的正式验收口径。
- Mac 侧 CI：无。候选 `mac-core.yml`（核心 ctest＋fast 档）可后置——本机 fast 档 2 分钟，日常开发价值有限，优先级低于 Windows CI。

## 6. 当前缺口清单

- ⬜ 远端仓库（阻塞：CI、Releases 更新、多人协作）
- 🚧 Windows TSF／设置／安装器（T2.3–T2.6）
- 🚧 `build-win-app.py` 统一打包脚本（A 线脚本已就绪，缺 B/C/D 的组装）
- ⬜ 更新检查机制（等远端＋选型裁决；MyGo 的 Releases＋Ed25519 方案可直接复用）
- ⬜ rc 级真机矩阵（朋友完整试用）
