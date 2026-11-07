# 发布与构建流程（Mac＋Windows）

从代码到可安装包、检查更新与 Draft Release 的流水线。版本规则见[版本管理](versioning.md)，功能状态见[双端功能对照](feature-parity.md)，更新合同见[检查更新](update.md)，验收门槛见[原生开发验收](validation/native-development.md)。

**状态标注**：✅ 已验证可用；🚧 部分就绪；⬜ 未开始。**未在真实安装包／真实宿主上验证的，不标 ✅。**

## 0. 交付等级

| 等级 | 版本形态 | 给谁 | 门槛 | 产物 |
| --- | --- | --- | --- | --- |
| 开机构建 | `0.1.x-dev.N`（构建号递增） | 自己 | `verify.py --profile fast`（约 2 分钟） | Mac 两 App＋Windows 组装输入（若产物齐全） |
| 功能交付包 | dev 版 | 自己＋朋友（测试用途） | fast＋构建身份＋安装冒烟 | Mac pkg；Windows Setup.exe（产物齐全时） |
| 候选版 rc | `0.1.x-rc.N` | 朋友正式试用 | **工作区干净**＋`--profile release` 全量＋双端安装／功能证据 | 双端安装包＋身份记录＋验证报告 |
| 定版 | `0.1.x`＋标签 `v0.1.x` | 归档 | rc 全过＋用户试用确认 | 标签一经创建不移动 |

每次**对外提供安装包前递增 `version.json` 构建号**；rc／定版构建由脚本强制要求干净工作区。构建身份（包内 `build-identity.json`＋外部 `dist/build-identity.json` 含 SHA-256）必须与验收报告绑定，报告不回写源码。

## 1. 双通道安装（stable＋dev）

2026-11-06 裁决：日常使用与开发测试隔离，用户数据共用。

| | stable（日常） | dev（测试） |
| --- | --- | --- |
| Mac 输入法包 | `Gogaku.app`（`org.gogaku.inputmethod`） | `Gogaku Dev.app`（`org.gogaku.inputmethod.dev`） |
| Mac 设置包 | `Gogaku Settings.app` | `Gogaku Settings Dev.app` |
| 输入源菜单 | Gogaku | Gogaku Dev |
| 用户数据 | `~/Library/Application Support/Gogaku/`（两通道共用） | 同左 |
| Windows（计划） | 独立 CLSID／档案名 `Gogaku` | `Gogaku Dev`＋`%LOCALAPPDATA%\GogakuDev` |

- 构建：`python3 scripts/build.py --channel dev`（清单与身份文件分通道：`bundle-manifest-dev.json`／`build-identity-dev.json`）。
- 安装：`python3 scripts/manage-install.py install --channel dev`；卸载／诊断／恢复同参数。跨通道装错会被 `own()` 哈希与身份校验拒绝。
- 验证：`python3 scripts/verify.py --profile fast --channel dev`。
- 通道检测由 bundle ID 后缀派生；Darwin 通知两通道共用（数据共用下跨通道热更新是预期行为）。
- **卸载任一通道的 `--purge-data` 会删掉共用数据，影响另一通道**（脚本有显式确认）。
- stable 只接受 stable 更新清单；dev 可接受 dev／rc。通道切换不自动。

## 2. Mac 构建（仅 PKG）✅

```
python3 scripts/build.py                     # 依赖→核心 ctest→Swift Release→组装双 App→身份
python3 scripts/package-macos-pkg.py         # 生成 dist/Gogaku-<版本>-b<构建号>.pkg
python3 scripts/verify.py --profile fast     # 验证门槛
python3 scripts/manage-install.py install    # 当前用户安装（可选 uninstall/recover/diagnose）
```

`build.py` 单命令流水线：读 `version.json`（非法即拒绝）→ 菜单图标检查 → `prepare-dependencies.py`（libime 等依赖缓存，同 pin）→ EngineBridge／GogakuCore CMake 构建＋核心 ctest → Swift 构建（Release）→ 组装 `dist/Gogaku.app`＋`dist/Gogaku Settings.app`＋`update-config.json` → 生成 `bundle-manifest.json`（逐文件 SHA-256）＋`build-identity.json` → `lsregister -u` 注销 dist 产物（防双注册）。

选项：`--configuration debug`（开发诊断）、`--validation`（验收状态接口）、`--prepare`（强制重建依赖）、`--channel dev`。

### 2.1 输入源身份与 dist 中立化

