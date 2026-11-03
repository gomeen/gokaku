# 三款翻译候选：本机实测前资源筛查

本轮只读核验官方文件/API，未下载权重、未构建 runtime、未运行模型、未改页面。承接[候选研究](research-translation-screenshot-candidates.md)；本机可用内存/磁盘、runtime 准备与实测由主线程负责。以下内存是**预算估算，不是 RSS 实测、上限承诺或速度预测**。

**结论：三者均适合进入“单模型、CPU-only、单请求、512/1024 token”资源实测。** Qwen 最小；Index 与 HY 权重各约 1.1–1.3GB，按本文约束给单进程预留 3GiB 较宽裕，但启动日志与实测峰值才是最终依据。没有证据可从这些大小推出完整翻译达到 500ms。

## 1. 精确产物与版本

以下来自 Hugging Face 官方 `api/models/{repo}?blobs=true` 中的 `sha`、`siblings[].size`、`lfs.sha256`，不是搜索摘要。GB/MB 为十进制；GiB/MiB 为二进制。

| 模型 | 官方 GGUF 仓库／确切文件名 | 字节数 | 换算 |
| --- | --- | ---: | ---: |
| Index | `IndexTeam/Index-Translate-2B-GGUF` / `Index-Translate-2B.Q4_K_M.gguf` | 1,312,164,352 | 1.312 GB / 1.222 GiB |
| Qwen | `Qwen/Qwen2.5-0.5B-Instruct-GGUF` / `qwen2.5-0.5b-instruct-q4_k_m.gguf` | 491,400,032 | 491.400 MB / 0.458 GiB |
| HY | `tencent/HY-MT1.5-1.8B-GGUF` / `HY-MT1.5-1.8B-Q4_K_M.gguf` | 1,133,080,512 | 1.133 GB / 1.055 GiB |

固定身份，后续准备权重时可直接使用：

```text
Index GGUF revision: 3a0eca6ce931d88d00614d427ab3ed8ff0743902
Index file SHA256: 044b313d29342bd3b2c77cbb64023ca0d209bd9b3247763f9d162767ef2d746a
Qwen GGUF revision: 9217f5db79a29953eb74d5343926648285ec7e67
Qwen file SHA256: 74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db
HY GGUF revision: 265b2e615a7dc9b06c435dc878829ad99a512ba2
HY file SHA256: 4383ac0c3c8e476de98ff979c2a3f069f8c4fb385e7860cf2d28da896cc477c7
```

三个文件合计 **2,936,644,896 字节，约 2.735 GiB**；不含 runtime、缓存重复副本及临时文件。文本任务只取这三个指定文件，Index 不需要 `mmproj`，不需要原始 safetensors。

**对上轮 Index 的核对结果：** 官方 `config.json` 确认 `Qwen3_5ForConditionalGeneration` / `qwen3_5`，GGUF 模型卡确认 2B、Q4_K_M 1.31GB，并写明 2026-10-03 发布；API 创建时间是 2026-10-02T21:10:16Z，当前最后修改时间是 2026-10-10T16:59:13Z。因此本轮没有发现需要改成另一模型版本或另一体积的证据；主要补充是**其文本骨干为混合线性注意力，不能当成普通全注意力 24 层模型估 KV**。上轮“搜索摘录未锁版本”的限制由本节精确 revision/字节/SHA256 补足。[I1–I3]

## 2. 官方配置与 KV／循环状态估算

固定的基础模型 revision（与量化仓库 revision 分开记录）：

| 基础模型仓库 | config revision | 配置关键字段 |
| --- | --- | --- |
| `IndexTeam/Index-Translate-2B` | `9bc08445315723eb9b77d1b93505915eb03c3f01` | 文本 24 层：18 linear + 6 full；hidden 2048；完整注意力 Q heads=8、KV heads=2、head_dim=256；最大位置 262144；线性部分 key/value heads=16、head_dim=128、conv kernel=4；另有 vision 配置及 1 层 MTP 配置 |
| `Qwen/Qwen2.5-0.5B-Instruct` | `7ae557604adf67be50417f59c2c2f167def9a775` | `Qwen2ForCausalLM` / `qwen2`；24 层，hidden=896，Q heads=14、KV heads=2，head_dim=896/14=64；最大位置 32768；`use_sliding_window=false` |
| `tencent/HY-MT1.5-1.8B` | `dbad03788f49709801014c95d481a514c272ca52` | `HunYuanDenseV1ForCausalLM` / `hunyuan_v1_dense`；32 层，hidden=2048，Q heads=16、KV heads=4，head_dim=128；最大位置 262144；`use_cla=false`，不能按 `cla_share_factor=2` 擅自减半 KV |

