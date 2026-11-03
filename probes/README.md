# 隔离可行性探针

这些文件用于复查[可行性报告](../docs/feasibility.md)，不是 Gogaku 输入法实现。不安装、注册或切换输入源，不连接真实聊天输入，不读取个人输入记录。

本次外部源码和编译产物放在 `/tmp/gogaku-validation/`。源码版本见 [environment.json](results/environment.json)。Gogaku 内只保存自行编写的探针、运行结果和测试日志，不包含上游源码、schema 或模型权重。

## GGUF 新模型资源预研与 20 句实测

截图候选与 Index-Translate 的资料复核见 [候选复核](../docs/research-translation-screenshot-candidates.md)；运行内存与协议预研见 [资源预研](../docs/research-translation-resource-prescreen.md)。

```sh
python3 scripts/prepare-gguf-translation.py   # 固定 revision 下载官方权重与 llama.cpp b12064 x64，LFS SHA256 校验
python3 probes/benchmark-gguf-translation.py  # 串行启动/停止 llama-server，每模型跑同 20 句
python3 probes/benchmark-gguf-translation.py --models qwen3-06b --threads 4 --tag t4  # 变体：结果键追加 -t4，不覆盖原运行
python3 scripts/build-translation-comparison.py --render-only  # 全部完成的结果并入对照页
```

产物在 [results/gguf-translation/](results/gguf-translation/)：`artifacts.json`（revision、字节数、SHA256）、逐模型 `run.json`／`<model>.json`（原始响应、每句完整请求耗时、CPU、RSS／物理占用采样）与 server 日志。权重缓存在 `~/Library/Caches/Gogaku/models/gguf-translation/`，约 2.94GB，不进仓库。

固定协议：CPU-only（`-ngl 0`）、默认 2 线程（`--threads` 可变，带 `--tag` 的变体如 `-t4` 单独存档）、上下文 1024、batch 128、`--cache-ram 0 --ctx-checkpoints 0`、Index 走 `enable_thinking=false` 官方翻译 prompt，HY 用官方 ZH↔XX 指令句式，greedy 均为实验变体；每模型先预热两条再正式测。耗时是完整本机 HTTP 请求（含分词／prefill／全解码／解析），与 CT2 列口径不同，不能直接互比；内存为每 50ms 采样的 RSS／物理占用峰值，非精确峰值；单模型超过 6GiB 即终止该模型。2026-11-03 首轮实测与线程变体汇总见 [summary.md](results/gguf-translation/summary.md)；词／短语级质量与固定风险集均未覆盖。

## 20 句翻译网页对照

[translation-comparison-cases.json](translation-comparison-cases.json) 在本次推理前固定中→英、英→中各 10 句，覆盖日常、习惯表达、品牌、时间、数量、否定和信息完整性。参考译法由人工编写，仅帮助理解原意，不作唯一答案。

```sh
python3 scripts/build-translation-comparison.py
# 只改页面样式时复用已有真实输出，不重新测模型：
python3 scripts/build-translation-comparison.py --render-only
# 可直接打开 HTML；浏览器工具不允许 file URL 时只绑定本机服务：
python3 -m http.server 8767 --bind 127.0.0.1 --directory prototypes
```

打开 `http://127.0.0.1:8767/translation-comparison.html` 或 [单文件页面](../prototypes/translation-comparison.html)。输出保存在 [comparison.json](results/translation-comparison/comparison.json)，同目录保留各隔离进程 JSONL 与 stderr。默认模型路径沿用 `~/Library/Caches/Gogaku/models/{small100-gate,quickmt-speed}`，可通过参数覆盖；脚本不下载模型。模板为 `prototypes/translation-comparison.template.html`，生成页内嵌数据，无外部依赖；评价仅存当前浏览器本地，可导出 JSON。重新推理后生成时间变化，评价与旧运行隔离。

