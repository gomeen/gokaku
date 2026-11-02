# quickmt 双向模型速度实测（Mac 门槛机）

日期：2026-11-02。性质：**速度探针＋可用性烟测，非质量门槛**；语义结论需独立门槛流程（风险集逐条审阅＋自建短文本评测集＋用户盲测）。

## 环境

- Intel i9-9880H、macOS 26.7.2、CTranslate2 4.6.0（venv-ct2，无 PyTorch，与 small100 门槛同一环境）
- 模型：`quickmt/quickmt-en-zh`、`quickmt/quickmt-zh-en`（HF，CC-BY-4.0，2026-04 更新版），原生 CT2 格式，加载时在线 int8 转换
- 参数对齐 small100 门槛：greedy（beam=1）、batch=1、intra_threads=2、inter_threads=1、max_decoding_length=256、12 轮热态（每句对先热身 1 次）
- 协议按 quickmt 官方库 translator.py：src spm encode→追加 `</s>`；tgt spm decode
- 脚本：`scripts/validate-quickmt-speed.py`；数据：[evaluate.json](evaluate.json)、[summary](evaluate.json.summary.json)

## 速度结果（对照预算与 small100）

| 方向 | 句型 | quickmt p50 | quickmt p95 | small100 p95（门槛实测） | 预算 |
| --- | --- | --- | --- | --- | --- |
| en→zh | 短表达 | 56.5ms | **66.8ms** | 125.5ms | 500ms |
| en→zh | 短句 | 69.4ms | **79.0ms** | 218.7ms | 2s |
| zh→en | 短表达 | 35.4ms | **41.6ms** | 111.2ms | 500ms |
| zh→en | 短句 | 68.5ms | **82.2ms** | 198.9ms | 2s |

- 模型载入（含在线 int8 转换）：0.88s／0.81s；beam=5 时短句 p50 也仅 ~60ms。
- 风险集 32／32、留存集 180／180 可用（空/重复（机械判定口径）/超时均为 0）；句级 p95：风险集 101.2ms、留存集 111.6ms；max 约 1.27s（个别长句，仍在 2s 短句预算内）。
- **速度判定：大幅达标，约为预算的 1/6–1/8，比 small100 快 2–2.8 倍。**

## 质量观察（烟测级，非结论）

small100 固定风险集四个失败点的对照（beam=1）：

| 用例 | small100 输出 | quickmt 输出 | 判定 |
| --- | --- | --- | --- |
| en-names（Bob） | 丢 Bob | `爱丽丝将于周五在北京与鲍勃见面。` | **修复** |
| en-long（10:30 a.m.） | `下午10点30点` | `会议已转移到下周二上午10:30。` | **修复** |
| zh-long（十点半） | `10 a.m.`（丢半） | `10:30 a.m. next Tuesday` | **修复** |
| en-phrase（attend a meeting） | `參加會議`（繁体） | `参加会议 会议`（简体但尾部重复） | 部分：繁简修复，新暴露重复 |

beam=2/5 不能消除短语级重复（模型固有行为，非搜索问题）。

**新暴露的短语级（1–3 词）失败模式——恰是输入法主场景**：
- 重复：`attend a meeting`→`出席会议 会议`、`Good morning.`→`早上好 好 好`、`see you tomorrow`→`明天见,你明天见`
- 繁体漂移：`thanks`→`謝謝你!`、`how are you`→`你怎麼會這樣?`
- 截断：`谢谢`→`Thanks for the`（beam=2；beam=5 时 `Thank you very much.`）
- 语义跑偏：`how are you`→`你怎麼會這樣?`（寒暄译成质问）

`I cannot open the attachment, please send it again.` 在 beam=1 出现尾部多余「联系方式」，beam=2 正常——超短输入的输出稳定性差于句级。

## 判定与下一步

1. **速度解堵确认**：quickmt 双向均远超速度预算，速度不再是一票否决项。
2. **质量不能免检**：句级强于 small100，但短语级失败模式（重复/繁体漂移/截断/跑偏）与加固层对症范围重合（重复检测、OpenCC t2s 归一、长度比率、低置信回退），且部分（语义跑偏）必须靠评测集审阅处置。
3. 下一步：① 自建短文本评测集时把上述短语样本纳入；② 跑同一套风险集语义审阅＋用户盲测后，才能讨论「替换 small100」；③ en→zh 方向繁体漂移的覆盖率需要在更大样本上量化。

## 加固层处置效果验证（同日补入）

加固层第一片（`native/GogakuCore/translate/`，55 项断言入 ctest）对本报告观察到的失败与 small100 历史失败逐条验证，证据 [hardening-demo.json](hardening-demo.json)：

- **拦截/修复**：尾部重复（参加会议 会议→回退）、词元复读（好 好 好→回退）、短语复现（明天见,你明天见→回退）、繁体漂移（謝謝你!→谢谢你! 归一候选）、时段翻转（下午9点→回退）、乱码编造（181 个 Q→回退）；small100 參加會議归一为参加会议。
- **未拦（v1 边界，第二片工作）**：语义跑偏（你怎么会这样? 归一后仍候选——需评测集审阅处置）、多余尾部（联系方式——需覆盖 QE）、短源截断（Thanks for the——长度网对超短源无能为力）、人名丢失与品牌改写（需专名对齐检查接入管线）。
- 结论：裁决口径下的「安全拦截」链路成立；完整达标还需第二片（管线接入＋专名对齐＋覆盖检查）＋评测集语义审阅＋用户盲测。

## 产物哈希

- quickmt-en-zh model.bin sha256 `433e7c41b63223f2d4600c740ce2a00a1bbe6dba1190a5fc10e8cc245e2ef387`（409,972,810 bytes）
- quickmt-zh-en model.bin sha256 `e7cac9c2bc585e476d8fe47af11ed76723d4b5cf69ccef8f5ff821fb3ec05000`（407,101,843 bytes）
- src/tgt spm 校验见下载记录（与 HF LFS oid 一致）；本地缓存 `~/Library/Caches/Gogaku/models/quickmt-speed/`
