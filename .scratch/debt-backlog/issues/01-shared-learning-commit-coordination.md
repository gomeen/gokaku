# 01 共享学习提交协调（等待期间按键缓冲）

Status: ready-for-agent

来源：[实施计划](../../../docs/implementation-plan.md)「学习提交协调」；P1 剩余项。

## 背景

预译缓存、翻译调度合同与一次提交已在共享核心／薄封装；**等待期间按键缓冲仍在 Mac `InputController`**，Windows 尚无对应实现。逐键编辑取消旧请求并发起新修订的行为两端已有，但缓冲逻辑是 Mac 平台层的第二份实现，违反「共享实现规则」。

## 验收标准

- 等待期间按键缓冲抽为共享模块，Mac `InputController` 改为消费共享实现，删除平台侧副本。
- Windows 补上同一实现，行为与 Mac 一致：等待翻译期间可继续输入、旧请求取消、新修订发起。
- 按「共享实现规则」入库两端共跑的对拍向量（同一组输入与期望结论），两端测试跑同一份数据。
- 改共享核心后跑 ASan 冒烟：`python3 scripts/verify.py --profile release --only asan-ubsan --quick`。
- [功能对照](../../../docs/feature-parity.md)「提交协调与等待期间编辑」行同步更新。
