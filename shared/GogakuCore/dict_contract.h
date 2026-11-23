/* 扩展词库契约（导入转换、元数据、清单、加载挂载）的共享声明。
 *
 * 实现在 dict_contract.cpp；行为向量在 tests/dict_import_test.cpp 与
 * tests/dict_catalog_test.cpp，两端跑同一份源码。合同全文见
 * docs/dictionaries.md：存储目录、元数据 schema 1、转换过滤规则、
 * 挂载计划（学习阈值）与官方渠道签名清单。
 *
 * 本组导出全部是附加接口：不改动任何已有结构布局与函数签名，
 * GOGAKU_CORE_ABI_VERSION 保持 4。返回的 JSON 用 gc_contract_free 释放。
 * 核心不建线程：导入与加载的线程由平台提供，进度回调在调用方线程执行。
 */
#ifndef GOGAKU_DICT_CONTRACT_H
#define GOGAKU_DICT_CONTRACT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* gc_dict_load 产出的已解析词库。对平台不透明：所有权可交给
 * gc_normal_dicts_apply／gc_learning_dicts_apply（挂载成功后由核心释放），
 * 未移交的句柄用 gc_dict_handle_free 释放。可在任意线程创建，
 * 同一句柄只允许移交一次。 */
typedef struct GcDictHandle GcDictHandle;

/* gc_dict_import 的请求参数；全部 UTF-8 路径，字符串生命周期覆盖调用。 */
typedef struct GcDictImportRequest {
    const char *input_path;        /* 用户提供的源文件；必填 */
    const char *dictionaries_dir;  /* 词库目录（不存在时创建）；必填 */
    const char *system_dict_path;  /* libime 出厂词典（去重与读音推断）；必填 */
    const char *display_name;      /* 显示名；NULL/空用源文件名（去扩展名） */
} GcDictImportRequest;

/* 导入返回码，也用于 gc_dict_install／gc_dict_load 等的通用错误分层：
 * 0 成功；1 参数错误；2 格式或 I/O 错误；3 已取消；4 重复导入。 */

/* 导入一个源文件：识别格式→解析→过滤→写出 <id>.dict 与 <id>.json。
 * 进度回调在调用方线程执行（done/total 为解析阶段条目数），返回非 0 表示
 * 取消：核心清理临时文件后返回 3，不留半成品。
 * result_json 可为 NULL；非 NULL 时写入
 * {id,name,entryCount,dropped:{...},sizeBytes,contentId}。
 * err/err_len 可为 NULL，写入可读原因（重复导入时含冲突 id）。 */
GOGAKU_CORE_EXPORT int gc_dict_import(const GcDictImportRequest *req,
                                      int (*progress)(void *ctx, size_t done, size_t total),
                                      void *ctx, char **result_json,
                                      char *err, size_t err_len);

/* 列出词库目录。flags bit0 = learningAvailable（完整版且学习翻译启用；
 * 未置位时每本 learning=false）。corrupt 元数据备份为 <file>.corrupt 并在
 * 结果里报告。返回：
 * {dictionaries:[{<元数据字段...>, normal, learning, estimatedBytes}],
 *  enabledEstimatedBytes, warn, corrupt:[{file, reason}]} */
GOGAKU_CORE_EXPORT int gc_dict_list(const char *dir, uint32_t flags, char **json);

/* 启用／停用一本词库（写回元数据，保留未知字段）。返回 0 成功；1 参数错误；
 * 2 未找到或 I/O 失败。 */
GOGAKU_CORE_EXPORT int gc_dict_set_enabled(const char *dir, const char *id,
                                           int32_t enabled, char *err, size_t err_len);

/* 删除一本词库：先删元数据，再删 .dict。返回 0 成功；1 参数错误；2 未找到或
 * I/O 失败。 */
GOGAKU_CORE_EXPORT int gc_dict_remove(const char *dir, const char *id,
                                      char *err, size_t err_len);

