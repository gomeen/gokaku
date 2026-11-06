# 版本与构建管理

Gogaku 的版本管理覆盖**双端开发测试版**：本地 Git 提交与标签；检查更新使用公开 GitHub Releases 与签名清单（见[检查更新](update.md)）。项目公开许可、Developer ID／公证和 Authenticode 仍未决定；源码仓库是否公开不由发布仓库决定（见[产品方向](product.md)「交付与验收边界」）。

## 单一版本来源

仓库根目录 `version.json` 是唯一版本来源，由 `scripts/build.py` 读取并生成两套应用与 helper 的版本元数据：

```json
{ "version": "0.1.0-dev.1", "buildNumber": 2 }
```

- `version`：完整 SemVer。三段数字，预发布段只允许 `dev.N`／`rc.N`。
- `buildNumber`：单调递增整数，写入 `CFBundleVersion`；每次对外提供安装包都必须递增。更新判断只按构建号，不按版本字符串字典序；同版本更高构建号可更新，不自动降级。

macOS 限制 `CFBundleShortVersionString` 只能是三段数字，完整预发布版本另存包内 `Contents/Resources/build-identity.json`，并在设置应用侧栏与诊断输出中显示。

## 阶段规则

| 阶段 | 版本 | 约束 |
| --- | --- | --- |
| 开发构建 | `0.1.0-dev.1` 起递增 | 允许带未提交修改，构建身份标记 `dirty=true` |
| 候选版（RC） | `0.1.0-rc.1`、`0.1.0-rc.2` … | 源码已提交且无未提交修改，否则构建脚本拒绝 |
| 定版 | `0.1.0`，附注标签 `v0.1.0` | 全部必需验收通过＋用户试用确认后执行 |
| 兼容性修复 | `0.1.1` 等补丁版本 | 标签一经创建不移动；后续修复用新版本 |
| 功能里程碑 | 后续次版本 | 能力范围另行规划 |

`v0.1.0` 标签一经创建不移动；对同一提交重新定版构建会因标签已存在被拒绝。

「dirty／工作区干净」只看**已跟踪文件**的修改（`git status --porcelain --untracked-files=no`）：验证过程自身产出的未跟踪报告与日志不算源码修改；rc／定版构建前仍应把当轮验收证据提交入库。

## 构建身份

每次构建产出两层身份记录：

- **包内** `Contents/Resources/build-identity.json`：完整版本、构建号、阶段、Git 提交、dirty、架构、构建配置、验收开关、ABI 版本、依赖锁与数据来源清单哈希。
- **外部** `dist/build-identity.json`：包内身份＋主程序、helper、动态库与安装包的 SHA-256（产物哈希不写入包内，避免自引用）。

验收报告必须绑定对应构建的身份记录；报告不回写源码（避免身份循环）。历史报告不自动继承为当前版本通过。

## 版本边界

应用版本（`version.json`）、核心 C ABI 版本（`gc_abi_version`，当前 4）、用户数据格式版本、更新清单 schema（当前 1）四者独立管理。升版本不构成修改 ABI、存储格式或清单 schema 的理由。

## 更新身份

- 每个安装通道（stable／dev）使用自己的更新清单 `channel`；stable 只接受正式版本，dev 可接受 dev／rc／正式。
- 更新清单的 `buildNumber` 必须大于已安装构建号才提示升级；`version` 不参与排序。
- Ed25519 `keyId` 标识发布公钥；轮换时保留旧 keyId 直到所有受支持版本升级完成。
- 更新偏好单独存 `update-preferences.json`（schema 1，自动检查默认 false，按通道节流与缓存 ETag）；升级应用不重置用户选择。
- 设置数据 schema 2 起移除本地翻译后端／beam；旧本地模型配置迁移为关闭学习翻译，已启用火山配置保留凭据与用量。

## 拒绝路径（由 `scripts/verify.py --profile fast` 自测）

非法版本号、非法／缺失构建号、构建号倒退、dirty 候选构建、两套应用版本不一致、报告指向旧产物（身份提交 ≠ 当前 HEAD）、缺少必需报告——全部拒绝，不允许带病构建或带病验收。

更新清单的拒绝路径：未知 schema、未知 keyId、签名失败、stable 清单含预发布段、通道不符、构建号不递增、平台／架构不支持、`minOS` 高于当前系统、重复 platform/arch、`sha256` 非 64 位十六进制、资产大小／哈希与下载不符——均拒绝，不显示为「已是最新」。
