# 工程化检查记录（0.1.0 前）

日期：2026-11-02。范围：当前交付链路（共享 C++ 核心 → Swift／IMK 平台层 → 两套应用 → 本机安装）的工程检查与整改。目标：区分**发布阻塞**与**后续改进**，避免无目的重构；每项列出证据、影响、处置与验证结果。验收状态仍以[原生开发验收](native-development.md)为准；性能与宿主矩阵阻塞不在本文重复展开，只登记工程侧关联项。

执行环境：Intel Mac i9-9880H、macOS 26.7.2；本轮首个基线提交 `176ae8e`（现状基线、尚未完成验收）。

## 1. 模块边界与接口

**检查**：共享核心（`shared/GogakuCore`，C ABI v2）不含 Apple 框架头文件（`grep AppKit|Foundation|CoreFoundation|Darwin/` 于全部 `.cpp`／头文件无匹配）；平台接入（IMK／AppKit）全部在 `macos/Sources/GogakuInput`／`macos/Sources/GogakuHost`；宿主 IMK 调用全部 `@try/@catch` 包裹（`Host.m` 全部 5 个入口）。UTF-8→UTF-16 转换集中在 `PreeditCaret`（越界裁剪＋半标量回退，有单测）；核心报告 UTF-8 字节偏移，平台不混用原始偏移（线程／所有权合同见 `gogaku_core.h` 头注释：会话非线程安全、单串行队列拥有、库内分配库内释放、异常与 STL 不跨 ABI——`gc_normal_handle`／`create`／`flush` 均有 try/catch 边界）。

**发现**：

| 项 | 级别 | 处置 |
| --- | --- | --- |
| `nm -gU libgogaku_core.dylib` 除 `gc_*` 外还导出 2 个 libime RTTI 弱符号（`__ZTI/__ZTS shared_ptr_emplace`） | 后续改进 | macOS dylib 无实际风险；**Windows DLL 必须用显式导出清单只导出 `gc_*`**，已写入移植注意（`docs/implementation-plan.md` §二已含 DLL 导出要求） |
| 会话串行队列合同靠约定（`EngineHub` 单队列），ABI 层无运行时断言 | 后续改进 | 头文件已写明；跨平台迁移时在 ABI 层加所有者断言，不在本轮扩接口 |

**Windows 移植依赖记录**（非本轮验证项，不得写成已验证）：libime（上游有 Clang64 工作流，自验未做）、CTranslate2＋SentencePiece 本地实现、TSF 前端、Win32 设置、显式 DLL 导出、UTF-8 路径处理。以上全部未开始。

## 2. 构建与依赖

**检查**：依赖固定在 `probes/prepare-libime-input.py` 顶部常量（libime `5be1300`、fcitx5 `dfb1278`、ECM `7dd28cc`、KenLM `4cb443e`）；下载档案按 sha256 校验；转换数据（`sc.dict`／`zh_CN.lm`）与冻结哈希逐字节比对（`prepare-dependencies.py`）；`dependencies.lock.json` 随包。数据生成（英文词表、gloss）脚本化、来源与哈希入清单（`resources/*-sources.json`）。

**本轮整改**：

| 项 | 影响 | 处置 | 验证 |
| --- | --- | --- | --- |
| `prepare-dependencies.py` 隐式迁移 `/tmp/gogaku-ime-benchmark` 遗留物 | 生产构建依赖旧探针缓存路径 | 删除迁移块；本机工具（git／cmake／ninja／clang）缺失时明确报错 | 语法检查＋`verify.py fast` 资源检查通过 |
| 版本硬编码 `CFBundleVersion=1`、`0.1.0` | 构建不可区分、无法追溯 | `version.json` 单一来源＋包内／外部构建身份（见 [versioning.md](../versioning.md)） | 构建（本轮 release 验证）产出身份且提交绑定 |
| 无干净构建证明 | 不确定性漂移 | `build.py` 支持 `GOGAKU_BUILD_ROOT`；`verify.py release` 的 `clean-build` 先删后建全新构建根（native／core／swift 互不复用）；依赖缓存只读复用（不清除用户缓存，全新缓存构建留待依赖变更时执行并记录） | 本轮 release 报告（见 §8 产物） |
| 出厂模型被未知进程改名 `.corrupt`（2026-11-02 两次；内容未损坏，已按锁哈希核对后恢复） | 依赖静默损坏会传染到所有下游测试与安装包 | 无法定位行为进程（两次均发生在多进程验证窗口内；仓库内所有 rename 源码路径均只针对 userDir/model.userlm 与 custom-words 路径）。处置：`chflags uchg` 对出厂 `sc.dict`／`zh_CN.lm` 加文件系统不可变保护（重新生成依赖前需 `nouchg`，已写进 prepare-dependencies 注释）；`verify.py resources` 检查会在再次发生时立即记 blocked，不再静默传染 | 恢复后 shasum 与锁哈希一致；275 项核心断言全过 |