输入法身份键（`TISInputSourceID`／`ComponentInputModeDict` 等 8 键）**只允许出现在安装目的地**：dist 产物一律中立（剥离身份键），被 LaunchServices 扫描注册也只是普通 App，永不进输入源列表。`manage-install` 在安装位注入身份并 ad-hoc 重签；**pkg 在打包阶段**把身份注入 staged App 并用 Developer ID（或 ad-hoc）签名，postinstall 只校验、不重签，以保留 Developer ID 签名与公证。身份键集合与重建逻辑共用 `scripts/_gogaku_dist.py`。事故经过与两个根因（dist 扫描幽灵＋pkg 沙箱幽灵）见该模块 docstring 与提交 41d5dff。后果约定：仓库里 `dist/*.app` 不能直接当输入法运行（缺身份键）——安装必须走 manage-install 或 pkg；`check-bundle` 检查时按 bundle ID 重建身份。

### 2.2 PKG（唯一对外 Mac 产物）🚧

`scripts/package-macos-pkg.py` 生成 `dist/Gogaku-<版本>-b<构建号>[-dev].pkg`：

- 用户级安装，无需管理员密码；`domains` 限定当前用户主目录，payload 为空，postinstall 落位＋`lsregister` 重注册。
- pkg 装出的文件不带隔离标记（DMG 拷出会带，会拦输入法进程——这是输入法普遍用 pkg 而非 DMG 的原因）。**本轮不再生成或交付 DMG。**
- 落位与 manage-install 一致：输入法 → `~/Library/Input Methods/`，设置 → `~/Applications/`；升级不删学习数据。
- **事务式 postinstall**（`scripts/pkg-postinstall.sh`）：解包 → 校验包内已注入身份／构建号／签名 → 备份旧包 → 替换 → 核对安装后身份／构建号 → 注册。任一步失败恢复两者；不先删除唯一可用副本。
- **包内 App 的身份与签名在打包阶段完成**：`package-macos-pkg.py` 复制 dist 中立 App 到 staging、注入输入源身份、由内向外签名（Developer ID 或 ad-hoc），再打成 zip。postinstall 不再重签，因此 Developer ID 签名不会被降级。
- 安装器含欢迎页、说明页与**安装完成页**（添加输入源／打开设置／检查更新指引）。
- 事务状态写入 `~/Library/Application Support/Gogaku/install/transaction.txt`；中断后下次 pkg 安装先恢复旧版本；备份保留最近两份（`.disabled` 后缀防 LaunchServices 误启动）。
- 若当前输入源正选着 Gogaku 或旧进程仍在运行，只提示切换输入源／注销，不强杀宿主。
- 工程坑：productbuild 手写 distribution 的 `choices-root` 结构会静默产出无组件的 2KB 空壳——必须 `--synthesize` 生成基线再补丁；脚本内置体积断言（<10MB 拒绝放行）。

**当前状态**：已用真实 `installer -pkg ... -target CurrentUserHomeDirectory` 复验构建 87 dev（双 App 构建号、身份、签名、事务成功、安装后 helper 均核对）；ad-hoc 包 `spctl` 仍拒绝，Developer ID／公证未跑（无证书）。

### 2.3 签名与公证（正式分发）

开发测试包默认 ad-hoc，`pkgutil --check-signature` 显示无签名，Gatekeeper 会提示。正式分发需要 Apple Developer ID：

```sh
# 一次性：存 notarytool 凭据（app-specific password）
xcrun notarytool store-credentials gogaku-notary \
  --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx

# 签名 App + 签 pkg + 公证 + stapling + Gatekeeper 评估
python3 scripts/package-macos-pkg.py --channel stable \
  --app-sign-identity "Developer ID Application: Your Name (TEAMID)" \
  --installer-sign-identity "Developer ID Installer: Your Name (TEAMID)" \
  --notarize --notary-profile gogaku-notary
```

也可用环境变量：`GOGAKU_APP_SIGN_IDENTITY`、`GOGAKU_INSTALLER_SIGN_IDENTITY`、`GOGAKU_NOTARY_PROFILE`。

脚本行为：

1. 用 `security find-identity -v -p codesigning` 校验身份存在，缺失立即失败；
2. 对 `Contents/Frameworks`、`Helpers`、`MacOS` 内的 Mach-O 由内向外签名（`--options runtime --timestamp`），再签 App 根；
3. `productbuild --sign` 签 pkg；
4. `xcrun notarytool submit --wait` → `stapler staple` → `stapler validate` → `spctl -a -vv -t install`，任一步失败不交付。

