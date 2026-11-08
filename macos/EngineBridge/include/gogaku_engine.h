#ifndef GOGAKU_ENGINE_H
#define GOGAKU_ENGINE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* 单线程拥有 handle。所有字符串是独立 UTF-8 副本，仅用 ge_snapshot_free 释放。 */
typedef struct GEEngine GEEngine;
typedef struct {
    char *text;
    size_t index;
    size_t raw_start; /* ASCII 编码偏移，绝非 UTF-16 文本范围 */
    size_t raw_length;
    int completes;
} GECandidate;
typedef struct {
    char *raw;
    char *preedit;
    char *selected;
    char *commit;
    GECandidate *candidates;
    size_t count;
    size_t total;
    size_t page;
    size_t selected_length;
    int composing;
} GESnapshot;
enum GEOperation { GE_PEEK, GE_TYPE, GE_BACKSPACE, GE_SELECT, GE_CANCEL, GE_PAGE, GE_CURSOR };
/* 错误码：0 成功、1 参数/范围无效、2 资源/引擎失败；不跨 ABI 抛出异常。 */
int ge_create(const char *dictionary, const char *model, GEEngine **out);
void ge_destroy(GEEngine *engine);
int ge_command(GEEngine *engine, int operation, int64_t argument, GESnapshot **out);
void ge_snapshot_free(GESnapshot *snapshot);
#ifdef __cplusplus
}
#endif
#endif
