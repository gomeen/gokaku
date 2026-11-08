# Windows 安装器组装

交付为 Windows 11 x64 的 Inno Setup `Setup.exe`。本脚本只验证、复制已构建文件和编译安装器，不构建 native、不启动 Gogaku，也不要求 VM／真机。Mac 上可用现有 `.build/win-tools/iscc`：Wine 仅运行 Inno 编译器，不执行生成的 Setup 或随包程序。

## 输入与布局

默认从 `.build/win-app/<channel>/bin/` 读取产物。两种 TSF 都通过私有管道连接 x64 `GogakuAgent.exe`；TSF 不直接或间接加载核心，不需要 x86 核心。

```text
.build/win-app/dev/
  bin/
    x64/GogakuTsf.dll
    x64/GogakuAgent.exe
    x64/GogakuSettings.exe
    x64/libgogaku_core.dll
    x86/GogakuTsf.dll
  data/                         # 通过 --data-dir 明确指定
    sc.dict
    zh_CN.lm
    english-words.txt
    gloss.tsv
  licenses/                     # 通过 --license-dir 明确指定，可重复
```

各架构的非系统 DLL 必须与对应程序同目录或由旧 `--core-dir`／`--core-dir-x86` 指定的本架构目录提供。脚本解析 PE/COFF Machine、DLL/EXE 类型、普通和 delay import，递归收集依赖；不搜索 PATH，不向另一架构借 DLL。缺失依赖、坏 PE／截断文件、x64/x86 放错和 TSF 依赖核心均以 exit 2 拒绝。只有实际导入 `libwinpthread-1.dll` 时才需要它；已静态链接的 libime／Fcitx 等不再强制要求对应 DLL。VC++／MinGW runtime 不当作系统库豁免。动态加载的 x64 核心作为明确的必需根文件检查。

只复制闭包内的 PE，不复制 bin 目录中的日志、导入库或过期 DLL。`--tsf-x64`、`--tsf-x86`、`--agent`、`--settings` 仍可指定独立文件，优先于 `--bin-dir`；旧 `--core-dir` 指定 x64 核心及依赖，`--core-dir-x86` 只提供 x86 依赖，不要求 x86 核心。未指定独立路径时优先采用上述新布局，仍可回退到旧 `.build/win-tsf/`、`.build/win-agent/`、`.build/win-settings/` 与 `.build/win-cross/clang{64,32}/bin/` 路径。

## 资源与许可

`--data-dir` 默认 `.build/win-data`。`--resources-dir` 默认仓库 `resources/`，从中明确加入：

- `english-wordlist-sources.json`、`gloss-sources.json` → 包内 `data/`。
- `update/config.json` → 包内 `resources/update/windows.json`，与 Windows 更新代码读取路径一致，原样保留空 owner/repo；构建不联网或生成更新源。
- `licenses/` → 包内 `licenses/` 的独立子目录，包括 SCOWL、wordfreq／Wiktionary／CC-CEDICT、jieba、Mayoi 相关许可和署名。

`--license-dir` 可重复，未传时为 `shared/licenses`；将指定目录的实际文件连同相对目录结构复制到编号子目录，避免同名 `LICENSE`／`COPYING` 覆盖。不扫描整个仓库或将源码目录递归打入安装包。

`--deps-source-dir` 默认 `.build/win-cross/static`，从固定目录加入 libime 的 `LICENSES/LGPL-2.1-or-later.txt`，KenLM 的 `COPYING`、`COPYING.3`、`COPYING.LESSER.3`、`LICENSE`，以及 Fcitx5 的 LGPL 和 Unicode 许可。根目录下需有 `libime/` 和 `fcitx5/`；使用其它源码缓存时显式传此参数。静态链接仍需保留这些许可材料。

`--windows-source-dir` 默认 `windows/GogakuWindows`，从 `third_party/` 加入 `json-LICENSE.MIT`、`miniz-LICENSE.txt`、`monocypher-LICENCE.md`。Windows Ed25519 使用 Monocypher，不能写成系统 CNG 提供。实际静态 runtime／zstd 等附加声明应准备在 `--license-dir` 中；脚本不从 PE import 推断静态代码的许可完整性。资源和明确列出的许可文件缺失或为空会失败。

## 自测、检查与编译

先由 native 构建流程备齐输入；以下命令不会重编译或执行 native：

```sh
python3 scripts/build-win-app.py --self-test
# 可选：临时合成 PE 夹具也交给实际 Inno 编译，测试产物只在临时目录，随测试删除。
python3 scripts/build-win-app.py --self-test --iscc "$PWD/.build/win-tools/iscc"

python3 scripts/build-win-app.py --channel dev \
  --bin-dir .build/win-app/dev/bin \
  --data-dir .build/win-app/dev/data \
  --license-dir .build/win-app/dev/licenses --check

python3 scripts/build-win-app.py --channel dev \
  --bin-dir .build/win-app/dev/bin \
  --data-dir .build/win-app/dev/data \
  --license-dir .build/win-app/dev/licenses \
  --iscc "$PWD/.build/win-tools/iscc"
```

