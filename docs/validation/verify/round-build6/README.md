# 构建整合改轮验收登记（2026-11-02，构建 6，commit 44e47e3）

本轮逐项解决用户提出的 0–7 项问题。裁决依据与验收证据如下；历史记录保留原结果。

## 逐项结果

| # | 问题 | 结论 | 证据 |
| --- | --- | --- | --- |
| 0 | 设置页不符合 demo | 已还原（token 19 色＋结构度量逐值落地，静态复核通过；真机 24 张截图归档） | `settings/*.png`、`native-gui-acceptance.json`、复核报告（settings 分支） |
| 1 | 切换图标无外框 | 根因实证修复：TextInputSwitcher 进程内缓存旧包裸笔画图标；安装流程重启该代理；真机截图确认 HUD 与输入菜单均为键帽图标（浅/深、选中/未选中） | `hud/`（hud-zoom-gogaku-keycap-dark/light.png、menu-zoom-*-*.png、menubar-icon-*.png） |
| 2 | Shift 后切英文 | 新裁决落地：组合中 Shift＝原样上屏＋切英文直输，再单击回中文；probe 11/11、TextEdit 11/11（含 `nihc→Shift→abc.→"nihcabc."` 与往返场景） | `shift-strict-probe.json`、`shift-strict-textedit.json` |
| 3 | 位置是否仍不准 | 本轮无新定位回归（严格场景全部通过）；Bob 弹窗为「矩形无效→隐藏保留组合」既定策略执行 | `shift-strict-*.json`、`bob-level-20261102/after-build6.json` |
| 4 | Bob 遮挡候选窗 | 真机根因找到并修复：`isFloatingPanel=true` 的 setter 把已设 `level` 覆写为 floating(3)；修后候选窗 layer=101 > Bob 弹窗 layer=8（窗口清单实证）。层级随宿主 `windowLevel`+1 的机制保留 | `bob-level-20261102/after-build6.json` |
| 5 | 右侧英文 | 名称与说明按裁决调整（「显示英文释义」＋"不随中文上屏"），行为不变（离线释义、不随上屏） | `settings/normal-input-*.png`（行 32–33 帮助文案） |
| 6 | 草稿 | 菜单改名「恢复未完成输入」／「恢复未发出文字」；边界复核（无空列表、不落盘、重复通知不重复）见分支报告 | C 分支复核报告；InputController menu() |
| 7 | 表格不齐 | 四列统一（名称→键帽→来源→操作）、筛选分行；录制/清除/恢复默认写回修复（原 onChange 断链）；冲突草稿进入冲突筛选；搜索组合规范化 | `settings/shortcut-*.png`、交互回环（native-gui-acceptance.json） |

## 已知行为变化（需用户知晓）

1. **Bob 输入弹窗内候选窗从「错位显示且被挡」变为「隐藏保留组合」**：该弹窗不提供有效光标矩形（含组合起点查询），b5 靠索引 0 兜底错位显示；b6 按既定策略「缺少可信定位信息就隐藏」执行，组合与上屏不受影响。如需弹窗内显示候选窗，需另行设计插入点回退（此前已被裁决否决）。
2. **Orca 1.4.246（2026-11-02 03:08 自动更新）组合期间对插入点与组合起点都返回零矩形**，用户报告「Orca 输入不显示候选窗」。修复：插入点矩形无效时改查组合起点（宿主真实测量）；Orca 连组合起点也为零，控制器再冻结组合内最后有效锚点（首字位置），矩形恢复重新跟随。真机验证：候选窗显示于插入点旁（layer 101 > Orca 19），组合结束恢复跟踪（`orca-panel-final.png`）。
3. orca-pty 的 Shift 单击检测失败为既有专项遗留（单击未到达核心，组合延续；与本轮规则改动无关）。probe 与 TextEdit 宿主完整通过（修复后 final 回归 11/11）。
4. 冲突草稿在 Esc 取消录制后清除计数，行内提示残留至下一次交互（小瑕疵，记入后续打磨）。

## 验证记录

- 开发期：fast 档全过 ×2（合并后 `report-fast-20261102-194912.json`、最终 `report-fast-20261102-205343.json`：核心 ctest 100%＋Swift Release 96 项）；ASan＋UBSan 冒烟 2000 序列无错误；渲染检查 51 项。
- 四个实现分支（settings-visual／shift-english／panel-level／switch-icon）各自经独立复核代理审查实际 diff：C 分支曾退回（probes 单文件编译链破坏，已修复并实测）；其余一次通过。
- 真机（本机构建 6，安装件 `~/Library/Input Methods/Gogaku.app`）：HUD/输入菜单截图、设置 GUI 24 张＋交互回环、Bob 层级窗口清单、Shift strict 场景（probe／TextEdit／orca-pty）、Orca 1.4.246 面板显示修复（`orca-panel-final.png`，最终版 commit 7627535 复验）。
- 版本：`version.json` buildNumber 6；`dist/build-identity.json` commit 7627535f（isFloatingPanel 修复＋Orca 组合矩形回退/锚点冻结）；证据归档提交见 git log。

## 未测范围

- 全量 release 档（干净构建／包检查／质量／数据可靠性／十万序列插桩）未跑——按验证节奏留给发版前。
- host 档完整矩阵（两轮宿主矩阵、万次性能、两小时稳定性）未跑——旧性能阻塞单独保留，待用户空闲时段。
- Chrome／Safari／Terminal 宿主的 Shift 新行为未单独跑（矩阵运行时一并覆盖）；Orca Shift 单击检测专项未解。
- 触控栏／VoiceOver 未回归。

## 并行会话说明

本仓库工作区存在另一会话的未提交修改（translate-safety 相关：`gogakuCore.h`、CMakeLists、若干 docs）。本轮未触碰、未提交这些改动；最终 fast 档在含这些改动的工作区运行并通过。`docs/validation/native-development.md` 的本轮正式登记因该文件正被另一会话编辑而暂缓，待协调后补记。
