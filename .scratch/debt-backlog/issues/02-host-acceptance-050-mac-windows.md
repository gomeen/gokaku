# 02 0.5.0 真实宿主验收（Mac host ＋ Windows 真机）

Status: ready-for-human

来源：[扩展词库验收](../../../docs/validation/dictionaries-0.5.0.md)；[实施计划](../../../docs/implementation-plan.md) D4 行「运行未验收」；[功能对照](../../../docs/feature-parity.md)所有「已编译，运行未验收」行。

## 背景

0.5.0 发布时 host 未运行（书面豁免）：Mac 真实输入源、Windows 全部功能运行均未验收。「已编译」只表示进入构建。b110 与 b131 两轮定版均如此。

## 需要用户做的

- **Mac host（本机）**：空闲时段授权 `python3 scripts/verify.py --profile host --yes`（每次定版短档；核心／IMK 改动用 host-full，会注入真实按键）。
- **Windows 真机**：真实 Windows 11 x64 机器安装 0.5.0 stable 完整版＋Lite 各一次，功能验收：普通输入、九页／六页设置、扩展词库导入与挂载、代理重载、安装即启用复查。

## 验收标准

- [功能对照](../../../docs/feature-parity.md)中所有「已编译，运行未验收」「待用户验证」行改为有证据状态。
- 验收记录（`docs/validation/dictionaries-0.5.0.md` 及后续定版记录）补真实宿主结果，下轮定版不再默认豁免。
