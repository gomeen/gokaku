# 扩展词库（合同与实施说明）

状态：**实施中（0.5.0 一次发版）**。本文是扩展词库的合同来源：存储与元数据格式、转换规则、C ABI、挂载计划、重载通知与官方渠道。裁决依据与许可红线见[扩展词库调研](research-dictionaries.md)；阶段排期见[双端实施计划](implementation-plan.md)；功能状态见[双端功能对照](feature-parity.md)。

## 一、总则

- 三层能力一次发布：引擎挂载多本词典、导入转换、官方精选词库渠道。
- 共享核心新增一组**附加 C ABI**：不改任何已有结构布局与函数签名，`GOGAKU_CORE_ABI_VERSION` 保持 4，两端加载方不需要重编译合同检查以外的部分。
- 返回的 JSON 用 `gc_contract_free` 释放。核心本身不建线程：转换与加载的线程由平台提供（Mac 设置进程后台队列、输入法 `org.gogaku.dictionaries` 后台串行队列；Windows 代理后台线程）。
- 用户可见行为（与两端一致）：
  - 设置新增「扩展词库」页，排在「自定义词语」之后。Mac 完整版 9 页；Lite 独立包与完整版的 Lite 模式都是 6 页。Windows 完整版 8 页、Lite 5 页。
  - 页面内容：「导入词库」按钮（可多选文件）；词库列表（名称、条目数、来源、内存估算、开关、删除）；启用词库合计内存估算，超过 200MB 提醒但不阻止启用；「打开搜狗细胞词库」（浏览器打开 `https://pinyin.sogou.com/dict`）；「萌娘百科词库」（打开 mw2fcitx 发布页并注明内容为 CC BY-NC-SA，只能非商业使用，Gogaku 不分发）；「获取更多词库」（用户点击后才联网拉取官方清单）。
  - 完整版启用学习翻译时，未进入学习模式的词库标「仅普通模式」。
  - 导入自动识别 `.scel`、Rime `.dict.yaml`、libime `.txt`／`.dict` 和无拼音纯词表 `.txt`。导入结束显示导入条数和每种丢弃原因的数量。同一源文件重复导入被拒绝。
  - 输入行为：扩展词默认全部参与排序，权重统一为 0，候选不做来源标识；启用、停用、删除词库后输入法自动重载，组合进行中不切换、组合结束后的下一个事件前生效；对扩展词按 Ctrl＋Backspace 提示「扩展词请到设置停用或删除词库」，不删除；普通模式上屏的扩展词照常学入调频，删除词库后已学词保留。
  - 兼容：`settings.json` 不新增字段，schema 仍为 2，不需要迁移；旧版本忽略 `dictionaries/` 目录。

## 二、转换规则（只在共享核心实现一份）

### 2.1 过滤与权重

- 所有条目权重写 0（libime 把词典权重当排序加分；Rime 词频原样写入会挤掉正常候选）。
- 丢弃条目按原因计数，导入结束时报告：

| 原因 | 判定 |
| --- | --- |
| `duplicateFactory` | 与出厂词库同词同音的条目 |
| `duplicateEntry` | 文件内重复（同词同音） |
| `middleDot` | 词中含间隔号 `·`（U+00B7）、`•`（U+2022）、`・`（U+30FB） |
| `tooLong` | 词超过 32 个 Unicode 标量 |
| `invalidLine` | 拼音非法，或词／读音含空白、控制字符 |
| `nonHan` | 仅纯词表：词含非汉字字符 |
| `ambiguousReading` | 仅纯词表：读音无法唯一确定（见 2.2） |

- 带拼音的格式保留含字母和数字的条目；纯词表只保留全是汉字的条目。
- 判定顺序：invalidLine → middleDot → tooLong → duplicateFactory → duplicateEntry →（纯词表）nonHan → ambiguousReading。每个条目只记入第一个命中的原因。

### 2.2 无拼音条目定读音

1. 整词在出厂词库里只有一个读音时直接采用。
2. 否则按出厂词库做最长匹配切分，每一段都必须在出厂词库里只有一个读音；有一段不满足（含零读音或多读音）就丢弃整条，计入 `ambiguousReading`。
3. 段读音按音节顺序拼接，音节间加撇号（`ni'hao` 形式全拼）。

同一份实现给设置应用导入和发布侧预处理（THUOCL 等无拼音数据）共用。

