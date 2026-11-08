// 共享 C++ 学习模式核心：学习组合状态机＋三状态按键语义＋翻译调度合同。
// Swift CompositionSession 的迁移实现（docs/implementation-plan.md G1）；
// 事件轨迹规格见 tests/learning_session_test.cpp 与同一 Swift 行为合同。
// 不引用 Apple 框架；翻译请求的进程与传输仍在平台侧。
#include "gogaku_core.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include <libime/core/userlanguagemodel.h>
#include <libime/pinyin/pinyincontext.h>
#include <libime/pinyin/pinyindictionary.h>
#include <libime/pinyin/pinyinime.h>
#include <libime/pinyin/shuangpinprofile.h>

namespace {

constexpr size_t kPageSize = 9;
constexpr size_t kMaxInputScalars = 512;

char *copy_cstr(const std::string &s) {
    auto *r = static_cast<char *>(std::malloc(s.size() + 1));
    if (r == nullptr) throw std::bad_alloc();
    memcpy(r, s.c_str(), s.size() + 1);
    return r;
}

// ── 解码内核（普通态与中→英源文推导共用；语义与历史 ge_* 桥一致） ──
// 小鹤固定（历史行为；普通输入的完整状态机走普通模式会话，不经本会话）。
struct DecodeCore {
    libime::PinyinIME ime;
    libime::PinyinContext context;
    size_t page = 0;
    DecodeCore(const char *dict, const char *model)
        : ime(std::make_unique<libime::PinyinDictionary>(), std::make_unique<libime::UserLanguageModel>(model)),
          context(&ime) {
        ime.dict()->load(libime::PinyinDictionary::SystemDict, dict, libime::PinyinDictFormat::Binary);
        ime.setShuangpinProfile(std::make_shared<libime::ShuangpinProfile>(libime::ShuangpinBuiltinProfile::Xiaohe));
        ime.setPreeditMode(libime::PinyinPreeditMode::Pinyin);
        context.setUseShuangpin(true);
        context.setMaxSentenceLength(512);
    }
    // 单键入内核校验（小写字母；撇号仅组合中）。返回 0 合法。
    int type(uint32_t c) {
        if (!((c >= 'a' && c <= 'z') || (c == '\'' && !context.empty())) || context.size() >= 512) return 1;
        if (!context.type(c)) return 1;
        page = 0;
        return 0;
    }
    void cancel() {
        context.clear();
        context.clearContextWords();
        page = 0;
    }
    // ge GE_SELECT 语义：越界返回 1；完整选择时取走提交文本并清空上下文。
    int select(size_t index, std::string &commit) {
        const auto &items = context.candidatesToCursor();
        if (index >= items.size()) return 1;
        context.selectCandidatesToCursor(index);
        page = 0;
        commit.clear();
        if (context.selected()) {
            commit = context.selectedSentence();
            context.clear();
        }
        return 0;
    }
    int page_move(int64_t delta) {
        if (delta != -1 && delta != 1) return 1;
        if (delta > 0) ++page;
        else if (page) --page;
        return 0;
    }
};

// 内核候选物化（范围按 Unicode 标量：此上下文以小鹤键计，1 键＝1 标量）。
struct CoreCand {
    std::string text;
    size_t index = 0;
    size_t raw_start = 0;
    size_t raw_length = 0;
    bool completes = false;
};

struct CoreState {
    std::string raw, preedit, selected;
    size_t selected_length = 0, total = 0, page = 0;
    bool composing = false;
    std::vector<CoreCand> candidates; // 当前页（最多 9 条）
};

CoreState collect(DecodeCore &e) {
    CoreState s;
    auto &c = e.context;
    const auto &candidates = c.candidatesToCursor();
    e.page = std::min(e.page, candidates.empty() ? 0 : (candidates.size() - 1) / kPageSize);
    s.raw = c.userInput();
    s.preedit = c.preedit(libime::PinyinPreeditMode::Pinyin);
    s.selected = c.selectedSentence();
    s.selected_length = c.selectedLength();
    s.composing = !c.empty();
    s.total = candidates.size();
    s.page = e.page;
    const size_t count = std::min(kPageSize, candidates.size() - std::min(candidates.size(), e.page * kPageSize));
    for (size_t n = 0; n < count; ++n) {
        const size_t index = n + e.page * kPageSize;
        const auto &candidate = candidates[index];
        CoreCand item;
        item.text = candidate.toString();
        item.index = index;
        item.raw_start = c.selectedLength();
        const auto &nodes = candidate.sentence();
        // libime 在每次部分选择后重建剩余图；节点索引相对未消费后缀。
        const size_t end = nodes.empty() ? item.raw_start : item.raw_start + nodes.back()->to()->index();
        if (end < item.raw_start || end > c.size()) throw std::runtime_error("invalid graph range");
        item.raw_length = end - item.raw_start;
        item.completes = end == c.size();
        s.candidates.push_back(std::move(item));
    }
    return s;
}

// UTF-8 → Unicode 标量序列；非法序列返回 false（ABI 不接收非法输入）。
bool utf8_to_scalars(const char *text, size_t length, std::u32string &out) {
    out.clear();
    if (text == nullptr) return length == 0;
    size_t i = 0;
    while (i < length) {
        const unsigned char b = static_cast<unsigned char>(text[i]);
        uint32_t cp = 0;
        size_t extra = 0;
        if (b < 0x80) { cp = b; extra = 0; }
        else if ((b & 0xE0) == 0xC0) { cp = b & 0x1F; extra = 1; }
        else if ((b & 0xF0) == 0xE0) { cp = b & 0x0F; extra = 2; }
        else if ((b & 0xF8) == 0xF0) { cp = b & 0x07; extra = 3; }
        else return false;
        if (extra != 0 && i + extra >= length) return false; // 尾部截断
        for (size_t k = 1; k <= extra; ++k) {
            const unsigned char cb = static_cast<unsigned char>(text[i + k]);
            if ((cb & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (cb & 0x3F);
        }
        if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
        if ((extra == 1 && cp < 0x80) || (extra == 2 && cp < 0x800) || (extra == 3 && cp < 0x10000)) return false;
        out.push_back(static_cast<char32_t>(cp));
        i += extra + 1;
    }
    return true;
}

void scalars_to_utf8(const std::u32string &scalars, std::string &out) {
    out.clear();
    for (const char32_t cp : scalars) {
        if (cp < 0x80) out.push_back(static_cast<char>(cp));
        else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }
}

bool is_encoding(uint32_t c) { return (c >= 'a' && c <= 'z') || c == '\''; }

// 回格删除一个字素簇（与历史 Swift String.removeLast 同语义）：组合标记、
// 变体选择符、肤色修饰、ZWJ 粘接与区域指示符对按簇回退。
// v1 局限：Tag 序列旗标不再延伸；CBT/Indic 音节未实现。
bool is_extending(uint32_t c) {
    return (c >= 0x0300 && c <= 0x036F) || (c >= 0x1AB0 && c <= 0x1AFF) ||
           (c >= 0x1DC0 && c <= 0x1DFF) || (c >= 0xFE20 && c <= 0xFE2F) || // 组合标记
           c == 0x20E3 ||                                                   // 键帽组合框
           (c >= 0xFE00 && c <= 0xFE0F) ||                                  // 变体选择符
           (c >= 0x1F3FB && c <= 0x1F3FF);                                  // 肤色修饰
}

bool is_regional_indicator(uint32_t c) { return c >= 0x1F1E6 && c <= 0x1F1FF; }

void backspace_cluster(std::u32string &raw) {
    if (raw.empty()) return;
    char32_t cur = raw.back();
    raw.pop_back();
    while (!raw.empty()) {
        const char32_t last = raw.back();
        if (is_extending(cur) || cur == 0x200D) {
            cur = last; raw.pop_back();   // 被删标量是延伸符或 ZWJ：基字同簇
        } else if (is_extending(last)) {
            cur = last; raw.pop_back();   // 尾部延伸符粘接被删标量
        } else if (last == 0x200D) {
            raw.pop_back();               // ZWJ：连前一个基字
            if (raw.empty()) break;
            cur = raw.back(); raw.pop_back();
        } else if (is_regional_indicator(cur) && is_regional_indicator(last)) {
            raw.pop_back();               // 区域指示符对（旗标）
            break;
        } else {
            break;
        }
    }
}

struct Issue {
    int64_t location = 0, length = 0;
    std::string explanation;
};

struct Src {
    std::string id, text;
    int64_t start = 0, length = 0;
};

struct Cand {
    std::string source_id, source, target, resource;
    int64_t start = 0, length = 0, engine_index = -1;
    bool completes = false;
};

} // namespace

struct GcLearningSession {
    DecodeCore core;
    // 身份
    uint64_t focus = 0, epoch = 0, revision = 0;
    int32_t mode = GC_LEARN_MODE_NORMAL;
    int32_t direction = GC_LEARN_DIR_ZH_TO_EN;
    // 视图状态
    std::u32string raw; // 学习态原始输入（标量）；普通态镜像内核 userInput
    std::string preedit, status, typed_prefix;
    std::vector<Cand> candidates;
    size_t selected = 0, page = 0;
    size_t total_candidates = 0;
    std::vector<Src> sources;
    bool frozen = false;
    bool translation_needed = false;
    int64_t translation_source = -1;
    std::vector<Issue> issues;

    GcLearningSession(const char *dict, const char *model) : core(dict, model) {}

    // configure/cancel 共用：结束当前组合并开启新组合身份。
    void reset_composition() {
        core.cancel();
        raw.clear(); preedit.clear(); status.clear(); typed_prefix.clear();
        candidates.clear(); selected = 0; page = 0; total_candidates = 0;
        sources.clear(); frozen = false;
        translation_needed = false; translation_source = -1;
        issues.clear();
        revision = 0;
        epoch += 1;
    }

    void revise() {
        revision += 1;
        candidates.clear(); selected = 0; page = 0;
        status.clear(); frozen = false;
    }

    // 普通态：把内核状态物化进视图（publishNormal 语义；selected 恒 0）。
    void publish_normal(const CoreState &st) {
        utf8_to_scalars(st.raw.c_str(), st.raw.size(), raw);
        preedit = st.preedit;
        typed_prefix = st.selected;
        total_candidates = st.total;
        page = st.page;
        candidates.clear();
        for (const auto &item : st.candidates) {
            Cand cand;
            cand.source_id = "libime:" + std::to_string(item.index);
            cand.source = st.selected + item.text;
            cand.target = item.text;
            cand.resource = "libime-1.1.17";
            cand.start = static_cast<int64_t>(item.raw_start);
            cand.length = static_cast<int64_t>(item.raw_length);
            cand.engine_index = static_cast<int64_t>(item.index);
            cand.completes = item.completes;
            candidates.push_back(std::move(cand));
        }
    }

    // 学习态发布（publishLearning 语义）：产出源表达式并在发布后置请求旗标。
    // 返回 false ＝内核拒绝（与历史 decode 抛异常同源；调用方以引擎错误返回）。
    bool publish_learning() {
        sources.clear();
        translation_needed = false;
        translation_source = -1;
        scalars_to_utf8(raw, preedit);
        if (raw.empty()) return true;
        if (direction == GC_LEARN_DIR_EN_TO_ZH) {
            std::string raw_utf8;
            scalars_to_utf8(raw, raw_utf8);
            sources.push_back({"english:full", raw_utf8, 0, static_cast<int64_t>(raw.size())});
        } else {
            // 编码与字面片段分别解码；数字、标点、emoji 永不作为拼音送入内核。
            std::string decoded;
            std::vector<Src> alternatives;
            size_t start = 0;
            bool failed = false;
            while (start < raw.size()) {
                const bool encoded = is_encoding(raw[start]);
                size_t end = start + 1;
                while (end < raw.size() && is_encoding(raw[end]) == encoded) ++end;
                if (encoded) {
                    core.cancel();
                    for (size_t k = start; k < end; ++k) {
                        // 内核拒绝（如撇号开头）与历史 decode 抛异常同源。
                        if (core.type(static_cast<uint32_t>(raw[k])) != 0) return false;
                    }
                    if (failed) break;
                    const CoreState state = collect(core);
                    if (state.candidates.empty() || !state.candidates.front().completes) {
                        status = "当前小鹤片段尚无完整中文来源";
                        failed = true;
                        break;
                    }
                    if (alternatives.empty()) {
                        for (const auto &candidate : state.candidates) {
                            if (candidate.raw_start != 0) continue;
                            alternatives.push_back({"chinese:" + std::to_string(start) + ":" +
                                                        std::to_string(candidate.index),
                                                    decoded + candidate.text, 0,
                                                    static_cast<int64_t>(start + candidate.raw_length)});
                        }
                    }
                    decoded += state.candidates.front().text;
                } else {
                    const std::u32string segment(raw.begin() + static_cast<long>(start),
                                                 raw.begin() + static_cast<long>(end));
                    std::string text;
                    scalars_to_utf8(segment, text);
                    decoded += text;
                }
                start = end;
            }
            if (failed) return true; // preedit 保持原码；无源、无请求
            sources.push_back({"chinese:full", decoded, 0, static_cast<int64_t>(raw.size())});
            for (auto &alt : alternatives) {
                if (alt.text != decoded) sources.push_back(std::move(alt));
            }
            preedit = decoded;
        }
        if (!sources.empty()) {
            translation_needed = true;
            translation_source = 0;
        }
        return true;
    }

    bool stamp_matches(const GcLearningEvent &ev) const {
        return ev.stamp_focus == focus && ev.stamp_epoch == epoch && ev.stamp_revision == revision &&
               ev.stamp_mode == mode && ev.stamp_direction == direction;
    }
};

namespace {

int append_text(GcLearningSession &s, const char *text, size_t length) {
    std::u32string scalars;
    if (!utf8_to_scalars(text, length, scalars)) return 1;
    // 512 标量输入上限（两种模式同守卫；超限保留全部现有输入）。
    if (s.raw.size() + scalars.size() > kMaxInputScalars) {
        s.status = "输入上限 512 个 Unicode 标量；已保留全部现有输入";
        return 0;
    }
    if (s.mode == GC_LEARN_MODE_NORMAL) {
        for (const char32_t c : scalars) {
            if (s.core.type(static_cast<uint32_t>(c)) != 0) return 2;
        }
        s.revise();
        s.publish_normal(collect(s.core));
    } else {
        s.raw += scalars;
        s.revise();
        if (!s.publish_learning()) return 2;
    }
    return 0;
}

using Owned = std::unique_ptr<GcLearningSnapshot, decltype(&gc_learning_snapshot_free)>;

GcIssue *copy_issues(const std::vector<Issue> &issues, size_t &count) {
    count = issues.size();
    if (issues.empty()) return nullptr;
    auto *items = static_cast<GcIssue *>(std::calloc(issues.size(), sizeof(GcIssue)));
    if (items == nullptr) throw std::bad_alloc();
    for (size_t i = 0; i < issues.size(); ++i) {
        items[i].location = issues[i].location;
        items[i].length = issues[i].length;
        items[i].explanation = copy_cstr(issues[i].explanation);
    }
    return items;
}

GcLearningSnapshot *make_snapshot(GcLearningSession &s) {
    Owned snap(static_cast<GcLearningSnapshot *>(std::calloc(1, sizeof(GcLearningSnapshot))),
               gc_learning_snapshot_free);
    if (!snap) throw std::bad_alloc();
    snap->focus = s.focus;
    snap->epoch = s.epoch;
    snap->revision = s.revision;
    snap->mode = s.mode;
    snap->direction = s.direction;
    std::string raw_utf8;
    scalars_to_utf8(s.raw, raw_utf8);
    snap->raw = copy_cstr(raw_utf8);
    snap->preedit = copy_cstr(s.preedit);
    snap->status = copy_cstr(s.status);
    snap->typed_prefix = copy_cstr(s.typed_prefix);
    snap->frozen = s.frozen ? 1 : 0;
    snap->candidate_count = s.candidates.size();
    if (!s.candidates.empty()) {
        snap->candidates = static_cast<GcLearningCandidate *>(
            std::calloc(s.candidates.size(), sizeof(GcLearningCandidate)));
        if (!snap->candidates) throw std::bad_alloc();
    }
    for (size_t i = 0; i < s.candidates.size(); ++i) {
        const auto &c = s.candidates[i];
        auto &item = snap->candidates[i];
        item.source_id = copy_cstr(c.source_id);
        item.source = copy_cstr(c.source);
        item.target = copy_cstr(c.target);
        item.resource = copy_cstr(c.resource);
        item.start = c.start;
        item.length = c.length;
        item.engine_index = c.engine_index;
        item.completes = c.completes ? 1 : 0;
    }
    snap->selected = s.selected;
    snap->page = s.page;
    snap->total_candidates = s.mode == GC_LEARN_MODE_NORMAL ? s.total_candidates : s.candidates.size();
    snap->source_count = s.sources.size();
    if (!s.sources.empty()) {
        snap->sources = static_cast<GcSourceExpression *>(
            std::calloc(s.sources.size(), sizeof(GcSourceExpression)));
        if (!snap->sources) throw std::bad_alloc();
    }
    for (size_t i = 0; i < s.sources.size(); ++i) {
        snap->sources[i].id = copy_cstr(s.sources[i].id);
        snap->sources[i].text = copy_cstr(s.sources[i].text);
        snap->sources[i].start = s.sources[i].start;
        snap->sources[i].length = s.sources[i].length;
    }
    snap->translation_needed = s.translation_needed ? 1 : 0;
    snap->translation_source_index = s.translation_needed ? s.translation_source : -1;
    snap->issues = copy_issues(s.issues, snap->issue_count);
    return snap.release();
}

// 提交意图字段（CHOOSE/ORIGINAL 成功时填写；id 由平台生成）。
struct CommitInfo {
    std::string text, source, resource, recovery;
    bool original = false;
    uint64_t focus = 0, epoch = 0, revision = 0;
    int32_t mode = 0, direction = 0;
};

void fill_commit(GcLearningSnapshot &snap, const CommitInfo &info) {
    snap.commit_text = copy_cstr(info.text);
    snap.commit_source = copy_cstr(info.source);
    snap.commit_resource = copy_cstr(info.resource);
    snap.commit_original = info.original ? 1 : 0;
    snap.commit_recovery_raw = copy_cstr(info.recovery);
    snap.commit_focus = info.focus;
    snap.commit_epoch = info.epoch;
    snap.commit_revision = info.revision;
    snap.commit_mode = info.mode;
    snap.commit_direction = info.direction;
}

CommitInfo commit_of(const GcLearningSession &pre) {
    CommitInfo info;
    info.focus = pre.focus;
    info.epoch = pre.epoch;
    info.revision = pre.revision;
    info.mode = pre.mode;
    info.direction = pre.direction;
    return info;
}

} // namespace

extern "C" void gc_learning_snapshot_free(GcLearningSnapshot *snapshot) {
    if (!snapshot) return;
    std::free(snapshot->raw);
    std::free(snapshot->preedit);
    std::free(snapshot->status);
    std::free(snapshot->typed_prefix);
    if (snapshot->candidates) {
        for (size_t i = 0; i < snapshot->candidate_count; ++i) {
            std::free(snapshot->candidates[i].source_id);
            std::free(snapshot->candidates[i].source);
            std::free(snapshot->candidates[i].target);
            std::free(snapshot->candidates[i].resource);
        }
    }
    std::free(snapshot->candidates);
    if (snapshot->sources) {
        for (size_t i = 0; i < snapshot->source_count; ++i) {
            std::free(snapshot->sources[i].id);
            std::free(snapshot->sources[i].text);
        }
    }
    std::free(snapshot->sources);
    if (snapshot->issues) {
        for (size_t i = 0; i < snapshot->issue_count; ++i) std::free(snapshot->issues[i].explanation);
    }
    std::free(snapshot->issues);
    std::free(snapshot->commit_text);
    std::free(snapshot->commit_source);
    std::free(snapshot->commit_resource);
    std::free(snapshot->commit_recovery_raw);
    std::free(snapshot);
}

extern "C" int gc_learning_session_create(const GcLearningConfig *config, GcLearningSession **out,
                                          char *err, size_t err_len) {
    if (!out) return 1;
    *out = nullptr;
    if (!config || !config->dict_path || !config->model_path) return 1;
    try {
        *out = new GcLearningSession(config->dict_path, config->model_path);
        return 0;
    } catch (const std::exception &e) {
        if (err && err_len) snprintf(err, err_len, "学习会话创建失败：%s", e.what());
        return 2;
    } catch (...) {
        if (err && err_len) snprintf(err, err_len, "学习会话创建失败：未知错误");
        return 2;
    }
}

extern "C" void gc_learning_session_destroy(GcLearningSession *session) {
    try { delete session; } catch (...) {}
}

extern "C" int gc_learning_handle(GcLearningSession *session, const GcLearningEvent *event,
                                  GcLearningSnapshot **out) {
    if (!out) return 1;
    *out = nullptr;
    if (!session || !event) return 1;
    GcLearningSession &s = *session;
    try {
        // translation_needed 是逐事件输出：只有本次事件的发布/显式请求才置位。
        s.translation_needed = false;
        s.translation_source = -1;
        switch (event->kind) {
        case GC_LEV_CONFIGURE: {
            if (event->arg1 != GC_LEARN_MODE_NORMAL && event->arg1 != GC_LEARN_MODE_LEARNING) return 1;
            if (event->arg2 != GC_LEARN_DIR_ZH_TO_EN && event->arg2 != GC_LEARN_DIR_EN_TO_ZH) return 1;
            s.focus = static_cast<uint64_t>(event->arg0);
            s.mode = static_cast<int32_t>(event->arg1);
            s.direction = static_cast<int32_t>(event->arg2);
            s.reset_composition();
            break;
        }
        case GC_LEV_TYPE: {
            const int rc = append_text(s, event->text, event->text ? strlen(event->text) : 0);
            if (rc != 0) return rc;
            break;
        }
        case GC_LEV_BACKSPACE: {
            if (s.mode == GC_LEARN_MODE_NORMAL) {
                s.core.context.backspace();
                s.core.page = 0;
                s.revise();
                s.publish_normal(collect(s.core));
            } else if (!s.raw.empty()) {
                backspace_cluster(s.raw);
                s.revise();
                if (!s.publish_learning()) return 2;
            }
            break;
        }
        case GC_LEV_CANCEL: {
            s.reset_composition();
            break;
        }
        case GC_LEV_RESTORE: {
            s.reset_composition();
            const int rc = append_text(s, event->text, event->text ? strlen(event->text) : 0);
            if (rc != 0) return rc;
            break;
        }
        case GC_LEV_PAGE: {
            if (s.mode == GC_LEARN_MODE_NORMAL) {
                if (s.core.page_move(event->arg0) != 0) return 1;
                s.revise();
                s.publish_normal(collect(s.core));
            } else {
                s.frozen = true;
                const int64_t last = std::max<int64_t>(
                    0, (static_cast<int64_t>(s.candidates.size()) - 1) / static_cast<int64_t>(kPageSize));
                const int64_t next = std::max<int64_t>(0, std::min(last, static_cast<int64_t>(s.page) + event->arg0));
                s.page = static_cast<size_t>(next);
                s.selected = s.page * kPageSize;
            }
            break;
        }
        case GC_LEV_NAVIGATE: {
            s.frozen = true;
            if (s.candidates.empty()) break;
            const int64_t next = std::max<int64_t>(0, std::min<int64_t>(
                static_cast<int64_t>(s.candidates.size()) - 1,
                static_cast<int64_t>(s.selected) + event->arg0));
            s.selected = static_cast<size_t>(next);
            s.page = s.selected / kPageSize;
            break;
        }
        case GC_LEV_CHOOSE: {
            const int64_t index64 = event->arg0;
            if (index64 < 0 || static_cast<size_t>(index64) >= s.candidates.size()) return 1;
            const Cand chosen = s.candidates[static_cast<size_t>(index64)];
            s.frozen = true;
            if (s.mode == GC_LEARN_MODE_NORMAL && chosen.engine_index >= 0) {
                const std::string recovery_raw = s.core.context.userInput();
                std::string commit;
                if (s.core.select(static_cast<size_t>(chosen.engine_index), commit) != 0) return 1;
                s.revise();
                if (!commit.empty()) {
                    // 完整选择：提交并结束组合（cancel 语义；意图属事件前状态）。
                    const CommitInfo pre = commit_of(s);
                    s.reset_composition();
                    Owned snap(make_snapshot(s), gc_learning_snapshot_free);
                    CommitInfo info = pre;
                    info.text = commit;
                    info.source = chosen.source;
                    info.resource = chosen.resource;
                    info.original = false;
                    info.recovery = recovery_raw;
                    fill_commit(*snap, info);
                    *out = snap.release();
                    return 0;
                }
                s.publish_normal(collect(s.core));
                break;
            }
            // 学习候选只消费它明确覆盖的源范围；当前实现只允许从组合起点消费。
            if (chosen.start != 0 || chosen.length > static_cast<int64_t>(s.raw.size())) return 1;
            std::string recovery_utf8;
            scalars_to_utf8(s.raw, recovery_utf8);
            CommitInfo info = commit_of(s);
            info.text = chosen.target;
            info.source = chosen.source;
            info.resource = chosen.resource;
            info.original = false;
            info.recovery = recovery_utf8;
            s.raw.erase(0, static_cast<size_t>(chosen.length));
            s.revise();
            // 发布失败（如剩余片段内核拒绝）：意图作废、原码已消费，与历史
            // Swift choose 的 try publishLearning 行为一致（try? 丢弃意图）。
            if (!s.publish_learning()) return 2;
            Owned snap(make_snapshot(s), gc_learning_snapshot_free);
            fill_commit(*snap, info);
            *out = snap.release();
            return 0;
        }
        case GC_LEV_ORIGINAL: {
            if (s.mode != GC_LEARN_MODE_LEARNING) return 1;
            if (s.raw.empty()) return 1;
            std::string raw_utf8;
            scalars_to_utf8(s.raw, raw_utf8);
            CommitInfo info = commit_of(s);
            info.text = raw_utf8;
            info.source = raw_utf8;
            info.resource = "original";
            info.original = true;
            info.recovery = raw_utf8;
            s.reset_composition();
            Owned snap(make_snapshot(s), gc_learning_snapshot_free);
            fill_commit(*snap, info);
            *out = snap.release();
            return 0;
        }
        case GC_LEV_VIEW_ERROR: {
            s.status = "引擎操作失败；输入已保留，请取消或保存草稿";
            break;
        }
        case GC_LEV_REQUEST_SOURCE: {
            const int64_t index = event->arg0;
            if (index < 0 || static_cast<size_t>(index) >= s.sources.size()) return 1;
            s.translation_needed = true;
            s.translation_source = index;
            break;
        }
        case GC_LEV_RECEIVE: {
            if (!event->approved) break;
            if (!s.stamp_matches(*event)) break;
            if (s.frozen) break;
            if (!event->target || !*event->target) break;
            if (!event->source_id || !event->source) break;
            const Src *source = nullptr;
            for (const auto &candidate : s.sources) {
                if (candidate.id == event->source_id && candidate.text == event->source) {
                    source = &candidate;
                    break;
                }
            }
            if (!source) break;
            bool duplicate = false;
            for (const auto &candidate : s.candidates) {
                if (candidate.source_id == source->id) { duplicate = true; break; }
            }
            if (duplicate) break;
            Cand cand;
            cand.source_id = source->id;
            cand.source = source->text;
            cand.target = event->target;
            cand.resource = event->resource ? event->resource : "";
            cand.start = source->start;
            cand.length = source->length;
            cand.engine_index = -1;
            s.candidates.push_back(std::move(cand));
            s.status.clear();
            break;
        }
        case GC_LEV_TRANSLATION_FAILED: {
            if (!s.stamp_matches(*event)) break;
            if (!s.candidates.empty() || s.frozen) break;
            s.status = event->message ? event->message : "";
            break;
        }
        case GC_LEV_SET_ISSUES: {
            if (!s.stamp_matches(*event)) break;
            if (s.mode != GC_LEARN_MODE_LEARNING || s.direction != GC_LEARN_DIR_EN_TO_ZH) break;
            s.issues.clear();
            for (size_t i = 0; i < event->issue_count; ++i) {
                const GcIssue &item = event->issues[i];
                s.issues.push_back({item.location, item.length,
                                    item.explanation ? item.explanation : ""});
            }
            break;
        }
        default:
            return 1;
        }
        *out = make_snapshot(s);
        return 0;
    } catch (...) {
        return 2;
    }
}
