# 本机原生开发版

这是首阶段实施中的本机开发版，完整产品尚未通过。已验证能力与待验收矩阵见[验收记录](validation/native-development.md)，产品行为以[产品方向](product.md)为准。

## 构建与检查

目标为当前 Intel Mac、macOS 26.7.2。需要已有 Xcode／Swift 6、CMake、Ninja、Boost、gettext、zstd。依赖准备仅写 Gogaku 自身缓存，不改系统输入源。

```sh
python3 scripts/prepare-dependencies.py --jobs 2
python3 scripts/build.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -c release -j 2
```

若默认 Command Line Tools 缺少 XCTest，使用上面的单次 `DEVELOPER_DIR`，无需改全局 `xcode-select`。构建脚本在已有 `/Applications/Xcode.app` 时也使用该目录。测试与交付构建同为 **Release 配置**；Debug 测试结果不作为验收证据。

### 验证节奏

开发要快，全量留给里程碑与排查；档位实现见 `scripts/verify.py` 文件头。

| 场景 | 命令 | 耗时 | 内容 |
| --- | --- | --- | --- |
| 平时开发（每轮改动） | `python3 scripts/verify.py --profile fast` | 约 2 分钟 | 关键测试：核心 ctest＋Release Swift＋版本＋资源 |
| 核心／内存敏感改动后（可选） | `python3 scripts/verify.py --profile release --only asan-ubsan --quick` | 约 4 分钟 | ASan/UBSan 2000 序列冒烟（注明不满足十万门槛） |
| 发版本／交付 rc／定版／疑难排查 | `python3 scripts/verify.py --profile release` | 约 2.5 小时 | 全量：干净构建＋包检查＋质量＋渲染＋数据可靠性＋十万序列插桩＋安装预检；**后台运行，不阻塞迭代** |
| 真实宿主／性能／稳定性 | `python3 scripts/verify.py --profile host --yes` | 数小时 | 两轮宿主矩阵、Orca Shift 专项、万次性能、两小时稳定性；仅用户空闲时段执行 |

约定：全量档只在「要对外提供安装包」或「出现难以定位的问题需要全面排查」时运行；开发阶段不允许为等待全量结果阻塞迭代（后台跑完再归档证据）。历史报告不自动代表当前源码通过，源码改变后按受影响范围补跑。

产物为 `dist/Gogaku.app` 与 `dist/Gogaku Settings.app`。输入源包含固定libime数据及重定位共享库，运行不需Homebrew或源码目录。依赖锁与许可在包内；ad-hoc签名只用于本机，不代表已公证或可公开分发。正式公开前仍须处理GPL／LGPL源码及重新链接义务。

图标源头是 `assets/app-icon/`：`icon.svg`（应用图标，全出血暖纸底圆角方块＋炭黑「こ」＋红浊点，四角保持真透明、不烘焙阴影描边，与 Zakki 图标同一套视觉语法）和 `menu.svg`（输入源菜单用黑色圆角键帽，内部两笔为真正透明镂空）。`python3 scripts/make-icons.py` 生成 `AppIcon.icns`、预览 PNG 与一个 22×16pt 的纯矢量 `gogaku-menu.pdf`；应用图标各尺寸由 NSImage（`scripts/render-svg.swift`）从 SVG 直出并保留透明通道——qlmanage 生成的是 Finder 白底缩略图，会把透明边距压成不透明白色，导致 dock 图标外多一圈白框，已弃用。页面尺寸与青简一致，键帽几乎撑满页面，系统菜单里与 ABC、青简等输入源图标同宽同高；笔画用 even-odd 镂空而非白色填充，避免系统按模板染色后字形消失。`build.py` 和包检查都会渲染 PDF，断言页面为 22×16、墨迹撑满页面且内部存在透明笔画。重新安装会刷新注册元数据；若系统菜单仍缓存旧图，可在退出菜单后运行 `killall TextInputMenuAgent` 让它自动重建。

## 安装和手动启用

```sh
python3 scripts/manage-install.py install
open "$HOME/Applications/Gogaku Settings.app"
```

输入源装入 `~/Library/Input Methods/Gogaku.app`，设置应用装入 `~/Applications/Gogaku Settings.app`。更新只覆盖经bundle ID核对的Gogaku应用，旧版应用转移到用户目录 `DeveloperBackups/`。若正在使用Gogaku，先手动切到ABC等现有输入源。

输入法的 Info.plist 含 `ComponentInputModeDict`（`org.gogaku.inputmethod.Hans` 模式）、带扩展名的图标键与 `InfoPlist.strings` 本地化显示名。安装时执行 LaunchServices 与 TIS 注册；`register` 子命令可单独刷新 TIS 元数据。输入源启动时只创建 IMKServer，不再自启用，以免反复弹出系统确认并干扰切换。

在“系统设置 → 键盘 → 文本输入 → 编辑 → ＋”中手动添加Gogaku，再从输入源菜单手动切换。原有输入源保留，脚本不会切默认。如果安装后没有出现在列表，可能需要用户自行注销／重新登录；不自动注销、重启或关闭系统安全机制。

**当前尚未通过宿主安全矩阵。** 学习模式会显示未验收提示，翻译、拼写辅助与真实学习记录保持关闭；仍可明确原文上屏。开启系统语言包也不会自动解除这项宿主安全门槛。

