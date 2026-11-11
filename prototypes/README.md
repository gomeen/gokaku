# 定稿原型

本目录保留三份仍被产品文档引用的交互参考，另有一份尚未裁决的探索原型。它们运行示例数据，不能代替真实输入法、翻译、性能或宿主验收。当前规则以 [产品方向](../docs/product.md) 为准，实际能力见 [原生开发验收](../docs/validation/native-development.md)。

| 入口 | 保留用途 | 配套文件 |
| --- | --- | --- |
| [输入习惯](input-habits-demo.html) | 普通输入按键、候选窗比例与学习交互演示 | `input-habits-demo.template.html`、`input-habits-demo-data.json`、`scripts/generate-input-habits-demo-data.py`、`screenshots/input-habits-*.png` |
| [设置定稿](settings-final.html) | 设置布局、控件及列表交互参考 | 无外部依赖 |
| [皮肤定稿](skin-settings-demo.html) | 主题选择、两级编辑及固定预览参考 | 无外部依赖 |
| [英文模式补全（探索中）](english-completion-demo.html) | 普通模式英文下当前词补全与上文预测效果：打开自动播放打邮件演示（建议条／组合式／行内灰字／上文预测四种方案可切换，上文预测用手写示例搭配数据），也可手动打字体验；尚未裁决，不是需求 | 内嵌 `resources/english-words.txt` 全量词表，无外部依赖 |

直接用浏览器打开即可。输入习惯 HTML 由模板与候选快照生成，不直接手改产出文件；模板、数据和生成脚本一起维护。

原型冻结于功能裁决阶段，部分文字和示例已经过时：如本地翻译／模型质量门槛、旧学习菜单、已取消的词表文件入口以及部分历史 Shift 截图。查当前行为时应读产品文档与原生实现，不为保持旧演示而恢复退役功能。

2026-11-08 清理了早期 `input-flow.html`、其两张截图和八张无引用的 `settings-final-*` 截图；早期结论见 [流程决策](../docs/prototype-input-flow.md)，完整探索可从 Git 历史追溯。三个定稿原型及其必要配套文件继续保留。
