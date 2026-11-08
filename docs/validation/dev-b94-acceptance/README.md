# Windows b94 宿主验收（2026-11-08）

**结论：不通过。Chrome 在字段切换后连续两次把旧组合提交到了新字段，触发产品要求的暂停条件。** 本轮没有修改产品源码或重建安装包。[机器可读汇总](../dev-b94-acceptance.json)绑定 b94 安装包、源码与既有 fast 测试指纹。

## 实际环境与方法

Windows 11 x64 build 26300；记事本 11.2607.14.0；Chrome for Testing 157.0.8103.38 使用专属临时配置。测试只向带唯一标题的自有空白文档／页面发送合成内容，逐键校验前台窗口、聚焦控件归属，记录加载中的 TSF 路径与内存 PE 时间戳。Chrome 的按键通过 Windows SendInput 发出；CDP 用于聚焦字段与读取 DOM 值，没有用 DOM 赋值模拟上屏。环境和便携工具版本见 [environment.json](environment.json)、[portable-hosts-verification.json](portable-hosts-verification.json)。

## 阻塞项：跨字段提交 WIN-B94-FOCUS

复现步骤：

1. 在专属 Chrome 页面启用 Gogaku Dev，在第一个 textarea 输入 `ni`。
2. 调用第二个 textarea 的 `focus()`，等待 250ms。
3. 通过 SendInput 按空格，再读取两个字段的值。

预期：旧提交资格失效，第一个字段不保留预编辑字母，第二个字段只收到空格；没有旧候选上屏。实际：第一个字段留下 `ni`，第二个字段收到 `你`。两次结果相同，均加载 b94 TSF：[首次](chrome-focus-first-result.json)、[重复](chrome-focus-repeat-result.json)。候选窗在切换后不可见，说明隐藏候选窗本身没有阻止旧组合提交。根因尚未确定。

该结果违反 [产品方向](../../product.md) 中“字段变化立即使旧请求和旧提交资格失效”“不带入新字段”的要求。发现后停止后续输入兼容性测试；没有通过重跑覆盖失败。

## 其余已运行项

| 检查 | 实际结果 | 结论与证据 |
| --- | --- | --- |
| 记事本首轮 `nihc`＋空格 | `ni好` | 保留异常；[首轮驱动](notepad-initial-harness-result.json)的 mode 尾空格跳过了预定的代理冷启动分支，不纳入冷启动结论 |
| 记事本普通及新进程复测 | `你好` | 限定通过：[普通](notepad-basic-result.json)、[新进程](notepad-fresh1-result.json) |
| 记事本代理缺席后复测 | `你好` | 限定通过：[第一次](notepad-cold-result.json)、[新进程](notepad-fresh-cold-result.json)；记录确认代理原先不存在，但 ActivateProfile 为 0ms，不能等同于此前新建 Edit 的 TSF 首次激活耗时实验 |
| Chrome 首轮 `nihc`＋空格 | `nih次` | 间歇失败：[首次](chrome-first1-result.json)；[新开浏览器复测](chrome-first2-result.json)得到 `你好`，原因和频率未确定 |
| Chrome 合成密码字段 | `nihc `，无候选 | 本项通过：[结果](chrome-password-result.json)；未据此宣称全部隐私或记录路径通过 |

记事本正常关闭前备份了原状态，未强制终止用户宿主。备份记录在 `notepad-reopen-result.json`、`notepad-close-b94-result.json`、`notepad-close-fresh1-result.json`。代理缺席检查只停止了已核对路径的 Gogaku 自有代理。

## 安装回滚与卸载：被环境阻塞

使用生产 Inno 模板生成了独立 AppId／CLSID／Run 名称的隔离夹具，计划覆盖 A 安装、x64 注册失败恢复、x86 注册失败恢复、B 升级及卸载。其 DLL 仅写隔离 COM 项，不注册真实键盘；代理／设置替身没有产品行为。

实际以 SYSTEM 计划任务运行 [runtime.ps1](installer-fixture/runtime.ps1) 后，预检读取 A.exe 哈希时被 Windows Defender 拒绝并隔离，检测名为 `Trojan:Win32/Bearfoos.B!ml`。[原始结果](installer-fixture/runtime-result.json)记录 `mutationStarted=false`、`runtimeExecuted=false`；[事件及最终检查](final-state.json)保留 1116／1117 事件、实时防护状态和夹具不存在的检查。因此 A 安装及全部后续步骤均未执行，不能标为回滚／卸载通过；不对该安全检测作误报判定。此次被隔离的是测试夹具，不是 b94 产品 Setup.exe。

生成器、注册替身、包哈希和静态检查记录保存在 [installer-fixture](installer-fixture/README.md)，不包含可执行包或 Wine 环境。源码归档仅便于复核，后续仍需完成运行验证。

## 收尾与剩余范围

[最终状态](final-state.json)确认 b94 代理运行、原有 dev／stable 自启动均保持关闭、隔离夹具的安装根／注册／外部哨兵未创建、临时安装任务已删除，Windows 安全保持开启。[用户会话读取](user-final-state.json)确认设置哈希未变，原有五个用户文件都保留；中文调频模型因合成普通输入发生预期更新。

Enter／Esc／数字／选区替换的剩余项、Windows Terminal、Electron／VS Code、真实 32 位应用、完整学习／隐私矩阵、性能和稳定性均未在本轮完成。此前的双架构受控 Edit、默认升级和七页设置证据仍只适用于原场景。

下一步先修复字段切换后的旧组合资格，补充可重现该反例的回归，再构建新编号包复验本页失败用例；通过后继续剩余矩阵。首组输入异常仍需保留并定位，安装故障恢复／卸载也仍缺运行证据。

## 复现工具

[reproducer](reproducer/)保留实际使用的 C++ 驱动、浏览器用例和交互任务执行器。可在仓库根交叉编译驱动（先准备本项目 Windows 构建工具）：

```sh
x86_64-w64-mingw32-g++ -std=c++17 -O2 -static -municode -mwindows \
  -I shared/third_party \
  docs/validation/dev-b94-acceptance/reproducer/host-acceptance.cpp \
  -o local/windows-acceptance/host-acceptance.exe \
  -lgdiplus -lgdi32 -lole32 -luuid -ladvapi32 -lwinhttp
```

驱动写死本次 VM 临时根与 dev 输入源，使用前必须核对目标环境。`chrome-focus` 是本轮确定失败用例，`chrome-basic` 用于首组输入异常。重跑会注入真实按键，应安排在用户空闲时段并复用窗口所有权保护。
