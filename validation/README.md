# 翻译测试数据（考题，不是验收报告）

这些合成输入和参考译法与提供商无关，换在线模型后仍可复用。不随包部署模型，也不会在 fast 中调用网络。

| 文件 | 数量 | 用途 |
| --- | ---: | --- |
| `translation-holdout.json`／`.tsv` | 200 | 中英双向留存集；TSV 是冻结来源 |
| `translation-short-expressions.json` | 88 | 词、短语、时间、品牌与错拼陷阱 |
| `translation-confirm-set.json` | 100 | 独立确认集 |
| `translation-final-set.json` | 224 | 200 条应译样例＋24 条保留探针 |
| `manifest.json` | — | 上述文件及 probes 中通用输入的冻结哈希 |

加上 `probes/translation-cases.json`（32）、`translation-comparison-cases.json`（20）、`translation-language-probes.json`（24），共 688 条输入。风险审阅索引是辅助材料，不另算题目。

`python3 scripts/validate-translation-data.py` 检查完整加载、数量、方向、ID、哈希、确认／最终集去重和随包资源归属。它不生成译文、不计算现役服务质量分数；参考不是唯一正确答案，旧模型的注释和冻结背景也不等于当前提供商已验收。其他语言输入仅作未来扩展，不代表当前支持。

旧评分运行工具、模型排名与实验结果已退役；测试输入及原始冻结元数据保留，避免删除历史输出时顺手把测试内容也删掉。产品需求以 [产品方向](../docs/product.md) 为准。

真正的版本验收记录在 [`docs/validation/`](../docs/validation/)，不要与本目录混淆。