## 真实宿主回归

先在系统设置中手动启用输入源，再执行：

```sh
python3 probes/validate-imk-host.py
python3 probes/validate-imk-host.py --orca
```

脚本短暂切换焦点和输入源，在新建 AppKit 窗口及专用 Orca 测试终端中仅输入合成文字，结束后恢复。Orca 部分直接核对 PTY 字节，报告写入 `docs/validation/imk-host-smoke.json`；不会向已有 agent 终端发送文字。已覆盖普通上屏、原文回车、Control＋空格、选区替换、连续按键与部分撤销场景，完整安全矩阵仍见[验收记录](validation/native-development.md)。

## 设置页面

设置窗口采用 200pt 左侧分类导航、右侧内容滚动区与固定底部状态栏布局，六页分别为“语言资源”“普通输入”“自定义词语”“快捷键”“学习与隐私”“学习片段”，默认 900×620、最小 760×520，青绿强调色跟随系统明暗外观（视觉规格见[产品方向](product.md)「设置页面规格」）。

所有改动**立即保存**：普通选项、应用列表、有效快捷键改动即时提交；连续文本输入（如忽略词）合并 300 毫秒后提交，失焦或关闭窗口时提交剩余改动。底部状态栏显示保存中／已保存／失败，失败时改动保留并可点「重试」。添加应用通过可搜索弹层（索引 `/Applications`、`/System/Applications`、`~/Applications`），也可点「选择其他位置的 .app…」；未安装的应用保留在列表中并显示通用图标。

### 添加自定义词语

打开「Gogaku Settings → 自定义词语」，在对应区域新增；拼音词表单标题应为「编辑拼音词」，显示内容、读音和「自动读音」按钮，编辑时预填当前词条，新增时为空白：

- **拼音词**：例如内容填「极视角」，读音填 `ji'shi'jiao`（规范全拼、每字一个音节、用英文撇号分隔），也可点「自动读音」后核对多音字。保存后，小鹤输入 `jiuijn`、全拼输入 `jishijiao` 都能匹配，并作为高权重词参与组句。自动读音使用设置应用自己的随包词典，无需开发缓存。
- **短码短语**：例如编码填 `dz`，内容填完整地址；只有输入完整编码时匹配，不会将编码自动换算成双拼。

保存后约 1 秒内在普通模式的中文状态生效。可在列表中编辑、删除、启停与调整顺序；清空调频不影响自定义词语。若自动读音无法覆盖某个字，可逐字手填读音。

## Apple本地语言资源（历史实现）

**Apple Translation 已退出正式交付链路**（双端计划已确认统一采用 small100；本节仅作历史证据保留，不是当前使用说明）。2026-11-03 起，设置应用“语言资源”页不再提供 Apple 语言资源的查询与安装入口，只展示实际随包资源（`sc.dict`／`zh_CN.lm`／`english-words.txt`／`gloss.tsv`）与功能开放状态；学习模式保持关闭（见验收记录）。不要把安装 Apple 语言资源当作学习功能前置步骤。

推理helper使用 `TranslationSession(installedSource:target:)`，缺包返回 `resource_not_installed`，不在后台下载。当前辅助进程不提供任意网络接口。

冻结双向各100条保留集与原32条风险回归后，在资源安装完成时运行：

```sh
python3 scripts/validate-translation.py
```

结果进入被Git忽略的 `local/translation-validation/`，区分风险集、保留集的盲测／参考文件。应译可用率需用户逐条审阅确认；脚本不把非空输出当作语义通过，也不自动宣布资源合格。安装缺口不计作质量测试失败，不据此跳到small100。

## 输入与恢复

- 普通状态：小鹤、空格选中文、Enter原编码、数字 1–9 选候选；Esc取消；`,`／`.` 翻上一页／下一页（有候选时，每页 9 个）
- 学习键位和数字／标点规则详见[产品方向](product.md)。当前资源及宿主门槛未通过时，没有可提交机器译文。
- 模式／方向、应用／字段切换使旧候选失效。未完成输入保留为进程内草稿，在输入源菜单显式恢复或清空，退出不保留。
普通输入支持 `Page Up`／`Page Down` 以及 `,`／`.` 翻页；逗号和句号只有在当前组合已有候选时作为翻页键，否则交还宿主或按原有标点规则处理。

```sh
python3 scripts/manage-install.py diagnose
python3 scripts/manage-install.py recover
```

恢复命令给出手动切源、移除／重新添加、重建与备份位置，不修改系统输入源选择。诊断只读Gogaku安装／签名和当前是否选中，不读取私人输入历史。

## 卸载与数据

先切到其他输入源，在系统设置移除Gogaku，再执行：

```sh
python3 scripts/manage-install.py uninstall
```

默认保留 `~/Library/Application Support/Gogaku/`，包含设置、学习库和开发备份。确需清除时使用 `uninstall --purge-data` 并在终端输入 `DELETE`确认。系统语言包仍由系统管理。

真实宿主验收只在新建的合成测试文档／字段进行，核对正文、焦点和选区；自动化操作成功、桥接调用返回或核心测试通过，均不能替代最终宿主内容证据。
