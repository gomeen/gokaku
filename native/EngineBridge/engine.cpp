#include "gogaku_engine.h"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <libime/core/userlanguagemodel.h>
#include <libime/pinyin/pinyincontext.h>
#include <libime/pinyin/pinyindictionary.h>
#include <libime/pinyin/pinyinime.h>
#include <libime/pinyin/shuangpinprofile.h>

struct GEEngine {
    libime::PinyinIME ime;
    libime::PinyinContext context;
    size_t page = 0;
    GEEngine(const char *dict, const char *model)
        : ime(std::make_unique<libime::PinyinDictionary>(), std::make_unique<libime::UserLanguageModel>(model)), context(&ime) {
        ime.dict()->load(libime::PinyinDictionary::SystemDict, dict, libime::PinyinDictFormat::Binary);
        ime.setShuangpinProfile(std::make_shared<libime::ShuangpinProfile>(libime::ShuangpinBuiltinProfile::Xiaohe));
        ime.setPreeditMode(libime::PinyinPreeditMode::Pinyin);
        context.setUseShuangpin(true);
        context.setMaxSentenceLength(512);
    }
};
namespace {
constexpr size_t PageSize = 9;
char *copy(const std::string &s) {
    auto *result = static_cast<char *>(std::malloc(s.size() + 1));
    if (!result) throw std::bad_alloc();
    std::memcpy(result, s.c_str(), s.size() + 1);
    return result;
}
using Owned = std::unique_ptr<GESnapshot, decltype(&ge_snapshot_free)>;
GESnapshot *collect(GEEngine &e, const std::string &commit) {
    Owned s(static_cast<GESnapshot *>(std::calloc(1, sizeof(GESnapshot))), ge_snapshot_free);
    if (!s) throw std::bad_alloc();
    auto &c = e.context;
    const auto &candidates = c.candidatesToCursor();
    e.page = std::min(e.page, candidates.empty() ? 0 : (candidates.size() - 1) / PageSize);
    s->raw = copy(c.userInput());
    s->preedit = copy(c.preedit(libime::PinyinPreeditMode::Pinyin));
    s->selected = copy(c.selectedSentence());
    s->commit = copy(commit);
    s->selected_length = c.selectedLength();
    s->composing = !c.empty();
    s->total = candidates.size();
    s->page = e.page;
    s->count = std::min(PageSize, candidates.size() - std::min(candidates.size(), e.page * PageSize));
    if (s->count) {
        s->candidates = static_cast<GECandidate *>(std::calloc(s->count, sizeof(GECandidate)));
        if (!s->candidates) throw std::bad_alloc();
    }
    for (size_t n = 0; n < s->count; ++n) {
        const auto index = n + e.page * PageSize;
        const auto &candidate = candidates[index];
        auto &item = s->candidates[n];
        item.text = copy(candidate.toString());
        item.index = index;
        item.raw_start = c.selectedLength();
        const auto &nodes = candidate.sentence();
        // libime 在每次部分选择后重建剩余图；节点索引相对未消费后缀。
        const size_t end = nodes.empty() ? item.raw_start : item.raw_start + nodes.back()->to()->index();
        if (end < item.raw_start || end > c.size()) throw std::runtime_error("invalid graph range");
        item.raw_length = end - item.raw_start;
        item.completes = end == c.size();
    }
    return s.release();
}
}
extern "C" int ge_create(const char *dict, const char *model, GEEngine **out) {
    if (!out) return 1;
    *out = nullptr;
    if (!dict || !model) return 1;
    try { *out = new GEEngine(dict, model); return 0; } catch (...) { return 2; }
}
extern "C" void ge_destroy(GEEngine *e) { try { delete e; } catch (...) {} }
extern "C" void ge_snapshot_free(GESnapshot *s) {
    if (!s) return;
    std::free(s->raw); std::free(s->preedit); std::free(s->selected); std::free(s->commit);
    if (s->candidates) for (size_t i = 0; i < s->count; ++i) std::free(s->candidates[i].text);
    std::free(s->candidates); std::free(s);
}
extern "C" int ge_command(GEEngine *e, int op, int64_t arg, GESnapshot **out) {
    if (!out) return 1;
    *out = nullptr;
    if (!e) return 1;
    try {
        auto &c = e->context;
        std::string commit;
        switch (op) {
        case GE_PEEK: break;
        case GE_TYPE:
            if (!((arg >= 'a' && arg <= 'z') || (arg == '\'' && !c.empty())) || c.size() >= 512) return 1;
            if (!c.type(static_cast<uint32_t>(arg))) return 1;
            e->page = 0; break;
        case GE_BACKSPACE: c.backspace(); e->page = 0; break;
        case GE_SELECT: {
            const auto &items = c.candidatesToCursor();
            if (arg < 0 || static_cast<size_t>(arg) >= items.size()) return 1;
            c.selectCandidatesToCursor(static_cast<size_t>(arg));
            if (c.selected()) { commit = c.selectedSentence(); c.clear(); }
            e->page = 0; break;
        }
        case GE_CANCEL: c.clear(); c.clearContextWords(); e->page = 0; break;
        case GE_PAGE:
            if (arg != -1 && arg != 1) return 1;
            if (arg > 0) ++e->page; else if (e->page) --e->page;
            break;
        case GE_CURSOR:
            if (arg < 0 || static_cast<size_t>(arg) > c.size()) return 1;
            c.setCursor(static_cast<size_t>(arg)); e->page = 0; break;
        default: return 1;
        }
        *out = collect(*e, commit);
        return 0;
    } catch (...) { return 2; }
}
