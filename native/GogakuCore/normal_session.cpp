// 共享 C++ 普通模式核心：组合状态机＋libime 绑定＋自定义词语＋英文候选。
// 不引用 Apple 框架；同一实现供 macOS（IMK）与 Windows（TSF）调用。
// 事件轨迹规格见 docs/product.md「普通模式行为规格」与 tests/normal_session_test.cpp。
#include "gogaku_core.h"

#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <libime/core/userlanguagemodel.h>
#include <libime/pinyin/pinyincontext.h>
#include <libime/pinyin/pinyindictionary.h>
#include <libime/pinyin/pinyinencoder.h>
#include <libime/pinyin/pinyinime.h>
#include <libime/pinyin/shuangpinprofile.h>

namespace {

constexpr size_t kPageSize = 9;
constexpr size_t kMaxInputScalars = 512;
constexpr size_t kMaxChineseCandidates = 200;
constexpr size_t kMaxEnglishPrefixHits = 3;
constexpr size_t kMaxShortcodeLen = 32;
constexpr int64_t kQuickAddWindowMs = 60000;
// 词典下标：0 = 出厂 SystemDict；libime TrieDictionary 仅提供两个槽位
// （SystemDict／UserDict），自定义拼音词与已学习词共用 idx 1。
constexpr size_t kUserDictIdx = 1;
// libime 的 cost 加到语言模型分数上，值越大越优；不能当作待最小化的代价。
// 自定义拼音词用正值提升，避免未知词在解码阶段被剪枝（提升候选排序已来不及）。
constexpr float kCustomWordCost = 18.0f;
constexpr float kLearnedWordCost = -12.0f;

char *copy_cstr(const std::string &s) {
    auto *r = static_cast<char *>(std::malloc(s.size() + 1));
    if (r == nullptr) throw std::bad_alloc();
    memcpy(r, s.c_str(), s.size() + 1);
    return r;
}

enum class EngMode { Off, Temp, AppDefault };

// ── 候选身份与文本分离 ────────────────────────────────────────────
// 合并阶段只产出「身份＋总数」；文本、释义、最终类别在展示／选择时按需生成。
// 中文候选最多 200 条，全部转换会拖慢每个按键；实际只需当前页与下一页。
struct MergedEntry {
    int32_t kind = GC_CAND_CHINESE;  // 展示类别（中文候选的最终类别在物化时确定）
    bool libimeText = false;          // 文本来自 libime 中文候选
    bool pinyinWord = false;          // 自定义拼音词（完整匹配提升到首位）
    size_t libimeIndex = 0;           // libimeText：candidatesToCursor 下标
    bool completes = false;           // 覆盖到当前输入末尾
    std::string fixedText;            // 非 libime 候选的文本（英文／短码）
};

// 物化后的候选：文本、释义、类别与可删标记。
struct MaterializedCandidate {
    std::string text;
    std::string gloss;
    int32_t kind = GC_CAND_CHINESE;
    bool deletable = false;
    bool completes = false;
    std::string pinyin;   // 已学习词删除所需
};

// 一次合并的结果：候选身份序列 ＋ 按需物化缓存。
// 物化缓存按下标存，命中即复用；条目数量上限为当前页与下一页（≤18）。
struct MergedSet {
    std::vector<MergedEntry> entries;
    std::string staged;                 // 已暂存（已转中文）前缀
    std::vector<std::pair<size_t, MaterializedCandidate>> cache;
};

// ── 英文词表索引 ────────────────────────────────────────────────────
// 英文候选规则：整段为小写字母；整词一致（≥3 字母）或前缀补全（≥4 字母，最多 3）。
// 原实现每次按键线性遍历整份词表（出厂数据 5 万词）；这里改为
// 「精确哈希 ＋ 排序前缀区间」，并用原下标保持词频（列表）顺序，
// 产出的候选顺序与原实现逐字一致。
class EnglishWordIndex {
public:
    void build(std::vector<std::string> words);

    const std::vector<std::string> &words() const { return words_; }

    // 精确匹配：返回列表中首次出现的下标。
    bool findExact(const std::string &word, uint32_t &index) const;

    // 前缀补全：按列表顺序取前 n 个以 prefix 开头且更长的词。
    void findPrefix(const std::string &prefix, size_t n, std::vector<uint32_t> &out) const;

private:
    std::vector<std::string> words_;
    std::unordered_map<std::string, uint32_t> exact_;
    std::vector<std::pair<std::string, uint32_t>> sorted_;  // (词, 列表下标)，按词排序
};

void EnglishWordIndex::build(std::vector<std::string> words) {
    words_ = std::move(words);
    exact_.clear();
    sorted_.clear();
    exact_.reserve(words_.size() * 2);
    sorted_.reserve(words_.size());
    for (size_t i = 0; i < words_.size(); ++i) {
        // emplace 不覆盖：首次出现优先，与原实现「首次匹配即 break」一致。
        exact_.emplace(words_[i], static_cast<uint32_t>(i));
        sorted_.emplace_back(words_[i], static_cast<uint32_t>(i));
    }
    std::sort(sorted_.begin(), sorted_.end(),
              [](const std::pair<std::string, uint32_t> &a,
                 const std::pair<std::string, uint32_t> &b) {
                  if (a.first != b.first) return a.first < b.first;
                  return a.second < b.second;
              });
}

bool EnglishWordIndex::findExact(const std::string &word, uint32_t &index) const {
    auto it = exact_.find(word);
    if (it == exact_.end()) return false;
    index = it->second;
    return true;
}

void EnglishWordIndex::findPrefix(const std::string &prefix, size_t n,
                                  std::vector<uint32_t> &out) const {
    out.clear();
    if (n == 0) return;
    const size_t limit = std::min(n, kMaxEnglishPrefixHits);
    auto it = std::lower_bound(sorted_.begin(), sorted_.end(), prefix,
                               [](const std::pair<std::string, uint32_t> &entry,
                                  const std::string &key) { return entry.first < key; });
    // 区间内按列表下标取最小的 limit 个，保持词频（列表）顺序。
    uint32_t best[kMaxEnglishPrefixHits] = {UINT32_MAX, UINT32_MAX, UINT32_MAX};
    size_t count = 0;
    for (; it != sorted_.end(); ++it) {
        const std::string &w = it->first;
        if (w.size() <= prefix.size()) continue;      // 与原实现的 w.size() > remain.size() 一致
        if (w.compare(0, prefix.size(), prefix) != 0) break;
        const uint32_t index = it->second;
        if (count == limit && index >= best[limit - 1]) continue;
        size_t pos = std::min(count, limit - 1);
        while (pos > 0 && best[pos - 1] > index) {
            best[pos] = best[pos - 1];
            --pos;
        }
        best[pos] = index;
        if (count < limit) ++count;
    }
    for (size_t i = 0; i < count; ++i) out.push_back(best[i]);
}

bool is_han_codepoint(uint32_t cp) {
    return (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0x9FFF) ||
           (cp >= 0xF900 && cp <= 0xFAFF);
}

std::string punct_map(char c) {
    switch (c) {
    case ',': return "，";
    case '.': return "。";
    case '?': return "？";
    case '!': return "！";
    case ';': return "；";
    case ':': return "：";
    case '(': return "（";
    case ')': return "）";
    case '[': return "【";
    case ']': return "】";
    case '{': return "｛";
    case '}': return "｝";
    case '<': return "《";
    case '>': return "》";
    case '\\': return "、";
    case '~': return "～";
    case '@': return "＠";
    case '#': return "＃";
    case '%': return "％";
    case '&': return "＆";
    case '*': return "＊";
    case '+': return "＋";
    case '=': return "＝";
    case '^': return "＾";
    case '$': return "＄";
    case '_': return "＿";
    case '|': return "｜";
    default: return "";
    }
}

bool is_digit(char c) { return c >= '0' && c <= '9'; }
bool is_lower(char c) { return c >= 'a' && c <= 'z'; }

uint32_t last_scalar_codepoint(const std::string &s) {
    if (s.empty()) return 0;
    size_t i = s.size() - 1;
    while (i > 0 && (static_cast<unsigned char>(s[i]) & 0xC0) == 0x80) --i;
    unsigned char lead = static_cast<unsigned char>(s[i]);
    size_t len = lead < 0x80 ? 1 : (lead & 0xE0) == 0xC0 ? 2 : (lead & 0xF0) == 0xE0 ? 3 : (lead & 0xF8) == 0xF0 ? 4 : 0;
    if (len == 0 || i + len > s.size()) return 0;
    if (len == 1) return lead;  // 单字节标量不掩盖高位
    uint32_t cp = lead & (0xFF >> (len + 1));
    for (size_t k = 1; k < len; ++k) cp = (cp << 6) | (static_cast<unsigned char>(s[i + k]) & 0x3F);
    return cp;
}

bool contains_han(const std::string &s) {
    for (size_t i = 0; i < s.size();) {
        unsigned char lead = static_cast<unsigned char>(s[i]);
        size_t len = lead < 0x80 ? 1 : (lead & 0xE0) == 0xC0 ? 2 : (lead & 0xF0) == 0xE0 ? 3 : (lead & 0xF8) == 0xF0 ? 4 : 0;
        if (len == 0 || i + len > s.size()) return false;
        uint32_t cp = len == 1 ? lead : (lead & (0xFF >> (len + 1)));
        for (size_t k = 1; k < len; ++k) cp = (cp << 6) | (static_cast<unsigned char>(s[i + k]) & 0x3F);
        if (is_han_codepoint(cp)) return true;
        i += len;
    }
    return false;
}

bool is_digit_codepoint(uint32_t cp) { return cp >= '0' && cp <= '9'; }

struct CustomEntry {
    int32_t kind = GC_WORD_SHORTCODE;
    bool enabled = true;
    std::string code;
    std::string pinyin;
    std::string content;
};

bool read_file(const std::string &path, std::string &out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    std::ostringstream ss;
    ss << in.rdbuf();
    out = ss.str();
    return true;
}

// 写临时文件＋fsync＋rename，保证进程被杀或掉电后目标文件要么是完整旧内容、
// 要么是完整新内容，不出现半截文件。rename 后再 fsync 父目录使改名本身落盘。
// fsync 失败按整体失败处理（复查 C1），调用方保留 dirty 状态下次重写。
// 临时名带 pid（复查 C2）：输入法与设置进程可能并发写同一文件，固定 .tmp 会
// 互相覆盖。失败或残留的临时文件下次写入自然覆盖。
bool atomic_write(const std::string &path, const std::string &data) {
    std::string temp = path + "." + std::to_string(::getpid()) + ".tmp";
    {
        std::ofstream out(temp, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out.write(data.data(), static_cast<std::streamsize>(data.size()));
        out.flush();
        if (!out.good()) return false;
    }
    {
        int fd = ::open(temp.c_str(), O_RDONLY);
        if (fd < 0) return false;
        if (::fsync(fd) != 0) {
            ::close(fd);
            std::remove(temp.c_str());
            return false;
        }
        ::close(fd);
    }
    if (std::rename(temp.c_str(), path.c_str()) != 0) {
        std::remove(temp.c_str());
        return false;
    }
    {
        const size_t slash = path.find_last_of('/');
        const std::string dir = slash == std::string::npos ? "." : path.substr(0, slash);
        int dfd = ::open(dir.c_str(), O_RDONLY);
        if (dfd >= 0) {
            ::fsync(dfd);
            ::close(dfd);
        }
    }
    return true;
}

}  // namespace

struct GcNormalSession {
    std::unique_ptr<libime::PinyinIME> ime;
    std::unique_ptr<libime::PinyinContext> context;

