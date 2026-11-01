# 变更记录

人类可读的版本变更说明。版本规则见 [docs/versioning.md](docs/versioning.md)；验收状态以 [docs/validation/native-development.md](docs/validation/native-development.md) 为准，本文不重复验收结论。

## 0.1.0-dev.1（构建 2）— 2026-11-02

工程化与普通输入收尾（未定版；0.1.0 需验收通过＋用户试用确认）。

### 新增

- `version.json` 单一版本来源；构建读取并生成包内／外部两层构建身份（完整版本、构建号、提交、dirty、架构、工具链、依赖与数据哈希、产物哈希）。`CFBundleVersion` 改为真实构建号，不再恒为 1。
- `scripts/verify.py` 统一验证入口：`--profile fast`（日常提交）、`release`（交付门槛，不接管桌面）、`host`（真实宿主／性能／稳定性，需 `--yes` 显式确认）。机器可读报告＋摘要，必需项全过才算门槛通过。
- `CHANGELOG.md` 与版本管理说明。
- 设置应用侧栏显示完整预发布版本与构建号（读包内 build-identity.json）。

### 修复

- **Shift 提交不更新最近上屏字符**（核心缺陷）：组合中 Shift 上屏后，下一标点错误沿用数字后半角例外（Terminal 实测「Shift 确认＋句号」得半角 `.`）。修复后与 Enter／空格／选词提交同规则；补「数字 → 字母组合 → Shift → 句号／冒号」核心反例回归（事件轨迹 257 → 265 项断言）。
- **安装备份以旧 `.app` 形式暴露**：备份改为 `*.app.disabled` 并只保留最近 3 份，历史 `.app` 备份自动改名；消除 LaunchServices 索引旧备份导致输入法随机启动旧二进制的隐患（此前曾发生 76 个旧备份包）。安装后自动核对实际安装路径全部文件与 dist 清单哈希。
- 依赖准备移除对 `/tmp` 旧探针缓存的隐式迁移；本机工具（git／cmake／ninja／clang）缺失时明确报错。
- 文档错误更正：收尾复测「5.55ms 低于 5ms」表述（5.55ms 高于 5ms 门槛）；开发说明中的 Debug 测试命令统一为 Release 配置；过时的 Apple Translation 使用说明改为历史证据定位。

### 变更

- **释义精简**（离线生成规则收紧，消费接口不变）：`character` 类别不再显示为 `char.` 词性；结构化词典标签（`(hakka)` 等）不再透传；`(Classifier: …)` 量词搭配表剥离；俚语／粗俗等强语域义项整条剔除（不再降级透传）；单条义项 ≤64 字符（超长整条剔除，不截断）；键必须为纯 CJK 表意字符。词条 161,839 → 143,777。来源清单、哈希与署名同步更新；固定种子 50 条抽样审阅见 `docs/validation/gloss-simplification-review.md`。
- Hyper（fn）修饰不再触发 Shift 单击判定。

### 已知阻塞（不计入本轮完成）

- IMK 主线程性能未达标（10,035 事件 p95 10.35ms／p99 15.38ms，门槛 5ms／10ms；归因：长单行文档的必要同步宿主写入本身超预算）。
- 最终宿主连续两轮矩阵、十万序列插桩、两小时稳定性／内存／冷启动未完成；Spotlight／Raycast 未验收。
- 学习模式保持关闭（模型质量门槛未通过）；Windows 未开始。