Windows 上可将 `--iscc` 改为实际 `ISCC.exe` 路径。本机 Wine wrapper 仅转换 `.iss` 参数，脚本会把模板内绝对 POSIX 路径转换为 Wine 的 `Z:\...`。官方 Inno 6.7.4 不附 `ChineseSimplified.isl`，模板采用自带英文向导消息，Gogaku 自定义提示保留中文。

根 `version.json` 是唯一版本来源。版本须为三段 SemVer，可带 `dev.N`／`rc.N`；构建号为 1–65535 整数，Windows 数值版本为三段版本＋构建号。兼容 `--version`／`--build` 只能传与根文件完全相同的值，不能覆盖。stable 只接受正式版本；dev 通道可接受 dev／rc／正式，但 rc／正式无论通道都要求已跟踪文件干净，dev 版本允许 dirty。Git 状态按 `git status --porcelain --untracked-files=no` 计算，与仓库版本规则一致。

输出默认在 `dist/gogaku-win/`：版本暂存子目录、`Gogaku-<version>-b<build>[-dev]-windows-x64-setup.exe` 和 `.exe.sha256`。包内 `build-identity.json` 包含根版本文件哈希、Git commit／dirty、版本阶段、两架构 PE 导入闭包和每个 payload 文件的 SHA-256／大小。`.iss` 位于暂存根，但 `[Files]` 只列 bin、data、resources、licenses 及 identity，不包含 `.iss` 自身。未传 `--iscc` 只暂存；传入后要求编译成功且生成非空 EXE，旧同名输出不会冒充本轮成功。

## 安装与卸载行为

- 只允许 Windows 11 x64（10.0.22000+），Program Files 安装。机器级 COM／TSF 注册使用 UAC；x64 用 System32 的 `regsvr32`，x86 用 SysWOW64，调用时显式控制文件系统重定向。
- 注册位于文件安装阶段的 `AfterInstall`，检查进程启动结果和退出码；任一架构失败会尝试撤销本次注册、恢复旧双架构注册与路径指针，并抛错触发文件回滚。清理／恢复错误附在失败信息中；真实故障恢复矩阵需另行验证。
- 不激活、不设默认输入法、不改用户语言列表。设置应用默认不打开；只有用户勾选后才以原用户身份启动。登录启动默认关闭，仅用户勾选后由代理以 `runasoriginaluser` 写入自己的 Run 项。安装期间不无条件启动常驻代理。
- 程序与只读资源放入 `{app}\versions\<version>-b<build>-<channel>`；卸载器留在固定 `{app}`。升级只检查新目标目录，不覆盖旧宿主持有的 DLL；同一构建重装和卸载仍检查占用，提示用户手动退出后重试。`CloseApplications=no`、`RestartApplications=no`，不强杀宿主、不自动注销／重启，也不安排重启后替换。
- 注册前保存双架构旧 DLL 路径；新注册失败时撤销本次注册、恢复旧注册和路径指针。成功后以 64 位 `HKLM\Software\Gogaku\<channel>\ActiveRoot`／`PreviousRoot` 记录当前与上一 payload；没有旧指针时从旧 DLL 路径推导。新 TSF 只信任这两个受保护根下的准确代理路径，健康旧代理可继续持有调频；旧宿主释放后的版本清理尚未自动化。
- 升级仅迁移已加载用户 hive 中、准确指向旧 payload 的既有自启动值；没有启用自启动的用户保持关闭。离线用户 hive 不加载、不迁移。
- `[UninstallRun]` 不使用非法的 `runasoriginaluser`。确认卸载后，Pascal 清理从 HKEY_USERS 枚举已加载用户 hive，只删除当前通道命名、且命令完整匹配本安装目录代理的 Run 值，不在提升账户的 HKCU 执行用户代理命令。离线用户 hive 不加载、不修改，界面提示这类用户可在 Windows 启动应用中移除失效项。双架构 `regsvr32 /u /s` 注销在文件删除前执行并检查结果。
- 使用 Inno 的安装文件清单卸载，不递归清空整个安装目录；用户额外放入的文件不擅自删除。`%LOCALAPPDATA%\Gogaku` 中的数据、词表、主题和凭据默认保留。

这里只记录构建与组装边界。成功生成 EXE 表示 Inno 编译通过，不代表安装／卸载、TSF 宿主或输入功能已经通过运行验收；本组装任务不执行这些程序，也不以它们为生成安装包的前提。

## 许可边界

Inno Setup 仅作为构建工具使用，工具本身的使用许可单独适用。安装器不包含本地翻译模型。当前不做 Authenticode 签名；公开分发前仍需完成实际静态链接依赖的适用源码／重链接材料和 Gogaku 自身许可决定，不能仅凭附带许可文本宣称全部义务已完成。
