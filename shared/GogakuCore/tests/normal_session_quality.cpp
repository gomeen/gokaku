// 中文质量回归：120 条冻结测试集（probes/input-engine-cases.json ＋ holdout）
// 首选命中不低于既有基准（首选 109／前十 112），且启用调频、自定义词语后
// 不改变未涉及词语的排序；英文候选排序规则抽样核对。
//
// 运行前提：libime 出厂数据（sc.dict ＋ zh_CN.lm）。默认取
// ~/Library/Caches/Gogaku/libime-1.1.17/data，可用 GOGAKU_CORE_TEST_DATA 覆盖。
// 门槛数字（109／112）来自 docs/input-selection-decision.md 对同一测试集的
// libime 出厂数据测量；本测试用同一按键与同一模型验证当前核心不倒退。
#include "gogaku_core.h"

#include <unistd.h>
#include "quality_cases.inc"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace {

int g_failures = 0;
int g_checks = 0;

void check(bool ok, const std::string &what) {
    ++g_checks;
    if (!ok) {
        ++g_failures;
        fprintf(stderr, "  FAIL: %s\n", what.c_str());
    }
}

void check_eq(int got, int want, const std::string &what) {
    ++g_checks;
    if (got != want) {
        ++g_failures;
        fprintf(stderr, "  FAIL: %s（got %d want %d）\n", what.c_str(), got, want);
    }
}

const char *kEnglishList =
    "company\n"      // 词频降序：com 前缀的顺序即列表顺序
    "compare\n"
    "compact\n"
    "min\n"
    "mind\n"
    "hello\n"
    "help\n"
    "helix\n";

struct CaseEnv {
    std::string dir;
    std::string dictPath;
    std::string modelPath;
    std::string wordsPath;
    std::string englishPath;
};

bool make_env(CaseEnv &env) {
    const char *dataDir = getenv("GOGAKU_CORE_TEST_DATA");
    std::string base = dataDir != nullptr && *dataDir != '\0' ? dataDir
        : std::string(getenv("HOME") == nullptr ? "" : getenv("HOME")) + "/Library/Caches/Gogaku/libime-1.1.17/data";
    env.modelPath = base + "/zh_CN.lm";
    env.dictPath = base + "/sc.dict";
    std::ifstream probe(env.modelPath, std::ios::binary), probe2(env.dictPath, std::ios::binary);
    if (!probe || !probe2) {
        // 复查 E1：缺数据必须显式区分于通过。
        fprintf(stderr, "SKIP: 未找到 libime 出厂数据（%s／%s）\n", env.dictPath.c_str(), env.modelPath.c_str());
        exit(3);
    }
    char tpl[] = "/tmp/gogaku-quality-XXXXXX";
    if (mkdtemp(tpl) == nullptr) return false;
    env.dir = tpl;
    env.wordsPath = env.dir + "/custom-words.tsv";
    env.englishPath = env.dir + "/english-words.txt";
    { std::ofstream out(env.englishPath, std::ios::binary); out << kEnglishList; }
    return true;
}

GcNormalSession *make_session(const CaseEnv &env, bool freqEnabled = true,
                              const char *customWordsPath = nullptr) {
    GcNormalConfig cfg{};
    cfg.dict_path = env.dictPath.c_str();
    cfg.model_path = env.modelPath.c_str();
    cfg.user_dir = env.dir.c_str();
    cfg.custom_words_path = customWordsPath;
    cfg.english_words_path = env.englishPath.c_str();
    cfg.scheme = GC_SCHEME_XIAOHE;
    cfg.full_pinyin_preedit = 1;
    cfg.freq_enabled = freqEnabled ? 1 : 0;
    cfg.english_enabled = 1;
    GcNormalSession *s = nullptr;
    char err[256] = {0};
    if (gc_normal_session_create(&cfg, &s, err, sizeof(err)) != 0) {
        fprintf(stderr, "session create failed: %s\n", err);
        return nullptr;
    }
    return s;
}