**未验证**：本机无 Developer ID 证书，签名／公证／`spctl` 通过路径未执行；ad-hoc 路径已真实安装验证。

## 3. Windows 构建（Setup.exe）

构包流程只要求编译与静态检查，Windows 桌面不作为前置。**后续代码迭代**可用 `python3 scripts/prepare-win-setup.py --plan` 查看缺项；首次按 `--stage deps --download` 备齐固定依赖，缺出厂数据时按脚本提示运行 `scripts/prepare-dependencies.py`，再依据 `--tools-help` 手动准备 Wine／官方 Inno，最后执行 `--stage setup --download`（仅联网补齐缺失许可）生成安装输入。日常直接重编 x64、x86 后打包，不再手工猜测缓存路径。该准备器已做静态／自测验证，尚未在全新机器上完成网络拉取到最终安装包的端到端验收。用户后续授权连接其已安装的 Windows VM 排查输入、候选窗、设置与图标；限定运行结果见[验收记录](validation/native-development.md)。当前工作区新生成 dev b92 双端安装包与 fast 报告（仅构包验证）见[原生开发验收](validation/native-development.md)；构建 91 的历史构包结果仍见 [windows-setup-build.json](validation/windows-setup-build.json)，功能缺口见[对照表](feature-parity.md)。[构建 91 的限定运行证据](validation/windows-desktop-b91.json)保留了冷启动首组输入失败，不能据此标为稳定版，更不能用作 b92 的 VM 验收；安装前曾人工迁走占用文件，不是无干预升级验收。

| 部件 | 构建线 | 工具链 | 状态 |
| --- | --- | --- | --- |
| 共享核心 `libgogaku_core.dll`（x64） | Mac 交叉编译 | MinGW-w64 GCC 16.2；静态链接依赖 | 已编译；最终 DLL 只导入系统库 |
| TSF `GogakuTsf.dll`（x64／x86） | Mac 交叉编译 | MinGW-w64，真实 COM 接口 | 两架构已编译，通过管道连 x64 代理 |
| 每用户代理 `GogakuAgent.exe`（x64） | Mac 交叉编译 | MinGW-w64／WinHTTP／CNG | 已编译；核心、翻译、拼写与托盘入口已接通 |
| 设置 `GogakuSettings.exe`（x64） | Mac 交叉编译 | Win32／Direct2D／DirectWrite／WIC | 七页设置与更新窗口已编译 |
| 安装向导 | Mac 上运行编译器 | Wine＋官方 Inno Setup 6.7.4 | 实际构包；不启动生成的程序 |

```sh
# 首次准备（--download 只补齐缺失的固定源码／小包／许可；Wine/Inno 手动准备）
python3 scripts/prepare-win-setup.py --plan
python3 scripts/prepare-win-setup.py --stage deps --download
# 若提示出厂数据缺失，按提示运行 scripts/prepare-dependencies.py
python3 scripts/prepare-win-setup.py --tools-help
python3 scripts/prepare-win-setup.py --stage setup --download

# 平时迭代：每次改动源码后编译两架构（默认 dev）
python3 scripts/compile-win-native.py --arch x64 --jobs 3
python3 scripts/compile-win-native.py --arch x86 --jobs 3

# 检查编译收据与固定数据／许可证，再构建安装器
python3 scripts/build-win-app.py --channel dev --check \
    --data-dir .build/win-app/dev/data \
    --license-dir .build/win-app/dev/licenses
python3 scripts/build-win-app.py --channel dev \
    --data-dir .build/win-app/dev/data \
    --license-dir .build/win-app/dev/licenses \
    --iscc .build/win-tools/iscc
```

两架构编译完成时分别写入 `build-receipt.json`，打包前逐文件校验编译来源、通道、源码指纹及锁定数据；Mac 打包同样强制校验两 App 的构建身份和当前源码。安装包旁的 `*.receipt.json` 记录安装包大小及哈希；打包脚本不会把旧二进制仅改名冒充新构建。`--check` 只检查，不生成安装包。收据和本地构建可防误用缓存，不等同于代码签名或真机验收。

安装器（`packaging/windows/gogaku.iss.in`）：

- Windows 11 x64；同时带 x64 与 x86 TSF，仅 x64 代理持有业务核心。
- UAC 完成机器级注册；注册错误在文件安装事务内中止，不以 `[Run]` 忽略退出码。自启为可选项，按原用户身份写 HKCU。
- 程序与只读资源装入 Program Files；数据由程序写 `%LOCALAPPDATA%\Gogaku`；卸载默认保留数据。
- 当前使用固定目录；升级／卸载先检查已加载程序，要求用户退出代理和宿主，无法替换时中止。版本目录与上一版本恢复尚未完成。
- 不设置默认输入法，不强杀宿主，不自动注销／重启，不安排锁定文件下次重启替换。
- 未做 Authenticode 签名；不关闭系统安全机制。

