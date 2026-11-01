// 真实编码序列性能基准：普通模式核心逐键处理延迟分布（p50/p95/p99，分场景）。
//
// 优化目标（docs/validation/pre-user-test.md）：核心逐键处理（真实编码序列，
// 含候选生成）p95 ≤ 1ms。未达标返回 2，但不替代真实 IMK 的正式交付门槛。
// 此为共享核心耗时，不含宿主插字与面板渲染。
//
// 序列来自冻结的 120 条中文测试集（probes/input-engine-cases.json ＋
// input-engine-holdout.json，经 scripts/generate-core-cases.py 生成数组），
// 逐字符发出真实小鹤按键，并轮换场景：空格首选、↓导航后空格、`,`／`.` 翻页、
// 多音节分段选择（数字）、组合中标点、数字串、Shift 单击切换中英、Esc 取消。
// 调频路径通过重复选择触发；全部经过拼音解码，不再使用占位单字母。
// 逐键事件总数 ≥ 10000；统计保留全部样本（无剔除）。
//
// 运行前提：libime 出厂数据（sc.dict ＋ zh_CN.lm）。默认取
// ~/Library/Caches/Gogaku/libime-1.1.17/data，可用 GOGAKU_CORE_TEST_DATA 覆盖；
// 也可用 argv[1] argv[2] 显式指定词典与模型路径。
#include "gogaku_core.h"
#include "quality_cases.inc"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

uint64_t now_ns() {
    using namespace std::chrono;
    return duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count();
}

// 场景分类，分桶统计。
enum Bucket { B_SHORT, B_LONG, B_PAGE, B_PUNCT, B_SELECT, B_ENG, B_COUNT };

const char *bucket_name(int b) {
    switch (b) {
    case B_SHORT: return "短词(≤4键组合)";
    case B_LONG: return "长句(>4键组合)";
    case B_PAGE: return "翻页";
    case B_PUNCT: return "标点/数字";
    case B_SELECT: return "分段/数字选择";
    case B_ENG: return "英文直通/切换";
    }
    return "?";
}

struct ScriptItem {
    int32_t kind;
    std::string text;
    Bucket bucket;
};

}  // namespace