统一配置为 CPU CT2 INT8、2 线程、每条生成、最大输出 256 tokens，每方向预热一次。quickmt beam 曲线（2026-11-03 同 20 句实测，`ct2-variants.json` 存全部变体，页面对应列）：可选任意正整数（1=贪心，无上限）；本组实测 1→2 大量改写（14/20 相同），重复与 sunscreen 修复出现在 beam≥4，beam5≈6 完全一致，beam10 仅把「报销」修复为 `Can I be reimbursed`；中位耗时 88/117/129/140/142/175ms（beam 1/2/4/5/6/10），均远低于预算。quickmt 为编码器-解码器 NMT，官方 README 无 prompt/formality 接口，beam 与前置资源层是仅有的质量旋钮。两模型分别生成，未经词典、反向评分、繁简转换或人工修正；网页显示的单次耗时包含分词／推理／解码，不包含模型加载或 IPC。此次 40 条输出均非空且未截断，但不等于语义合格；不能用这组有意覆盖风险的 20 句推断总体合格率或正式 p95。截图补充的 OPUS-MT、NLLB、HY-MT1.5、Qwen2.5、Llama 3.2 与 Index-Translate 在本页仅列候选，没有虚构译文。

浏览器检查覆盖 20 卡片、方向筛选到 10 条、参考译法展开、评价计数与撤销；导出的 JSON 已读回核对 20 条记录及对应运行身份，测试评价已清除。页面内嵌的 40 条结果与原始 JSON 一致。这属于独立展示验证，不运行原生输入源验收，也不改变生产学习门禁。

## 收敛选型测试

结论见[技术选择](../docs/input-selection-decision.md)，范围先冻结于[收敛方案](../docs/input-selection-decision-plan.md)。`input-engine-holdout.json`为看输出前冻结的80条独立样例；其目标命中不等于全部合法中文判断。

沿用已装配的三个manifest，仅运行新集质量，不重复大基准：

```sh
python3 probes/benchmark-input-engines.py \
  --manifest /tmp/gogaku-ime-benchmark/qingjian/manifest.json \
  --manifest /tmp/gogaku-ime-benchmark/rime/manifest.json \
  --manifest /tmp/gogaku-ime-benchmark/libime/manifest.json \
  --cases probes/input-engine-holdout.json --phases quality \
  --output-dir /tmp/gogaku-holdout-rerun
mkdir -p /tmp/gogaku-decision
swiftc -O probes/native-text-client.swift -o /tmp/gogaku-decision/native-text-client
python3 probes/benchmark-input-decision.py \
  --native /tmp/gogaku-decision/native-text-client --rounds 3 --interval-ms 100 \
  --output /tmp/gogaku-layout-rerun
```

正式计时前等待所有构建结束。当前脚本固定本机临时manifest路径与Q0/R1/I0，不安装输入源。受控原生客户端实际验证NSTextView中的预编辑和提交，并测候选布局准备；不含IMK激活、屏幕可见时间和外部应用宿主。

默认不逐键离屏截图；`--rasterize`仅作同步位图诊断，其排队时间不能代表正常产品UI。`--translation-python /tmp/gogaku-benchmark/venv-ct2/bin/python --model-root /tmp/gogaku-benchmark/models`可显式启用原OPUS真实负载，但必须先检查固定模型仍在。本轮权重缺失，正式结果标记`no_translation_materials`且翻译请求数为0，不能声称真实翻译并发已测。不要为已被质量否决的模型无边界重建环境。

## macOS 拼写与语法接口

本次使用 macOS 26.7.2、Swift 6.3.3 和系统 AppKit，运行合成英文样例。

```sh
mkdir -p /tmp/gogaku-validation/bin
swiftc probes/macos-text-check.swift -o /tmp/gogaku-validation/bin/macos-text-check
/tmp/gogaku-validation/bin/macos-text-check
```

可用进程沙箱再运行一次：

```sh
sandbox-exec -p '(version 1)(allow default)(deny network*)' /tmp/gogaku-validation/bin/macos-text-check
```

脚本指定 `en_US`，不学习单词、不修改用户词典。结果同时包括拼写标记、语法问题及原生文本视图的拼写属性读回情况，不测试实际绘制和鼠标点击。沙箱只限制探针进程，不等于全机或进程外系统服务已经断网。

