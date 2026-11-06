# 更新源配置（随包）

`config.json` 在构建时复制为 `Gogaku Settings.app/Contents/Resources/update-config.json`。

- `owner`／`repo`：公开的 GitHub Releases 仓库；留空表示本机构建未配置更新源。
  客户端此时必须显示「未配置更新源」，不能显示「已是最新」。
- `trustedKeys`：Ed25519 可信公钥（base64 原始 32 字节）。`keyId` 必须与
  `update-manifest.json` 的 `keyId` 一致。**私钥只存发布环境，绝不入库。**
- 正式发布前替换为生产公钥；开发公钥仅用于协议回归。轮换公钥时同时保留
  旧 keyId 直到所有受支持版本升级完成。

签名/发布脚本见 `scripts/update-signing.swift`、`scripts/make-update-manifest.py`、
`scripts/publish-release.py`；合同见 `docs/update.md`。
