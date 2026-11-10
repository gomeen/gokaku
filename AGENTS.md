# Gogaku 协作说明

开始工作前完整阅读 [README.md](README.md) 和 [产品方向](docs/product.md)。产品需求与方案状态以 `docs/product.md` 为准。

- 当前已进入原生工程实施，阶段状态和证据见 [原生开发验收](docs/validation/native-development.md)。核心测试、可构建程序、系统输入源真实宿主验收分别记载。`prototypes/` 仍是可丢弃的预设样例演示，不代表模型或 macOS 宿主已验证。区分已确认需求、待验证方案和已实现能力。
- 实现用户可感知的行为后，同步更新对应文档；只有经过实际验证的能力才能标为已实现。
- 契约逻辑只有一份实现（见 [双端实施计划](docs/implementation-plan.md)「共享实现规则」）：解析、规范化、迁移、签名、校验、内置数据表这类与 UI 和系统 API 无关的逻辑住在共享核心，平台侧只做按键／文本／路径／应用身份的转换。确实需要第二份实现时，必须入库两端共跑的同一组输入与期望结论；跨端一致不允许靠注释对照或「照某文件写」维持。
- 版本与构建：仓库根 `version.json` 是唯一版本来源（见 [docs/versioning.md](docs/versioning.md)）；对外提供安装包前递增构建号，定版构建要求工作区干净；不再使用 rc，定版号决定后固定，验证失败的修复只递增构建号。
- 验证节奏（详见 [docs/native-development.md](docs/native-development.md)「验证节奏」）：**平时开发只跑关键测试** `python3 scripts/verify.py --profile fast`（约 2 分钟），改动涉及共享核心／内存敏感路径时加 ASan 冒烟 `--profile release --only asan-ubsan --quick`（约 4 分钟）；**全量测试 `--profile release`（含十万序列插桩，分片并行后预计约 15 分钟）只在定版或排查疑难问题时后台运行**，不阻塞日常迭代；真实宿主用 `--profile host --yes`（每次定版的短档），核心／IMK 改动或里程碑用 `--profile host-full --yes`（会注入真实按键），仅在用户空闲时段执行。不要为等待长验证在会话里轮询空等。
- 引入青简源码、数据或模型前，核对具体文件及组件的许可证；Gogaku 自身代码以 MIT 许可发布（根目录 LICENSE），第三方组件与随包数据保留各自原许可。
- 交流和文档使用中文，代码标识符使用英文。
