# 检查更新与发布清单

状态：**Mac 客户端协议实现并有离屏测试；0.3.0 起支持就地热更新与代码／数据包分离。数据下载资产是 `.pkg`，客户端通过 xar／gzip+cpio 取出内层 ZIP，再校验清单指纹与逐文件哈希；同构建号下检测到缺失或过期的数据指纹时，可只修复数据、不重复替换 App。Windows 原生客户端已交叉编译并随安装包提供，本轮继续读 schema 1 清单、安装整包（Windows 数据拆分与热更新待跟进）。发布侧已完成 `gomeen/gokaku` 的 GitHub Release、双端资产和清单签名验证；客户端从旧版点击检查、下载、安装并重开验证仍未完成。** 本文是更新合同、默认值和发布流程的唯一说明；功能状态见[双端功能对照](feature-parity.md)，安装流程见[发布与构建](release.md)。

## 一、范围与默认值

| 项 | 规则 |
| --- | --- |
| 检查入口 | 设置应用「关于」页的「检查更新」；检查结果与下载／安装操作均在同一页完成；「查看更新说明」打开只读说明窗口 |
| 自动检查 | **默认关闭**；开启后仅在设置窗口打开期间按 24 小时最多尝试一次（关闭窗口即退出设置应用） |
| 自动下载／安装 | **不自动下载或安装**；自动检查只拉取并验签元数据，发现新版后等待用户明确点击「下载更新」 |
| 输入法进程 | 不检查更新、不在按键路径联网或读更新缓存 |
| 通道 | 跟随安装通道：stable 只接受正式版本；dev 可接受 dev／正式（客户端兼容解析历史 rc，发布侧不再产生） |
| 降级 | 不自动降级；以构建号判定，同版本更高构建号可更新 |
| 请求内容 | 只请求 GitHub 公开 Releases；不携带输入内容、火山凭据、学习记录或设备唯一标识 |
| 系统信任 | 更新签名只证明来自发布者，**不替代** macOS 公证或 Windows Authenticode；未签名包的系统提示照实说明 |

自动检查失败不紧密重试；手动检查可立即重试。自动发现新版只在设置应用的「关于」页显示，不下载、不安装、不弹窗、不抢输入焦点。

### 更新交互

「关于」页是唯一的更新操作入口：手动「检查更新」只执行检查。发现新版后，macOS 由用户点击「下载并更新」触发下载、校验与安装；若代码构建号相同而本机数据指纹缺失或过期，则显示「修复出厂数据」，只下载并安装数据包。Windows 由用户分别点击「下载更新」和「安装更新」来启动交互式安装向导。自动检查只执行同一套检查，不下载、不安装、不打开窗口；启用时显示上次自动尝试的时间。检查失败或限流时清除旧的可操作候选，缓存的历史结果不能触发下载。两端的「查看更新说明」窗口只展示说明，不提供更新操作。

当前版本发现仍依赖 GitHub Releases API；限流会显示检查失败，不会显示为「已是最新」。绕开匿名 API 限流的更新入口是另一个待办。

## 二、清单合同（v1 ＋ v2 双清单）

自 0.3.0 起（数据／代码包分离＋就地热更新，2026-11 裁决），每个 Release 按产品附**两份**清单；schema 1 清单继续存在是为了旧客户端兼容，**数据包永不进 schema 1 清单**：

| 资产 | schema | 内容 | 读者 |
| --- | --- | --- | --- |
| `update-manifest.json` + `.sig`（Lite：`update-manifest-lite.json`） | 1 | 只含主包（Mac 代码 pkg／Windows Setup） | 0.2.0 及更早旧客户端；新客户端的回落路径 |
| `update-manifest-v2.json` + `.sig`（Lite：`update-manifest-lite-v2.json`） | 2 | 主包 ＋ `dataPackage` | 0.3.0 起新客户端（优先拉取，404／缺失回落 v1） |