    std::string dictPath, modelPath, userDir, customWordsPath, englishWordsPath, glossPath;
    int32_t scheme = GC_SCHEME_XIAOHE;
    uint32_t fuzzyMask = 0;
    bool fullPinyinPreedit = true;
    bool freqEnabled = true;
    bool englishEnabled = false;

    EnglishWordIndex englishIndex;
    std::unordered_map<std::string, std::string> glosses;
    std::vector<CustomEntry> customWords;
    std::vector<CustomEntry> customInDict;
    // 自定义词索引：短码按编码查（列表顺序即设置顺序），拼音词按内容查。
    std::unordered_map<std::string, std::vector<size_t>> shortCodeIndex;
    std::unordered_set<std::string> pinyinContents;
    std::unordered_set<size_t> pinyinContentLengths;
    std::unordered_map<std::string, std::string> learnedWords;  // word -> full pinyin
    std::set<std::string> appDefaults;
    std::set<std::string> excludedApps;

    EngMode engMode = EngMode::Off;
    std::string currentApp, currentField;
    int quoteState = 0;
    uint32_t lastChar = 0;
    size_t selected = 0;         // 合并候选中的高亮（跨事件保持）
    bool literalUsed = false;    // 本次组合使用过大写原样段
    bool modelDirty = false;     // 调频历史待写盘（gc_normal_flush）
    bool learnedDirty = false;   // 已学习词待写盘
    // 合并结果按状态缓存：同一状态下只合并一次（跨事件也复用）。
    bool mergedValid = false;
    MergedSet merged;
    struct QuickAddRecord {
        bool valid = false;
        std::string text;
        std::string pinyin;
        std::string app;
        std::string field;
        int64_t timeMs = 0;
    } quickAdd;
};

namespace {

uint32_t fuzzy_bit_to_flag(uint32_t bit) {
    switch (bit) {
    case GC_FUZZY_Z_ZH: return static_cast<uint32_t>(libime::PinyinFuzzyFlag::Z_ZH);
    case GC_FUZZY_C_CH: return static_cast<uint32_t>(libime::PinyinFuzzyFlag::C_CH);
    case GC_FUZZY_S_SH: return static_cast<uint32_t>(libime::PinyinFuzzyFlag::S_SH);
    case GC_FUZZY_N_L: return static_cast<uint32_t>(libime::PinyinFuzzyFlag::L_N);
    case GC_FUZZY_F_H: return static_cast<uint32_t>(libime::PinyinFuzzyFlag::F_H);
    case GC_FUZZY_L_R: return static_cast<uint32_t>(libime::PinyinFuzzyFlag::L_R);
    case GC_FUZZY_AN_ANG: return static_cast<uint32_t>(libime::PinyinFuzzyFlag::AN_ANG);
    case GC_FUZZY_EN_ENG: return static_cast<uint32_t>(libime::PinyinFuzzyFlag::EN_ENG);
    case GC_FUZZY_IN_ING: return static_cast<uint32_t>(libime::PinyinFuzzyFlag::IN_ING);
    default: return 0;
    }
}

libime::PinyinFuzzyFlags to_libime_fuzzy(uint32_t mask) {
    libime::PinyinFuzzyFlags flags{libime::PinyinFuzzyFlag::None};
    for (uint32_t bit = 1; bit != 0; bit <<= 1) {
        if (mask & bit) {
            auto flag = fuzzy_bit_to_flag(bit);
            if (flag != 0) flags |= static_cast<libime::PinyinFuzzyFlag>(flag);
        }
    }
    return flags;
}

void load_custom_words(GcNormalSession &s, bool reportError, std::string &error) {
    s.customWords.clear();
    if (s.customWordsPath.empty()) return;
    GcCustomWordList *list = nullptr;
    if (gc_custom_words_read(s.customWordsPath.c_str(), &list) != 0) return;
    if (list->corrupt != 0 && reportError) {
        error = "custom-words.tsv 已损坏，已备份并以空表启动";
    }
    for (size_t i = 0; i < list->count; ++i) {
        const auto &w = list->words[i];
        CustomEntry e;
        e.kind = w.kind;
        e.enabled = w.enabled != 0;
        e.code = w.code == nullptr ? "" : w.code;
        e.pinyin = w.pinyin == nullptr ? "" : w.pinyin;
        e.content = w.content == nullptr ? "" : w.content;
        s.customWords.push_back(e);
    }
    gc_custom_word_list_free(list);
}

// 自定义词索引：短码按编码查（保持设置页顺序），拼音词按内容查。
void rebuild_custom_indexes(GcNormalSession &s) {
    s.shortCodeIndex.clear();
    s.pinyinContents.clear();
    s.pinyinContentLengths.clear();
    for (size_t i = 0; i < s.customWords.size(); ++i) {
        const auto &w = s.customWords[i];
        if (!w.enabled) continue;
        if (w.kind == GC_WORD_SHORTCODE) {
            s.shortCodeIndex[w.code].push_back(i);
        } else if (w.kind == GC_WORD_PINYIN) {
            s.pinyinContents.insert(w.content);
            s.pinyinContentLengths.insert(w.content.size());
        }
    }
}

// 合并结果与状态绑定：任何影响候选的变更都必须让它失效。
void invalidate_merge(GcNormalSession &s) { s.mergedValid = false; }

void sync_custom_dict(GcNormalSession &s) {
    std::vector<CustomEntry> want;
    for (const auto &w : s.customWords) {
        if (w.kind == GC_WORD_PINYIN && w.enabled) want.push_back(w);
    }
    for (const auto &old : s.customInDict) {
        bool still = false;
        for (const auto &nw : want) {
            if (nw.pinyin == old.pinyin && nw.content == old.content) {
                still = true;
                break;
            }
        }
        if (!still) s.ime->dict()->removeWord(kUserDictIdx, old.pinyin, old.content);
    }
    for (const auto &nw : want) {
        bool exists = false;
        for (const auto &old : s.customInDict) {
            if (old.pinyin == nw.pinyin && old.content == nw.content) {
                exists = true;
                break;
            }
        }
        if (!exists) s.ime->dict()->addWord(kUserDictIdx, nw.pinyin, nw.content, kCustomWordCost);
    }
    s.customInDict = std::move(want);
}

void load_learned_words(GcNormalSession &s) {
    s.learnedWords.clear();
    if (s.userDir.empty()) return;
    std::string data;
    if (!read_file(s.userDir + "/learned.txt", data)) return;
    std::istringstream in(data);
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        auto tab = line.find('\t');
        if (tab == std::string::npos) continue;
        std::string word = line.substr(0, tab);
        std::string pinyin = line.substr(tab + 1);
        if (!word.empty() && !pinyin.empty()) {
            s.learnedWords[word] = pinyin;
            s.ime->dict()->addWord(kUserDictIdx, pinyin, word, kLearnedWordCost);
        }
    }
}

GcSnapshot *make_snapshot(const GcNormalSession &s) {
    auto *snap = static_cast<GcSnapshot *>(std::calloc(1, sizeof(GcSnapshot)));
    if (snap == nullptr) throw std::bad_alloc();
    snap->preedit_caret = -1;
    snap->consumed = 1;
    snap->english = s.engMode == EngMode::Temp ? 1 : (s.engMode == EngMode::AppDefault ? 2 : 0);
    return snap;
}

void set_str(char **field, const std::string &value) { *field = copy_cstr(value); }

std::pair<std::string, int64_t> display_preedit(GcNormalSession &s) {
    auto &c = *s.context;
    const std::string staged = c.selectedSentence();
    const size_t selLen = c.selectedLength();
    // 展开全拼：两种输入方案都尊重 fullPinyinPreedit（小鹤 nihc → ni'hao）。
    // libime 返回的 caret 是预编辑串的字节偏移；空格换成撇号是 1:1 字节替换，
    // 偏移保持有效。
    if (s.fullPinyinPreedit) {
        auto withCursor = c.preeditWithCursor(libime::PinyinPreeditMode::Pinyin);
        std::string preedit = withCursor.first;
        for (auto &ch : preedit) {
            if (ch == ' ') ch = '\'';
        }
        // libime 没有可用候选时只回已暂存中文；此时退回原码形态，避免丢字。
        if (preedit != staged) {
            return {preedit, static_cast<int64_t>(withCursor.second)};
        }
    }
    const std::string &userInput = c.userInput();
    std::string raw = selLen <= userInput.size() ? userInput.substr(selLen) : "";
    const size_t cursor = c.cursor();
    const int64_t caret = static_cast<int64_t>(staged.size()) +
                          static_cast<int64_t>(cursor > selLen ? cursor - selLen : 0);
    return {staged + raw, caret};
}

// 按需物化候选：文本、释义、最终类别。
// 返回的引用指向 MergedSet::cache 内部；调用方不得在下一次物化后继续持有它。
const MaterializedCandidate &materialize_candidate(GcNormalSession &s, MergedSet &ms, size_t index) {
    for (const auto &cached : ms.cache) {
        if (cached.first == index) return cached.second;
    }
    const MergedEntry &e = ms.entries[index];
    MaterializedCandidate m;
    m.completes = e.completes;
    m.deletable = false;
    if (e.libimeText) {
        const auto &chinese = s.context->candidatesToCursor();
        const std::string word = chinese[e.libimeIndex].toString();
        m.text = ms.staged;
        m.text += word;
        auto g = s.glosses.find(word);
        if (g == s.glosses.end()) g = s.glosses.find(m.text);
        if (g != s.glosses.end()) m.gloss = g->second;
        if (e.pinyinWord) {
            m.kind = GC_CAND_PINYIN_WORD;
        } else {
            auto lw = s.learnedWords.find(word);
            if (lw != s.learnedWords.end()) {
                m.kind = GC_CAND_LEARNED;
                m.deletable = true;
                m.pinyin = lw->second;
            } else {
                m.kind = GC_CAND_CHINESE;
            }
        }
    } else {
        m.kind = e.kind;
        m.text = e.fixedText;
        auto g = s.glosses.find(e.fixedText);
        if (g != s.glosses.end()) m.gloss = g->second;
    }
    ms.cache.emplace_back(index, std::move(m));
    return ms.cache.back().second;
}

// 合并当前候选：短码 → 拼音词（完整匹配提升）→ 英文块 → 普通候选。
// 只计算身份与总数；文本在展示／选择时按需物化（当前页与下一页，≤18 项）。
MergedSet build_merged_set(GcNormalSession &s) {
    MergedSet ms;
    auto &c = *s.context;
    const auto &chinese = c.candidatesToCursor();
    ms.staged = c.selectedSentence();
    const size_t stagedLen = c.selectedLength();
    const size_t limit = std::min(chinese.size(), kMaxChineseCandidates);
    ms.cache.reserve(kPageSize * 2);

    // 中文候选身份：覆盖判定只读候选句尾下标，不生成文本。
    std::vector<char> completes(limit, 0);
    for (size_t i = 0; i < limit; ++i) {
        const auto &nodes = chinese[i].sentence();
        const size_t end = nodes.empty() ? stagedLen : stagedLen + nodes.back()->to()->index();
        completes[i] = end == c.size() ? 1 : 0;
    }

    // 拼音词完整匹配提升：首个「完整覆盖且文本等于启用拼音词」的中文候选。
    // 单节点候选直接比对节点词；多节点候选先按字节长度筛，避免无谓的字符串拼接。
    size_t boostIndex = SIZE_MAX;
    if (!s.pinyinContents.empty()) {
        for (size_t i = 0; i < limit; ++i) {
            if (completes[i] == 0) continue;
            const auto &nodes = chinese[i].sentence();
            if (nodes.size() == 1) {
                if (s.pinyinContents.count(nodes[0]->word()) != 0) {
                    boostIndex = i;
                    break;
                }
                continue;
            }
            size_t len = 0;
            for (const auto *node : nodes) len += node->word().size();
            if (s.pinyinContentLengths.count(len) == 0) continue;
            std::string word;
            word.reserve(len);
            for (const auto *node : nodes) word += node->word();
            if (s.pinyinContents.count(word) != 0) {
                boostIndex = i;
                break;
            }
        }
    }

    const std::string &raw = c.userInput();
    const std::string remain = stagedLen <= raw.size() ? raw.substr(stagedLen) : "";

    // 短码：无暂存、无大写原样段、当前输入恰好等于编码。
    std::vector<MergedEntry> shortEntries;
    if (stagedLen == 0 && !s.literalUsed && !remain.empty() && remain.size() <= kMaxShortcodeLen) {
        auto it = s.shortCodeIndex.find(remain);
        if (it != s.shortCodeIndex.end()) {
            for (size_t index : it->second) {
                MergedEntry e;
                e.kind = GC_CAND_SHORTCODE;
                e.completes = true;
                e.fixedText = s.customWords[index].content;
                shortEntries.push_back(std::move(e));
            }
        }
    }

    // 英文候选：整段为小写字母；整词一致（≥3）或前缀补全（≥4，最多 3）。
    std::vector<MergedEntry> englishEntries;
    bool englishAfterFirstChinese = false;
    if (s.englishEnabled && stagedLen == 0 && remain.size() >= 3) {
        bool allLower = true;
        for (char ch : remain) {
            if (!is_lower(static_cast<unsigned char>(ch))) {
                allLower = false;
                break;
            }
        }
        if (allLower) {
            // 中文首选（含汉字）无法完整覆盖输入时英文排第一；否则排第二位。
            englishAfterFirstChinese = limit > 0 && completes[0] != 0 &&
                                       contains_han(chinese[0].toString());
            uint32_t exactIndex = 0;
            if (s.englishIndex.findExact(remain, exactIndex)) {
                MergedEntry e;
                e.kind = GC_CAND_ENGLISH;
                e.completes = true;
                e.fixedText = remain;  // 保留输入大小写
                englishEntries.push_back(std::move(e));
            }
            if (remain.size() >= 4) {
                std::vector<uint32_t> hits;
                s.englishIndex.findPrefix(remain, kMaxEnglishPrefixHits, hits);
                for (uint32_t hit : hits) {
                    MergedEntry e;
                    e.kind = GC_CAND_ENGLISH;
                    e.completes = true;
                    e.fixedText = s.englishIndex.words()[hit];
                    englishEntries.push_back(std::move(e));
                }
            }
        }
    }

    std::vector<MergedEntry> out;
    out.reserve(shortEntries.size() + englishEntries.size() + limit + 1);
    for (auto &e : shortEntries) out.push_back(std::move(e));
    size_t firstChinese = SIZE_MAX;
    if (boostIndex != SIZE_MAX) {
        MergedEntry e;
        e.kind = GC_CAND_CHINESE;
        e.libimeText = true;
        e.pinyinWord = true;
        e.libimeIndex = boostIndex;
        e.completes = completes[boostIndex] != 0;
        out.push_back(std::move(e));
    }
    if (englishAfterFirstChinese) {
        for (size_t i = 0; i < limit; ++i) {
            if (i == boostIndex) continue;
            firstChinese = i;
            break;
        }
        if (firstChinese != SIZE_MAX) {
            MergedEntry e;
            e.kind = GC_CAND_CHINESE;
            e.libimeText = true;
            e.libimeIndex = firstChinese;
            e.completes = completes[firstChinese] != 0;
            out.push_back(std::move(e));
        }
    }
    for (auto &e : englishEntries) out.push_back(std::move(e));
    for (size_t i = 0; i < limit; ++i) {
        if (i == boostIndex || i == firstChinese) continue;
        MergedEntry e;
        e.kind = GC_CAND_CHINESE;
        e.libimeText = true;
        e.libimeIndex = i;
        e.completes = completes[i] != 0;
        out.push_back(std::move(e));
    }
    ms.entries = std::move(out);
    return ms;
}

// 预热当前页与下一页的候选文本（最多 18 项）：翻页与选中不必再转文本。
void warm_visible_pages(GcNormalSession &s) {
    MergedSet &ms = s.merged;
    const size_t total = ms.entries.size();
    if (total == 0) return;
    const size_t sel = std::min(s.selected, total - 1);
    const size_t page = sel / kPageSize;
    for (size_t p = page; p <= page + 1; ++p) {
        const size_t start = p * kPageSize;
        if (start >= total) break;
        const size_t count = std::min(kPageSize, total - start);
        for (size_t i = 0; i < count; ++i) materialize_candidate(s, ms, start + i);
    }
}

// 合并结果按状态缓存：同一状态下只合并一次（跨事件也复用）。
MergedSet &merged_set(GcNormalSession &s) {
    if (!s.mergedValid) {
        s.merged = build_merged_set(s);
        s.mergedValid = true;
        warm_visible_pages(s);
    }
    return s.merged;
}

GcSnapshot *build_snapshot(GcNormalSession &s, const std::string &commit,
                           const std::string &status, int32_t toast, bool beep,
                           bool consumed, MergedSet *merged) {
    auto *snap = make_snapshot(s);
    set_str(&snap->commit, commit);
    set_str(&snap->status, status);
    snap->toast = toast;
    snap->beep = beep ? 1 : 0;
    snap->consumed = consumed ? 1 : 0;
    const bool composing = s.context->selectedLength() > 0 || !s.context->empty();
    snap->composing = composing ? 1 : 0;
    if (composing) {
        auto pre = display_preedit(s);
        set_str(&snap->marked, pre.first);
        set_str(&snap->preedit, pre.first);
        snap->preedit_caret = pre.second;
        // 已暂存（已转中文）前缀长度：预编辑开头就是暂存中文时报告其标量个数。
        // 平台只用它分色，不决定光标（光标由 preedit_caret 的字节偏移给出）。
        const std::string staged = s.context->selectedSentence();
        const bool startsWithStaged = !staged.empty() && pre.first.rfind(staged, 0) == 0;
        size_t scalars = 0;
        if (startsWithStaged) {
            for (size_t i = 0; i < staged.size();) {
                unsigned char b = static_cast<unsigned char>(staged[i]);
                i += b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4;
                ++scalars;
            }
        }
        snap->typed_prefix_len = static_cast<int64_t>(scalars);
    } else {
        snap->typed_prefix_len = 0;
        set_str(&snap->marked, "");
        set_str(&snap->preedit, "");
    }
    // 候选列表只在组合仍在进行时附带；提交／清空后的快照不得携带候选页。
    if (composing && merged != nullptr && !merged->entries.empty()) {
        const size_t total = merged->entries.size();
        const size_t pageCount = (total + kPageSize - 1) / kPageSize;
        const size_t sel = std::min(s.selected, total - 1);
        const size_t page = sel / kPageSize;
        const size_t start = page * kPageSize;
        const size_t count = std::min(kPageSize, total - start);
        snap->candidates = static_cast<GcCandidate *>(std::calloc(count, sizeof(GcCandidate)));
        if (snap->candidates == nullptr) throw std::bad_alloc();
        for (size_t n = 0; n < count; ++n) {
            const MaterializedCandidate &m = materialize_candidate(s, *merged, start + n);
            auto &item = snap->candidates[n];
            item.text = copy_cstr(m.text);
            item.gloss = copy_cstr(m.gloss);
            item.kind = m.kind;
            item.deletable = m.deletable ? 1 : 0;
            item.completes = m.completes ? 1 : 0;
        }
        snap->count = count;
        snap->selected = sel;
        snap->page = page;
        snap->page_count = pageCount;
        snap->total = total;
    }
    return snap;
}

// 解码已选词的拼音（撇号连接）；失败返回空串。
std::string selected_pinyin(GcNormalSession &s) {
    try {
        const auto words = s.context->selectedWordsWithPinyin();
        std::string result;
        for (const auto &wc : words) {
            std::string pinyin = libime::PinyinEncoder::decodeFullPinyin(wc.second);
            if (pinyin.empty()) return "";
            if (!result.empty()) result += '\'';
            result += pinyin;
        }
        return result;
    } catch (...) {
        return "";
    }
}

struct CommitResult {
    std::string text;    // 空 = 部分暂存继续组合
    std::string pinyin;  // 中文完整上屏时的实际拼音（快速添加用）
    bool learned = false;
};

// 选中合并候选（中文类走 libime 选择；自定义/英文直接上屏）。
CommitResult select_merged(GcNormalSession &s, MergedSet &ms, size_t index) {
    CommitResult result;
    const MergedEntry &entry = ms.entries[index];
    const MaterializedCandidate &m = materialize_candidate(s, ms, index);
    switch (m.kind) {
    case GC_CAND_ENGLISH:
    case GC_CAND_SHORTCODE:
    case GC_CAND_PINYIN_WORD:
        s.context->clear();
        s.context->clearContextWords();
        invalidate_merge(s);
        result.text = m.text;
        return result;
    default:
        break;
    }
    s.context->selectCandidatesToCursor(entry.libimeIndex);
    if (s.context->selected()) {
        result.text = s.context->selectedSentence();
        if (s.freqEnabled) {
            // 整句词＋实际拼音：learn() 负责历史调频；词级条目自行登记，
            // 保证 Control＋Backspace 可删。
            std::string joined;
            std::string pinyin;
            size_t scalarCount = 0;
            for (const auto &wc : s.context->selectedWordsWithPinyin()) {
                joined += wc.first;
                ++scalarCount;
                std::string p;
                try {
                    p = libime::PinyinEncoder::decodeFullPinyin(wc.second);
                } catch (...) {
                    p = "";
                }
                if (p.empty()) continue;
                if (!pinyin.empty()) pinyin += '\'';
                pinyin += p;
            }
            s.context->learn();
            s.modelDirty = true;
            result.pinyin = pinyin;
            result.learned = true;  // 候选完整上屏即可快速添加（含单字）
            if (scalarCount >= 2 && !pinyin.empty() &&
                s.learnedWords.find(joined) == s.learnedWords.end()) {
                s.ime->dict()->addWord(kUserDictIdx, pinyin, joined, kLearnedWordCost);
                s.learnedWords[joined] = pinyin;
                s.learnedDirty = true;
            }
        }
        s.context->clear();
        s.context->clearContextWords();
        invalidate_merge(s);
        return result;
    }
    invalidate_merge(s);  // 部分暂存：上下文已变，合并结果失效
    return result;  // 部分暂存
}

// 组合剩余全部上屏文本（暂存＋剩余原编码）。
std::string composition_remainder(GcNormalSession &s) {
    auto &c = *s.context;
    const std::string raw = c.userInput();
    return c.selectedSentence() + (c.selectedLength() <= raw.size() ? raw.substr(c.selectedLength()) : "");
}

// 标点字符映射（含引号交替与数字后半角例外）。
// 组合中以前缀文本末字符为准；未组合时以最近一次交还/上屏的字符为准。
std::string mapped_punct(GcNormalSession &s, const std::string &prefix, char ch, const std::string &rawText) {
    if (ch == '"') {
        std::string p = s.quoteState == 0 ? "\u201c" : "\u201d";
        s.quoteState ^= 1;
        return p;
    }
    if (ch == '\'') {
        std::string p = s.quoteState == 0 ? "\u2018" : "\u2019";
        s.quoteState ^= 1;
        return p;
    }
    const uint32_t prev = prefix.empty() ? s.lastChar : last_scalar_codepoint(prefix);
    if ((ch == '.' || ch == ':') && is_digit_codepoint(prev)) {
        return rawText;  // 数字后半角例外
    }
    return punct_map(ch);
}

EngMode base_default(const GcNormalSession &s, const std::string &app) {
    return s.appDefaults.count(app) > 0 ? EngMode::AppDefault : EngMode::Off;
}

void record_commit(GcNormalSession &s, const GcKeyEvent *ev, const std::string &text, const std::string &pinyin) {
    s.quickAdd.valid = true;
    s.quickAdd.text = text;
    s.quickAdd.pinyin = pinyin;
    s.quickAdd.app = ev->app == nullptr ? "" : ev->app;
    s.quickAdd.field = ev->field == nullptr ? "" : ev->field;
    s.quickAdd.timeMs = ev->time_ms;
}

}  // namespace