估算条件：一个活动序列；`-c 512` 或 `-c 1024` 指 **prompt＋输出的总 token 容量**；K/V 使用 F16，Q4_K_M 仅指权重；不用 MTP/草稿模型、视觉、历史会话缓存。公式：

```text
全注意力 KV 字节 = 2(K,V) × 层数 × context × KV heads × head_dim × 2(F16)
```

| 模型 | 512 token KV | 1024 token KV | 额外持久状态 |
| --- | ---: | ---: | --- |
| Qwen | 6 MiB | 12 MiB | 无循环状态 |
| HY | 32 MiB | 64 MiB | 无循环状态 |
| Index | 6 MiB（只计 6 个 full 层） | 12 MiB | 约 **19.27 MiB/序列/状态副本**，两个上下文长度相同 |

Index 循环状态按 llama.cpp 当前实现的 FP32 R/S 张量推算：[L2]

```text
S = 18 × 16 × 128 × 128 × 4 bytes = 18 MiB
R = 18 × (4−1) × (2×16×128 + 16×128) × 4 bytes = 1.265625 MiB
R+S = 19.265625 MiB
```

因此 Index 基础 KV＋循环状态约 **25.27 / 31.27 MiB**。这不是完整运行内存：当前源码的 recurrent 分配行为还会乘 `mem_size × (1+n_rs_seq)`；单序列、不启用 rollback 时按一份估算，多序列、rollback snapshots、server context checkpoints 会增加占用。表格未计分配对齐与管理结构，应核对日志里的 `KV buffer size`、`RS buffer size`、`n_rs_seq`，不要把“线性注意力”写成“完全没有状态内存”。

在 **CPU-only、`-b 128 -ub 128`、单活动请求、无历史缓存** 前提下，建议用于预筛的规划区间如下；这是基于权重映射、上述状态量及小批计算缓冲/词表/图管理的工程估算，**额外缓冲没有官方本机实测值，区间不是经证明的边界**。

| 模型 | 权重之外的预算余量（已含 KV/状态，512 与 1024 共用粗区间） | 单模型总运行预算估计 |
| --- | ---: | ---: |
| Qwen | 0.15–0.50 GiB | 约 0.6–1.0 GiB |
| HY | 0.25–0.80 GiB | 约 1.3–1.9 GiB |
| Index | 0.30–1.00 GiB | 约 1.5–2.3 GiB |

短上下文 KV 很小，主要不确定性是 runtime 计算图、临时缓冲、分词器/词表、CPU 权重重排、映射页是否驻留。`mmap` 的虚拟映射量不等于 RSS，OS 文件缓存也不能重复算成另一份完整进程权重。较大 `-b/-ub`、全 logits、并发、GPU 副本或保留多次请求状态均可能超出上表。不要使用模型的 32K/262K 最大上下文作为这轮默认分配。

## 3. llama.cpp 支持与建议执行约束

本轮直接核验上游 `ggml-org/llama.cpp` 提交 **`37b0f9c36ae910c5a445b3934e840084ebc9b132`**（API 返回提交时间 2026-11-03T06:58:56Z）：

- Index：`src/models/qwen35.cpp` 有 24 层/hidden 2048 的 2B 分支和 gated delta net＋完整注意力实现，`llama-memory-hybrid.cpp` 将两类状态分开分配。
- Qwen：`src/models/qwen2.cpp` 有模型实现；Qwen 官方 GGUF 卡明确给出 llama.cpp 路径。
- HY：`conversion/hunyuan.py` 将 `HunYuanDenseV1ForCausalLM` 注册到 `HUNYUAN_DENSE`；`models.h` 中 `llama_model_hunyuan_dense` 复用 `hunyuan_vl` 的加载和图实现；官方常规 GGUF 卡给出 llama-cli 命令。这里不涉及 STQ/1.25bit 分支。

这证明**该上游源码有架构实现**，不证明本机已有二进制支持或这三个文件已成功加载。主线程应记录实际 runtime commit/构建信息与加载日志，尤其不能把旧版支持 Qwen2 等同于支持 Qwen3.5。[L1]

以下仅为后续启动参数建议，本轮未执行：

```sh
llama-server -m /absolute/path/to/model.gguf \
  -ngl 0 -c 1024 -np 1 -b 128 -ub 128 \
  -ctk f16 -ctv f16 --cache-ram 0 --ctx-checkpoints 0 \
  --no-context-shift --host 127.0.0.1 --port 8080
```

