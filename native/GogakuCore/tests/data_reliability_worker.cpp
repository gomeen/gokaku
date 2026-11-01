// 数据可靠性测试辅助进程：在指定目录反复执行「学习→flush」循环。
// 由 probes/validate-data-reliability.py 启动并在随机时刻 SIGKILL，
// 用于验证 model.userlm／learned.txt 在任意时刻被杀后不损坏或可自动恢复。
// verify 模式：在给定目录创建会话（应成功，损坏自动备份）并报告状态。
//
// 用法：gogaku_data_reliability_worker <userDir> <iterations>
//       gogaku_data_reliability_worker --verify <userDir>
#include "gogaku_core.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

int main(int argc, char **argv) {
    if (argc < 3) return 1;
    const char *dataDir = getenv("GOGAKU_CORE_TEST_DATA");
    std::string base = dataDir != nullptr && *dataDir != '\0' ? dataDir
        : std::string(getenv("HOME") == nullptr ? "" : getenv("HOME")) + "/Library/Caches/Gogaku/libime-1.1.17/data";

    const bool verify = strcmp(argv[1], "--verify") == 0;
    const char *userDir = verify ? argv[2] : argv[1];
    const int iterations = verify ? 0 : atoi(argv[2]);

    GcNormalConfig cfg{};
    std::string dict = base + "/sc.dict", model = base + "/zh_CN.lm";
    cfg.dict_path = dict.c_str();
    cfg.model_path = model.c_str();
    cfg.user_dir = userDir;
    cfg.freq_enabled = 1;

    if (verify) {
        GcNormalSession *s = nullptr;
        char err[256] = {0};
        const int rc = gc_normal_session_create(&cfg, &s, err, sizeof(err));
        if (rc != 0) {
            printf("VERIFY-FAIL %s\n", err);
            return 2;
        }
        // 能正常输入＋flush（损坏恢复后的完整路径）。
        GcKeyEvent ev{};
        static const char *keys = "nihc";
        for (const char *p = keys; *p != '\0'; ++p) {
            static std::string ch; ch = std::string(1, *p);
            ev.kind = GC_EV_TEXT; ev.text = ch.c_str(); ev.app = "rel.app"; ev.field = "f";
            GcSnapshot *snap = nullptr;
            if (gc_normal_handle(s, &ev, &snap) != 0) { printf("VERIFY-FAIL handle\n"); return 2; }
            gc_snapshot_free(snap);
        }
        ev.kind = GC_EV_SPACE; ev.text = nullptr; ev.app = "rel.app"; ev.field = "f";
        GcSnapshot *snap = nullptr;
        if (gc_normal_handle(s, &ev, &snap) != 0) { printf("VERIFY-FAIL space\n"); return 2; }
        gc_snapshot_free(snap);
        if (gc_normal_flush(s) != 0) { printf("VERIFY-FAIL flush\n"); return 2; }
        gc_normal_session_destroy(s);
        printf("VERIFY-OK\n");
        return 0;
    }

    for (int i = 0; i < iterations; ++i) {
        GcNormalSession *s = nullptr;
        char err[256] = {0};
        if (gc_normal_session_create(&cfg, &s, err, sizeof(err)) != 0) {
            fprintf(stderr, "create failed: %s\n", err);
            return 2;
        }
        // 学习（nihc→你好）触发 modelDirty＋learnedDirty，随后 flush 走两条写盘路径。
        GcKeyEvent ev{};
        static const char *keys = "nihc";
        for (const char *p = keys; *p != '\0'; ++p) {
            static std::string ch; ch = std::string(1, *p);
            ev.kind = GC_EV_TEXT; ev.text = ch.c_str(); ev.app = "rel.app"; ev.field = "f";
            ev.time_ms = i * 10;
            GcSnapshot *snap = nullptr;
            if (gc_normal_handle(s, &ev, &snap) != 0) return 2;
            gc_snapshot_free(snap);
        }
        ev.kind = GC_EV_SPACE; ev.text = nullptr; ev.time_ms = i * 10 + 1;
        GcSnapshot *snap = nullptr;
        if (gc_normal_handle(s, &ev, &snap) != 0) return 2;
        gc_snapshot_free(snap);
        if (gc_normal_flush(s) != 0) return 2;
        gc_normal_session_destroy(s);
    }
    printf("DONE\n");
    return 0;
}
