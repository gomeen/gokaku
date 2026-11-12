# 检查更新与发布清单

状态：**Mac 客户端协议实现并有离屏测试；Windows 原生客户端已交叉编译并随安装包提供。发布侧已完成 `gomeen/gokaku` 的 GitHub Release、双端资产和清单签名验证；客户端从旧版点击检查、下载、安装并重开验证仍未完成。** 本文是更新合同、默认值和发布流程的唯一说明；功能状态见[双端功能对照](feature-parity.md)，安装流程见[发布与构建](release.md)。

## 一、范围与默认值

| 项 | 规则 |
| --- | --- |
| 检查入口 | 设置应用版本信息旁「检查更新」；独立更新窗口 |
| 自动检查 | **默认关闭**；开启后仅在设置窗口打开期间按 24 小时最多尝试一次（关闭窗口即退出设置应用） |
| 自动下载／安装 | 不自动；下载与安装都由用户点击触发 |
| 输入法进程 | 不检查更新、不在按键路径联网或读更新缓存 |
| 通道 | 跟随安装通道：stable 只接受正式版本；dev 可接受 dev／正式（客户端兼容解析历史 rc，发布侧不再产生） |
| 降级 | 不自动降级；以构建号判定，同版本更高构建号可更新 |
| 请求内容 | 只请求 GitHub 公开 Releases；不携带输入内容、火山凭据、学习记录或设备唯一标识 |
| 系统信任 | 更新签名只证明来自发布者，**不替代** macOS 公证或 Windows Authenticode；未签名包的系统提示照实说明 |

自动检查失败不紧密重试；手动检查可立即重试。自动发现新版只在设置应用内更新按钮显示新版提示，不抢输入焦点，不自动打开窗口。Windows 设置页的提示目前只经过交叉编译，未在真实窗口验收。

## 二、清单合同（v1）

每个 Release 必须附两个资产：

- `update-manifest.json`：UTF-8 JSON；
- `update-manifest.json.sig`：对**清单原始 UTF-8 字节**的 Ed25519 分离签名。客户端接受原始 64 字节或 base64 文本（含换行）。

```json
{
  "schema": 1,
  "keyId": "gogaku-prod-2026",
  "version": "0.1.2",
  "buildNumber": 90,
  "channel": "stable",
  "notes": "发布说明（纯文本，≤64 KiB）",
  "assets": [
    {
      "platform": "macos",
      "arch": "x86_64",
      "minOS": "26.0",
      "assetId": 123456,
      "name": "Gogaku-0.1.2-b90.pkg",
      "size": 47185920,
      "sha256": "64 位小写十六进制"
    },
    {
      "platform": "windows",
      "arch": "x86_64",
      "minOS": "10.0.22000",
      "assetId": 123457,
      "name": "Gogaku-0.1.2-b90-windows-x64-setup.exe",
      "size": 104857600,
      "sha256": "64 位小写十六进制"
    }
  ]
}
```

字段规则：

- `schema` 必须为 `1`；未知 schema 拒绝。
- `keyId` 必须命中随包 `Contents/Resources/update-config.json` 的 `trustedKeys`。
- `version` 为 SemVer 三段数字，可带 `-dev.N`／`-rc.N`；stable 清单不得带预发布段。
- `buildNumber` 为正整数，必须**单调递增**；客户端只按构建号判断升级。
- `channel` 为 `stable`｜`dev`，必须与安装通道一致。
- `assets` 至少一项；`platform` 为 `macos`｜`windows`，`arch` 为 `x86_64`（本轮范围）；同一 `platform/arch` 不得重复；`name` 不得含路径分隔符；`size`／`sha256` 必须与 GitHub 资产一致。
- `minOS` 为点分数字；客户端只选择 `minOS <= 当前系统版本` 的资产。
- 本轮发布要求 macOS 与 Windows 资产齐全才进入更新列表；客户端只下载自己平台／架构的资产。

客户端只接受正式 Release（`draft=false`）；stable 忽略 `prerelease=true` 的发布，dev 可读取。通过 GitHub API 的 `assetId` 核对资产属于该仓库／该 Release，再下载 `browser_download_url`。

## 三、验证与下载

1. 取 GitHub Releases 列表（`api.github.com`，分页最多 3 页 × 30，逐页 ETag 缓存；304 仅复用已验签清单并按当前构建重新比较，不能把签名失败当作最新）。
2. 找到清单与签名的资产；下载上限 256 KiB／8 KiB。
3. 用内置 Ed25519 公钥验证清单原始字节；签名失败、未知 keyId、未知 schema、字段非法都报「更新清单校验失败」。
4. 校验通道、构建号、平台、架构、最低系统版本。
5. 下载安装包到当前用户可写的临时文件；校验长度与 SHA-256 后原子转为缓存文件；启动安装前再次校验。
6. 点击「安装更新」才把已校验的包交给系统安装器；不自动安装、不重启、不强杀宿主。
7. 下载可取消；取消删除临时文件；磁盘不足在开始前明确报错。