Windows VM 中的安装、限定文本宿主、设置和图标结果与编译、静态包检查分别记录。完整宿主、升级／卸载、真实翻译与在线更新仍未验收；用户使用与反馈步骤见[Windows 使用说明](windows-testing.md)。

## 4. 检查更新与 Draft Release

完整合同见[检查更新](update.md)。发布顺序：

1. 递增 `version.json` 构建号，构建双端安装包及两份 `*.receipt.json`；rc／定版要求工作区干净。
2. 使用与发布通道相同的验证报告（`verify.py --profile fast --channel dev`；rc／定版额外跑 release 档）。验证报告绑定源码指纹和两个安装包哈希；不通过门槛的报告不能发布。
3. `python3 scripts/publish-release.py --dry-run ... --verification-report <fast报告> ...` 离线核对收据、许可、报告、文件名与哈希；rc／定版同时传 `--verification-report <release报告>`。
4. `GITHUB_TOKEN=... python3 scripts/publish-release.py ...`：创建 Draft → 上传 pkg／setup → 取得 asset id → 生成并签名清单 → 上传清单与签名，生成 `release-state.json`。**不自动发布。**
5. 人工审阅 Draft 后，用原参数与原 `--out` 目录，加 `--publish-existing <Draft ID>`。脚本重新验证本地收据、报告、清单签名和远端 Draft 的四份资产，再只对指定 ID 执行 PATCH；若审阅期间资产变化，拒绝发布。也可在 GitHub 手动发布，但不会经过这一门槛。
6. 用两个构建验证旧版发现新版、下载、校验、安装、重开显示新版本、保留数据；记录报告。

发布脚本对缺失配置、私钥、许可材料或验证证据明确失败。`resources/update/config.json` 的 owner／repo 留空＝未配置更新源；客户端不得显示「已是最新」。生产发布前把 `trustedKeys` 换成生产公钥；脚本会拒绝配置中不存在的 `keyId`。私钥只存发布环境，绝不入库。

## 5. 发布 checklist

1. **递增构建号**：编辑 `version.json` `buildNumber`＋1。
2. **开发 fast 档**：`python3 scripts/verify.py --profile fast --channel dev`；改动涉共享核心／内存敏感路径时加 `--profile release --only asan-ubsan --quick`。打完双端安装包后重跑同通道 fast，报告必须绑定两个安装包哈希才能用于发布。
3. **核心有改动时（Windows）**：重跑交叉构建 → VM 跑核心 ctest／自检包全绿。
4. **Mac**：`build.py` → `package-macos-pkg.py` → 真实 `installer -pkg` 安装→打字→升级→恢复冒烟。
5. **Windows**：`build-win-app.py` → VM 安装→打字→检查更新→卸载冒烟。
6. **归档证据**：验证报告、`docs/validation/native-development.md` 对应小节、CHANGELOG 入库；构建身份与安装包收据随包归档（`dist` 生成物不强制入库）。`docs/validation/verify` 的保留策略：保留被文档／验收记录引用的运行记录、host 档全部运行，以及每个档位最新一份；其余历史运行在收敛时删除（git 历史仍可考）。
7. **rc 级**：确认工作区干净；全量 `--profile release` 后台跑（约 2.5 小时，不阻塞日常）。
8. **分发**：把安装包＋构建身份（或哈希清单）发给测试者；记录发放对象与版本。
9. **定版**：全部验收＋用户试用确认后打 `v0.1.x` 标签（不移动）。

## 6. CI 与当前缺口

- `windows-core.yml`：脚手架，**从未真实运行**（仓库无远端）。建远端后首跑预期要修：MSYS2 工具链差异、libc++ 兼容开关、路径形态、tar zstd。
- Mac 侧 CI：无。候选 `mac-core.yml` 可后置。
- ⬜ 远端仓库（阻塞：CI、Releases 更新、多人协作）。
- 🚧 Windows 安装／运行由用户验证；多候选预译、版本化升级恢复等实现缺口见[功能对照](feature-parity.md)。
- 🚧 Mac 双构建 pkg 升级／恢复复验（单次真实安装已有证据）。
- 🚧 真实 GitHub Releases 更新链路（P5）。
- ⬜ rc 级真机矩阵（朋友完整试用）。