用 `-c 512` 做另一组即可；线程数由主线程按本机安排。上述 server 版本默认 parallel 可自动选择，显式 `-np 1` 才对应本报告的单序列预算；`--cache-ram 0` 禁用历史 prompt RAM 缓存，`--ctx-checkpoints 0` 避免检查点放大 Index 循环状态。`-b/-ub` 是 token 批大小，不是并发请求数。配置项与当前上游参数源码/README 一致。[L3]

每条请求独立、无对话历史，`cache_prompt=false` 用于公平计时；模板和源文分词后须留出输出预算（例如最多 128 token，具体以句子需求为准）。达到输出上限或上下文上限应标截断/失败，不把不完整译文计为成功。

## 4. 推荐 prompt 与 thinking

### Index

GGUF 官方卡给出的普通翻译 user 内容：[I2]

```text
请将以下文本翻译为{target-language}，直接输出翻译结果，不要进行任何解释。

{source-text}
```

目标写完整语言名，如 `英语` / `中文`；官方 prompts 文档也给出同义冒号版本，实验固定一个版本即可。走 chat template，`temperature=0` / greedy。关闭 thinking 的两种版本对应写法：

```sh
# 模型卡原写法；适用于有这些参数的旧/现有 runtime
--jinja --chat-template-kwargs '{"enable_thinking":false}' --temp 0

# 本轮核验的 llama.cpp commit 推荐写法
--jinja --reasoning off --temp 0
```

当前 `common/arg.cpp` 明确将 `--reasoning off` 映射到模板的 `enable_thinking=false`，并对前一种写法发出 deprecated 提示，但仍接受它。两种写法不必叠加。[L3]

基础模型 `tokenizer_config.json` 的实际模板在 `add_generation_prompt=true` 且 thinking 不是 true 时，追加：

```text
<|im_start|>assistant
<think>

</think>

```

这是已经闭合的空思考前缀，用于让模型直接继续译文。不要只靠 `/no_think` 或 `--reasoning-format none`：前者不是此卡指定协议，后者只控制思考内容的解析/展示，不能等同于关闭生成思考。主线程加载 GGUF 后应核对实际嵌入模板或模板渲染结果；本轮未读取权重内部 metadata。[I3、L3]

### HY

官方中↔其他语言模板（因此**中→英和英→中都用中文指令**）：[H2]

```text
将以下文本翻译为{target_language}，注意只需要输出翻译后的结果，不要额外解释：

{source_text}
```

本次目标分别填 `英语` / `中文`。不涉及中文的 XX↔XX 才推荐：

```text
Translate the following segment into {target_language}, without additional explanation.

{source_text}
```

官方卡明确**没有默认 system prompt**；推荐 `temperature=0.7, top_k=20, top_p=0.6, repetition_penalty=1.05`。如果为了可复现另跑 greedy，应标为实验变体，不称官方推荐。卡里的简短 Python/CLI 示例虽用英文指令翻中文，正式 Prompts 分节对 ZH↔XX 的建议更明确，首轮遵循该分节。

本次基础 `tokenizer_config.json` 没有 `chat_template` 字段，不能盲目假设 HF 通用 `apply_chat_template` 一定可用。官方 GGUF 卡的 Ollama 模板给出无 system 的原生序列：

```text
<｜hy_begin▁of▁sentence｜><｜hy_User｜>{user_prompt}<｜hy_Assistant｜>
```

先核对实际 GGUF/llama.cpp 所用模板；已有正确模板时传 user 消息即可，避免再次手工包裹。若必须走 raw completion，按该官方格式处理 special tokens，禁止套用 Qwen ChatML。[H2]

### Qwen

基础与 GGUF 官方卡提供的是通用聊天示例，**本轮所核验官方文件没有专门的翻译 prompt 推荐**。模板是 ChatML；无显式 system 时自动插入 `You are Qwen, created by Alibaba Cloud. You are a helpful assistant.`，并以 `<|im_start|>assistant\n` 开始输出。[Q2–Q3]

实验可用 user 内容 `Translate the following text into {English/Chinese}. Output only the translation, without explanation.\n\n{source_text}`，保留原模型 chat template；这句话和 `temperature=0` 是本轮建议的实验协议，不是官方翻译基准。Qwen2.5 此模板没有 Qwen3 式 thinking 开关，不加 Index 的 thinking 参数。

## 官方来源与证据边界

本轮一次搜索工具调用因参数错误未取得结果；随后全部改为公开 HTTPS 直接读取原始小文本/API，未使用搜索摘要。没有扩展模型名单或重查许可长文。临时原文件保存在 `/tmp/gogaku-resource-prescreen/`，可被系统清理；可复核依据为以下官方链接和上文固定 revision。API 链接的 `main` 会变化，后续下载使用上文固定身份。