GcSnapshot *send(GcNormalSession *s, int32_t kind, const std::string &text = "", int64_t time_ms = 0) {
    GcKeyEvent ev{};
    ev.kind = kind;
    ev.time_ms = time_ms;
    ev.text = text.c_str();
    ev.app = "quality.app";
    ev.field = "f1";
    GcSnapshot *snap = nullptr;
    if (gc_normal_handle(s, &ev, &snap) != 0) return nullptr;
    return snap;
}

struct DelSnap {
    GcSnapshot *p;
    ~DelSnap() { if (p) gc_snapshot_free(p); }
};

// 平台确认宿主插入成功（ABI 版本 4）：确认后才调频学习。
void confirm(GcNormalSession *s, int64_t t) { GcSnapshot *p = send(s, GC_EV_COMMIT_CONFIRMED, "", t); delete p; }

// 只键入按键，返回最后一个按键事件的候选快照（调用方释放）。
GcSnapshot *type_keys(GcNormalSession *s, const char *keys, int64_t t = 0) {
    GcSnapshot *snap = nullptr;
    for (const char *p = keys; *p != '\0'; ++p) {
        delete snap;
        snap = send(s, GC_EV_TEXT, std::string(1, *p), t);
    }
    return snap;
}

bool is_chinese(const GcCandidate &c) { return c.kind == GC_CAND_CHINESE || c.kind == GC_CAND_LEARNED; }

bool is_target(const GcSnapshot *snap, size_t index, const QualityCase &c) {
    if (snap == nullptr || index >= snap->count) return false;
    if (!is_chinese(snap->candidates[index])) return false;
    for (size_t t = 0; t < c.target_count; ++t) {
        if (strcmp(snap->candidates[index].text, c.targets[t]) == 0) return true;
    }
    return false;
}

// 前 10 个中文候选里命中目标的下标（相对首位中文候选）；-1 未命中。
int hit_within10(const GcSnapshot *snap, const QualityCase &c) {
    int seen = 0;
    for (size_t i = 0; snap != nullptr && i < snap->count; ++i) {
        if (!is_chinese(snap->candidates[i])) continue;
        if (seen == 10) break;
        for (size_t t = 0; t < c.target_count; ++t) {
            if (strcmp(snap->candidates[i].text, c.targets[t]) == 0) return seen;
        }
        ++seen;
    }
    return -1;
}

// 前 10 个中文候选文本（忽略英文／自定义块，避免数据开关影响比较）。
std::vector<std::string> top_chinese(const GcSnapshot *snap, size_t n) {
    std::vector<std::string> out;
    if (snap == nullptr) return out;
    for (size_t i = 0; i < snap->count && out.size() < n; ++i) {
        if (is_chinese(snap->candidates[i])) out.emplace_back(snap->candidates[i].text);
    }
    return out;
}

void clear_composition(GcNormalSession *s) { do { GcSnapshot *p = send(s, GC_EV_ESC, ""); delete p; } while (0); }

}  // namespace