- 完整版与 Lite 的清单各自独立（Lite 客户端不读完整版清单，反之亦然）。
- 签名均为对**清单原始 UTF-8 字节**的 Ed25519 分离签名；两份清单各自签名。客户端接受原始 64 字节或 base64 文本（含换行）。
- `version`／`buildNumber`／`channel`／`notes` 两份清单逐字一致（同一发布）；`assets` 在两份清单里完全相同（数据包只出现在 `dataPackage` 字段，不进 `assets`）。
- **`notes` 是应用内短纯文本，不是 GitHub 发布正文**（2026-11-21 裁决）：更新窗口用纯文本控件显示它（SwiftUI 的 `Text(String)` 与 Win32 `EDIT` 都不解析 Markdown），所以不得包含标题（`#`）、粗体（`**`）或表格（`|`）记号。发布时由 `publish-release.py` 从 `--notes-file`（GitHub 正文 markdown）自动压缩成摘要（去标题／表格／粗体，`- ` 转 `· `，`## 下载` 之后丢弃，上限 12 行／1200 字）；也可用 `--update-notes-file` 直接给一份手写的纯文本（含 Markdown 记号会被门禁拒绝）。

schema 1 清单示例（旧客户端视角，无数据包字段）：

```json
{
  "schema": 1,
  "keyId": "gogaku-prod-2026",
  "version": "0.1.2",
  "buildNumber": 90,
  "channel": "stable",
  "notes": "应用内更新说明（纯文本，≤ 12 行／1200 字；不得含 Markdown 记号）",
  "assets": [
    {
      "platform": "macos",
      "arch": "x86_64",
      "minOS": "26.0",
      "assetId": 123456,
      "name": "Gogaku-0.1.2.pkg",
      "size": 47185920,
      "sha256": "64 位小写十六进制"
    },
    {
      "platform": "windows",
      "arch": "x86_64",
      "minOS": "10.0.22000",
      "assetId": 123457,
      "name": "Gogaku-0.1.2-windows-x64-setup.exe",
      "size": 104857600,
      "sha256": "64 位小写十六进制"
    }
  ]
}
```

schema 2 清单在 schema 1 全部字段之上新增可选 `dataPackage` 对象：

```json
{
  "schema": 2,
  "keyId": "gogaku-prod-2026",
  "version": "0.3.0",
  "buildNumber": 121,
  "channel": "stable",
  "notes": "…",
  "assets": [ "…与 schema 1 相同，只含主包…" ],
  "dataPackage": {
    "platform": "macos",
    "name": "Gogaku-Data-0.3.0.pkg",
    "size": 15728640,
    "sha256": "64 位小写十六进制",
    "assetId": 123458,
    "dataVersion": "16 位小写十六进制"
  }
}
```

字段规则：

- `schema` 必须为 `1` 或 `2`；未知 schema 拒绝。schema 2 清单必须携带 `dataPackage`（缺失即非法，不能静默丢数据包）；schema 1 清单不得声明 `dataPackage`。
- `dataPackage`：数据包资产（本轮范围只有 macOS 有数据包，Windows 仍整包——Windows 拆分与热更新待跟进，见文末）。字段约束与 `assets` 同名规则一致（`name` 不得含路径分隔符、`size`／`sha256` 必须与 GitHub 资产一致、`assetId` 必须真实存在于该 Release 的资产列表）。`dataVersion` 为 16 位小写十六进制的数据内容指纹短哈希（算法见下文「数据包」）；数据没变的版本之间相同。
- **数据未变时清单复制上一版的数据包资产引用**（`assetId`／`name`／`size`／`sha256`／`dataVersion` 指向最近一次数据变化那个 Release 的资产）。客户端按 `dataVersion` 命中本地缓存时不下载；引用的资产随 GitHub 历史发布长期可下载，且客户端只在缓存未命中时才解析该引用。
- `keyId` 必须命中随包 `Contents/Resources/update-config.json` 的 `trustedKeys`。
- `version` 为 SemVer 三段数字，可带 `-dev.N`；2026-11-10 起不再使用 `rc.N`，构建脚本与发布门禁拒绝 rc。
- `buildNumber` 为正整数，必须**单调递增**；客户端按构建号判断代码升级、不自动降级；构建号相同则比较本安装 App 内记录的数据指纹，发现数据包缺失或指纹不符时提供仅修复数据的操作。
- `channel` 为 `stable`｜`dev`，必须与安装通道一致。
- `assets` 至少一项；`platform` 为 `macos`｜`windows`，`arch` 为 `x86_64`（本轮范围）；同一 `platform/arch` 不得重复；`minOS` 为点分数字；客户端只选择 `minOS <= 当前系统版本` 的资产。
- 本轮发布要求 macOS 与 Windows **主包**资产齐全才进入更新列表；客户端只下载自己平台／架构的资产。