## Apple Translation 语言状态

此探针使用 macOS 26.4 起的 lowLatency API，需要相应系统、SDK 与 Swift 编译器。本次仅查询语言对可用性，只有状态为 installed 才调用翻译；不请求下载模型。

```sh
swiftc -parse-as-library -target x86_64-apple-macos26.4 probes/apple-translation.swift -o /tmp/gogaku-validation/bin/apple-translation
/tmp/gogaku-validation/bin/apple-translation
```

本次两方向均为 supported，cases 为空，不能把状态查询称为翻译成功，也不能将其推断为 Intel 完全不支持。

## Rime 小鹤引擎

需要鼠须管公共资源、其实际 librime 动态库、匹配版本的 `rime_api.h`，以及官方小鹤 schema。本次动态库版本为 1.16.0，schema 固定版本及数据许可见 [Rime 研究](../docs/research-rime.md)。

本次准备路径如下，复跑前先确认外部源码目录和 tag 仍存在。头文件取自 librime 的 `1.16.0` tag，而不是将最新 HEAD 当作安装版本。

```sh
REFS=/tmp/gogaku-validation
mkdir -p "$REFS/rime-headers-1.16.0" "$REFS/rime-probe-user/build"
git -C "$REFS/librime" show 1.16.0:src/rime_api.h > "$REFS/rime-headers-1.16.0/rime_api.h"
cp "$REFS/rime-double-pinyin/double_pinyin_flypy.schema.yaml" "$REFS/rime-probe-user/double_pinyin_flypy.schema.yaml"
clang -Wall -Wextra -I "$REFS/rime-headers-1.16.0" probes/rime-flypy.c -o "$REFS/bin/rime-flypy"
"$REFS/bin/rime-flypy" "/Library/Input Methods/Squirrel.app/Contents/Frameworks/librime.1.dylib" "/Library/Input Methods/Squirrel.app/Contents/SharedSupport" "$REFS/rime-probe-user" "$REFS/rime-probe-user/double_pinyin_flypy.schema.yaml"
```

如果临时源码已清理，可以从报告中的官方仓库重新取得对应提交；librime 的 `1.16.0` tag 是 `056793757e91510f9d4e8c88f93272f5d7309782`。重新取得外部材料不代表允许将其按 Gogaku 自有许可分发。

第三个参数必须是专门的临时用户目录，不要传入真实 Rime 用户目录。探针会在该目录部署 schema、建立测试用户数据，但只读取鼠须管公共资源。输出包括候选、选择前提交、明确选择第二候选的提交以及空格提交，不经过系统输入法 UI。

本次固定按键包括 `nihc`、`kdhv`、`hvyi`、`woxlxtykyu`、`wxqcf` 和 `meeting`。它们用于观察实际行为，不保证任意词典、社区方案或用户历史都有相同排序。

## 青简选定核心测试

本次外部源码固定为 `379139671d191a5c9dc21972a54e15bc1edd9e17`，使用独立编译目录。

```sh
CARGO_TARGET_DIR=/tmp/gogaku-validation/qingjian-target cargo test --locked --manifest-path /tmp/gogaku-validation/qingjian/Cargo.toml -p qingjian-core shuangpin --lib
CARGO_TARGET_DIR=/tmp/gogaku-validation/qingjian-target cargo test --locked --manifest-path /tmp/gogaku-validation/qingjian/Cargo.toml -p qingjian-core translation --lib
```

本次分别通过 38 项与 21 项。这是名称筛选后的核心测试，使用测试夹具和模拟接口，不是全项目测试、安装版青简测试或真实翻译模型评测。已有日志保存在 `results/`，不以测试执行耗时代替输入延迟。

## 真实离线翻译实验

本轮使用两份 OPUS-MT 单向模型与 M2M100 418M，独立于输入法引擎。模型来源、许可、固定 revision、文件大小及哈希在 [model-manifests.json](results/translation-benchmark/model-manifests.json)。权重与转换产物保存在 `/tmp/gogaku-benchmark/models/`，不进入产品仓库。再次分发前仍需按方向保留适用许可证、署名与转换说明。

