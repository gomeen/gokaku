// 普通模式核心分项成本基准：拆测 libime 解码、候选获取／转换、合并、查询、
// 快照各阶段耗时，并记录全部原始样本（CSV）。
//
// 与 tests/normal_session_bench.cpp 的区别：
//   - normal_session_bench 测的是端到端逐键延迟（公开 C ABI 路径）；
//   - 本工具直接用 libime 复刻核心内部各阶段，分别计时，回答
//     「时间花在解码、候选转换、释义／学习词查询、合并还是快照」。
//
// 阶段定义（同一状态下依次测量，可相加）：
//   decode        libime 解码：PinyinContext::type（含候选生成）
//   fetch         候选获取：candidatesToCursor（光标受限时生成截断候选）
//   convert200    旧实现：把最多 200 条中文候选转成字符串（含暂存前缀拼接）
//   lookup200     旧实现：对 200 条候选各查 2 次释义 ＋ 1 次学习词
//   merge_identity 新实现：只算候选身份与总数（不生成文本）
//   materialize18 新实现：只转换当前页＋下一页（≤18 项）的文本与查询
//   snapshot9     快照：复制一页 9 项候选（含 C 字符串分配）
//
// 另做端到端消融（走公开 C ABI）：英文候选开／关、释义表在／不在，
// 用于把剩余的非解码成本归因到具体数据面。
//
// 运行前提：libime 出厂数据（sc.dict ＋ zh_CN.lm）；可选
// GOGAKU_CORE_TEST_DATA 指定目录，GOGAKU_CORE_PROFILE_OUT 指定 CSV 输出路径
// （默认 bench/results/normal-session-profile-samples.csv），
// GOGAKU_CORE_PROFILE_ROOT 指定仓库根（用于找 resources/ 下的英文词表与释义表）。
// 默认输出到**当前工作目录**下的 bench/results/（请在 shared/GogakuCore 下运行），
// 也可用 GOGAKU_CORE_PROFILE_OUT 指定绝对路径。
#include "gogaku_core.h"
#include "quality_cases.inc"

#include <libime/core/userlanguagemodel.h>
#include <libime/pinyin/pinyincontext.h>
#include <libime/pinyin/pinyindictionary.h>
#include <libime/pinyin/pinyinime.h>
#include <libime/pinyin/shuangpinprofile.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

uint64_t now_ns() {
    using namespace std::chrono;
    return duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count();
}

constexpr size_t kMaxChineseCandidates = 200;
constexpr size_t kPageSize = 9;

struct Env {
    std::string dictPath;
    std::string modelPath;
    std::string englishPath;
    std::string glossPath;
};

bool make_env(Env &env) {
    const char *dataDir = getenv("GOGAKU_CORE_TEST_DATA");
    std::string base = dataDir != nullptr && *dataDir != '\0' ? dataDir
        : std::string(getenv("HOME") == nullptr ? "" : getenv("HOME")) + "/Library/Caches/Gogaku/libime-1.1.17/data";
    env.dictPath = base + "/sc.dict";
    env.modelPath = base + "/zh_CN.lm";
    std::ifstream probe(env.modelPath, std::ios::binary), probe2(env.dictPath, std::ios::binary);
    if (!probe || !probe2) {
        fprintf(stderr, "SKIP: 未找到 libime 出厂数据\n");
        return false;
    }
    const char *root = getenv("GOGAKU_CORE_PROFILE_ROOT");
    std::string repo = root != nullptr && *root != '\0' ? root : ".";
    env.englishPath = repo + "/resources/english-words.txt";
    env.glossPath = repo + "/resources/gloss.tsv";
    std::ifstream pe(env.englishPath, std::ios::binary);
    if (!pe) {
        fprintf(stderr, "提示: 未找到 %s，英文与释义查询阶段按空表测量\n", env.englishPath.c_str());
        env.englishPath.clear();
        env.glossPath.clear();
    }
    return true;
}

