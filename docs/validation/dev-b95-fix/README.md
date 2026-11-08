# Windows b95 组合终止修复与限定回归

本轮针对 [b94 扩大宿主验收](../dev-b94-acceptance/README.md) 中的 Chrome 跨字段提交与预编辑残留修复。版本为 `0.1.1-dev.2 / b95 / dev`。完整 Windows 宿主、安装回滚／卸载及朋友真机验收仍需单列完成。

## 修复内容

`windows/GogakuTsf/src/text_service.cpp` 的 `OnCompositionTerminated` 原先只释放本地组合并把 `opened_` 清为 false，未发送代理失焦。因此重新打开同一上下文身份时，代理仍可能返回旧编码，进而提交到另一个字段。现在使用终止回调给出的旧范围和编辑 cookie 清理预编辑，撤销代理提交资格，清空本地状态，并为该上下文下一次使用分配新字段身份。清理失败也必须撤销资格；重复通知、自身编辑通知和其他组合的通知不得误伤活动组合。

Chromium 的临时文本存储（`TS_SS_TRANSITORY`）可能先把预编辑确认进 DOM，再通知组合终止；回调中 `SetText` 即便成功也无法撤回 DOM 残留。该类文本存储保留空组合范围，编码只显示在浮动候选窗，明确选词时再写正文。原生持久文本存储仍遵循「输入区字母」设置。宿主复用上下文导致旧字段身份无法确认时，不向新字段提供旧草稿恢复。

## 可重跑的组合回归

构建：

```sh
python3 probes/build-windows-composition-lifecycle.py
```

复制 `.build/windows-composition-lifecycle/x64/` 和 `x86/` 到 Windows，分别运行 `CompositionLifecycleTest.exe`，保存每个目录的 `result.json` 和退出码。这是合成 COM 回归：调用生产 `TextService` 终止回调，替代代理传输，不发送真实按键，不访问用户数据。每架构两条路径覆盖旧范围清除成功／被拒绝、提交资格撤销、上下文身份更新、重复／无关／自身通知以及 COM 引用释放。

本轮 Windows 实跑：

- [修前负例](composition-before.json)：退出 1，旧回调保留代理提交资格。
- [修后 x64](composition-after-x64.json)、[修后 x86](composition-after-x86.json)：退出 0，两条路径通过。

[负例构建器](reproducer/build-baseline.py) 仅把当前生产源码中的终止回调换回旧实现，其他代码保持当前实现；需在仓库根执行。它生成独立 EXE，不替换或注册正式 DLL。

## 安装、身份与真实宿主

[安装记录](install.json) 核对了默认升级成功、71 个文件、双架构 COM 和当前／上一版本目录。首次管理员任务因无权读取用户数据在启动安装器前停止；随后改由已登录用户单独核对哈希，提权任务仅安装。未修改用户文件权限、未指定额外 `/DIR`、未强杀宿主。

正式包宿主回归结果见上级 [b95 汇总](../dev-b95-fix.json)。必须区分以下两组结果：

| 场景 | 实际结果 |
| --- | --- |
| b95 DLL＋长期运行 b94 代理的首轮切框 | 失败：原框留下 `i`，新框只有空格；旧中文未跨字段提交，独立根因仍未定位 |
| b95 DLL＋b95 代理，两次 Chrome 切框 | 通过：原框空，新框仅一个空格，无候选／旧草稿 |
| b95 DLL＋b95 代理，四个 Chrome 新宿主首组 | 均提交“你好” |
| b95 DLL＋b95 代理，合成密码字段 | 原样 `nihc `，无候选 |
| b95 DLL＋b95 代理，记事本两次暖启动 | 均提交“你好” |
| b95 DLL＋b95 代理，记事本两次代理缺席后的新进程首组 | 均提交“你好” |
| 诊断构建对照 | 当前代理切框、重新启动旧代理切框及首组“你好”通过；不覆盖首轮失败，不归因于版本差异 |

