# 本机原生开发版

这是首阶段实施中的本机开发版，完整产品尚未通过。已验证能力与待验收矩阵见[验收记录](validation/native-development.md)，产品行为以[产品方向](product.md)为准。

## 构建与检查

目标为当前 Intel Mac、macOS 26.7.2。需要已有 Xcode／Swift 6、CMake、Ninja、Boost、gettext、zstd。依赖准备仅写 Gogaku 自身缓存，不改系统输入源。

```sh
python3 scripts/prepare-dependencies.py --jobs 2
python3 scripts/build.py
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test -j 2
```

若默认 Command Line Tools 缺少 XCTest，使用上面的单次 `DEVELOPER_DIR`，无需改全局 `xcode-select`。构建脚本在已有 `/Applications/Xcode.app` 时也使用该目录。

产物为 `dist/Gogaku.app` 与 `dist/Gogaku Settings.app`。输入源包含固定libime数据及重定位共享库，运行不需Homebrew或源码目录。依赖锁与许可在包内；ad-hoc签名只用于本机，不代表已公证或可公开分发。正式公开前仍须处理GPL／LGPL源码及重新链接义务。

图标源头是 `assets/app-icon/`：`icon.svg`（应用图标，暖纸底＋炭黑「こ」＋红浊点，与 Zakki 图标同一套视觉语法）和 `menu.svg`（输入源菜单用黑色圆角键帽，内部两笔为真正透明镂空）。`python3 scripts/make-icons.py` 生成 `AppIcon.icns`、预览 PNG 与一个 22×16pt 的纯矢量 `gogaku-menu.pdf`。页面尺寸与青简一致，键帽几乎撑满页面，系统菜单里与 ABC、青简等输入源图标同宽同高；笔画用 even-odd 镂空而非白色填充，避免系统按模板染色后字形消失。`build.py` 和包检查都会渲染 PDF，断言页面为 22×16、墨迹撑满页面且内部存在透明笔画。重新安装会刷新注册元数据；若系统菜单仍缓存旧图，可在退出菜单后运行 `killall TextInputMenuAgent` 让它自动重建。

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

设置窗口参考 Zakki，采用左侧分类导航、右侧平面分组布局。四页分别为“语言资源”“快捷键”“学习与隐私”“学习片段”；标签在左、控件在右，每页独立滚动。修改快捷键、记录开关、应用排除或忽略词后，点击页面底部固定的“保存设置”。切换页面会保留本次窗口中尚未保存的输入。

## Apple本地语言资源

在设置应用左侧选择“语言资源”，分别点击“中文 → 英语”和“英语 → 中文”右侧的“安装资源”，按系统提示明确授权。安装后点击“刷新状态”；已显示“已安装”（系统 `installed`）的方向不必重复安装。系统管理资源，Gogaku不复制权重。只有双向均为“已安装”后，才能执行真实翻译验收；“尚未安装”（系统 `supported`）只说明系统支持获取资源。

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