/* 重新计算 <id>.dict 的 contentId 并与元数据比对。
 * 一致返回 0；不一致返回 2，json 写入 {expected, actual}；
 * 参数错误 1；未找到或 I/O 3。 */
GOGAKU_CORE_EXPORT int gc_dict_verify(const char *dir, const char *id,
                                      char **json, char *err, size_t err_len);

/* 官方清单合同校验（签名由平台先行验证，本函数只做字段与合同）。
 * bytes/len 为清单原始字节；config_json：
 * {trustedKeyIds:["gogaku-prod-2026",...], downloadPrefix:"https://github.com/<o>/<r>/releases/download/",
 *  catalogVersion:<本地记录，防回滚>}；installed_json：[{id,version}]（可空数组）。
 * 返回 {dictionaries:[{<清单字段...>, installed, updateAvailable}], rejected:[{id,reason}],
 *       catalogVersion}。返回码：0 成功；1 参数错误；2 合同不符
 * （kind／keyId／schema／catalogVersion 回滚）；3 清单 JSON 非法。 */
GOGAKU_CORE_EXPORT int gc_dict_catalog_parse(const uint8_t *bytes, size_t len,
                                             const char *config_json,
                                             const char *installed_json,
                                             char **json, char *err, size_t err_len);

/* 安装官方词库：校验 sha256 与清单 size→加载校验→原子写 <id>.dict 与 <id>.json。
 * entry_json 为 gc_dict_catalog_parse 结果里的一项（含 catalogVersion）。
 * 更新已有词库时保留原 enabled。返回码同导入（4 = sha256/size 不符）。 */
GOGAKU_CORE_EXPORT int gc_dict_install(const char *dir, const char *downloaded_path,
                                       const char *entry_json, char *err, size_t err_len);

/* 把词库解析成可挂载的 trie：读取 <id>.dict，校验 contentId 与元数据一致。
 * 可在任意线程调用。返回 0 成功；1 参数错误；2 contentId 不符；
 * 3 未找到或格式错误。 */
GOGAKU_CORE_EXPORT int gc_dict_load(const char *dir, const char *id,
                                    GcDictHandle **handle, char *err, size_t err_len);
GOGAKU_CORE_EXPORT void gc_dict_handle_free(GcDictHandle *handle);

/* 把目标集合应用到普通会话（调用方传完整集合；ids[i] 与 handles[i] 对应，
 * handles[i] 为 NULL 表示该 id 保留已挂载现状）。幂等求差：新增 setTrie 挂到
 * 复用槽或尾部（槽位从 2 起），移除换空 trie＋Disabled、尾部空槽 removeFrom 收掉。
 * 组合进行中返回 3，调用方在组合结束后的下一个事件前重试；成功移交的句柄
 * 由核心释放。返回 0 成功；1 参数错误；2 内部错误；3 组合进行中。 */
GOGAKU_CORE_EXPORT int gc_normal_dicts_apply(GcNormalSession *session,
                                             const char *const *ids,
                                             GcDictHandle *const *handles, size_t n);

/* 同 gc_normal_dicts_apply，作用于学习会话；按挂载计划过滤（单本 ≤8MiB 且
 * 按挂载顺序累计 ≤16MiB，超限词库不挂）。学习桩（Lite）返回 2。 */
GOGAKU_CORE_EXPORT int gc_learning_dicts_apply(GcLearningSession *session,
                                               const char *const *ids,
                                               GcDictHandle *const *handles, size_t n);

/* 会话当前挂载的词库 id 集合（调试与测试用；JSON 数组）。返回 0 成功。 */
GOGAKU_CORE_EXPORT int gc_normal_dicts_mounted(GcNormalSession *session, char **json);
GOGAKU_CORE_EXPORT int gc_learning_dicts_mounted(GcLearningSession *session, char **json);

#ifdef __cplusplus
}
#endif
#endif