需要同时核对 `modulesBefore`／`modulesAfter` 的正式安装路径与进程内 PE 时间戳；登记正确不代表宿主已换用新 DLL。诊断阶段的成功不代替正式安装件结果。11 次正式限定用例和 3 次诊断对照均已归档，原始失败也保留。

记事本预检发现旧 b94 模块时没有发送按键；会话与活动文档备份后正常关闭重开，未强杀用户宿主。冷启动夹具改为核对代理进程身份与存活状态，跳过已终止但仍在进程快照中的对象；初版工具在停止代理后的检查报错，未发送输入，修正后重测。仅用托盘窗口不存在不能证明代理已经退出。

[真实宿主夹具源码](reproducer/host-acceptance.cpp) 与 [浏览器用例](reproducer/browser-cases.h) 保留合成测试页面、焦点、逐键和模块证据。可用 MinGW-w64 构建：

```sh
x86_64-w64-mingw32-g++ -std=c++17 -O2 -static -municode -mwindows \
  -I shared/third_party \
  docs/validation/dev-b95-fix/reproducer/host-acceptance.cpp \
  -o HostAcceptance.exe -lgdiplus -lgdi32 -lole32 -loleaut32 -luuid -lcomctl32 -lwinhttp
```

夹具包含 [共用辅助源码](reproducer/helpers.cpp)。真实宿主复跑需先核对源码中的本机用户临时目录，并在其 `tools/chrome/chrome-win64/chrome.exe` 放好独立 Chromium 测试程序；未随仓库附带浏览器。只在已授权且空闲的 Windows 桌面运行 `HostAcceptance.exe chrome-focus` 等模式。夹具会创建专属测试文档并发送真实按键；正常关闭自己的窗口，不操作其他文档。测试目录和文档标记保留了历史 `B94` 前缀，构建身份以实际 DLL 模块及收据为准。私有 VM 连接执行器位于 `local/`／`.build`，不属于可移植产品工具。

## 构包和验证

- [fast 7/7](../verify/report-fast-dev-b95.json)：核心 CTest、Swift Release 217 项、资源及版本、翻译数据和验证／交付合同；源码、测试指纹及双端包哈希对应。
- [ASan／UBSan quick](../verify/report-asan-ubsan-quick-dev-b95.json)：2,000 序列通过；整体 release gate 仍未通过。首次旧目录缓存失败保存在 [初次报告](build/asan-initial-cache-failure.json)。
- Windows EXE SHA-256：`6bd53d42f870900a8cbebf354670c9003ce8aa96dfcd09ca392d1594b194bfa9`。
- Mac PKG SHA-256：`5f855ae522314934a76239a36ad76b29d5fed0d3037b4663750ad6fa6a619b25`；Mac 本轮只构包，未安装。
- [最终清理](state/cleanup95.json)：正式双架构注册恢复、正式 b95 代理运行、临时安装与已识别探针任务已清理，安全防护保持开启；设置及自启未变，数据文件保留，中文调频因合成提交变化。

## 验证边界

fast 报告绑定本轮源码、测试指纹和双端包哈希；Mac b95 仅重建，未在本轮安装。macOS 上的 clangd 没有 Windows SDK 头文件搜索路径，诊断因找不到 `windows.h` 失败，未记作静态检查通过；实际 MinGW x64／x86 编译及 Windows 回归结果另列。ASan／UBSan quick 仅验证共享核心随机序列，不替代 Windows COM 或真实宿主验收。首次 ASan 配置因目录迁移前的 CMake 缓存失败，已保留旧缓存并新建缓存重跑。

首组 `nih次`／`ni好` 属于 b94 的间歇异常。后续成功必须按实际轮数记录，不能据此声称已经定位其独立根因。完整宿主矩阵、性能／长时稳定性、真实在线翻译、安装故障恢复和卸载均不在本次限定修复通过范围内；安全软件预检阻塞仍保留历史结论。