extern "C" void gc_snapshot_free(GcSnapshot *snapshot) {
    if (snapshot == nullptr) return;
    free(snapshot->commit);
    free(snapshot->marked);
    free(snapshot->preedit);
    free(snapshot->status);
    if (snapshot->candidates != nullptr) {
        for (size_t i = 0; i < snapshot->count; ++i) {
            free(snapshot->candidates[i].text);
            free(snapshot->candidates[i].gloss);
        }
    }
    free(snapshot->candidates);
    free(snapshot);
}

extern "C" int gc_normal_session_create(const GcNormalConfig *config, GcNormalSession **out,
                                        char *err, size_t err_len) {
    if (out == nullptr || config == nullptr || config->dict_path == nullptr || config->model_path == nullptr) return 1;
    *out = nullptr;
    auto seterr = [&](const std::string &m) {
        if (err != nullptr && err_len > 0) snprintf(err, err_len, "%s", m.c_str());
    };
    try {
        auto *s = new GcNormalSession();
        s->dictPath = config->dict_path;
        s->modelPath = config->model_path;
        s->userDir = config->user_dir == nullptr ? "" : config->user_dir;
        s->customWordsPath = config->custom_words_path == nullptr ? "" : config->custom_words_path;
        s->englishWordsPath = config->english_words_path == nullptr ? "" : config->english_words_path;
        s->glossPath = config->gloss_path == nullptr ? "" : config->gloss_path;
        s->scheme = config->scheme;
        s->fuzzyMask = config->fuzzy_mask;
        s->fullPinyinPreedit = config->full_pinyin_preedit != 0;
        s->freqEnabled = config->freq_enabled != 0;
        s->englishEnabled = config->english_enabled != 0;

        std::string errorMsg;
        load_custom_words(*s, true, errorMsg);
        rebuild_custom_indexes(*s);

        auto dict = std::make_unique<libime::PinyinDictionary>();
        dict->load(0, s->dictPath.c_str(), libime::PinyinDictFormat::Binary);
        auto model = std::make_unique<libime::UserLanguageModel>(s->modelPath.c_str());
        if (!s->userDir.empty()) {
            std::string userModel;
            if (read_file(s->userDir + "/model.userlm", userModel)) {
                try {
                    std::istringstream in(userModel);
                    model->load(in);
                } catch (const std::exception &) {
                    // 调频历史损坏不能让整个输入法不可用：备份后以空模型继续。
                    const std::string userLm = s->userDir + "/model.userlm";
                    std::error_code ec;
                    std::filesystem::rename(userLm, userLm + ".corrupt", ec);
                    if (errorMsg.empty()) errorMsg = "model.userlm 已损坏，已备份并以空调频历史启动";
                }
            }
        }
        s->ime = std::make_unique<libime::PinyinIME>(std::move(dict), std::move(model));
        load_learned_words(*s);
        sync_custom_dict(*s);
        s->ime->setPreeditMode(libime::PinyinPreeditMode::Pinyin);
        s->context = std::make_unique<libime::PinyinContext>(s->ime.get());
        s->context->setMaxSentenceLength(static_cast<int>(kMaxInputScalars));
        gc_normal_update(s, s->scheme, s->fuzzyMask, s->fullPinyinPreedit ? 1 : 0, s->freqEnabled ? 1 : 0);

        if (!s->englishWordsPath.empty()) {
            std::string data;
            if (read_file(s->englishWordsPath, data)) {
                std::istringstream in(data);
                std::string line;
                std::vector<std::string> words;
                while (std::getline(in, line)) {
                    if (!line.empty() && line.back() == '\r') line.pop_back();
                    if (line.empty() || line[0] == '#') continue;
                    auto sp = line.find(' ');
                    words.push_back(sp == std::string::npos ? line : line.substr(0, sp));
                }
                s->englishIndex.build(std::move(words));
            }
        }
        if (!s->glossPath.empty()) {
            std::string data;
            if (read_file(s->glossPath, data)) {
                std::istringstream in(data);
                std::string line;
                while (std::getline(in, line)) {
                    if (!line.empty() && line.back() == '\r') line.pop_back();
                    auto tab = line.find('\t');
                    if (tab == std::string::npos || tab == 0) continue;
                    s->glosses[line.substr(0, tab)] = line.substr(tab + 1);
                }
            }
        }
        if (!errorMsg.empty()) seterr(errorMsg);
        *out = s;
        return 0;
    } catch (const std::exception &e) {
        seterr(e.what());
        return 2;
    } catch (...) {
        seterr("引擎初始化失败");
        return 2;
    }
}