std::vector<std::string> read_words(const std::string &path) {
    std::vector<std::string> out;
    std::ifstream in(path, std::ios::binary);
    if (!in) return out;
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        auto sp = line.find(' ');
        out.push_back(sp == std::string::npos ? line : line.substr(0, sp));
    }
    return out;
}

std::unordered_map<std::string, std::string> read_gloss(const std::string &path) {
    std::unordered_map<std::string, std::string> out;
    std::ifstream in(path, std::ios::binary);
    if (!in) return out;
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        auto tab = line.find('\t');
        if (tab == std::string::npos || tab == 0) continue;
        out.emplace(line.substr(0, tab), line.substr(tab + 1));
    }
    return out;
}

struct ScriptItem {
    int32_t kind;
    std::string text;
};

// 与 normal_session_bench.cpp 同一套脚本构造（保证可比）。
std::vector<ScriptItem> build_script() {
    std::vector<ScriptItem> script;
    auto emit = [&](int32_t kind, const std::string &text) { script.push_back({kind, text}); };
    auto emit_keys = [&](const char *keys) {
        for (const char *p = keys; *p != '\0'; ++p) emit(GC_EV_TEXT, std::string(1, *p));
    };
    int variant = 0;
    for (size_t ci = 0; ci < kQualityCaseCount; ++ci) {
        const QualityCase &c = kQualityCases[ci];
        const int v = variant % 6;
        switch (v) {
        case 0:
            emit_keys(c.keys); emit(GC_EV_SPACE, ""); break;
        case 1:
            emit_keys(c.keys); emit(GC_EV_DOWN, ""); emit(GC_EV_SPACE, ""); break;
        case 2:
            emit_keys(c.keys); emit(GC_EV_TEXT, "."); emit(GC_EV_TEXT, ","); emit(GC_EV_SPACE, ""); break;
        case 3:
            if (strlen(c.keys) > 4 && c.syllables >= 3) {
                emit_keys(std::string(c.keys, c.keys + 4).c_str());
                emit(GC_EV_TEXT, "1");
                emit_keys(c.keys + 4);
                emit(GC_EV_SPACE, "");
            } else {
                emit_keys(c.keys); emit(GC_EV_SPACE, "");
            }
            break;
        case 4:
            emit_keys(c.keys); emit(GC_EV_TEXT, ","); emit(GC_EV_TEXT, "2");
            emit(GC_EV_TEXT, "0"); emit(GC_EV_TEXT, "2"); emit(GC_EV_TEXT, "6");
            emit(GC_EV_TEXT, ".");
            break;
        case 5:
            emit_keys(c.keys); emit(GC_EV_TEXT, "1"); emit(GC_EV_SHIFT_CLICK, "");
            emit(GC_EV_TEXT, "g"); emit(GC_EV_TEXT, "o"); emit(GC_EV_SHIFT_CLICK, "");
            emit(GC_EV_ESC, "");
            break;
        }
        ++variant;
    }
    return script;
}

const char *kPhaseNames[] = {"decode", "fetch", "convert200", "lookup200",
                              "merge_identity", "materialize18", "snapshot9",
                              "english_index"};
constexpr size_t kPhaseCount = sizeof(kPhaseNames) / sizeof(kPhaseNames[0]);

void report(const char *label, std::vector<uint64_t> &v) {
    if (v.empty()) return;
    std::sort(v.begin(), v.end());
    auto pct = [&](double q) { return v[static_cast<size_t>(q * (v.size() - 1))] / 1000.0; };
    uint64_t sum = 0;
    for (uint64_t x : v) sum += x;
    fprintf(stderr, "  %-16s n=%-6zu mean=%8.1fµs p50=%8.1fµs p95=%8.1fµs p99=%9.1fµs max=%9.1fµs\n",
            label, v.size(), sum / 1000.0 / v.size(), pct(0.50), pct(0.95), pct(0.99),
            v.back() / 1000.0);
}