客户端只接受正式 Release（`draft=false`）；stable 忽略 `prerelease=true` 的发布，dev 可读取。通过 GitHub API 的 `assetId` 核对资产（主包与数据包都要）属于该仓库／该 Release，再下载 `browser_download_url`。

## 三、验证与下载

1. 取 GitHub Releases 列表（`api.github.com`，分页最多 3 页 × 30，逐页 ETag 缓存；304 仅复用已验签清单并按当前构建重新比较，不能把签名失败当作最新）。
2. 每个候选 Release 优先找 `update-manifest-v2.json` 与签名；缺失（资产不在列表或下载 404）回落 `update-manifest.json` 与签名。v2 资产存在但**验签失败按「更新清单校验失败」处理，不静默回落 v1**。下载上限 256 KiB／8 KiB。
3. 用内置 Ed25519 公钥验证清单原始字节；签名失败、未知 keyId、未知 schema、字段非法都报「更新清单校验失败」。
4. 校验通道、构建号、平台、架构、最低系统版本。
5. 下载主包到当前用户可写的临时文件；校验长度与 SHA-256 后原子转为缓存文件；启动安装前再次校验。
6. schema 2 且本平台声明了 `dataPackage` 时：本地缓存 `~/Library/Caches/Gogaku/updates/data/<dataVersion>/` 没有该数据版本才下载数据 `.pkg`（同样校验外层包长度与 SHA-256；缓存命中不重复下载——数据未变的版本之间共用缓存）。主包更新时，数据包下载或安装失败不回滚已安装代码，UI 明示；同构建号的数据包修复则不下载主包，失败可重试。
7. 检查发现新版后等待用户确认；在 macOS 上点击「下载并更新」后才下载，校验通过后执行下文的热更新事务；不强杀宿主。
8. 下载可取消；取消删除临时文件；磁盘不足在开始前明确报错。

只接受 HTTPS，主机白名单：`api.github.com`、`github.com`、`objects.githubusercontent.com`、`release-assets.githubusercontent.com`、`github-releases.githubusercontent.com`。重定向必须仍在白名单内。限流（403／429 且 `x-ratelimit-remaining: 0`）、超时、离线、404、5xx、未知 schema、签名失败、通道不符、缺资产分别显示不同状态；**未配置更新源不能显示「已是最新」**。

### 就地热更新（0.3.0 起，Mac）

主包安装不再调用 `/usr/bin/open` 交给系统 Installer，而是客户端自己完成与 pkg postinstall 逐条对应的事务（`UpdateInstaller`）：