extern "C" void gc_normal_session_destroy(GcNormalSession *s) { delete s; }

extern "C" int gc_normal_set_app_defaults(GcNormalSession *s, const char *const *apps, size_t count) {
    if (s == nullptr || (count > 0 && apps == nullptr)) return 1;
    s->appDefaults.clear();
    for (size_t i = 0; i < count; ++i) {
        if (apps[i] != nullptr) s->appDefaults.insert(apps[i]);
    }
    return 0;
}

extern "C" int gc_normal_set_excluded_apps(GcNormalSession *s, const char *const *apps, size_t count) {
    if (s == nullptr || (count > 0 && apps == nullptr)) return 1;
    s->excludedApps.clear();
    for (size_t i = 0; i < count; ++i) {
        if (apps[i] != nullptr) s->excludedApps.insert(apps[i]);
    }
    return 0;
}

extern "C" int gc_normal_update(GcNormalSession *s, int32_t scheme, uint32_t fuzzy_mask,
                                int32_t full_pinyin_preedit, int32_t freq_enabled) {
    if (s == nullptr) return 1;
    s->scheme = scheme == GC_SCHEME_FULLPINYIN ? GC_SCHEME_FULLPINYIN : GC_SCHEME_XIAOHE;
    s->fuzzyMask = fuzzy_mask;
    s->fullPinyinPreedit = full_pinyin_preedit != 0;
    s->freqEnabled = freq_enabled != 0;
    if (s->ime != nullptr) {
        s->ime->setFuzzyFlags(to_libime_fuzzy(s->fuzzyMask));
        if (s->scheme == GC_SCHEME_XIAOHE) {
            s->ime->setShuangpinProfile(std::make_shared<libime::ShuangpinProfile>(libime::ShuangpinBuiltinProfile::Xiaohe));
        }
    }
    if (s->context != nullptr) {
        s->context->setUseShuangpin(s->scheme == GC_SCHEME_XIAOHE);
    }
    invalidate_merge(*s);
    return 0;
}