### 2.3 各格式解析

- **搜狗 `.scel`**：按社区逆向的数据格式解析（拼音表＋词表，UTF-16LE）。合成测试样本由入库脚本生成，不含搜狗数据。
- **Rime `.dict.yaml`**：按 YAML 头里的 `columns` 解析，缺省为 `text、code、weight`。code 里空格分隔的音节改成撇号分隔；没有 code 列的条目走无拼音规则。只有 `import_tables`、没有词条的清单文件报错，提示用户导入 `cn_dicts/` 下的具体词库。
- **libime `.txt`／`.dict`**：`.dict` 是 libime 二进制格式，直接挂载前的校验为「能否被 `PinyinDictionary::load` 读入」。两种 `.txt` 共用格式探测：抽样前 1000 个非空行，如果至少 95% 的行第二列能编码成全拼，按 libime 文本处理；否则按纯词表处理，只取第一列。
- **大小上限**：输入文件不超过 256MiB；单本转换输出不超过 500 万条，超限报错。

### 2.4 安全边界

- 输入法进程只加载转换器写出的文件，或经过签名和哈希校验的官方文件。
- 用户提供的原始 `.dict`（scel／yaml／txt）只在设置进程里解析；输入法进程不接触这些原始格式。

## 三、存储与元数据

- 目录：macOS `~/Library/Application Support/Gogaku/dictionaries/`；Windows `%LOCALAPPDATA%\Gogaku\dictionaries\`。stable、dev、完整版、Lite 共用。
- 每本词库两个文件：`<id>.dict` 与 `<id>.json`。id 为 `import-<16位十六进制>`（导入），或官方 id（`[a-z0-9-]{1,64}`）。
- 元数据 schema 1，固定字段：

| 字段 | 说明 |
| --- | --- |
| `schemaVersion` | 常量 1 |
| `id` | 见上 |
| `name` | 显示名 |
| `origin` | `import` 或 `official` |
| `sourceFormat` | `scel`／`rime-yaml`／`libime-txt`／`libime-dict`／`plain-txt`（official 为构建时的源格式） |
| `sourceFileName` | 导入时的源文件名（official 为上游文件名） |
| `sourceContentId` | 源文件的 FNV-1a 64 位哈希（16 位十六进制）；重复导入据此拒绝 |
| `version` | 官方词库版本；导入词库为空串 |
| `license`／`attribution`／`sourceUrl` | 官方渠道写入；导入词库为空串 |
| `addedAt` | 挂载顺序依据（Unix 秒） |
| `entryCount` | 转换输出条数 |
| `dropped` | 丢弃计数对象（原因 → 数量） |
| `sizeBytes` | `.dict` 文件大小 |
| `contentId` | `.dict` 内容的 FNV-1a 64 位哈希（16 位十六进制） |
| `enabled` | 启用状态 |

- 文件写入全部用原子写（临时文件＋rename，沿用自定义词语与调频的规范）。损坏的元数据备份为 `<id>.json.corrupt` 并在页面提示；没有元数据的孤立 `.dict` 忽略（不加载、不显示）。删除时先删元数据、再删 `.dict`。
- 挂载顺序按 `addedAt` 升序。

## 四、挂载计划（核心一份实现）

- 每本词库预计内存 = 2×`sizeBytes`；启用词库合计超过 200MB 时设置页提醒（不阻止启用）。
- 学习引擎只挂：单本 ≤ 8MiB，且按挂载顺序累计 ≤ 16MiB 的启用词库。其余对学习引擎不可见。
- 停用等于卸载（普通引擎换空 trie＋Disabled 标记，学习引擎移出集合），释放内存。
- 槽位从 2 开始（0 出厂、1 用户词）；卸载用空 trie 替换并设 Disabled，空槽之后复用；尾部空槽用 `removeFrom` 收掉。
- 普通会话与学习会话共用同一份挂载实现。

## 五、C ABI（附加导出，版本保持 4）

JSON 出参一律为库内分配的 NUL 结尾 UTF-8，用 `gc_contract_free` 释放。

### 5.1 导入与元数据

```c
/* 返回码：0 成功；1 参数错误；2 格式或 I/O 错误；3 已取消；4 重复导入。 */
int gc_dict_import(const GcDictImportRequest *req,
                   int (*progress)(void *ctx, size_t done, size_t total),
                   void *ctx, char **result_json, char *err, size_t err_len);