1. **recover**：读 `~/Library/Application Support/Gogaku/install/transaction.txt`；phase ≠ success 且备份存在时，先把备份里的旧包恢复回原位（处理上次中断的事务）。
2. **解包**：`xar -xf <pkg>` → 组件包 `Scripts`（`gzip -dc | cpio -idm`）→ `ditto -x -k Gogaku-apps.zip` 到 stage。zip 内的 .app 不会被 LaunchServices 提前扫描。
3. **校验 stage**：双 App 的 bundle ID、`CFBundleVersion` ＝ 期望构建号、输入法的 `TISInputSourceID`，以及 `codesign --verify --deep --strict`（代码包密封不覆盖 EngineData——数据由数据包按清单哈希另行校验）。
4. **备份**：`ditto` 复制（不移动）现有双包到 `install/backups/<时间戳>/`，写 `transaction.txt` phase=installing。
5. **替换**：`rm -rf` 旧包 → `mv` 新包到位；安装后复核身份；**EngineData 结转**——主包不再带出厂数据，schema 1 路径或数据包失败时从备份把旧词库结转进新包（核心兼容旧数据，输入法不因数据包缺失而不可用）。
6. **数据包**（schema 2 且已下载）：校验外层 `.pkg` 哈希后，通过 `xar` 解开组件包、`gzip+cpio` 解开 Scripts 归档，取出 `Gogaku-data.zip`；校验其 `manifest.json` 的 `dataVersion` 与已签名清单一致，并逐文件 SHA-256 校验（缺文件、哈希错、路径越界都拒绝），再依次替换双 App 的 `Contents/Resources/EngineData`。数据阶段失败**不回滚主包**：保留新代码＋结转的旧数据，UI 明示；同构建号修复只运行数据阶段。
7. **收尾**：`lsregister -f` 双 App；写 transaction.txt phase=success；保留最近两份备份；经 `org.gogaku.inputmethod.restart` 通知输入法优雅退出。

输入法进程交接：GogakuInput 启动早期注册该通知监听，收到后结束在途组合（草稿落盘）、延迟 1.5 秒调 `NSApp.terminate` 正常退出（**绝不 SIGKILL**）；imklaunchagent 在连接断开后按需拉起新版进程。设置应用不需要重启（磁盘上已是新代码）。旧的 open-installer 路径保留为 fallback：`xar`／`cpio`／`ditto`／`codesign` 等工具缺失时更新窗口自动改走系统安装器。

事务语义与失败恢复的权威参照是 `macos/packaging/pkg-postinstall.sh`（系统 Installer 路径）与 `UpdateInstaller.swift`（就地路径），两者逐条对应；中断恢复同用一份 `transaction.txt`。

### 数据包（0.3.0 起，Mac）

- `Gogaku-Data-<版本>.pkg`（Lite：`GogakuLite-Data-<版本>.pkg`）只含双 App 的出厂数据；`Scripts/Gogaku-data.zip` 内含 `manifest.json` 与文件载荷。系统 postinstall 与客户端就地安装均校验逐文件 SHA-256、备份替换并失败恢复。
- 成功安装后，每个 App 的 `Contents/Resources/EngineData/.gogaku-data-version` 记录该 App 的数据指纹；客户端读取当前设置 App 的标记。同构建号且标记缺失／不匹配时，关于页提供只修复数据的操作。兼容诊断收据仍写入 `~/Library/Application Support/Gogaku/install/last-data-version.txt`。
- **数据内容指纹**：对排序后的 `(相对路径, sha256)` 清单文本（`path:sha256` 每行一条、`\n` 连接）再取一次 SHA-256，取前 16 位十六进制记作 `dataVersion`。同一数据集合在任何版本上指纹相同——这是「数据未变不重发、客户端跨版本复用缓存」的依据。发布侧（`_gogaku_delivery.data_fingerprint`）与客户端（`UpdateDataManifest.fingerprint`）逐字同算法，两侧测试绑定。
- 数据包只覆盖**出厂**数据；用户词频、自定义词、设置等用户数据不受影响（安装/升级默认保留）。

## 四、配置与密钥

随包 `resources/update/config.json` → `Gogaku Settings.app/Contents/Resources/update-config.json`：

```json
{
  "schema": 1,
  "owner": "gomeen",
  "repo": "gokaku",
  "trustedKeys": [
    { "keyId": "gogaku-prod-2026", "publicKey": "base64 原始 32 字节" }
  ]
}
```