extern "C" int gc_normal_reload_custom_words(GcNormalSession *s) {
    if (s == nullptr) return 1;
    std::string error;
    load_custom_words(*s, false, error);
    rebuild_custom_indexes(*s);
    sync_custom_dict(*s);
    invalidate_merge(*s);
    return 0;
}

extern "C" int gc_normal_flush(GcNormalSession *s) {
    if (s == nullptr) return 1;
    if (s->userDir.empty() || (!s->modelDirty && !s->learnedDirty)) return 0;
    try {
        if (!s->userDir.empty()) {
            std::error_code ec;
            std::filesystem::create_directories(s->userDir, ec);
        }
        if (s->modelDirty) {
            std::ostringstream out;
            s->ime->model()->save(out);
            if (atomic_write(s->userDir + "/model.userlm", out.str())) s->modelDirty = false;
        }
        if (s->learnedDirty) {
            std::string lines;
            for (const auto &wp : s->learnedWords) lines += wp.first + "\t" + wp.second + "\n";
            if (atomic_write(s->userDir + "/learned.txt", lines)) s->learnedDirty = false;
        }
        return 0;
    } catch (...) {
        return 2;
    }
}

extern "C" int32_t gc_normal_quick_add_available(GcNormalSession *s) {
    return s != nullptr && s->quickAdd.valid ? 1 : 0;
}

