# 已采用的中文输入路线

中文底座固定为 **libime 1.1.17＋出厂词典／语言模型＋内置 Xiaohe**。业务逻辑在 `shared/GogakuCore/`，两端通过同一版本化 C ABI 消费；macOS 使用 InputMethodKit／AppKit 与薄 EngineBridge，Windows 使用 TSF 与每用户代理。

## 采用理由与边界

- libime 提供小鹤、部分选择、候选与学习接口，能够支撑自己的原生前端，不必引入完整 Fcitx 框架或多引擎插件系统。
- 工程选择结合了中文候选质量、逐键成本与集成范围，不意味着它在所有硬件和语料中最快，也不意味着其他引擎不可用。
- 保留现行中文质量回归：120 条冻结样例，首选门槛 109、前十门槛 112。测试与生产共用核心，普通输入／学习调度／真实宿主分别验收。
- 固定依赖准备在 `scripts/prepare-dependencies.py` 与 `scripts/prepare-libime-windows.py`；两者仍消费 `probes/prepare-libime-input.py` 的固定来源声明，不能按名字把它当作废弃比较工具删除。
- 许可和分发义务以 [第三方许可](third-party.md) 及实际锁定清单为准；Gogaku 项目许可尚未决定。

## 已退役的实验

青简／Rime 等引擎对比及 OPUS、M2M100、small100、quickmt、GGUF 等翻译选型工具、运行结果和长篇研究已移出当前树，可从 Git 历史追溯。不再维护旧模型下载、转换、测速、排名或参数调优链路。

当前学习翻译仅支持用户配置的火山 NMT（默认关闭），不随包本地模型。后续可能新增在线提供商，但尚未决定具体接口，也没有因此引入通用插件框架。

当前实施与未通过项见 [实施计划](implementation-plan.md)、[功能对照](feature-parity.md) 和 [原生验收](validation/native-development.md)。旧实验结论不能代替当前版本的真实宿主、翻译、安装与性能验收。