- `owner`／`repo` 留空＝本机构建未配置更新源；客户端明确显示未配置。
- 当前仓库配置为 `gomeen/gokaku`；发布侧资产和清单签名已在 b110、b118 及 0.5.0（b131）三轮验证（b118 时资产名仍含构建号，见 [release-b118.json](validation/release-b118.json)；最新见 [release-0.5.0.json](validation/release-0.5.0.json)），客户端安装闭环仍待验证。2026-11-19 起资产名只用版本号，不再含构建号。
- 公钥可轮换：保留旧 keyId 直到所有受支持版本升级完成；私钥只存发布环境，绝不入库。
- 开发公钥 `gogaku-dev-2026-11` 仅用于协议回归；生产发布前替换为生产公钥。
  发布脚本会拒绝 `trustedKeys` 中不存在的 `keyId`，避免客户端无法验证的清单上线。
- 源码仓库是否公开与发布仓库无关；发布仓库公开不等于必须公开全部源码，但第三方许可要求的源码／重链接说明仍须提供。

## 五、发布流程

```sh
# 1. 定版：两端包和收据就绪后，运行相同通道的 fast、release、host
#    （release／host 可沿用同版本、Mac 平台指纹未变的旧构建报告；fast 每个构建重跑）
python3 scripts/verify.py --profile fast --channel stable
python3 scripts/verify.py --profile release --channel stable
# 仅在用户空闲并授权后运行；当前 host 探针只支持 stable；核心／IMK 改动用 host-full
python3 scripts/verify.py --profile host --channel stable --yes

# 2. 本地检查（不联网；实际报告文件名以 verify.py 输出为准）
python3 scripts/publish-release.py --dry-run \
  --repo gomeen/gokaku --channel stable \
  --macos-pkg dist/Gogaku-0.3.0.pkg \
  --macos-data-pkg dist/Gogaku-Data-0.3.0.pkg \
  --previous-state dist/release-0.2.0/out/release-state.json \
  --windows-setup dist/Gogaku-0.3.0-windows-x64-setup.exe \
  --verification-report docs/validation/verify/report-fast-YYYYMMDD-HHMMSS.json \
  --verification-report docs/validation/verify/report-release-YYYYMMDD-HHMMSS.json \
  --verification-report docs/validation/verify/report-host-YYYYMMDD-HHMMSS.json \
  --notes-file dist/update/notes.md

# 3. 创建 Draft、上传主包／数据包／setup，生成并上传双清单与签名
GITHUB_TOKEN=... python3 scripts/publish-release.py \
  --repo gomeen/gokaku --channel stable \
  --macos-pkg dist/Gogaku-0.3.0.pkg \
  --macos-data-pkg dist/Gogaku-Data-0.3.0.pkg \
  --previous-state dist/release-0.2.0/out/release-state.json \
  --windows-setup dist/Gogaku-0.3.0-windows-x64-setup.exe \
  --verification-report docs/validation/verify/report-fast-YYYYMMDD-HHMMSS.json \
  --verification-report docs/validation/verify/report-release-YYYYMMDD-HHMMSS.json \
  --verification-report docs/validation/verify/report-host-YYYYMMDD-HHMMSS.json \
  --notes-file dist/update/notes.md \
  --key ~/Library/Application\ Support/Gogaku/update-signing/prod-private-key.txt \
  --key-id gogaku-prod-2026

# 4. 人工审阅 Draft 后，沿用第 3 步完全相同的参数，仅追加 --publish-existing 123456
# 123456 必须是第 3 步返回的 Draft ID，不会再创建 Release。
```

流程细节：

