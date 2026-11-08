# 当前测试与诊断工具

这里保留**现行输入法**的测试装置和诊断工具，不再存放多引擎／本地翻译模型选型程序。旧比较工具、排名、下载转换依赖、长篇实验结果及翻译对照网页已删除，可从 Git 历史追溯；简短路线说明见 [采用理由](../docs/input-selection-decision.md)。

不是每个工具都在每次发布时自动执行。统一入口与当前策略是 `scripts/verify.py`、`scripts/_gogaku_verification.py`；[发布说明](../docs/release.md) 和 [测试审查](../docs/validation/testing-cleanup-audit.md) 区分自动检查、授权操作与未覆盖项。

## 日常／发布检查

| 工具 | 用途 | 统一入口 |
| --- | --- | --- |
| `render-candidate-panel.swift` | 实际候选窗离屏位图与几何检查 | release 的 render；不等于真实宿主验收 |
| `validate-data-reliability.py` | 40 轮强杀、损坏恢复、删除不复活 | release 的 data-reliability |
| `validate-engine-data.py` | 工厂数据故障诊断 | 手动诊断 |
| `validate-eager-annotation.py` | 候选释义／异步显示回归 | 手动诊断 |
| `latency-matrix.swift` | 受控 AppKit 逐键、布局及提交成本 | 手动诊断，不能替代真实 IMK 性能 |
| `macos-text-check.swift` | 系统拼写／语法 API 合成样例 | 手动诊断，不代替输入源行为验收 |

共享核心测试在 `shared/GogakuCore/tests/`，Mac 单测在 `macos/Tests/`；fast 会跑它们，不需要靠旧模型工具维持覆盖。

## 需要空闲桌面和明确授权

以下工具可能切换输入源、创建测试窗口、发送真实按键或占用桌面，**不能因位于 probes 就默认安全运行**：

- `validate-real-hosts.py`：TextEdit、Chrome、Safari、Terminal、Orca PTY 两轮严格宿主检查。
- `first_key_regression.py`：首键、Shift、组合和逐事件证据；也提供宿主工具共享层。
- `measure-imk-latency.py`、`attribute-imk-latency.py`：真实逐键性能与归因。
- `stability-soak.py`：两小时稳定性与内存趋势。
- `validate-imk-host.py`、`imk-regression-host.swift`、`ax-reader.swift`、`imk-terminal-receiver.py`、`real-host-test-page.html`：受控宿主及读取工具。
- `settings-gui-capture.py`、HUD／toast／OCR／窗口诊断工具：按各自说明操作真实桌面。截图存在不等于交互已通过。

```sh
# 仅用户空闲并授权后运行；目前统一宿主探针只支持 stable。
python3 scripts/verify.py --profile host --channel stable --yes
```

`--channel dev` 的 host 档明确 blocked，**不会用 stable 安装件冒充 dev 验收**。旧宿主结果不能自动代表当前源码通过。

## Windows 原生回归（授权的 Windows 会话）

- `windows-field-safety.cpp`：调用生产 `nativeEditFallbackSafe`，合成控件检查 Edit／RichEdit、文档归属、密码／只读／禁用等。分别编译运行 x64／x86，每架构 13 项；不是完整 TSF 密码字段验收。
- `windows-session-focus.cpp`：同用户／会话／通道代理的两个连接，验证旧连接迟到失焦不清空活动组合；会切焦点、改变组合，不能与日常输入并行。
- `windows-rpc-startup.cpp`：生产 `RpcClient` 对独立延迟假代理的双架构回归，检查激活等待、逐键连接不等待词库启动、超时后可重连；不发送按键、不访问产品数据。`python3 probes/build-windows-rpc-startup.py` 只编译，复制输出目录到 Windows 后依次运行 `fixture/bin/x64/RpcStartupTest.exe` 与 `fixture/bin/x86/RpcStartupTest.exe`，每次保存输出目录的 `result.json`。它验证连接机制，真实 TSF 冷启动仍须另测。

历史限定运行及冷启动已知失败见 [Windows 构建 91](../docs/validation/windows-desktop-b91.json)。当前完整 Windows 宿主／安装升级／卸载仍未形成自动发布闭环。

## 翻译：考题保留，旧模型工具退役

- `translation-cases.json`：32 条固定风险输入。
- `translation-comparison-cases.json`：中英各 10 条；当前火山探针仍使用，名称中的 comparison 不代表保留旧模型排名。
- `translation-risk-checks.json`：风险审阅辅助索引，不代替人工语义判读。
- `translation-language-probes.json`：24 条其他语言的合成输入，留作未来扩展，不表示已支持这些语言。
- 另有 `validation/` 的留存、短表达、确认与最终集。固定输入／参考的身份由 `validation/manifest.json` 记录。

```sh
# 离线数据完整性及正负例自测，不调用任何翻译服务：
python3 scripts/validate-translation-data.py
# 只有明确授权、准备测试凭据后才运行真实火山探针：
VOLC_ACCESS_KEY=... VOLC_SECRET_KEY=... python3 probes/volcengine-translate-probe.py
```

火山探针结果写入 `results/volcengine/`，保留的旧 20 句快照也归位到此；它不是当前版本生产 helper、TLS、计量或真实宿主已验收的证据。

## 名字像选型但仍有消费者的构建材料

`prepare-libime-input.py`、`libime-input-worker.cpp`、`prepare-input-engine-cases.py`、`input-engine-cases.json`、`input-engine-holdout.json` 仍被固定依赖准备、中文质量样例生成和核心回归消费，继续保留。不再准备青简／Rime 对照。

`results/icon-compare/`、`tis-icon-probe.swift`、`render-hud-paths.swift` 保留为当前菜单／HUD 图标诊断；其他当前产品证据按实际引用保留，不把整个 results 目录当成可删除缓存。
