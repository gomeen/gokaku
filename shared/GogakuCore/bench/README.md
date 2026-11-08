# 普通模式核心性能：分项成本证据

本目录只放共享核心（`shared/GogakuCore`）的性能证据，不改其他目录。

## 文件

| 文件 | 内容 |
| --- | --- |
| `results/normal-session-bench.txt` | 端到端逐键基准（公开 C ABI 路径，`tests/normal_session_bench.cpp`）：优化前／后同一台机器、同一构建参数的原始输出 |
| `results/normal-session-profile.txt` | 分项成本基准（`tests/normal_session_profile.cpp`）的分位数摘要 |
| `results/normal-session-profile-samples.csv` | 分项基准的**全部原始样本**（每行 `event,phase,ns`），未剔除任何样本 |

## 两个基准的区别（重要）

- `normal_session_bench`：**真实端到端**，调用公开的 `gc_normal_handle`，测的是平台实际会遇到的逐键延迟。用于核对「核心优化目标 p95 ≤ 1ms」；交付必须另测真实 IMK 的体感门槛。
- `normal_session_profile`：**分项归因工具**，它不经过 `gc_normal_handle`，而是用 libime 直接复刻核心内部的两套合并算法（旧：200 条候选全量转换＋全量查询；新：只算身份＋只物化当前页/下一页），在同一状态下依次计时各阶段。用途是回答「时间花在解码／转换／查询／合并／快照哪一段」，**不能**当作端到端延迟。

## 本轮结论（同一台机器实测）

| 阶段 | 优化前 | 优化后 | 说明 |
| --- | --- | --- | --- |
| libime 解码（`PinyinContext::type`） | — | mean 1328µs / p95 2864µs | 占逐键成本 98% 以上；本轮未改解码参数（不改 nbest/beamSize，不降质量） |
| 候选获取（`candidatesToCursor`） | — | mean 0.2µs | libime 内部缓存 |
| 旧：200 条候选全量转文本 | convert200 | mean 2.9µs | 已消除 |
| 旧：200 条候选 ×（2 次释义＋1 次学习词）查询 | lookup200 | mean 25.5µs / p95 65.9µs | 已消除（只在物化时查 ≤18 条） |
| 新：只算候选身份与总数 | — | merge_identity mean 1.4µs | 新增 |
| 新：只物化当前页＋下一页（≤18） | — | materialize18 mean 2.3µs | 新增 |
| 新：英文整词/前缀索引 | — | english_index mean 1.8µs | 替代原来每次按键线性扫 5 万词表 |
| 快照（复制 9 项） | — | snapshot9 mean 2.4µs | 未变（本来就只带 9 项） |

端到端（`normal_session_bench`，10320 事件）：

| 指标 | 优化前 | 优化后 |
| --- | --- | --- |
| 全部 mean | 1060.2µs | 1058.5µs |
| 全部 p50 | 771.4µs | 754.6µs |
| 全部 p95 | 2898.3µs | 2932.7µs（噪声内持平） |
| 翻页 mean | 18.5µs | 4.9µs（−73%，纯合并/查询路径） |
| 分段/数字选择 mean | 811.3µs | 795.9µs |

**为什么端到端只小幅改善**：逐键成本 98% 以上在 libime 解码里，而本轮范围限定为「合并/候选/查询/索引」，
解码参数按要求不得下调（会改变候选质量）。可优化的非解码部分（翻页、组合查询）改善明显
（翻页 −73%），但被解码成本淹没，端到端 p95 仍在 2.9ms 量级，**未达到 p95 ≤ 1ms 优化目标**（不单独阻塞交付）。

数据面消融（公开 C ABI，纯字母序列，轨迹一致）：

```
英文开+释义在 n=1198   mean=  1206.7µs p50=   947.2µs p95=  2934.9µs
英文关+释义在 n=1198   mean=  1183.8µs p50=   897.9µs p95=  2797.2µs
英文关+释义无 n=1198   mean=  1197.5µs p50=   929.8µs p95=  2854.0µs
```

三种配置差异已在噪声内：英文索引与释义查询已不再构成可测成本。

## 复现

```bash
cmake -S shared/GogakuCore -B .build/core -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DGOGAKU_DEPS="$HOME/Library/Caches/Gogaku/libime-1.1.17"
cmake --build .build/core -j 4
./.build/core/gogaku_core_normal_bench                       # 端到端（优化目标；未达标退出 2）
cd shared/GogakuCore && GOGAKU_CORE_PROFILE_ROOT="$PWD/../.." \
      ../../.build/core/gogaku_core_normal_profile 1200       # 分项＋原始样本 CSV
```

最终本机复测 10,320 事件：p95 2.997ms、p99 3.787ms，仍未达到 1ms 优化目标，见[最终核心日志](../../../docs/validation/final-mac/core-bench.log)。本目录其余数据为开发期分项实验。真实 IMK 全回调超标及停止交付的结论见[收尾报告](../../../docs/validation/pre-user-test.md)。