- 先上传主包与数据包，取得 GitHub `asset id`；`scripts/make-update-manifest.py` 用真实 ID 生成双清单，避免清单指向不存在的资产。
- 数据未变（本轮数据包收据的 `dataVersion` 与 `--previous-state` 记录相同）时：**不重复上传数据包**，schema 2 清单复制上一版的 `dataPackage` 资产引用；客户端按 `dataVersion` 命中缓存，实际下载量不因清单引用而增加。
- 数据变化时必须提供本轮数据包；主包必须始终存在；**数据包缺失时清单不得声明 dataPackage**（此时只能发 schema 1 清单，发布脚本会拒绝只发 schema 2 却缺 dataPackage 的组合）。
- 上传顺序：pkg／setup → 数据包 → 本地 `asset-ids.json` → 双清单（v1＋v2）与各自 `.sig`。全部成功后仅写 `release-state.json`（含 `dataPackage` 引用记录，供下一版 `--previous-state` 复用），必须另行人工审阅并指定同一 Draft ID 发布。
- 发布脚本对缺失配置、私钥、许可材料、编译／打包收据或验证证据明确失败，不制作看似可更新的假发布。dev 至少 fast；定版需 fast＋release＋host（或 host-full）。fast 必须匹配当前策略、必需检查清单、源码／测试指纹和双端安装包哈希；release／host 匹配同一版本字符串与 Mac 平台指纹。缺项、跳过、单项或 quick ASan 报告不能放行。
- 清单与签名生成后可用 `scripts/update-signing.swift verify` 独立复核（v1 与 v2 都要验）。
- 发布前递增 `version.json` 构建号；定版要求工作区干净。

签名工具：

```sh
swift scripts/update-signing.swift generate --private <path> --public-out <pub>
swift scripts/update-signing.swift sign --private <path> --input update-manifest.json --output update-manifest.json.sig
swift scripts/update-signing.swift verify --public <base64> --input update-manifest.json --sig update-manifest.json.sig
```

## 六、客户端实现与状态

| 组件 | 状态 | 证据／边界 |
| --- | --- | --- |
| 清单解析／字段校验 | 已实现（schema 1＋2） | `UpdateContract.swift`；`UpdateTests` 覆盖 schema、字段、版本、OS 比较、重复资产、dataPackage 字段与双清单结构 |
| Ed25519 验签 | 已实现 | CryptoKit；有效／篡改／未知 keyId／base64 签名测试通过 |
| GitHub 列表／分页／ETag／限流 | 已实现（注入传输与 URLProtocol 离线测试） | `UpdateEngine.swift`／`UpdateTransport.swift`；真实 URLSession GET 的主机边界、签名失败不缓存、逐页 304、升级后重比构建号已有测试；实际 GitHub 链路未验收 |
| 下载／SHA-256／大小／缓存复用 | 已实现（本地文件） | `UpdateDownloader.swift`；测试覆盖主包和数据 `.pkg` 的复用、大小不符、哈希不符、数据包按 dataVersion 缓存 |
| 就地热更新与数据修复 | 已实现（离屏测试） | `UpdateInstaller.swift`：真实 xar/cpio/ditto/codesign 夹具覆盖数据 `.pkg` 解包、签名数据指纹绑定、逐文件校验、收据写入、同构建号缺失／过期指纹触发仅数据修复及部分成功；**真实双 App 安装和在线更新宿主验收未做** |
| 输入法优雅退出交接 | 已实现（单元级） | 通知注册幂等；真实输入源里的交接（打字中更新→新进程接管）未验收 |
| macOS 关于页检查与下载确认 | 单元测试已通过 | 真实设置窗口点击和在线更新闭环未验收 |
| Windows 关于页检查与下载确认 | x64 语法检查已通过 | 保留 schema 1 清单；完整构建、真实窗口及在线更新未验收 |
| 真实 GitHub Releases E2E | 部分 | 发布侧已通过：`gomeen/gokaku` 上 b110 至 0.5.0（b131）各轮发布的资产和公开清单签名已验证；客户端「旧版点更新→新版」端到端未做（见[欠账](../.scratch/debt-backlog/issues/03-update-e2e-real-releases.md)） |

