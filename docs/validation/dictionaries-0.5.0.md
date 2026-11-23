# Gogaku 0.5.0 扩展词库验收

0.5.0 构建 130 已完成构包与自动化验收。应用和词库都已上传为 Draft，等待人工审阅。最近公开版本为 0.4.1。

## 已取得的专项证据

- 共享核心的 `dict_import`、`dict_catalog`、`dict_mount` 通过。SCEL 夹具包含自造条目。对合成文件执行了 2,000 个固定种子的截断及变异输入。
- [构建 130 的 fast 报告](verify/report-fast-0.5.0.json) 通过 7/7 项，含 341 项 Swift 测试。[完整 release 报告](verify/report-release-0.5.0.json) 通过 14/14 项，含双分片共 100,000 条 ASan／UBSan 随机序列和三个词库核心测试。
- zhwiki 0.3.1 原始 `.dict` 包含 1,734,069 条，实测转换 13.88 秒。转换后 1,444,888 条。120 例普通输入的出厂词典结果为首选 109、前十 112，挂载转换后的 zhwiki 为首选 110、前十 113。
- catalog-1 的 13 个词库资产各重建一次，SHA-256 全部一致。THUOCL 成语表的 8,515 条与出厂词库重复，另有 4 条读音不唯一，因此按合同生成零条目的词库。其余 12 本生成非空词库。逐本报告随 `dist/dict-catalog/release-notes.md` 生成。
- `catalog-1` 的生产签名通过随包公钥验证。远端 Draft 的 13 本词库、清单、签名和两份许可附件共 17 个资产均通过大小和 SHA-256 比对。见[词库 Draft](https://github.com/gomeen/gogaku-dicts/releases/tag/untagged-fed0c9f0b10e9cdead8f)和[资产收据](catalog-1-draft.json)。
- 构建 128 的 Mac 与 Windows 完整版、Lite 均生成安装包和收据。构建 129 修复确认上屏后未把单节点扩展词写入用户词典的问题。共享核心回归覆盖未确认时不学习、删库后重新建会话可以召回、清空调频后不再召回。
- [构建 128 的 zhwiki 抽样与性能](dictionaries-0.5.0-b128-sample.md)达到门槛。300 条新词首选命中 240 条、前九命中 297 条，出厂词首选持平。两组逐键 p95 均未上升，挂载 0.152 ms，RSS 增量为词库文件的 1.056 倍。
- Mac CryptoKit 与 Windows Monocypher 渠道入口使用同一组签名向量，四项输出一致。Windows 用 Wine 执行离线控制台自检。通过向量覆盖有效签名、正文篡改、未知密钥与错误清单类型。复跑入口为 `probes/verify-dictionary-catalog-signatures.sh`。
- Mac EngineHub 离屏探针通过。创建会话时挂载已有词库，停用在当前组合结束后生效，随后启用和删除均能更新挂载集合。
- 构建 130 隔离语法错误、字段类型错误或文件名与 ID 不符的元数据。回归确认其他词库仍可用，稍后打开设置仍能看到备份记录。
- 本机 40 轮并发启停读回一致。逐文件写入限额探针覆盖词库和元数据写入失败，均清理了半成品。0.4.1 包内核心可在同一用户目录布局下正常生成候选。

## 构包与发布

构建 130 的 macOS、Windows 完整版和 Lite 同源于 `adc59289c654`。应用 Draft 的四个安装包、两个 Mac 数据包、四份更新清单及各自的签名共 14 个资产，均核对了远端大小和 SHA-256。见[应用 Draft](https://github.com/gomeen/gokaku/releases/tag/untagged-42d1db23d60d56b684ff)和[发布收据](release-0.5.0-draft.json)。

按实施计划，本轮没有安排用户授权的真实按键时段，Mac host 豁免已写入发布收据。Mac 真实输入源、Windows 输入法运行及公开词库渠道的在线安装仍待验收。