测量的输入、计时边界和判断规则见[实验方案](../docs/translation-benchmark-plan.md)。`translation-cases.json` 是 32 条自行编写的合成输入，实际生成结果与质量是两回事。`generated=true` 仅表示非空且未达输出上限，不能当作翻译质量通过率。

以下命令需要兼容的 x86_64 Python。本次使用 `/usr/bin/python3` 3.9.6，两份 requirements 记录完整版本。CTranslate2 推理环境不安装 Torch，因为包初始化可能间接导入 Torch 并加载第二份 OpenMP runtime；本轮原始冲突和 MPS 缺算子记录保留在 `smoke.json` 及 stderr 日志。

```sh
BENCH_ROOT=/tmp/gogaku-benchmark
/usr/bin/python3 -m venv "$BENCH_ROOT/venv"
/usr/bin/python3 -m venv "$BENCH_ROOT/venv-ct2"
"$BENCH_ROOT/venv/bin/python" -m pip install -r probes/results/translation-benchmark/venv-requirements.txt
"$BENCH_ROOT/venv-ct2/bin/python" -m pip install -r probes/results/translation-benchmark/venv-ct2-requirements.txt
"$BENCH_ROOT/venv/bin/python" probes/prepare-translation-models.py --phase download
"$BENCH_ROOT/venv/bin/python" probes/prepare-translation-models.py --phase convert
```

下载阶段检查模型卡许可并固定 revision，核对 LFS SHA256，保留卡片与文件清单。现有 manifest 存在时沿用该 revision；全新目录首次准备会解析当时 main，若需重现本轮应先复制本轮对应 manifest 到各模型目录。转换阶段仅用本地文件，以单线程规避本机 wheel 运行库冲突；已生成且哈希一致的转换会复用，不覆盖不完整或不一致的目录。

```sh
"$BENCH_ROOT/venv/bin/python" probes/benchmark-translations.py --phase quality --configs opus-ct2-int8-t2 m2m100-ct2-int8-t4 --output /tmp/gogaku-quality-recheck.json
"$BENCH_ROOT/venv/bin/python" probes/benchmark-translations.py --phase measure --configs opus-ct2-float32-t4 opus-ct2-int8-t2 opus-torch-cpu-t4 --rounds 5 --keep-workers --output /tmp/gogaku-measure-recheck.json
"$BENCH_ROOT/venv/bin/python" probes/validate-translation-runtime.py --output /tmp/gogaku-offline-recheck.json
```

`--phase tune` 在四条合成输入上筛查配置；原实验穷举了 CT2 两模型的 FP32/INT8、1/2/4/8 线程，Torch OPUS CPU 的 1/2/4/8 线程，以及 MPS FP32/FP16 加显式 CPU 回退，共 22 个配置。它是探索性调参，不证明选中线程在所有输入或负载下最优。纯 MPS 不回退的失败另存于 smoke。

`--phase measure` 要求至少五轮，使用 batch=1；`--keep-workers` 让每个配置独立进程驻留，再交错轮次请求。脚本写每条输入、完整译文、token 数、各阶段耗时、峰值进程 RSS、失败和系统负载。`ready_reused` 标明重复使用模型，不能重复统计为多次冷启动。正式性能计时子集是每方向五条，共十条，不包含全部质量风险样例。

`--phase profile` 另跑采样，不纳入延迟成绩。`validate-translation-runtime.py` 用禁止网络的进程沙箱验证实际加载与双向推理，并测试缺少方向、损坏权重、输入超限、空输入、错误之后仍能继续推理。网络连接失败有独立对照；该验证覆盖本地模型进程，不代表全机物理断网或未来输入法的焦点安全。

汇总完整原始实验时运行：

```sh
"$BENCH_ROOT/venv/bin/python" probes/summarize-translation-benchmark.py probes/results/translation-benchmark
```