- **I1 Index 精确文件 API**：[GGUF API](https://huggingface.co/api/models/IndexTeam/Index-Translate-2B-GGUF?blobs=true)、[基础模型 API](https://huggingface.co/api/models/IndexTeam/Index-Translate-2B?blobs=true)。
- **I2 Index GGUF 官方卡**：[固定 revision README](https://huggingface.co/IndexTeam/Index-Translate-2B-GGUF/blob/3a0eca6ce931d88d00614d427ab3ed8ff0743902/README.md)、[官方 prompts](https://github.com/bilibili/Index-Translate/blob/main/docs/prompts.md)。
- **I3 Index 官方配置/模板**：[config.json](https://huggingface.co/IndexTeam/Index-Translate-2B/blob/9bc08445315723eb9b77d1b93505915eb03c3f01/config.json)、[tokenizer_config.json](https://huggingface.co/IndexTeam/Index-Translate-2B/blob/9bc08445315723eb9b77d1b93505915eb03c3f01/tokenizer_config.json)。
- **Q1 Qwen 精确文件 API**：[GGUF API](https://huggingface.co/api/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF?blobs=true)。
- **Q2 Qwen GGUF 官方卡**：[README](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/blob/9217f5db79a29953eb74d5343926648285ec7e67/README.md)。
- **Q3 Qwen 官方配置/模板**：[config.json](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/blob/7ae557604adf67be50417f59c2c2f167def9a775/config.json)、[tokenizer_config.json](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/blob/7ae557604adf67be50417f59c2c2f167def9a775/tokenizer_config.json)。
- **H1 HY 精确文件 API**：[GGUF API](https://huggingface.co/api/models/tencent/HY-MT1.5-1.8B-GGUF?blobs=true)。
- **H2 HY 官方模板/参数**：[GGUF README](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF/blob/265b2e615a7dc9b06c435dc878829ad99a512ba2/README.md)、[基础模型 README](https://huggingface.co/tencent/HY-MT1.5-1.8B/blob/dbad03788f49709801014c95d481a514c272ca52/README.md)。
- **H3 HY 官方配置**：[config.json](https://huggingface.co/tencent/HY-MT1.5-1.8B/blob/dbad03788f49709801014c95d481a514c272ca52/config.json)、[tokenizer_config.json](https://huggingface.co/tencent/HY-MT1.5-1.8B/blob/dbad03788f49709801014c95d481a514c272ca52/tokenizer_config.json)。
- **L1 架构支持**：[qwen35.cpp](https://github.com/ggml-org/llama.cpp/blob/37b0f9c36ae910c5a445b3934e840084ebc9b132/src/models/qwen35.cpp)、[qwen2.cpp](https://github.com/ggml-org/llama.cpp/blob/37b0f9c36ae910c5a445b3934e840084ebc9b132/src/models/qwen2.cpp)、[HY 转换注册](https://github.com/ggml-org/llama.cpp/blob/37b0f9c36ae910c5a445b3934e840084ebc9b132/conversion/hunyuan.py)、[HY dense 类声明](https://github.com/ggml-org/llama.cpp/blob/37b0f9c36ae910c5a445b3934e840084ebc9b132/src/models/models.h)。
- **L2 状态维度/分配**：[llama-hparams.cpp](https://github.com/ggml-org/llama.cpp/blob/37b0f9c36ae910c5a445b3934e840084ebc9b132/src/llama-hparams.cpp)、[llama-memory-recurrent.cpp](https://github.com/ggml-org/llama.cpp/blob/37b0f9c36ae910c5a445b3934e840084ebc9b132/src/llama-memory-recurrent.cpp)、[llama-memory-hybrid.cpp](https://github.com/ggml-org/llama.cpp/blob/37b0f9c36ae910c5a445b3934e840084ebc9b132/src/llama-memory-hybrid.cpp)、[llama-model.cpp](https://github.com/ggml-org/llama.cpp/blob/37b0f9c36ae910c5a445b3934e840084ebc9b132/src/llama-model.cpp)。
- **L3 运行参数语义**：[common/arg.cpp](https://github.com/ggml-org/llama.cpp/blob/37b0f9c36ae910c5a445b3934e840084ebc9b132/common/arg.cpp)、[server README](https://github.com/ggml-org/llama.cpp/blob/37b0f9c36ae910c5a445b3934e840084ebc9b132/tools/server/README.md)。