```

- `req`：`input_path`、`dictionaries_dir`、`system_dict_path`（出厂词典，用于去重与读音推断）、`display_name`。
- 进度回调在调用方线程执行；返回非 0 表示取消（核心在下个检查点返回 3，已产生的临时文件清理，不留半成品）。
- `result_json`：`{id, name, entryCount, dropped:{...}, sizeBytes, contentId}`。

```c
int gc_dict_list(const char *dir, uint32_t flags, char **json);
/* flags bit0 = learningAvailable（完整版且学习翻译启用；否则每本 learning=false）。
 * 返回 {dictionaries:[{...metadata, normal:bool, learning:bool, estimatedBytes}],
 *       totalEnabled estimatedBytes, warn:bool, corrupt:[{id?, file}]}。 */
int gc_dict_set_enabled(const char *dir, const char *id, int32_t enabled, char *err, size_t err_len);
int gc_dict_remove(const char *dir, const char *id, char *err, size_t err_len);
int gc_dict_verify(const char *dir, const char *id, char **json, char *err, size_t err_len);
/* gc_dict_verify 重新计算 contentId；不一致时返回 2 且 json 里带 actual。 */
```

### 5.2 官方清单

```c
/* 清单原始字节先由平台验签（Ed25519），再调用本函数做字段与合同校验。
 * config_json: {trustedKeyIds:[...], installed:[{id,version}], allowDowngrade:false}
 * 返回 {dictionaries:[{...catalog entry, installed:bool, updateAvailable:bool}],
 *       rejected:[{id, reason}], catalogVersion}。
 * 返回码：0 成功；1 参数错误；2 合同不符（kind/keyId/schema/版本回滚）。 */
int gc_dict_catalog_parse(const uint8_t *bytes, size_t len,
                          const char *config_json, const char *installed_json,
                          char **json, char *err, size_t err_len);
int gc_dict_install(const char *dir, const char *downloaded_path,
                    const char *entry_json, char *err, size_t err_len);
/* 把官方词库文件放到位（校验 sha256→原子写→写元数据）；更新已有词库时保留原 enabled。 */
```

### 5.3 加载与挂载

```c
/* 可在任意线程调用；加载时校验 contentId（不符返回 2）。
 * handle 持有解析好的 trie，所有权随后交给核心或由 gc_dict_handle_free 释放。 */
int gc_dict_load(const char *dir, const char *id, GcDictHandle **handle, char *err, size_t err_len);
void gc_dict_handle_free(GcDictHandle *handle);

/* 调用方传入完整的目标集合（ids[i] 与 handles[i] 对应；handles[i] 可为 NULL 表示
 * 该 id 已挂载、保留现状）。返回 0 成功；3 = 组合进行中，本次调用被拒绝，
 * 调用方须在组合结束后的下一个事件前重试。 */
int gc_normal_dicts_apply(GcNormalSession *session,
                          const char *const *ids, GcDictHandle *const *handles, size_t n);
int gc_learning_dicts_apply(GcLearningSession *session,
                            const char *const *ids, GcDictHandle *const *handles, size_t n);