int main() {
    CaseEnv env;
    if (!make_env(env)) return 0;

    // ── 基线：出厂词典，调频开，无自定义词、无历史 ───────────────────
    int firstHit = 0, top10Hit = 0;
    std::vector<std::vector<std::string>> baselineTop10(kQualityCaseCount);
    {
        GcNormalSession *s = make_session(env);
        if (s == nullptr) return 1;
        int64_t t = 0;
        for (size_t ci = 0; ci < kQualityCaseCount; ++ci) {
            const QualityCase &c = kQualityCases[ci];
            GcSnapshot *snap = type_keys(s, c.keys, ++t);
            if (is_target(snap, 0, c)) ++firstHit;
            if (hit_within10(snap, c) >= 0) ++top10Hit;
            baselineTop10[ci] = top_chinese(snap, 10);
            delete snap;
            clear_composition(s);
        }
        gc_normal_session_destroy(s);
    }
    fprintf(stderr, "质量基线：首选 %d／120，前十 %d／120（历史基准 109／112）\n", firstHit, top10Hit);
    check(firstHit >= 109, "首选命中 ≥109");
    check(top10Hit >= 112, "前十命中 ≥112");

    // ── 空格确认与候选一致（首选命中的用例）──────────────────────────
    {
        GcNormalSession *s = make_session(env);
        if (s == nullptr) return 1;
        int64_t t = 0;
        int commitMismatches = 0;
        for (size_t ci = 0; ci < kQualityCaseCount; ++ci) {
            const QualityCase &c = kQualityCases[ci];
            GcSnapshot *snap = type_keys(s, c.keys, ++t);
            const bool first = is_target(snap, 0, c);
            delete snap;
            if (!first) { clear_composition(s); continue; }
            DelSnap commit{send(s, GC_EV_SPACE, "", ++t)};
            confirm(s, ++t);   // 空格上屏成功→确认→调频
            bool ok = commit.p != nullptr;
            if (ok) {
                ok = false;
                for (size_t k = 0; k < c.target_count; ++k) {
                    if (strcmp(commit.p->commit, c.targets[k]) == 0) ok = true;
                }
            }
            if (!ok) ++commitMismatches;
        }
        check_eq(commitMismatches, 0, "空格确认上屏文本＝首选目标");
        gc_normal_session_destroy(s);
    }

    // ── 调频开关本身不改变排序（同一无历史状态，仅开关不同）──────────
    {
        GcNormalSession *s = make_session(env, false);
        if (s == nullptr) return 1;
        int64_t t = 0;
        int disturbed = 0;
        for (size_t ci = 0; ci < kQualityCaseCount; ++ci) {
            GcSnapshot *snap = type_keys(s, kQualityCases[ci].keys, ++t);
            if (top_chinese(snap, 10) != baselineTop10[ci]) ++disturbed;
            delete snap;
            clear_composition(s);
        }
        check_eq(disturbed, 0, "调频关闭与开启（无历史）排序一致");
        gc_normal_session_destroy(s);
    }

    // ── 调频学习后未涉及用例排序不变 ─────────────────────────────────
    // 只对首选命中的用例确认其目标（学习真实目标词），其余用例视为未涉及。
    {
        GcNormalSession *s = make_session(env);
        if (s == nullptr) return 1;
        int64_t t = 0;
        std::vector<bool> involved(kQualityCaseCount, false);
        for (size_t ci = 0; ci < kQualityCaseCount; ++ci) {
            const QualityCase &c = kQualityCases[ci];
            GcSnapshot *snap = type_keys(s, c.keys, ++t);
            involved[ci] = is_target(snap, 0, c);
            delete snap;
            if (involved[ci]) {
                DelSnap commit{send(s, GC_EV_SPACE, "", ++t)};  // 确认目标＝调频学习
                confirm(s, ++t);   // 平台确认上屏成功后才学习
            } else {
                clear_composition(s);
            }
        }
        int disturbed = 0;
        for (size_t ci = 0; ci < kQualityCaseCount; ++ci) {
            if (involved[ci]) continue;
            GcSnapshot *snap = type_keys(s, kQualityCases[ci].keys, ++t);
            if (top_chinese(snap, 10) != baselineTop10[ci]) ++disturbed;
            delete snap;
            clear_composition(s);
        }
        check_eq(disturbed, 0, "调频学习后未涉及用例排序不变");
        gc_normal_session_destroy(s);
    }

    // ── 无关自定义词不改变任何用例排序 ───────────────────────────────
    {
        // 短码 "qq" 与拼音词 ta'le 在 120 条用例按键中均无完整匹配。
        const char *content = "#gogaku-custom-words\tv1\n"
                              "0\t1\tqq\t\t应急短语\n"
                              "1\t1\t\tta'le\t踏乐\n";
        { std::ofstream out(env.wordsPath, std::ios::binary); out << content; }
        for (size_t ci = 0; ci < kQualityCaseCount; ++ci) {
            if (strcmp(kQualityCases[ci].keys, "qq") == 0 || strcmp(kQualityCases[ci].keys, "tl") == 0) {
                fprintf(stderr, "SKIP: 用例按键与测试自定义词冲突\n");
                return 0;
            }
        }
        GcNormalSession *s = make_session(env, true, env.wordsPath.c_str());
        if (s == nullptr) return 1;
        int64_t t = 0;
        int disturbed = 0;
        for (size_t ci = 0; ci < kQualityCaseCount; ++ci) {
            GcSnapshot *snap = type_keys(s, kQualityCases[ci].keys, ++t);
            if (top_chinese(snap, 10) != baselineTop10[ci]) ++disturbed;
            delete snap;
            clear_composition(s);
        }
        check_eq(disturbed, 0, "无关自定义词不改变任何用例排序");
        gc_normal_session_destroy(s);
        remove(env.wordsPath.c_str());
    }

    // ── 英文候选排序规则抽样 ────────────────────────────────────────
    {
        GcNormalSession *s = make_session(env);
        if (s == nullptr) return 1;
        {   // 中文能完整覆盖（出厂数据）→ 英文整词与前缀补全排第二位，
            // 前缀补全 ≤3 且按词表（词频降序）；3 字输入不出现前缀补全。
            const char *keys = "compa";
            GcSnapshot *snap = nullptr;
            for (const char *p = keys; *p != '\0'; ++p) {
                delete snap;
                snap = send(s, GC_EV_TEXT, std::string(1, *p), 0);
            }
            check(snap != nullptr && snap->count > 0 && is_chinese(snap->candidates[0]),
                  "中文完整覆盖时中文首位");
            check(snap != nullptr && snap->count > 1 && strcmp(snap->candidates[1].text, "company") == 0,
                  "英文整词／补全排第二");
            check(snap != nullptr && snap->count > 2 && strcmp(snap->candidates[2].text, "compare") == 0,
                  "前缀补全按词频序 1");
            check(snap != nullptr && snap->count > 3 && strcmp(snap->candidates[3].text, "compact") == 0,
                  "前缀补全按词频序 2");
            int englishCount = 0;
            for (size_t i = 0; snap != nullptr && i < snap->count; ++i) {
                if (snap->candidates[i].kind == GC_CAND_ENGLISH) ++englishCount;
            }
            check(englishCount == 3, "前缀补全 ≤3");
            delete snap;
            clear_composition(s);
        }
        {   // 整词一致（≥3 字）出现在中文首位之后；3 字输入无前缀补全。
            const char *keys = "min";
            GcSnapshot *snap = nullptr;
            for (const char *p = keys; *p != '\0'; ++p) {
                delete snap;
                snap = send(s, GC_EV_TEXT, std::string(1, *p), 0);
            }
            check(snap != nullptr && snap->count > 1 && snap->candidates[1].kind == GC_CAND_ENGLISH
                      && strcmp(snap->candidates[1].text, "min") == 0,
                  "整词一致排在中文首位之后");
            bool noPrefix = true;
            for (size_t i = 2; snap != nullptr && i < snap->count; ++i) {
                if (snap->candidates[i].kind == GC_CAND_ENGLISH) noPrefix = false;
            }
            check(noPrefix, "3 字输入不出现前缀补全");
            delete snap;
            clear_composition(s);
        }
        gc_normal_session_destroy(s);
    }

    fprintf(stderr, "质量回归：%d 项检查，失败 %d — %s\n", g_checks, g_failures,
            g_failures == 0 ? "PASS" : "FAIL");
    return g_failures == 0 ? 0 : 2;
}
