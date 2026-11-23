// Gogaku Lite：不编入学习会话，仅提供 ABI 占位符号供链接。
#include "gogaku_core.h"
#include <cstdlib>
#include <cstring>

extern "C" int gc_learning_session_create(const GcLearningConfig *, GcLearningSession **out, char *err, size_t err_len) {
    if (out) *out = nullptr;
    if (err && err_len) {
        const char msg[] = "Gogaku Lite 未包含学习模式";
        size_t n = sizeof(msg) - 1;
        if (n >= err_len) n = err_len - 1;
        memcpy(err, msg, n);
        err[n] = '\0';
    }
    return 1;
}

extern "C" void gc_learning_session_destroy(GcLearningSession *) {}

extern "C" int gc_learning_handle(GcLearningSession *, const GcLearningEvent *, GcLearningSnapshot **out) {
    if (out) *out = nullptr;
    return 1;
}

extern "C" void gc_learning_snapshot_free(GcLearningSnapshot *snapshot) {
    if (!snapshot) return;
    if (snapshot->sources) free(snapshot->sources);
    if (snapshot->candidates) free(snapshot->candidates);
    if (snapshot->issues) free(snapshot->issues);
    if (snapshot->raw) free(snapshot->raw);
    if (snapshot->preedit) free(snapshot->preedit);
    if (snapshot->status) free(snapshot->status);
    if (snapshot->commit_text) free(snapshot->commit_text);
    if (snapshot->commit_recovery_raw) free(snapshot->commit_recovery_raw);
    free(snapshot);
}

extern "C" int gc_learning_dicts_apply(GcLearningSession *, const char *const *,
                                       GcDictHandle *const *, size_t) {
    return 2;  // Lite 无学习会话：挂载不可用。
}

extern "C" int gc_learning_dicts_mounted(GcLearningSession *, char **json) {
    if (json) {
        char *empty = static_cast<char *>(std::malloc(3));
        if (empty) {
            memcpy(empty, "[]", 3);
            *json = empty;
        }
    }
    return 0;
}