只接受 HTTPS，主机白名单：`api.github.com`、`github.com`、`objects.githubusercontent.com`、`release-assets.githubusercontent.com`、`github-releases.githubusercontent.com`。重定向必须仍在白名单内。限流（403／429 且 `x-ratelimit-remaining: 0`）、超时、离线、404、5xx、未知 schema、签名失败、通道不符、缺资产分别显示不同状态；**未配置更新源不能显示「已是最新」**。

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
- 当前仓库配置为 `gomeen/gokaku`；b113 stable（0.1.5）已完成发布侧资产和清单签名验证，但客户端安装闭环仍待验证。
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
  --macos-pkg dist/Gogaku-0.1.2-b90.pkg \
  --windows-setup dist/Gogaku-0.1.2-b90-windows-x64-setup.exe \
  --verification-report docs/validation/verify/report-fast-YYYYMMDD-HHMMSS.json \
  --verification-report docs/validation/verify/report-release-YYYYMMDD-HHMMSS.json \
  --verification-report docs/validation/verify/report-host-YYYYMMDD-HHMMSS.json \
  --notes-file dist/update/notes.md

# 3. 创建 Draft、上传 pkg／setup、生成并上传清单与签名
GITHUB_TOKEN=... python3 scripts/publish-release.py \
  --repo gomeen/gokaku --channel stable \
  --macos-pkg dist/Gogaku-0.1.2-b90.pkg \
  --windows-setup dist/Gogaku-0.1.2-b90-windows-x64-setup.exe \
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

- 先上传安装包，取得 GitHub `asset id`；`scripts/make-update-manifest.py` 用真实 ID 生成清单，避免清单指向不存在的资产。
- 上传顺序：pkg／setup → 本地 `asset-ids.json` → `update-manifest.json` → `.sig`。全部成功后仅写 `release-state.json`，必须另行人工审阅并指定同一 Draft ID 发布。
- 发布脚本对缺失配置、私钥、许可材料、编译／打包收据或验证证据明确失败，不制作看似可更新的假发布。dev 至少 fast；定版需 fast＋release＋host（或 host-full）。fast 必须匹配当前策略、必需检查清单、源码／测试指纹和双端安装包哈希；release／host 匹配同一版本字符串与 Mac 平台指纹。缺项、跳过、单项或 quick ASan 报告不能放行。
- 清单与签名生成后可用 `scripts/update-signing.swift verify` 独立复核。
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
| 清单解析／字段校验 | 已实现 | `UpdateContract.swift`；`UpdateTests` 覆盖 schema、字段、版本、OS 比较、重复资产 |
| Ed25519 验签 | 已实现 | CryptoKit；有效／篡改／未知 keyId／base64 签名测试通过 |
| GitHub 列表／分页／ETag／限流 | 已实现（注入传输与 URLProtocol 离线测试） | `UpdateEngine.swift`／`UpdateTransport.swift`；真实 URLSession GET 的主机边界、签名失败不缓存、逐页 304、升级后重比构建号已有测试；实际 GitHub 链路未验收 |
| 下载／SHA-256／大小／缓存复用 | 已实现（本地文件） | `UpdateDownloader.swift`；测试覆盖复用、大小不符、哈希不符 |
| 安装交接 | 已实现（`open` pkg） | 未在真实安装器上点过 |
| 设置页更新窗口／自动检查 | 已实现 | `UpdateWindow.swift`；未做真实点击验收 |
| Windows 客户端 | 已编译，尚未运行 | `windows/GogakuWindows/update.cpp`；Monocypher Ed25519、WinHTTP、窗口与自动检查；真实链路由用户验证 |
| 真实 GitHub Releases E2E | 部分 | 发布侧已通过：`gomeen/gokaku` 上 b113 stable 及此前 b112／b110／dev 发布的资产和公开清单签名已验证；客户端「旧版点更新→新版」端到端未做 |

已做的协议回归不访问真实网络：使用注入传输模拟 GitHub API 与资产下载；签名用临时 Ed25519 密钥。**未完成真实链路前不得把在线更新标为已验收。**

## 七、测试

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test -c release -j 2 --filter 'UpdateTests|VolcengineTests'
python3 scripts/make-update-manifest.py --self-test
python3 scripts/build-win-app.py --self-test
```

真实链路回归（首发配置后进行）：

1. 用两个构建验证旧版发现新版、下载、校验、安装、重开显示新构建号、数据保留；
2. 覆盖 dev／rc／stable 隔离、同版更高构建号、旧版拒绝、错误签名、哈希不符、断网、限流、取消、磁盘不足；
3. 记录 GitHub API 速率限制、资产 ID、清单与签名哈希；
4. 失败恢复不影响输入法正常使用。