// 端到端消融：走公开 C ABI，比较不同数据面配置下的逐键耗时。
// 用纯字母序列（每个序列后 Esc 重置）：两种配置的按键轨迹完全一致，
// 避免「数字选中英文候选→提前提交」造成的状态分叉而污染比较。
void ablation(const Env &env, const std::vector<ScriptItem> &script, size_t maxEvents) {
    struct Variant { const char *name; bool english; bool gloss; };
    const Variant variants[] = {
        {"英文开+释义在", true, true},
        {"英文关+释义在", false, true},
        {"英文关+释义无", false, false},
    };
    for (const Variant &v : variants) {
        GcNormalConfig cfg{};
        cfg.dict_path = env.dictPath.c_str();
        cfg.model_path = env.modelPath.c_str();
        cfg.scheme = GC_SCHEME_XIAOHE;
        cfg.full_pinyin_preedit = 1;
        cfg.freq_enabled = 1;
        cfg.english_enabled = v.english ? 1 : 0;
        cfg.english_words_path = v.english && !env.englishPath.empty() ? env.englishPath.c_str() : nullptr;
        cfg.gloss_path = v.gloss && !env.glossPath.empty() ? env.glossPath.c_str() : nullptr;
        GcNormalSession *s = nullptr;
        char err[256] = {0};
        if (gc_normal_session_create(&cfg, &s, err, sizeof(err)) != 0) {
            fprintf(stderr, "会话创建失败：%s\n", err);
            return;
        }
        std::vector<uint64_t> samples;
        GcKeyEvent ev{};
        ev.app = "profile.app";
        ev.field = "f";
        int64_t t = 0;
        size_t index = 0;
        for (const ScriptItem &item : script) {
            if (index >= maxEvents) break;
            ev.kind = item.kind;
            ev.text = item.text.c_str();
            ev.time_ms = ++t;
            GcSnapshot *snap = nullptr;
            const uint64_t start = now_ns();
            if (gc_normal_handle(s, &ev, &snap) != 0 || snap == nullptr) {
                gc_normal_session_destroy(s);
                return;
            }
            const uint64_t elapsed = now_ns() - start;
            gc_snapshot_free(snap);
            samples.push_back(elapsed);
            ++index;
        }
        gc_normal_session_destroy(s);
        report(v.name, samples);
    }
}

// 纯字母脚本（每个用例后 Esc）：用于数据面消融，保证各配置轨迹一致。
std::vector<ScriptItem> build_letter_script() {
    std::vector<ScriptItem> script;
    for (size_t ci = 0; ci < kQualityCaseCount; ++ci) {
        const QualityCase &c = kQualityCases[ci];
        for (const char *p = c.keys; *p != '\0'; ++p) {
            script.push_back({GC_EV_TEXT, std::string(1, *p)});
        }
        script.push_back({GC_EV_ESC, ""});
    }
    return script;
}

// 与核心一致的英文索引（精确哈希 ＋ 排序前缀区间），用于单独计时。
class EnglishIndexReplica {
public:
    void build(std::vector<std::string> words) {
        words_ = std::move(words);
        for (size_t i = 0; i < words_.size(); ++i) {
            exact_.emplace(words_[i], static_cast<uint32_t>(i));
            sorted_.emplace_back(words_[i], static_cast<uint32_t>(i));
        }
        std::sort(sorted_.begin(), sorted_.end());
    }
    bool findExact(const std::string &word) const { return exact_.count(word) != 0; }
    size_t findPrefix(const std::string &prefix, size_t n) const {
        size_t found = 0;
        auto it = std::lower_bound(sorted_.begin(), sorted_.end(), prefix,
                                   [](const std::pair<std::string, uint32_t> &e, const std::string &k) {
                                       return e.first < k;
                                   });
        for (; it != sorted_.end(); ++it) {
            if (it->first.size() <= prefix.size()) continue;
            if (it->first.compare(0, prefix.size(), prefix) != 0) break;
            if (found >= n) break;
            ++found;
        }
        return found;
    }
    const std::vector<std::string> &words() const { return words_; }

private:
    std::vector<std::string> words_;
    std::unordered_map<std::string, uint32_t> exact_;
    std::vector<std::pair<std::string, uint32_t>> sorted_;
};

}  // namespace