```

- apply 是幂等的全量集合操作：与当前挂载集合求差，新增的 `setTrie` 挂到复用槽或尾部，移除的换空 trie＋Disabled（尾部则 `removeFrom` 收掉）。
- `gc_learning_dicts_apply` 按挂载计划过滤（单本 ≤ 8MiB、累计 ≤ 16MiB），超限词库不挂。

## 六、重载通知

- **macOS**：设置应用写盘后发分布式通知 `org.gogaku.dictionaries.changed`。输入法进程在后台串行队列（QoS utility）用 `gc_dict_load` 解析词库，再回到引擎队列调用 `gc_normal_dicts_apply`／`gc_learning_dicts_apply`。学习会话创建后同样异步挂载符合条件的小词库。组合进行中 apply 返回 3，输入法缓存挂载意图，组合结束后（快照 `composing=0` 时）下一个事件前重试。
- **Windows**：设置应用经管道发 `op:"reload-dictionaries"`；代理的既有 watcher 循环每 500ms 额外检查一次 `dictionaries` 目录的 mtime。代理在后台线程 `gc_dict_load`，持 `core.mutex` 后对普通会话与每个连接的学习会话调用 apply；组合中返回 3 的处理同上。

## 七、官方渠道

- **配置**：`resources/dictionaries/catalog-config.json`（owner `gomeen`、repo `gogaku-dicts`），随设置应用打包。公钥复用检查更新的 trustedKeys（`gogaku-prod-2026`）。
- **清单**：`catalog.json`＋分离 Ed25519 签名 `catalog.json.sig`，从 `https://github.com/gomeen/gogaku-dicts/releases/latest/download/` 获取。字段：`schemaVersion: 1`、`kind: "gogaku-dictionary-catalog"`、`keyId`、单调递增的 `catalogVersion`、`dictionaries` 数组。数组每项：`id`、`name`、`category`、`description`、`version`、`license`、`attribution`、`sourceUrl`、`downloadUrl`、`size`、`sha256`、`entryCount`。
- `downloadUrl` 必须在该仓库 `releases/download/` 前缀下，主机白名单与检查更新相同。防回滚：`catalogVersion` 不得小于本地记录（本地记录随目录里任一官方词库元数据持久化；导入词库不影响）。
- **首批 13 本**：zhwiki（fcitx5-pinyin-zhwiki）与网络流行语各一本，CC BY-SA 4.0，署名维基百科贡献者与 fcitx5-pinyin-zhwiki，注明已过滤去重；THUOCL 11 个分类（IT、财经、法律、医学、饮食、地名、动物、成语、历史、古诗文、自然），MIT，按其 README 署名。
- **发布侧**：
  - `resources/dictionaries/sources.json` 锁定上游版本与 SHA-256。
  - `scripts/prepare-dictionary-sources.py` 下载上游数据并校验，存入缓存目录。
  - `scripts/build-dictionary-catalog.py` 调用核心工具 `gogaku_dict_tool`（与导入共用同一份转换实现）生成 `.dict` 与 `catalog.json`，并签名（复用发布签名环境）。
  - `scripts/publish-dictionaries.py` 先建 Draft、人工审阅后发布；支持 `--dry-run`。Release 正文附带署名与许可文本，并写明每本的丢弃计数。
- **客户端**：Mac 复用 `UpdateTransport` 与 CryptoKit；Windows 复用 WinHTTP、monocypher、CNG。只有用户点击「获取更多词库」才请求，不自动检查；离线、超时、404、验签失败、哈希不符、URL 越界分别给出不同提示，均不安装；下载可取消；请求不携带输入内容、凭据或设备标识。已安装词库显示版本，有新版显示「更新」。

## 八、验收与测试

- 核心 ctest：`dict_import`（五种格式、每个丢弃原因、每个错误码、大小上限、取消、重复导入）、`dict_catalog`（清单合同、签名对拍向量）、`dict_mount`（挂载、停用释放、删除中间一本、空槽复用、组合中延迟、学习阈值、删词提示、权重 0、英文排序不变）。
- 合成 scel 样本由入库脚本生成，不含搜狗数据。解析器模糊冒烟 2000 例无崩溃；ASan quick 无报错。
- 导入 170 万条 `.dict` 不超过 30 秒。
- 质量（release 档 quality）：120 例在只有出厂词库与挂上 zhwiki 两种情况下首选 ≥109／前十 ≥112；zhwiki 新词样本 300 例（固定种子）前九 ≥90%、首选 ≥60%；出厂词样本首选命中率下降不超过 1 个百分点。
- 性能：逐键 p95 增量 ≤ 0.5ms；apply ≤ 5ms；驻留内存增量 ≤ 文件大小的 2.2 倍。
- 其他场景：两个设置应用并发开关 40 轮终态一致；元数据损坏／`.dict` 篡改／磁盘满／中途取消不留半成品；stable 与 dev 同目录；删除词库后已学词仍可打出、清空调频一并清除；Lite 模式页面集合正确、Lite 构建无学习挂载；降级 0.4.x 输入法照常运行。

## 九、假设与默认值（常量集中在核心一处）

内存提醒阈值 200MB；预计内存按 2×文件大小；学习引擎阈值单本 8MiB／累计 16MiB；间隔号条目丢弃；带拼音格式保留含字母数字条目、纯词表只保留汉字；复用生产签名密钥与 trustedKeys、以 `kind` 区分清单；停用即卸载；挂载顺序按 addedAt；重复导入拒绝；首批官方词库 13 本全部发布并在发布记录写明丢弃计数。
