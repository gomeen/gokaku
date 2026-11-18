# 2026-11-17 工作区审查与主题缓存修复

## 范围与结论

审查基线为 `dd868c1b6442790ac6e3b131eff40d408e864f37` 到当时工作区的已跟踪改动及新增源码／测试，重点为共享位图渲染、两端薄封装、Lite/full 分叉、构建链路和 Shift 修复。不代表对仓库全部历史代码完成了穷尽审计。

逻辑／规格、代码规范／健壮性、性能三个只读子代理并行审查，均使用用户指定的 `group/glm-5-3-flash`、high thinking；主代理核实发现项后，交由另一子代理修改，再独立核对改动与验证结果。

| 发现 | 主代理判断与处理 |
| --- | --- |
| P1：大背景图主题每帧复制／解析 JSON，耗时随图片大小增长 | 确认，已修复。共享核心新增拥有不可变快照的 prepared theme 句柄，两端热路径复用；Windows 设置复制与主题解析移到设置更新路径。保留旧 JSON 入口兼容，其完整字节比较仍为 O(payload)。 |
| P3：`typedPrefixUTF16` 没有在整数转换前夹紧 | 已按预编辑 UTF-16 总长夹紧，覆盖非 BMP 与超大有限数。 |
| 渲染器选择传裸字符串；`pageCount` 局部变量实际指可见候选数 | 已改用现有 `CandidateRenderer` 枚举，并将局部变量改名 `visibleCandidateCount`。属于可维护性清理。 |
| 规范硬规则 | 未发现已证实的违反；共享契约、许可、ABI 失败输出、双架构独立构建均已核对。 |
| 逻辑／规格 | 未发现新的可证实 P0/P1 行为缺陷；分页索引、UTF-16 转换、Lite 裁剪和失败回退已走查。真实宿主未测。 |

本次修复不包含大图首次解码调度；冷加载性能仍未达标，详见下文。

## 性能证据

固定探针 `probes/benchmark-panel-theme.py`：四候选竖排、scale 2、PingFang face 3、每尺寸独立进程，预热 10 帧后测 200 帧；有效 PNG 使用确定性随机像素及合法填充块。不是九候选／多字体／全主题矩阵，也不含平台封装与宿主窗口。

- [修改前原始报告](before.json)：核心 SHA-256 `5cb56298c5cdec97224b78bcddea59fd0a6f2d1289f42093a3a6076dd48cb11b`。
- [最终 prepared 原始报告](final-prepared.json)：核心 SHA-256 `480ca1e93c4bc5a9a1acaedbcda478bc4306fa253cff422956728b67df142892`。
- [逐项输入与像素对照](final-comparison.json)：五组 PNG、主题、帧、尺寸和 RGBA 哈希均对应一致。
- [最终运行环境与命令](final-environment.json)：测量前后 `CPU_Speed_Limit=100`；未停止用户应用或修改电源设置。改前／改后在不同时间测量，倍率仅作诊断，不是受控机器的严格性能保证。

| PNG 文件大小 | 修前热态 p95 | 最终热态 p95 | 最终主题准备 | 最终首帧渲染 | 准备＋首帧 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 无图 | 0.690ms | 0.545ms | 0.922ms | 14.589ms | 15.511ms |
| 256KiB | 3.988ms | 1.187ms | 1.663ms | 7.053ms | 8.716ms |
| 1MiB | 10.890ms | 1.151ms | 6.254ms | 13.544ms | 19.797ms |
| 4MiB | 77.914ms | 1.391ms | 33.569ms | 48.706ms | 82.275ms |
| 8MiB | 81.888ms | 1.126ms | 68.954ms | 89.602ms | 158.556ms |

五组热态 p95 均小于 2ms，图片大小带来的逐帧解析退化已消除；冷加载仍不满足 8ms 目标，连无图样本也有首帧波动。每个尺寸只有一个新进程冷样本，没有清 OS 文件缓存，不能将这张表当作冷启动分布。

`after-legacy.json`／`after-prepared.json` 是首次缓存改动的过程数据；`optimized-prepared.json` 是最终合成代码在较高系统负载下的早期观测（无图 p95 5.93ms、8MiB 10.51ms），完整保留。该报告与最终报告二进制哈希相同，说明单凭那次高耗时无法判定代码退化；后续诊断曾观测虚拟机进程约 388% CPU，但没有逐帧负载记录，不能把全部波动归因于该进程。

## 功能与构建验证

- [fast 报告](../verify/report-fast-20261117-175645.json)：7/7 检查通过，CTest 11/11、Swift Release 277/277，`runIdentityStable=true`、`gate.passed=true`。
- [ASan／UBSan quick 报告](../verify/report-release-20261117-175801.json)：2,000 随机序列与[共享渲染插桩向量](../verify/release-20261117-175709/asan-panel-render.log)通过。命令因 `--only` 跳过其余必需项返回 1，整体 release gate 为 false；没有运行完整 release。
- 回归覆盖主题同址同长度 A→B→A、图片替换、无图与深色回退、调用方输入释放后的快照所有权、句柄并发、失败输出清空、句柄释放、超界 UTF-16 前缀。最终合成优化前后五组像素哈希一致。
- Windows 命令 `python3 scripts/compile-win-native.py --arch all --channel dev --flavor full --out .build/review-fix-windows --core-build .build/review-fix-windows/core --jobs 2` 退出 0；含 x64 核心／Agent／Settings、x64／x86 TSF 与双架构渲染／平台接缝自检 EXE。PE 头核对为对应的 PE32／PE32+。源码收据与产物哈希见[最终身份核对](final-identity.json)。**未执行 Windows EXE**，不算 Windows 功能或性能通过；本次修复后没有重新构建 Lite 包。

以上为工作区源码验证，构建身份仍为 b114，未提交，未安装或发布新包；本机运行中的输入法不自动获得这些改动。

## 保留问题

1. **大图首次加载**：共享解码仍在首次渲染同步执行；Windows 主题 JSON 准备也在首次位图调用发生。8MiB 单次准备＋首帧约 159ms。需要另行实现并验证主题预准备／解码的调度及生命周期；仅把耗时移出统计区间不能算修复。
2. **真实平台验收**：Mac IMK 与 Windows TSF、当前程序的首次显示／按键延迟、Windows 自检、跨屏 DPI、全部皮肤热更新仍未完成。保留系统渲染回退。
3. **低优先级观察**：Windows 字体未命中的负缓存进程内不过期；中途安装字体需重启进程。系统／位图回退分支有少量重复文案逻辑；Mac 位图契约的提示／恢复按钮尚未接线，实际提示走 ToastWindow、恢复走菜单；Windows 拼写说明保留到下一帧，Mac 仅当帧显示。后续统一接线或移除过渡路径时处理，不据此扩大本轮修复。