extern "C" size_t gc_normal_copy_raw(GcNormalSession *s, char *buffer, size_t capacity) {
    if (s == nullptr || s->context == nullptr) return 0;
    const std::string &raw = s->context->userInput();
    const size_t required = raw.size() + 1;  // 含结尾 NUL
    if (buffer == nullptr || capacity < required) return required;
    memcpy(buffer, raw.data(), raw.size());
    buffer[raw.size()] = '\0';
    return required;
}

extern "C" int gc_normal_handle(GcNormalSession *s, const GcKeyEvent *event, GcSnapshot **out) {
    if (s == nullptr || event == nullptr || out == nullptr) return 1;
    *out = nullptr;
    try {
        auto &c = *s->context;
        const std::string app = event->app == nullptr ? "" : event->app;
        const std::string field = event->field == nullptr ? "" : event->field;
        std::string commit;
        std::string status;
        int32_t toast = 0;
        bool beep = false;
        bool consumed = true;
        const bool composing = c.selectedLength() > 0 || !c.empty();

        switch (event->kind) {
        case GC_EV_FOCUS_SYNC: {
            const bool appChanged = app != s->currentApp;
            const bool fieldChanged = field != s->currentField;
            s->currentApp = app;
            s->currentField = field;
            if (appChanged || fieldChanged) {
                if (composing) {
                    c.clear();
                    c.clearContextWords();
                }
                s->quoteState = 0;
                s->lastChar = 0;
                s->literalUsed = false;
                s->selected = 0;
                invalidate_merge(*s);
            }
            if (appChanged) s->engMode = base_default(*s, app);
            *out = build_snapshot(*s, "", "", 0, false, false, nullptr);
            return 0;
        }
        case GC_EV_SHIFT_CLICK: {
            if (composing) {
                // 组合中 Shift：暂存＋剩余原编码一次上屏，不切中英。
                // 提交后必须更新最近上屏字符：下一个标点以它判定数字后半角
                // 例外（反例：数字 7 → 组合 nihc → Shift → 句号，应得全角「。」
                // 而非沿用数字后半角；与 Enter／空格／选词提交同规则）。
                commit = composition_remainder(*s);
                c.clear();
                c.clearContextWords();
                invalidate_merge(*s);
                s->lastChar = last_scalar_codepoint(commit);
                s->literalUsed = false;
                s->selected = 0;
            } else if (s->engMode == EngMode::Off) {
                s->engMode = EngMode::Temp;
                toast = 2;
            } else if (s->engMode == EngMode::Temp) {
                s->engMode = base_default(*s, app);
                toast = s->engMode == EngMode::AppDefault ? 2 : 1;
            } else {
                s->engMode = EngMode::Off;  // 按应用默认英文被 Shift 覆盖为中文
                toast = 1;
            }
            *out = build_snapshot(*s, commit, status, toast, beep, consumed, nullptr);
            return 0;
        }
        case GC_EV_ESC: {
            if (composing) {
                c.clear();
                c.clearContextWords();
                invalidate_merge(*s);
                s->literalUsed = false;
                s->selected = 0;
            } else if (s->engMode != base_default(*s, app)) {
                s->engMode = base_default(*s, app);
                toast = s->engMode == EngMode::Off ? 1 : 2;
            } else {
                consumed = false;
            }
            *out = build_snapshot(*s, "", status, toast, beep, consumed, nullptr);
            return 0;
        }
        case GC_EV_QUICK_ADD: {
            bool eligible = s->quickAdd.valid && !s->quickAdd.pinyin.empty() &&
                            app == s->quickAdd.app && field == s->quickAdd.field &&
                            event->time_ms >= s->quickAdd.timeMs &&
                            event->time_ms - s->quickAdd.timeMs <= kQuickAddWindowMs &&
                            s->excludedApps.count(app) == 0;
            if (eligible) {
                // 内容必须满足拼音词规格（1–16 汉字）；否则不可添加。
                char verr[128] = {0};
                eligible = gc_custom_words_validate(GC_WORD_PINYIN, "", s->quickAdd.pinyin.c_str(),
                                                    s->quickAdd.text.c_str(), verr, sizeof(verr)) == 0;
                (void)verr;
            }
            if (eligible) {
                bool exists = false;
                for (const auto &w : s->customWords) {
                    if (w.kind == GC_WORD_PINYIN && w.content == s->quickAdd.text) {
                        exists = true;
                        break;
                    }
                }
                if (!exists && !s->customWordsPath.empty()) {
                    std::vector<GcCustomWord> all;
                    for (const auto &w : s->customWords) {
                        GcCustomWord cw{};
                        cw.kind = w.kind;
                        cw.enabled = w.enabled ? 1 : 0;
                        cw.code = const_cast<char *>(w.code.c_str());
                        cw.pinyin = const_cast<char *>(w.pinyin.c_str());
                        cw.content = const_cast<char *>(w.content.c_str());
                        all.push_back(cw);
                    }
                    GcCustomWord nw{};
                    nw.kind = GC_WORD_PINYIN;
                    nw.enabled = 1;
                    char empty[] = "";
                    nw.code = empty;
                    nw.pinyin = const_cast<char *>(s->quickAdd.pinyin.c_str());
                    nw.content = const_cast<char *>(s->quickAdd.text.c_str());
                    all.push_back(nw);
                    GcCustomWordList list{};
                    list.words = all.data();
                    list.count = all.size();
                    if (gc_custom_words_write(s->customWordsPath.c_str(), &list) == 0) {
                        load_custom_words(*s, false, status);
                        rebuild_custom_indexes(*s);
                        sync_custom_dict(*s);
                        invalidate_merge(*s);
                        status = "已加入「" + s->quickAdd.text + "」";
                    } else {
                        status = "自定义词语保存失败";
                        beep = true;
                    }
                } else if (exists) {
                    status = "已存在";
                } else {
                    consumed = false;
                }
            } else {
                consumed = false;  // 没有可添加内容：交还宿主
            }
            *out = build_snapshot(*s, "", status, 0, beep, consumed, nullptr);
            return 0;
        }
        default:
            break;
        }

        // 英文直输：除已处理的 Shift/Esc/快捷键外全部交还宿主。
        if (!composing && s->engMode != EngMode::Off) {
            if (event->kind == GC_EV_TEXT && event->text != nullptr && *event->text != '\0') {
                s->lastChar = last_scalar_codepoint(event->text);
            }
            *out = build_snapshot(*s, "", status, 0, beep, false, nullptr);
            return 0;
        }

        // 惰性合并：只有真正需要候选时才合并；同一状态下只合并一次。
        // merged_set 按状态决定是否重建（上下文变更后合并结果失效），
        // 返回的始终是会话内的缓存对象，地址稳定。
        auto ensure_view = [&]() -> MergedSet & { return merged_set(*s); };
        auto candidate_count = [&]() -> size_t { return ensure_view().entries.size(); };
        auto has_candidates = [&]() -> bool { return candidate_count() > 0; };

        switch (event->kind) {
        case GC_EV_TEXT: {
            const std::string text = event->text == nullptr ? "" : event->text;
            if (text.empty() || text.size() > 4) {
                consumed = false;
                break;
            }
            const char ch = text[0];
            const uint32_t cp = last_scalar_codepoint(text);
            if (text.size() == 1 && is_lower(static_cast<unsigned char>(ch))) {
                if (c.size() >= kMaxInputScalars) {
                    beep = true;
                    status = "输入上限 512 个字母";
                    break;
                }
                c.type(text);
                invalidate_merge(*s);
                s->selected = 0;
                *out = build_snapshot(*s, "", status, 0, beep, consumed, &ensure_view());
                return 0;
            }
            if (text.size() == 1 && cp >= 'A' && cp <= 'Z') {
                if (composing) {
                    beep = true;  // 规格只定义组合首字母大写；组合中大写不处理
                    break;
                }
                if (c.size() >= kMaxInputScalars) {
                    beep = true;
                    break;
                }
                std::string lower(1, static_cast<char>(std::tolower(static_cast<unsigned char>(ch))));
                c.type(lower);
                c.selectCustom(1, text);
                invalidate_merge(*s);
                s->literalUsed = true;
                s->selected = 0;
                *out = build_snapshot(*s, "", status, 0, beep, consumed, &ensure_view());
                return 0;
            }
            if (composing) {
                // 有候选时 `,`/`.` 作为翻页键；否则进入标点路径。
                if ((ch == ',' || ch == '.') && has_candidates()) {
                    const size_t total = candidate_count();
                    const size_t last = (total - 1) / kPageSize;
                    const size_t page = std::min(s->selected / kPageSize, last);
                    const size_t nextPage = ch == ',' ? (page > 0 ? page - 1 : page) : (page < last ? page + 1 : page);
                    if (nextPage != page) {
                        s->selected = std::min(nextPage * kPageSize, total - 1);
                        *out = build_snapshot(*s, "", status, 0, beep, consumed, &ensure_view());
                        return 0;
                    }
                    beep = true;  // 已在边界
                    break;
                }
                if (text.size() == 1 && is_digit(ch)) {
                    const long n = ch - '0';
                    // 1–9 选当前页：页内序号 + 页首全局下标。
                    const size_t total = candidate_count();
                    const size_t pageStart = total > 0 ? (std::min(s->selected, total - 1) / kPageSize) * kPageSize : 0;
                    const size_t idx = n == 0 ? SIZE_MAX : pageStart + static_cast<size_t>(n - 1);
                    if (n >= 1 && n <= 9 && idx < total) {
                        CommitResult r = select_merged(*s, ensure_view(), idx);
                        if (r.text.empty()) {
                            s->selected = 0;
                            *out = build_snapshot(*s, "", status, 0, beep, consumed, &ensure_view());
                            return 0;
                        }
                        commit = r.text;
                        if (r.learned) record_commit(*s, event, r.text, r.pinyin);
                        s->lastChar = last_scalar_codepoint(commit);
                    } else {
                        // 0 或超出页内数量：先上屏高亮候选（完整时）再输出数字。
                        std::string prefix;
                        if (total > 0) {
                            MergedSet &ms = ensure_view();
                            const MaterializedCandidate &hm =
                                materialize_candidate(*s, ms, std::min(s->selected, total - 1));
                            if ((hm.kind == GC_CAND_CHINESE || hm.kind == GC_CAND_LEARNED) && hm.completes) {
                                c.selectCandidatesToCursor(ms.entries[std::min(s->selected, total - 1)].libimeIndex);
                                if (c.selected()) {
                                    prefix = c.selectedSentence();
                                    if (s->freqEnabled) {
                                        c.learn();
                                        s->modelDirty = true;
                                        record_commit(*s, event, prefix, selected_pinyin(*s));
                                    }
                                    c.clear();
                                    c.clearContextWords();
                                    invalidate_merge(*s);
                                }
                            }
                        }
                        if (prefix.empty()) prefix = composition_remainder(*s);
                        if (prefix.empty() && c.selectedLength() == 0 && c.empty()) {
                            c.clear();
                            c.clearContextWords();
                        }
                        commit = prefix + text;
                        c.clear();
                        c.clearContextWords();
                        invalidate_merge(*s);
                        s->lastChar = static_cast<uint32_t>(ch);
                    }
                    s->literalUsed = false;
                    s->selected = 0;
                    break;
                }
                // 组合中标点：完整覆盖→暂存＋候选＋标点；部分覆盖→暂存＋剩余原编码＋标点。
                const bool isPunct = !punct_map(ch).empty() || ch == '"' || ch == '\'';
                if (isPunct) {
                    std::string prefix;
                    const size_t total = candidate_count();
                    if (total > 0) {
                        MergedSet &ms = ensure_view();
                        const size_t hi = std::min(s->selected, total - 1);
                        const MaterializedCandidate &hm = materialize_candidate(*s, ms, hi);
                        if ((hm.kind == GC_CAND_CHINESE || hm.kind == GC_CAND_LEARNED) && hm.completes) {
                            c.selectCandidatesToCursor(ms.entries[hi].libimeIndex);
                            if (c.selected()) {
                                prefix = c.selectedSentence();
                                if (s->freqEnabled) {
                                    c.learn();
                                    s->modelDirty = true;
                                    record_commit(*s, event, prefix, selected_pinyin(*s));
                                }
                                c.clear();
                                c.clearContextWords();
                                invalidate_merge(*s);
                            }
                        }
                    }
                    if (prefix.empty()) prefix = composition_remainder(*s);
                    const std::string punct = mapped_punct(*s, prefix, ch, text);
                    commit = prefix + punct;
                    c.clear();
                    c.clearContextWords();
                    invalidate_merge(*s);
                    s->lastChar = last_scalar_codepoint(punct);
                    s->literalUsed = false;
                    s->selected = 0;
                    break;
                }
                // 未处理字符（如 - /）：先上屏组合再交还宿主。
                commit = composition_remainder(*s);
                c.clear();
                c.clearContextWords();
                invalidate_merge(*s);
                s->lastChar = last_scalar_codepoint(commit);
                s->literalUsed = false;
                s->selected = 0;
                consumed = false;
                break;
            }
            // 未组合
            const bool isPunct = !punct_map(ch).empty() || ch == '"' || ch == '\'';
            if (isPunct) {
                const std::string punct = mapped_punct(*s, "", ch, text);
                commit = punct;
                s->lastChar = last_scalar_codepoint(punct);
            } else {
                consumed = false;
                s->lastChar = cp;
            }
            break;
        }
        case GC_EV_SPACE: {
            if (composing) {
                if (!has_candidates()) {
                    if (c.selectedLength() > 0) {
                        commit = c.selectedSentence();
                        c.clear();
                        c.clearContextWords();
                        invalidate_merge(*s);
                        s->lastChar = last_scalar_codepoint(commit);
                        s->literalUsed = false;
                    } else {
                        beep = true;
                    }
                    break;
                }
                const size_t total = candidate_count();
                CommitResult r = select_merged(*s, ensure_view(), std::min(s->selected, total - 1));
                if (r.text.empty()) {
                    s->selected = 0;
                    *out = build_snapshot(*s, "", status, 0, beep, consumed, &ensure_view());
                    return 0;
                }
                commit = r.text;
                if (r.learned) record_commit(*s, event, r.text, r.pinyin);
                s->lastChar = last_scalar_codepoint(commit);
            } else {
                consumed = false;
            }
            break;
        }
        case GC_EV_ENTER: {
            if (composing) {
                commit = composition_remainder(*s);
                c.clear();
                c.clearContextWords();
                invalidate_merge(*s);
                s->lastChar = last_scalar_codepoint(commit);
                s->literalUsed = false;
                s->selected = 0;
            } else {
                consumed = false;
            }
            break;
        }
        case GC_EV_BACKSPACE: {
            if (composing) {
                // 演示裁决：有暂存分段时退格先撤回最后一次选择，再删剩余编码。
                if (c.selectedLength() > 0) {
                    c.cancel();
                } else if (c.cursor() > 0) {
                    c.backspace();
                }
                if (c.empty() && c.selectedLength() == 0) s->literalUsed = false;
                invalidate_merge(*s);
                s->selected = 0;
                *out = build_snapshot(*s, "", status, 0, beep, consumed, &ensure_view());
                return 0;
            }
            consumed = false;
            break;
        }
        case GC_EV_DELETE_WORD: {
            if (composing && has_candidates()) {
                MergedSet &ms = ensure_view();
                const size_t hi = std::min(s->selected, ms.entries.size() - 1);
                const MaterializedCandidate &m = materialize_candidate(*s, ms, hi);
                if (m.deletable) {
                    // 展示文本包含暂存前缀；词典和 learnedWords 的键只含裸词。
                    const std::string word = m.text.substr(ms.staged.size());
                    s->ime->dict()->removeWord(kUserDictIdx, m.pinyin, word);
                    s->learnedWords.erase(word);
                    s->learnedDirty = true;
                    status = "已删除学习词「" + word + "」";
                    invalidate_merge(*s);
                    s->selected = 0;
                    *out = build_snapshot(*s, "", status, 0, beep, consumed, &ensure_view());
                    return 0;
                }
                if (m.kind == GC_CAND_PINYIN_WORD || m.kind == GC_CAND_SHORTCODE) {
                    status = "自定义词请在设置中删除";
                } else if (m.kind == GC_CAND_ENGLISH) {
                    status = "英文候选不参与删词";
                } else {
                    status = "出厂词不能删除";
                }
                beep = true;
                break;
            }
            consumed = false;
            break;
        }
        case GC_EV_UP:
        case GC_EV_CTRL_P: {
            if (composing && has_candidates()) {
                if (s->selected > 0) s->selected -= 1;
            } else if (composing) {
                beep = true;
            } else {
                consumed = false;
            }
            break;
        }
        case GC_EV_DOWN:
        case GC_EV_CTRL_N: {
            if (composing && has_candidates()) {
                if (s->selected + 1 < candidate_count()) s->selected += 1;
            } else if (composing) {
                beep = true;
            } else {
                consumed = false;
            }
            break;
        }
        case GC_EV_PAGE_UP: {
            if (composing && has_candidates()) {
                const size_t page = s->selected / kPageSize;
                if (page > 0) s->selected = (page - 1) * kPageSize;
            } else if (composing) {
                beep = true;
            } else {
                consumed = false;
            }
            break;
        }
        case GC_EV_PAGE_DOWN: {
            if (composing && has_candidates()) {
                const size_t total = candidate_count();
                const size_t last = (total - 1) / kPageSize;
                const size_t page = s->selected / kPageSize;
                if (page < last) s->selected = std::min((page + 1) * kPageSize, total - 1);
            } else if (composing) {
                beep = true;
            } else {
                consumed = false;
            }
            break;
        }
        case GC_EV_LEFT:
        case GC_EV_CTRL_B: {
            if (composing) {
                const size_t cursor = c.cursor();
                if (cursor > c.selectedLength()) c.setCursor(cursor - 1);
                invalidate_merge(*s);
                s->selected = 0;
                *out = build_snapshot(*s, "", status, 0, beep, consumed, &ensure_view());
                return 0;
            }
            consumed = false;
            break;
        }
        case GC_EV_RIGHT:
        case GC_EV_CTRL_F: {
            if (composing) {
                const size_t cursor = c.cursor();
                if (cursor < c.size()) c.setCursor(cursor + 1);
                invalidate_merge(*s);
                s->selected = 0;
                *out = build_snapshot(*s, "", status, 0, beep, consumed, &ensure_view());
                return 0;
            }
            consumed = false;
            break;
        }
        case GC_EV_HOME:
        case GC_EV_CTRL_A: {
            if (composing) {
                c.setCursor(c.selectedLength());
                invalidate_merge(*s);
                s->selected = 0;
                *out = build_snapshot(*s, "", status, 0, beep, consumed, &ensure_view());
                return 0;
            }
            consumed = false;
            break;
        }
        case GC_EV_END:
        case GC_EV_CTRL_E: {
            if (composing) {
                c.setCursor(c.size());
                invalidate_merge(*s);
                s->selected = 0;
                *out = build_snapshot(*s, "", status, 0, beep, consumed, &ensure_view());
                return 0;
            }
            consumed = false;
            break;
        }
        default:
            consumed = false;
            break;
        }

        // 组合仍在进行时才带候选页；已提交或已清空时不附候选。
        MergedSet *snapshotMerged = nullptr;
        if (c.selectedLength() > 0 || !c.empty()) snapshotMerged = &ensure_view();
        *out = build_snapshot(*s, commit, status, toast, beep, consumed, snapshotMerged);
        return 0;
    } catch (...) {
        return 2;
    }
}