汇总脚本要求所有正式轮次齐全，生成请求级统计、逐条译文对照与产物哈希。它不自动给翻译打分。`parent_ready_ms` 包含解释器导入，`model_load_ms` 是已导入环境下的模型及分词器加载，`peak_rss_bytes` 是 Python 推理进程峰值；MPS 的该值不包含全部独立显存，不能直接与 CPU RSS 比较为模型总内存。

## 输入源切换 HUD 图标取图证据（2026-11）

只读调查探针，配合 scripts/manage-install.py 的 HUD 重启步骤。结论与证据见 [results/icon-compare/SUMMARY.md](results/icon-compare/SUMMARY.md)；背景：切换浮层曾显示旧包"裸笔画"图标，根因是 TextInputSwitcher 进程内 NSImage 缓存跨安装不失效。

```sh
# TIS 图标属性枚举（只读；输出 JSON 到 stdout，存档副本 results/icon-compare/）
swift probes/tis-icon-probe.swift
# 四种候选渲染路径对比（NSImage／alpha 蒙版／反相蒙版／PDFKit／CGPDFPage），
# 产出 opaque・black・transparent 占比与对比 PNG，验证当前键帽 PDF 在合理路径下形态正确
swift probes/render-hud-paths.swift --output probes/results/icon-compare
```

两个探针都不注册、不启用、不切换输入源、不写系统目录。`render-hud-paths` 的 C 路径（PDFKit 缩略）非确定性，哈希会漂移，以占比结论为准。

## 统一翻译后端复测（2026-11-03）

同一驱动比较 small100 与 quickmt 的模型层、辅助进程层和加固层；结论与完整产物见 [统一实测决定](results/translation-backends/decision.md)。前提：small100 门槛缓存、quickmt 本地模型、无 PyTorch 的 `venv-ct2`，以及已构建的 `.build/core/libgogaku_core.dylib`。

```sh
python3 probes/benchmark-translation-backends.py \
  --backends small100 quickmt --directions en-zh,zh-en --cases all --rounds 5 \
  --output-dir probes/results/translation-backends --force
python3 scripts/summarize-translation-backends.py \
  --run-dir probes/results/translation-backends-round2 \
  --run-dir probes/results/translation-backends \
  --output-dir probes/results/translation-backends-round2 \
  --review probes/results/translation-backends-round2/semantic-review-round2.json
```

`--cases all` 组合 32 条风险集、200 条保留集、88 条专项短文本（2026-11-03 起纳入，加载器有数量断言）和 8 条速度句；正式运行要求至少 5 轮。汇总支持多次 `--run-dir` 合并（第一个为主目录，提供模型身份／资源／环境；质量与延迟覆盖并集，主目录 worker pin 不一致即报错）。审阅文件（schema v2，含冻结评分规则）必须覆盖每个放行候选，缺失审阅的门槛报 `blocked-pending-review`，不会报完成；延迟预算取速度子集，任何应译请求超预算都记入 `latencyOverBudget`，缺数据报 `incomplete` 不算通过。评测管线自身回归：`python3 scripts/validate-translation-eval.py`（已接入 verify fast 档）。独立确认集运行与盲测材料生成：

```sh
python3 probes/benchmark-translation-backends.py --cases short,confirm --rounds 5 \
  --output-dir probes/results/translation-backends-round2
python3 scripts/make-translation-blind-comparison.py \
  --run-dir probes/results/translation-backends-round2
```

`requests.jsonl` 保留逐条源文哈希、token、阶段耗时和输出；失败请求保留父进程等待时间与 `budgetExceededMs`；`models.json` 重新计算文件 SHA256。重跑后输出若变化需重新审阅，不能把旧审阅硬套到新结果。

未来语言只做延迟/资源探针，不与中英质量结论混用：

```sh
python3 probes/benchmark-translation-backends.py \
  --backends small100 --cases language \
  --directions en-ja,ja-en,en-ko,ko-en,en-es,es-en --rounds 5 \
  --output-dir probes/results/translation-backends-multilingual --force
python3 scripts/summarize-translation-backends.py --run-dir probes/results/translation-backends-multilingual
```