int main(int argc, char **argv) {
    const char *data = getenv("GOGAKU_CORE_TEST_DATA");
    std::string base = data != nullptr && *data != '\0' ? data
        : std::string(getenv("HOME") == nullptr ? "" : getenv("HOME")) + "/Library/Caches/Gogaku/libime-1.1.17/data";
    std::string dictPath = argc > 1 ? argv[1] : base + "/sc.dict";
    std::string modelPath = argc > 2 ? argv[2] : base + "/zh_CN.lm";

    GcNormalConfig cfg{};
    cfg.dict_path = dictPath.c_str();
    cfg.model_path = modelPath.c_str();
    cfg.scheme = GC_SCHEME_XIAOHE;
    cfg.full_pinyin_preedit = 1;
    cfg.freq_enabled = 1;
    cfg.english_enabled = 1;
    GcNormalSession *s = nullptr;
    char err[256] = {0};
    if (gc_normal_session_create(&cfg, &s, err, sizeof(err)) != 0) {
        fprintf(stderr, "session create failed: %s\n", err);
        return 1;
    }

    // 用冻结用例构造脚本：每条用例轮换一种确认方式，前 12 条额外重复两轮以
    // 触发调频学习路径（真实频率更新进入逐键计时）。
    std::vector<ScriptItem> script;
    script.reserve(4096);
    auto emit = [&](int32_t kind, const std::string &text, Bucket bucket) {
        script.push_back({kind, text, bucket});
    };
    auto emit_keys = [&](const char *keys, Bucket bucket) {
        for (const char *p = keys; *p != '\0'; ++p) emit(GC_EV_TEXT, std::string(1, *p), bucket);
    };
    int variant = 0;
    for (size_t ci = 0; ci < kQualityCaseCount; ++ci) {
        const QualityCase &c = kQualityCases[ci];
        int repeats = ci < 12 ? 3 : 1;  // 调频热路径：前 12 条各重复 3 次
        for (int r = 0; r < repeats; ++r) {
            const int v = (variant + (r == 0 ? 0 : r)) % 6;
            const Bucket b = static_cast<size_t>(c.syllables) <= 4 ? B_SHORT : B_LONG;
            switch (v) {
            case 0:  // 空格首选
                emit_keys(c.keys, b);
                emit(GC_EV_SPACE, "", b);
                break;
            case 1:  // ↓ 导航到第二项再空格
                emit_keys(c.keys, b);
                emit(GC_EV_DOWN, "", b);
                emit(GC_EV_SPACE, "", b);
                break;
            case 2:  // `.` 下翻 `,` 上翻再空格
                emit_keys(c.keys, b);
                emit(GC_EV_TEXT, ".", B_PAGE);
                emit(GC_EV_TEXT, ",", B_PAGE);
                emit(GC_EV_SPACE, "", b);
                break;
            case 3:  // 分段选择：输入前 4 键后数字 1（不完整覆盖时暂存继续）
                if (strlen(c.keys) > 4 && c.syllables >= 3) {
                    emit_keys(std::string(c.keys, c.keys + 4).c_str(), B_SELECT);
                    emit(GC_EV_TEXT, "1", B_SELECT);
                    emit_keys(c.keys + 4, b);
                    emit(GC_EV_SPACE, "", b);
                } else {
                    emit_keys(c.keys, b);
                    emit(GC_EV_SPACE, "", b);
                }
                break;
            case 4:  // 组合中标点＋数字串＋句号
                emit_keys(c.keys, b);
                emit(GC_EV_TEXT, ",", B_PUNCT);
                emit(GC_EV_TEXT, "2", B_PUNCT);
                emit(GC_EV_TEXT, "0", B_PUNCT);
                emit(GC_EV_TEXT, "2", B_PUNCT);
                emit(GC_EV_TEXT, "6", B_PUNCT);
                emit(GC_EV_TEXT, ".", B_PUNCT);
                break;
            case 5:  // Shift 单击切英文打一个词再切回；Esc 取消兜底
                emit_keys(c.keys, b);
                emit(GC_EV_TEXT, "1", B_SELECT);  // 数字选候选（部分选择场景）
                emit(GC_EV_SHIFT_CLICK, "", B_ENG);
                emit(GC_EV_TEXT, "g", B_ENG);
                emit(GC_EV_TEXT, "o", B_ENG);
                emit(GC_EV_SHIFT_CLICK, "", B_ENG);
                emit(GC_EV_ESC, "", b);
                break;
            }
            ++variant;
        }
    }

    size_t totalEvents = script.size();
    while (totalEvents < 10000) totalEvents += script.size();  // 补足 ≥1 万次
    const int passes = static_cast<int>(totalEvents / script.size());
    std::vector<uint64_t> samples;
    std::vector<std::vector<uint64_t>> byBucket(B_COUNT);
    samples.reserve(totalEvents);
    GcKeyEvent ev{};
    ev.app = "bench.app";
    ev.field = "f";
    int64_t t = 0;
    uint64_t totalNs = 0;
    int failures = 0;
    for (int pass = 0; pass < passes; ++pass) {
        for (const ScriptItem &item : script) {
            ev.kind = item.kind;
            ev.text = item.text.c_str();
            ev.time_ms = ++t;
            GcSnapshot *snap = nullptr;
            const uint64_t start = now_ns();
            int rc = gc_normal_handle(s, &ev, &snap);
            const uint64_t elapsed = now_ns() - start;
            if (rc != 0 || snap == nullptr) {
                fprintf(stderr, "handle failed kind=%d rc=%d\n", item.kind, rc);
                ++failures;
                continue;
            }
            gc_snapshot_free(snap);
            samples.push_back(elapsed);
            byBucket[item.bucket].push_back(elapsed);
            totalNs += elapsed;
        }
    }

    auto report = [&](const char *label, const std::vector<uint64_t> &xs) {
        if (xs.empty()) return;
        std::vector<uint64_t> sorted = xs;
        std::sort(sorted.begin(), sorted.end());
        auto pct = [&](double p) {
            size_t idx = static_cast<size_t>(p * (sorted.size() - 1));
            return sorted[idx] / 1000.0;  // µs
        };
        uint64_t sum = 0;
        for (uint64_t v : xs) sum += v;
        fprintf(stderr, "  %-14s n=%-6zu mean=%8.1fµs p50=%8.1fµs p95=%9.1fµs p99=%9.1fµs max=%10.1fµs\n",
                label, xs.size(), sum / 1000.0 / xs.size(), pct(0.50), pct(0.95), pct(0.99),
                sorted.back() / 1000.0);
    };

    fprintf(stderr, "真实序列基准：%zu 条用例脚本 × %d 轮 = %zu 事件\n",
            kQualityCaseCount, passes, samples.size());
    report("全部", samples);
    for (int b = 0; b < B_COUNT; ++b) report(bucket_name(b), byBucket[b]);

    std::vector<uint64_t> sorted = samples;
    std::sort(sorted.begin(), sorted.end());
    const double p95us = sorted[static_cast<size_t>(0.95 * (sorted.size() - 1))] / 1000.0;
    const double p99us = sorted[static_cast<size_t>(0.99 * (sorted.size() - 1))] / 1000.0;
    fprintf(stderr, "核心逐键 p95 %.3f ms（p99 %.3f ms）— 优化目标 p95 ≤ 1ms：%s\n",
            p95us / 1000.0, p99us / 1000.0, (p95us <= 1000.0 && failures == 0) ? "PASS" : "FAIL");
    gc_normal_session_destroy(s);
    return (p95us <= 1000.0 && failures == 0) ? 0 : 2;
}