**后续改进**（不阻塞）：全新 GOGAKU_DEPS 缓存的冷构建演练；`swift build` 产物模块目录路径的版本 pin 说明；继续追查 `.corrupt` 改名来源（若复现，用 `chflags` 触发显式失败定位）。

## 3. 测试与证据

**检查**：核心 ctest（ABI／事件轨迹 265 断言／质量 13 项／fuzz 冒烟）、Swift 49 项 XCTest＋swift-testing、渲染 51 项、数据可靠性 40 轮、ASan/UBSan 插桩（十万个序列为门槛）、包检查（签名／闭包／包内冒烟）、真实宿主与性能驱动（`probes/`）。

**本轮整改**：

| 项 | 影响 | 处置 | 验证 |
| --- | --- | --- | --- |
| 文档构建命令漂移：Release 交付配 Debug 测试命令 | 用 Debug 测试冒充 Release 证据 | `docs/native-development.md`、验收记录统一为 `swift test -c release` | 已改；`verify.py swift-tests` 显式 `-c release` 且 0 测试时记 blocked |
| 数据缺失时测试 SKIP 但命令退出 0 | 覆盖被误读为完整 | `verify.py` 把输出中的 `SKIP:` 记为 blocked；0 tests 记 blocked；必需项只有 passed 过门槛 | fast 档实测（quality 在缺数据环境会输出 SKIP 的路径由检查识别） |
| 无统一入口，验证靠手工拼接 | 步骤可漏、证据无身份绑定 | `scripts/verify.py` 三档位；报告绑定提交／dirty／版本，旧报告不继承 | 本轮三档报告（fast 已过；release／host 见 §8） |

## 4. 数据可靠性

**检查**：核心三个用户数据写路径（`model.userlm`／`learned.txt`／`custom-words.tsv`）已用「临时文件＋fsync＋rename＋父目录 fsync」，fsync 失败按整体失败处理、调用方保留 dirty 下次重写（复查 C1/C2 已修）；40 轮强杀／损坏备份重建／删词不复活回归通过（`probes/validate-data-reliability.py`）。设置页保存失败显示具体错误（「设置未保存，请检查磁盘和目录权限」）。

**发现与处置**：

| 项 | 级别 | 处置 |
| --- | --- | --- |
| `Settings.save()` 用 `.atomic`（临时＋rename）但无 fsync；`InputController.persistPreference` 用 `try?` 静默吞错（按应用偏好） | 后续改进 | 最坏结果是偏好回退为默认值，不产生半截文件，不涉学习数据；列后续改进（加 fsync＋失败提示），不在本轮扩 |
| 学习记录 SQLite 写路径 | 不适用 | 学习模式保持关闭，真实记录链路未启用；启用前须按产品规格验收（队列≤256、失败不拖慢输入） |

**故障注入覆盖**：40 轮 SIGKILL＋损坏注入＋删除复活（本轮 release 档重跑）；核心单测新增 `write_failure` 反例组（2026-11-02）：只读目录下 flush 保留 dirty、会话仍可用，快速添加明确报「自定义词语保存失败」＋beep（不显示成功），权限恢复后同会话重试 flush 补上持久化（事件轨迹共 275 项断言全过）；「提交已发生但持久化失败不回退正文」由调频 flush 的 dirty 语义保证（提交上屏不依赖 flush 成功）。

## 5. 安装与恢复