int main(int argc, char **argv) {
    Env env;
    if (!make_env(env)) return 3;

    const size_t maxEvents = argc > 1 ? static_cast<size_t>(atol(argv[1])) : 1200;
    const char *outPath = getenv("GOGAKU_CORE_PROFILE_OUT");
    std::string outFile = outPath != nullptr && *outPath != '\0' ? outPath
        : "bench/results/normal-session-profile-samples.csv";
    {   // 确保输出目录存在
        size_t slash = outFile.find_last_of('/');
        if (slash != std::string::npos) {
            std::string dir = outFile.substr(0, slash);
            const std::string cmd = "mkdir -p '" + dir + "'";
            if (system(cmd.c_str()) != 0) fprintf(stderr, "提示: 无法创建目录 %s\n", dir.c_str());
        }
    }

    auto dictp = std::make_unique<libime::PinyinDictionary>();
    dictp->load(0, env.dictPath.c_str(), libime::PinyinDictFormat::Binary);
    auto model = std::make_unique<libime::UserLanguageModel>(env.modelPath.c_str());
    auto ime = std::make_unique<libime::PinyinIME>(std::move(dictp), std::move(model));
    ime->setPreeditMode(libime::PinyinPreeditMode::Pinyin);
    ime->setShuangpinProfile(std::make_shared<libime::ShuangpinProfile>(libime::ShuangpinBuiltinProfile::Xiaohe));
    libime::PinyinContext ctx(ime.get());
    ctx.setUseShuangpin(true);
    ctx.setMaxSentenceLength(512);

    const std::vector<std::string> englishWords = read_words(env.englishPath);
    const std::unordered_map<std::string, std::string> glosses = read_gloss(env.glossPath);
    EnglishIndexReplica englishIndex;
    englishIndex.build(englishWords);
    std::unordered_map<std::string, std::string> learnedWords;
    learnedWords["你好"] = "ni'hao";
    learnedWords["今天"] = "jin'tian";

    fprintf(stderr, "分项基准：英文词 %zu 条，释义 %zu 条\n", englishWords.size(), glosses.size());

    std::vector<ScriptItem> script = build_script();
    std::vector<std::vector<uint64_t>> samples(kPhaseCount);
    for (auto &s : samples) s.reserve(maxEvents);

    std::ofstream csv(outFile, std::ios::binary | std::ios::trunc);
    csv << "event,phase,ns\n";
    size_t eventIndex = 0;
    size_t letterEvents = 0;
    for (const ScriptItem &item : script) {
        if (letterEvents >= maxEvents) break;
        const bool isLetter = item.kind == GC_EV_TEXT && item.text.size() == 1 &&
                              item.text[0] >= 'a' && item.text[0] <= 'z';
        if (isLetter) {
            const uint64_t t0 = now_ns();
            ctx.type(item.text);
            const uint64_t t1 = now_ns();
            const auto &chinese = ctx.candidatesToCursor();
            const uint64_t t2 = now_ns();
            const std::string staged = ctx.selectedSentence();
            // 旧实现：200 条候选全部转文本
            std::vector<std::string> words;
            words.reserve(std::min(chinese.size(), kMaxChineseCandidates));
            for (size_t i = 0; i < std::min(chinese.size(), kMaxChineseCandidates); ++i) {
                words.push_back(staged + chinese[i].toString());
            }
            const uint64_t t3 = now_ns();
            // 旧实现：200 条候选各查 2 次释义 ＋ 1 次学习词
            for (size_t i = 0; i < words.size(); ++i) {
                const std::string &word = words[i];
                auto g = glosses.find(word);
                if (g == glosses.end()) g = glosses.find(staged + word);
                (void)g;
                (void)learnedWords.find(word);
            }
            const uint64_t t4 = now_ns();
            // 新实现：只算身份与总数
            struct Entry { int32_t kind; size_t libimeIndex; bool completes; };
            std::vector<Entry> entries;
            entries.reserve(std::min(chinese.size(), kMaxChineseCandidates));
            for (size_t i = 0; i < std::min(chinese.size(), kMaxChineseCandidates); ++i) {
                const auto &nodes = chinese[i].sentence();
                const size_t rawStart = ctx.selectedLength();
                const size_t end = nodes.empty() ? rawStart : rawStart + nodes.back()->to()->index();
                entries.push_back({0, i, end == ctx.size()});
            }
            const uint64_t t5 = now_ns();
            // 新实现：只转换当前页＋下一页（≤18 项）
            std::vector<std::string> materialized;
            materialized.reserve(kPageSize * 2);
            for (size_t i = 0; i < entries.size() && i < kPageSize * 2; ++i) {
                const std::string word = chinese[entries[i].libimeIndex].toString();
                std::string text = staged + word;
                auto g = glosses.find(word);
                if (g == glosses.end()) g = glosses.find(text);
                (void)g;
                (void)learnedWords.find(word);
                materialized.push_back(std::move(text));
            }
            const uint64_t t6 = now_ns();
            // 快照：复制一页 9 项
            std::vector<std::pair<char *, char *>> page;
            for (size_t i = 0; i < materialized.size() && i < kPageSize; ++i) {
                char *text = static_cast<char *>(std::malloc(materialized[i].size() + 1));
                memcpy(text, materialized[i].c_str(), materialized[i].size() + 1);
                char *gl = static_cast<char *>(std::malloc(1));
                gl[0] = '\0';
                page.emplace_back(text, gl);
            }
            const uint64_t t7 = now_ns();
            // 英文索引：整词一致 ＋ 前缀补全（与核心同一算法）
            const uint64_t t8 = now_ns();
            {
                const std::string remain = ctx.userInput().substr(ctx.selectedLength());
                if (remain.size() >= 3) {
                    bool allLower = true;
                    for (char ch : remain) {
                        if (ch < 'a' || ch > 'z') { allLower = false; break; }
                    }
                    if (allLower) {
                        englishIndex.findExact(remain);
                        if (remain.size() >= 4) englishIndex.findPrefix(remain, 3);
                    }
                }
            }
            const uint64_t t9 = now_ns();
            for (auto &p : page) {
                std::free(p.first);
                std::free(p.second);
            }
            const uint64_t parts[kPhaseCount] = {t1 - t0, t2 - t1, t3 - t2, t4 - t3,
                                                 t5 - t4, t6 - t5, t7 - t6, t9 - t8};
            for (size_t p = 0; p < kPhaseCount; ++p) {
                samples[p].push_back(parts[p]);
                csv << eventIndex << ',' << kPhaseNames[p] << ',' << parts[p] << '\n';
            }
            ++eventIndex;
            ++letterEvents;
            continue;
        }
        // 非字母事件：按脚本推进（空格／Esc 负责清空组合）。
        if (item.kind == GC_EV_SPACE || item.kind == GC_EV_ESC || item.kind == GC_EV_ENTER) {
            ctx.clear();
            ctx.clearContextWords();
        } else if (item.kind == GC_EV_TEXT) {
            // 标点／数字：核心内部会清空或继续；这里保持与真实序列一致的最简处理。
            ctx.clear();
            ctx.clearContextWords();
        }
    }
    csv.close();

    fprintf(stderr, "分项基准：%zu 个字母事件，原始样本写入 %s\n", letterEvents, outFile.c_str());
    for (size_t p = 0; p < kPhaseCount; ++p) report(kPhaseNames[p], samples[p]);

    fprintf(stderr, "端到端消融（公开 C ABI，纯字母序列 %zu 事件）：\n", maxEvents);
    const std::vector<ScriptItem> letterScript = build_letter_script();
    ablation(env, letterScript, maxEvents);
    return 0;
}
