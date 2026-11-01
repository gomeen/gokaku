# Qingjian Q0 worker

自编 JSONL 适配器，使用固定 `379139671d191a5c9dc21972a54e15bc1edd9e17` 的真实 `qingjian-core`。仅隔离核心，不安装输入法、不连接宿主、不访问已安装青简的任何配置、词库或历史。

```sh
python3 probes/prepare-qingjian-input.py
/tmp/gogaku-ime-benchmark/qingjian/build/release/gogaku-qingjian-worker /tmp/gogaku-ime-benchmark/qingjian
```

准备器先读取固定版本许可和锁文件，校验源码压缩包与正式 `data-v8` 产品包 SHA-256，再生成临时 Cargo 项目、Release 构建并跑正确性冒烟。此处 `Cargo.toml` 是模板，`@SOURCE@` 由准备器替换；不在仓库内直接 cargo build。Cargo cache、lock、源码、数据、构建产物和证据均放 `/tmp/gogaku-ime-benchmark/qingjian/`。重新构建命令、环境、依赖许可、包与逐文件哈希见该目录 `manifest.json`。源码压缩包哈希为首次从固定 GitHub 提交下载后固定；产品包哈希由该提交的 `tools/release/data.lock` 提供。

使用随包 `dict.qj`、`lm.qj`、缺省启用的 `dicts/general.qj`（secondary）和 `dicts/idioms.qj`；保留随包英文候选和中英 emoji、内置颜文字/符号及默认排序。领域词库按生产默认启用，未全开来提高命中率。翻译表、云、神经模型不装配，`Engine::set_learning(false)` 加默认 `NoLearner` 阻止所有个人学习。包内虽有含章神经模型，worker 不加载。具体许可按组件记录；上游规范字/常用词表转录来源未附许可证、general 语料来源描述不足，不能据此宣称数据可再分发。

stdin 请求 `reset/key/select/peek/quit`，stdout 首行 ready，后续一请求一 JSON。日志仅 stderr。key 接收小写 ASCII、单引号、8/27/32，额外支持 13（回车原文上屏）。不支持的键与非法索引返回 `ok=false`，字段完整。`select.index` 为本次实际枚举候选中 0 起索引。最多十项，顺序等于生产调用的 `Engine::query().candidates.items`；不按目标或前缀长度重排，不模拟翻页或候选高亮移动。

核心自身维护缓冲：适配器只分派 `push/backspace/clear/commit/take_raw`，缓存当前可见候选对象供下次选择。Space 选择首项，无候选但仍组句时原文上屏，空态不处理；Backspace 优先撤销 held，Escape 丢弃编码与 held。部分选择可能 `commit=""`、`raw_input` 尚有编码、`composing=true`；额外 `held` 字段供审计。预编辑由核心 `marked_text` 产生，解析失败时显示 held 与真实原编码。reset 调用 clear、break_chain、enter_input_box，丢弃本次状态与输入框历史，不重新加载静态数据。

`process_ns` 包含状态操作、query 及排序；`collect_ns` 包含前十枚举、候选文本复制、预编辑和状态提取。`total_ns` 在生成响应 JSON 前结束，包含两阶段；无惰性候选工作漏到计时之外。load_ms 从打开/校验/mmap 数据、解析英文及 emoji 到引擎装配和设置结束，父进程另量启动到 ready。现有 `smoke.json` 的数值仅协议与非负验证，不是正式性能结果。

```sh
/tmp/gogaku-ime-benchmark/qingjian/build/release/gogaku-qingjian-worker --check-layout probes/input-engine-cases.json
```

此命令用上游 `Scheme::Xiaohe.encode` 逐音节检查冻结集，单独输出校验 JSON。准备器记录冻结集与生成器哈希，不修改目标。主实验仍应按方案用独立质量与性能进程，正式性能的 33 轮由共同主进程交错执行。