**检查**：`manage-install.py` 只覆盖 bundle ID 核对过的 Gogaku 应用；要求用户先切离 Gogaku 输入源；不自动启用／设默认。旧备份包曾被 LaunchServices 索引导致随机启动旧二进制（76 个，2026-11-01 清理）。

**本轮整改**：

| 项 | 影响 | 处置 | 验证 |
| --- | --- | --- | --- |
| 备份以 `.app` 形式存于 Application Support，可被系统索引误启动 | 验收运行旧二进制、结论失真 | 备份改名 `*.app.disabled`（LaunchServices 不识别为应用）；只保留最近 3 份；历史 `.app` 备份在下次安装时自动改名 | `verify.py release` 的 `install-preflight` 检查备份目录无 `.app` 暴露 |
| 安装后不核对实际文件 | 旧包残留／拷贝损坏不可见 | `install` 后逐文件核对与 `dist/bundle-manifest.json` 哈希，缺失／不一致／多余文件均报错终止 | 逻辑就位；真实安装在下一次发布安装时执行（本轮不自动接管已装环境） |
| 更新失败一致性、旧包注册问题 | — | 沿用既有顺序（backup→copy→lsregister -f→TIS 注册）；恢复路径 `recover`／`diagnose` 保留 | 已有；真实更新矩阵（升级／失败恢复／卸载保留数据）仍属 §8 待执行验收 |

## 6. 隐私与依赖许可

**检查**：正式包不含验收 socket／诊断进程（`-DGOGAKU_VALIDATION` 显式开关，默认关）；包检查扫描产物禁含按键日志标记（`/tmp/gogaku-`、`gogaku-keys.log`、`gogaku-debug-enabled`）；核心与平台层无输入文本日志。数据许可：gloss（CC BY-SA 4.0，署名义务随包）、英文词表（SCOWL／wordfreq，随包署名）、依赖许可按实际打包库选择（`licenses()`）。

**本轮整改**：释义数据生成规则收紧后重新生成来源清单与哈希（[审阅记录](gloss-simplification-review.md)）；`third-party.md` 的哈希入口指向自动更新的 `gloss-sources.json`，保持有效。

**后续改进**（不阻塞 0.1.0 本机开发版）：CC BY-SA 4.0 的 ShareAlike 边界说明已在 `third-party.md`，公开分发前复核。

## 7. 汇总：发布阻塞 vs 后续改进

**0.1.0 前必须解决（发布阻塞，承验收记录）**：IMK 主线程性能（p95 10.35ms > 5ms；必要同步宿主写入超预算，方案取舍未定）、最终宿主连续两轮矩阵、十万序列 ASan/UBSan 完成、两小时稳定性／内存／冷启动、旧开发版升级／更新失败恢复矩阵、用户试用确认。以上属验收门槛，工程侧已把每项落为 `verify.py` 检查或 host 档计划。

**本轮已修（工程阻塞清零）**：版本可追溯（§2）、干净构建（§2）、测试证据绑定（§3）、备份暴露（§5）、`/tmp` 隐式依赖（§2）、释义数据规则与署名（§6）。

**后续改进（不阻塞）**：核心 dylib RTTI 符号收敛（Windows 前置）、ABI 层线程所有者断言、Settings 写 fsync、全新依赖缓存冷构建演练。

## 8. 本轮验证产物

- fast 档：`verify/report-fast-*.json`（version／resources／core-tests／swift-tests 全 passed）。
- release 档（完整跑，2026-11-02）：`verify/report-release-20261102-091139.json` —— 11 项中 10 项 passed，asan-ubsan 一项因检查脚本自身只读 stdout 而误判 failed（fuzz 实际输出为 PASS，证据见同目录 `asan-ubsan.log`）；判定修复后重跑该单项：`verify/report-release-20261102-111248.json` passed（100000 序列 / 1250029 事件，失败 0）。合并后全部 11 项均有 passed 证据。
- host 档：`verify/report-host-*.json`（默认 blocked＋计划，含 Orca Shift 专项；`--yes` 后执行真实矩阵，需用户空闲时段）。
- 释义审阅：[gloss-simplification-review.md](gloss-simplification-review.md)。
