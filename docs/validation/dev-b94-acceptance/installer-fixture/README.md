# 实际执行补记

2026-11-08：已在 Windows VM 以 SYSTEM 计划任务尝试 `runtime.ps1 -InputActivityFinished`。预检读取 A.exe 哈希时被 Microsoft Defender 拒绝，记录为 Trojan:Win32/Bearfoos.B!ml 并隔离；不对该检测作误报判定。`runtime-result.json` 记录 `mutationStarted=false`、`runtimeExecuted=false`；A、失败回滚、成功升级及卸载均未执行。最终只读检查确认夹具安装根、隔离注册及外部哨兵未创建，临时计划任务已删除。正式产品包未在此次隔离事务中执行。

以下是夹具编制时的说明，尚未运行的步骤仍为预期断言。源码归档后需复制回仓库 `local/windows-acceptance/installer-fixture/` 才能使用原生成器的相对路径；本归档不含可执行包、Wine prefix 或 payload。清单保留当时包哈希。

# b94 隔离安装事务夹具

这里所有产物都用于安装器事务验收，不是 Gogaku 产品包。没有运行任何夹具 EXE、DLL、安装器或卸载器，也没有连接 VM。只通过既有 Wine 运行 ISCC 编译器。生产模板及源码只读，生成器的临时文件、Wine prefix、缓存和输出均位于本目录。

## 本机复现

在本目录运行：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 generate.py
PYTHONDONTWRITEBYTECODE=1 python3 verify.py
```

依赖现有双架构 MinGW GCC/objdump，以及仓库 `.build/win-tools/` 下的 Wine、Inno ISCC。没有调用会写其他目录的原有 ISCC wrapper。`generate.py` 从真实 `windows/packaging/gogaku.iss.in` 替换占位符，核对 `[Code]` 除 Run 名称替换外逐字一致。版本为 1.0.0，A 构建号 1，其余为 2。

- `register.c`：不调用 CTF、不注册真实键盘；在自身架构的 HKLM 视图写隔离 CLSID。x86 使用显式 `@0` 内部符号映射，并禁用链接器 stdcall 自动修补；对外仅导出无修饰的两个标准入口。
- `noop.c`：代理和设置程序均立即返回 0，没有文件、注册表或进程操作。
- `payloads/`：只含夹具 PE、少量哨兵、构建身份；没有真实用户数据、凭据或产品资源。
- `packages/`：A、B-success、B-fail-x64、B-fail-x86 四个安装器。
- `packages.json`：绝对和相对包路径、SHA-256、预期安装版本根、完整隔离身份、逐步 VM 断言及调用日志顺序。
- `verification.json`：独立静态复核结果。检查实际 PE、双架构导出、依赖、安装包哈希、输入文件及 ISCC 压缩清单；没有通过运行安装器验证。

两个失败包分别在本 payload 的 `data/fail-register-x64.flag` 或 `data/fail-register-x86.flag` 中携带故障计划。DLL 先写入隔离 InprocServer32，再返回 `E_FAIL`；撤销始终不读取故障标志。A 不含标志，因此恢复 A 不被 B 的计划影响。注册事件追加到安装根 `fixture-register.log`，包含模块路径、架构、操作、HRESULT 和注入标志；日志留在版本目录外，回滚后仍可取证。

## 主线程未来在 VM 的顺序

详细机器可读步骤以 `packages.json` 的 `vmExecution` 为准，当前未执行。使用 Windows 11 x64 管理员上下文，每一步等待进程结束、采集退出码和独立 Inno 日志。拒绝覆盖任何既有夹具身份、安装根或同名 Run 值。实际根由 `%ProgramW6432%` 展开，默认 `GogakuAcceptanceB94`；不要传 `/DIR`。使用清单提供的参数，清空全部任务，避免启动任何代理或设置。

1. 只读记录 dev/stable 的双视图 COM/TSF、通道指针、卸载键、所有已加载 hive 的 Run 项和用户数据文件集合/哈希；在独立 ProgramData 目录放一个外部保留哨兵。
2. 安装 A：退出 0，双视图指向 A，ActiveRoot=A、PreviousRoot 为空字符串，无自动 Run 项。核对文件哈希后，仅在操作者已加载 hive 中手工设置隔离 Run 名称，值为双引号包围的 A 代理完整路径。
3. 安装 B-fail-x64：非零退出；日志应为 B64 注册失败、B86 撤销、B64 撤销、A64/A86 恢复。两视图恢复 A、指针和 Run 不变、B 文件回滚、A 文件及卸载信息保留。
4. 安装 B-fail-x86：非零退出；日志应为 B64 成功、B86 失败、B86/B64 撤销、A64/A86 恢复，其余断言同上。
5. 安装 B-success：退出 0，两视图指向 B，ActiveRoot=B、PreviousRoot=A，既有隔离 Run 迁移至 B；原先没有 Run 项的其他 hive 保持没有。核对 B 的文件哈希。
6. 运行隔离根下的 `unins000.exe`：退出 0，两视图隔离 CLSID、指针、已种入的 Run 值、夹具卸载记录及 A/B 文件均删除。允许空通道键、空目录和夹具日志残留。取回日志后再清理夹具残留。外部哨兵及生产快照必须不变。

B 三种包故意共用版本根，因此必须先跑两次失败再跑成功。此次故障发生在指针/Run 迁移前，不能据此声称覆盖迁移中途回滚；注销失败、ACL/指针失败、真实 TSF 及输入功能也未覆盖。无副作用代理不实现自启动设置，故 Run 迁移用独立预置值验收。