已做的协议回归不访问真实网络：使用注入传输模拟 GitHub API 与资产下载；签名用临时 Ed25519 密钥。**未完成真实链路前不得把在线更新标为已验收。**

## 七、测试

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test -c release -j 2 --filter 'UpdateTests|UpdateInstallerTests|VolcengineTests'
python3 scripts/make-update-manifest.py --self-test
python3 scripts/build-win-app.py --self-test
python3 -m unittest scripts.test_delivery_pipeline
```

真实链路回归（首发配置后进行）：

1. 用两个构建验证旧版发现新版、下载、就地安装、重开显示新构建号、数据保留；覆盖 v2 清单路径与 v1 回落路径（0.2.0 旧客户端视角：只有 schema 1 清单的发布照常升级主包，EngineData 由 postinstall 结转保留）。
2. 覆盖数据包：数据未变的连续两版更新，第二版不重新下载数据（dataVersion 缓存命中）；数据变化后更新词库生效；数据包哈希错时主包照常更新、UI 明示词库回退；同构建号且数据指纹缺失／过期时只下载并重装数据包，成功后重启输入法并更新收据。
3. 覆盖 dev／rc／stable 隔离、同版更高构建号、旧版拒绝、错误签名、哈希不符、断网、限流、取消、磁盘不足。
4. 记录 GitHub API 速率限制、资产 ID、清单与签名哈希。
5. 失败恢复不影响输入法正常使用；就地更新中断（kill 安装进程）后再次更新先恢复旧版再装新版（transaction.txt recover）。

## 八、本轮边界与已知限制

- **Windows 本轮不拆分**：Windows Setup 继续包含数据（Inno 模板与 TSF 注册深度耦合，数据包需要独立的 ActiveRoot 定位安装器与 update.cpp 的 schema 2／数据下载链路）。Windows 客户端继续读 `update-manifest.json`（schema 1，只含主包）——主包始终存在，旧路径不受双清单影响。跟进项：Windows 数据包（Inno 拆包）＋Windows 客户端 schema 2／热更新。
- **就地更新的密封边界**：代码包的 App 密封不含 EngineData（构包时先剔除再签名）；数据包把 EngineData 装进已安装的 App 后，该 bundle 的资源密封相对安装时的原始签名是「超集」——`codesign --verify --deep --strict` 对已装且装过数据的 bundle 会报 file added。运行时不受影响（输入法经 imklaunchagent 启动、无 quarantine、Gatekeeper 评估只发生在 pkg 安装时）；代码完整性由安装前的严格校验＋主程序嵌入签名保证，数据完整性由清单逐文件哈希保证。若未来引入 Developer ID＋公证分发，需重新评估 EngineData 的落位（数据外置到用户目录是候选方向），在此之前以本模型如实交付。
- **手动安装顺序**：系统 Installer 路径（双击 pkg）下必须先装主包再装同一产品的 `Gogaku-Data`／`GogakuLite-Data` 数据包。数据 postinstall 用构包时生成的哈希校验，不依赖 Python；事务按产品与通道分开，回滚只还原两份 `EngineData`。客户端「检查更新」路径自动处理顺序。
- **旧客户端的升级数据**：0.2.0 及更早客户端经 schema 1 清单升级时只拿到主包；pkg postinstall 与就地安装器都会把备份里的旧 EngineData 结转进新包，词库回退到旧版（核心兼容旧数据）。旧客户端无法主动获取新数据包——这是发布侧用「数据未变不重发」前提下的已知边界：数据变化后，旧客户端要等下一次「代码也变化」的发布并在那时经 v2 清单补齐数据。
- **就地更新的 TCC**：替换 `~/Library/Input Methods` 与 `~/Applications` 下的 bundle 是普通用户目录文件操作，不提权；真机上的系统提示与权限行为待宿主验收确认。
