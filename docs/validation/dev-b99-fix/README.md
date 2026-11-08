# Windows b99 挂起 Shift 补发与 VS Code 受限项

版本 `0.1.1-dev.2 / b99 / dev`。本轮延续 [b98 记录](../dev-b98-fix/README.md)的三个修复，新增一处窄场景修复，并如实记录 VS Code／Windows Terminal 宿主矩阵的环境受限。

## 产品变更：挂起的恢复 Shift 点击

用户配置了 `appDefaultEnglish`（code.exe／windowsterminal.exe 等）时，会话默认处于临时英文，单击 Shift 切回中文。实测发现：若 Shift 点击落在会话可用之前（`syncContext` 失败），该点击被静默丢失，用户整组字母直通。b99 起该点击挂起，下一次按键在 600ms 内补发 `SHIFT_CLICK`，失焦即清除。

范围限制：若整个 Shift 键对到达于 TIP 激活完成之前（键盘 sink 尚未建立），输入法收不到任何事件，无法补发——这是 TSF 激活时序的固有窗口，b94 的「首键接管」边界同样适用。VS Code 冷启动期间实测触发该窗口（见下）。

## VS Code／Electron 类宿主：受限项

用户设置确有 `code.exe` 默认英文配置，夹具行为正确。三轮实测（[code-1](cases/b99-matrix-code-1.json)、[code-ready-1](cases/b99-matrix-code-ready-1.json)、[code-settle-1](cases/b99-matrix-code-settle-1.json)）：

- 激活后立即输入：临时英文下字母直通 `nihc `（符合文档回退行为），恢复 Shift 点击丢失。
- `ITfKeystrokeMgr::GetForeground` 轮询 14.3 秒从未匹配 dev CLSID，不能用作就绪探针。
- 等待 3 秒再输入：按键全部进入窗口但编辑器缓冲为空——VS Code 首启 UI 抢占编辑焦点，属夹具目标状态问题。

结论：VS Code／Electron 类宿主矩阵需要专用诊断（CDP／工作区隔离）另立轮次；Windows Terminal 未安装（`wt.exe` 不存在）同样受限。此项**未通过**，不计入已验证范围。

## b99 验证

- [fast 7/7](build/report-fast-dev-b99.json)；[ASan／UBSan quick](build/report-asan-ubsan-quick-dev-b99.json) 2,000 序列通过。
- Windows EXE SHA-256：以[收据](build/windows-setup.json)为准。
- **本机已更新**：`manage-install.py --channel dev install` 装入 b99（52＋44 个文件哈希核对）；重装后输入源注册需 `register` 刷新；[14 项 IMK 冒烟](../../validation/imk-host-smoke-dev.json)一次通过。另发现替换 bundle 后运行中的输入法进程不会自动重启，kill 旧进程后冒烟 14/14 在新进程通过。**后续（b100 发布同日）：本机已按用户要求卸载 dev 通道**（应用与 285MB dev 备份移除；stable 86 与共用用户数据保留），测试时用 `manage-install.py --channel dev install` 重装。
- **发布进展**：更新源已配置为 `gomeen/gokaku`；b100（对外发布前递增）双端重建并通过 fast，[离线门禁与真实发布](../release-b100.json)完成——Draft `v0.1.1-dev.2-b100-dev`（ID 438177886）已含双端安装包与签名清单，待人工审阅发布（[发布记录](../release-b100.json)）。
- [安装记录](install.json)：默认升级返回 0，71 个文件与双架构 COM 匹配，上一根指向 b98。
- 无回归验证 3 轮：Chrome 切框、密码 `nihc `、记事本「你好」，模块身份均为 b99（PE 1794128481），见 [cases/](cases/)。
- 组合生命周期与 13 轮矩阵沿用 [b98 记录](../dev-b98-fix/README.md)（本轮未改动组合路径）。
- [最终清理](state/cleanup99.json)：正式 b99 代理与注册恢复，临时任务清理，安全防护保持开启；设置与自启未变，数据文件保留，调频随合成提交更新。

## 复现源码

[host-acceptance.cpp](reproducer/host-acceptance.cpp) 等夹具源码与 [b98 记录](../dev-b98-fix/README.md)共用，含默认英文读取修正与 VS Code 等待说明。构建命令同前。完整验收仍未通过，未完成项见[汇总](../dev-b99-fix.json)。