扩展探针每方向 4 条，没有人工参考，不报告语义质量分数；quickmt 扩展方向本轮未下载、未实测。`--allow-short-run` 只用于烟测，不能作为正式成绩。

## 学习翻译开发版后端（2026-11-03 裁决）

quickmt 双向权重从探针缓存装配为输入法外置辅助进程（2026-11-03 用户裁决，范围与风险清单见[开发版裁决](../docs/learning-quickmt-dev-decision.md)；只评测不接生产的历史口径见上节）。准备脚本幂等可重跑；权重 SHA256 与 [models.json](results/translation-backends/models.json) pins 不符即拒绝装配；venv 用 `/usr/bin/python3`（pinned `ctranslate2==4.6.0`＋`sentencepiece==0.2.0`，不装 PyTorch）：

```sh
python3 scripts/prepare-learning-translation.py        # 装配到 ~/Library/Application Support/Gogaku/translation/
```

协议适配：`scripts/quickmt_worker.py` 复用探针的 quickmt 官方协议（src spm＋`</s>` → tgt spm decode），但响应对齐输入法 `TranslationRequest`／`TranslationResult` v1（回显请求字段，附 `target`／`error`／`milliseconds`）；beam 来自设置（默认 1，1–10 可调，重建进程生效）。回归：

```sh
python3 scripts/validate-learning-translation.py protocol   # 回显／invalid_request／model_missing／非法行存活（已接入 verify fast 档）
python3 scripts/validate-learning-translation.py samples \
  --python "$HOME/Library/Application Support/Gogaku/translation/venv/bin/python"   # 两方向各 3 条固定样例与探针记录逐字一致＋延迟抽测
```

样例预期来自 [requests.jsonl](results/translation-backends/requests.jsonl)（2026-11-03 轮次 1，beam1/INT8/2 线程）；预热口径同上节（每方向一次，首次含模型加载 1–2s 不计入逐句延迟）。worker 无端口、无文本日志、无网络访问；缺权重时逐请求返回 `model_missing`，不阻塞普通模式。

## 翻译组合策略验收（2026-11-04）

固定路线「运行时保留判定 → 品牌映射 → 审核表达资源 → 双向时间模板 → small100 多候选 → 结构检查 → quickmt 反向评分」的评测入口。结论与证据见[翻译组合策略决定](../docs/translation-strategy-decision.md)与[首轮验收报告](results/translation-strategy-final/report.md)。

```sh
# 1) 构建审核资源（需要 CC-CEDICT 与 jieba 缓存；输出 resources/translation/）
python3 scripts/build-translation-expressions.py
python3 scripts/build-translation-expressions.py --print   # 只打印供人工复核

# 2) 开发数据采集：候选＋反向分数各取一次（λ=0 也采集，供离线选 λ）
python3 probes/benchmark-translation-strategy.py \
  --cases risk,holdout,short,confirm --rounds 1 --allow-short-run --collect-scores \
  --output-dir probes/results/translation-strategy-dev --force
python3 scripts/select-translation-lambda.py \
  --requests probes/results/translation-strategy-dev/requests.jsonl \
  --labels probes/results/translation-strategy-dev/labels.json \
  --output probes/results/translation-strategy-dev/lambda-selection.json

# 3) 封板后跑一次验收（λ、资源、模板、品牌表、编排代码与 dylib 哈希绑定）
python3 probes/benchmark-translation-strategy.py --cases final,risk --rounds 5 \
  --lambda-file probes/results/translation-strategy-freeze.json \
  --output-dir probes/results/translation-strategy-final --force
python3 scripts/summarize-translation-strategy.py \
  --run probes/results/translation-strategy-final \
  --labels probes/results/translation-strategy-final/final-labels.json \
  --output probes/results/translation-strategy-final/acceptance.json
```

边界：`translation_strategy.py` 与驱动只在隔离辅助进程里编排，不接入生产 C ABI、不改设置与输入行为。驱动校验封板哈希，策略文件改动后必须重新封板并重跑，不能沿用旧验收。汇总要求每条放行译文都有语义标注（缺一即 `blocked`），并把回退、错误放行、分路径与超预算记录分开统计。


