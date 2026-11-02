// 翻译加固层：纯文本规则（2026-11-02 模型路线裁决的处置手段）。
//
// 裁决口径：对固定风险集逐条「修正或安全拦截」均算已处置——回退为显示原文
// 不译、错误译文不进入默认候选即达标（docs/implementation-plan.md §四）。
// 本文件实现与模型无关的检查/归一纯函数，供翻译调度与评测脚本使用：
//   - 重复分类：拦截「参加会议 会议」「早上好 好 好」「181 个 Q」类复读；
//   - 繁→简归一：修正繁体漂移（单字级，见 t2s_table.inc；词组级 v1 不覆盖）；
//   - 时间一致性：拦截「9 a.m.→下午9点」类时段翻转与「十点半→10 点整」丢半；
//   - 脚本校验：输出语向必须与目标一致（简体／拉丁主导）；
//   - 长度比率：拦截疑似截断与膨胀（粗网，短语级截断靠审阅兜底）；
//   - 保护候选扫描：URL／版本号／驼峰／全大写／句中大写词（品牌/人名）。
//
// 已知 v1 局限（记录于 docs/research-translation-model-unblock.md）：
//   - t2s 为单字级，「滑鼠→鼠标」类地区词不转换；
//   - 时间检查按词元/子串近似，不解析完整日期语法；
//   - 句首大写词不作为保护候选（无法与普通句首词区分），品牌保护靠调用方词表；
//   - 小写代码标识符（let/count）不在候选范围。
//
// 全部函数：UTF-8＋字节长度；非法 UTF-8 字节原样透传、绝不崩溃；无全局状态。
#include "gogaku_core.h"

#include <algorithm>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "t2s_table.inc"

namespace {

struct Scalar {
    uint32_t cp;
    size_t begin;
    size_t end;
};

// 宽松 UTF-8 迭代：非法序列按单字节透传，不报错、不越界。
class Utf8View {
public:
    explicit Utf8View(std::string_view text) : text_(text) {}

    template <typename Fn>
    void each(Fn &&fn) const {
        size_t i = 0;
        while (i < text_.size()) {
            const unsigned char lead = static_cast<unsigned char>(text_[i]);
            const size_t len = sequence_length(lead);
            if (len == 1 || i + len > text_.size() || !continuations_ok(i, len)) {
                fn(Scalar{lead, i, i + 1});
                i += 1;
                continue;
            }
            uint32_t cp = lead & lead_mask(len);
            for (size_t k = 1; k < len; ++k) {
                cp = (cp << 6) | (static_cast<unsigned char>(text_[i + k]) & 0x3F);
            }
            fn(Scalar{cp, i, i + len});
            i += len;
        }
    }

    std::vector<Scalar> collect() const {
        std::vector<Scalar> out;
        each([&](const Scalar &s) { out.push_back(s); });
        return out;
    }

private:
    static size_t sequence_length(unsigned char lead) {
        if (lead < 0x80) return 1;
        if ((lead & 0xE0) == 0xC0) return 2;
        if ((lead & 0xF0) == 0xE0) return 3;
        if ((lead & 0xF8) == 0xF0) return 4;
        return 1;  // 孤立续字节：按透传处理
    }
    static unsigned char lead_mask(size_t len) {
        static const unsigned char kMasks[] = {0, 0x7F, 0x1F, 0x0F, 0x07};
        return kMasks[len];
    }
    bool continuations_ok(size_t i, size_t len) const {
        for (size_t k = 1; k < len; ++k) {
            if ((static_cast<unsigned char>(text_[i + k]) & 0xC0) != 0x80) return false;
        }
        return true;
    }

    std::string_view text_;
};

bool is_han(uint32_t cp) {
    return (cp >= 0x3400 && cp <= 0x9FFF) || (cp >= 0xF900 && cp <= 0xFAFF) || cp == 0x3007;
}

bool is_ascii_letter(uint32_t cp) {
    return (cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z');
}

bool is_ascii_digit(uint32_t cp) {
    return cp >= '0' && cp <= '9';
}

// 重复检测词元：CJK 字逐字成元；拉丁/数字连续串折叠为词。
std::vector<std::string_view> tokenize_for_repeat(const std::vector<Scalar> &scalars,
                                                  std::string_view text) {
    std::vector<std::string_view> tokens;
    size_t i = 0;
    while (i < scalars.size()) {
        const Scalar &s = scalars[i];
        if (is_han(s.cp)) {
            tokens.push_back(text.substr(s.begin, s.end - s.begin));
            ++i;
            continue;
        }
        if (!is_ascii_letter(s.cp) && !is_ascii_digit(s.cp)) {
            ++i;
            continue;
        }
        const bool digits = is_ascii_digit(s.cp);
        size_t j = i;
        while (j < scalars.size() &&
               (is_han(scalars[j].cp) ? false
                                      : digits ? is_ascii_digit(scalars[j].cp)
                                               : is_ascii_letter(scalars[j].cp))) {
            ++j;
        }
        tokens.push_back(text.substr(s.begin, scalars[j - 1].end - s.begin));
        i = j;
    }
    return tokens;
}

bool token_equal_lower(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (size_t k = 0; k < a.size(); ++k) {
        char ca = a[k], cb = b[k];
        if (ca >= 'A' && ca <= 'Z') ca = static_cast<char>(ca - 'A' + 'a');
        if (cb >= 'A' && cb <= 'Z') cb = static_cast<char>(cb - 'A' + 'a');
        if (ca != cb) return false;
    }
    return true;
}

const GcT2sEntry *t2s_find(uint32_t cp) {
    size_t lo = 0, hi = kT2sTableSize;
    while (lo < hi) {
        const size_t mid = lo + (hi - lo) / 2;
        if (kT2sTable[mid].trad < cp) {
            lo = mid + 1;
        } else if (kT2sTable[mid].trad > cp) {
            hi = mid;
        } else {
            return &kT2sTable[mid];
        }
    }
    return nullptr;
}

void encode_utf8(uint32_t cp, std::string &out) {
    if (cp < 0x80) {
        out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
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

struct Counts {
    size_t han = 0;
    size_t latin = 0;
};

Counts count_scripts(const std::vector<Scalar> &scalars) {
    Counts c;
    for (const Scalar &s : scalars) {
        if (is_han(s.cp)) c.han += 1;
        else if (is_ascii_letter(s.cp)) c.latin += 1;
    }
    return c;
}

bool han_dominant(const std::vector<Scalar> &scalars) {
    const Counts c = count_scripts(scalars);
    return c.han > 0 && c.han >= c.latin;
}

std::string_view trim(std::string_view v) {
    while (!v.empty() && (v.front() == ' ' || v.front() == '\t' || v.front() == '\n' ||
                          v.front() == '\r')) {
        v.remove_prefix(1);
    }
    while (!v.empty() && (v.back() == ' ' || v.back() == '\t' || v.back() == '\n' ||
                          v.back() == '\r')) {
        v.remove_suffix(1);
    }
    return v;
}

bool contains(std::string_view hay, std::string_view needle) {
    return hay.find(needle) != std::string_view::npos;
}

bool has_digit(std::string_view v) {
    for (const char ch : v) {
        if (ch >= '0' && ch <= '9') return true;
    }
    return false;
}

// 数字时间线索：「10:30」「9点」（含空格分隔的「 9」，配合 am/pm 判断）。
bool has_digit_time(std::string_view v) {
    for (size_t i = 0; i + 1 < v.size(); ++i) {
        if (v[i] < '0' || v[i] > '9') continue;
        if (v[i + 1] == ':') return true;
        // 「点」UTF-8 = E7 82 B9
        if (i + 3 < v.size() && v[i + 1] == '\xE7' && v[i + 2] == '\x82' &&
            v[i + 3] == '\xB9') {
            return true;
        }
        if (v[i + 1] == ' ') return true;
    }
    return false;
}

// ---- 时间事实抽取（源/输出共用词表）----
struct TimeFacts {
    bool has_am = false;             // a.m. / am / morning / 上午 / 早上 / 清晨
    bool has_pm = false;             // p.m. / pm / afternoon / evening / night / 下午 / 晚上 / 傍晚 / 夜里
    bool has_meridiem_digit = false; // 显式「数字＋上下午」
    bool has_half = false;           // 点半 / half past / thirty / :30
    bool has_any_time = false;       // 任何时间线索（含 noon/midnight/中午/午夜）
};

TimeFacts extract_facts(std::string_view v) {
    TimeFacts f;
    // 拉丁侧：按「字母＋点」切词元，去点后比对 am/pm（避免 example/amp 误报）。
    std::string token;
    auto flush_token = [&](bool at_boundary) {
        if (at_boundary && !token.empty()) {
            std::string clean;
            for (const char ch : token) {
                if (ch != '.') clean.push_back(ch);
            }
            for (char &ch : clean) {
                if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
            }
            if (clean == "am") f.has_am = true;
            if (clean == "pm") f.has_pm = true;
        }
        token.clear();
    };
    for (size_t i = 0; i <= v.size(); ++i) {
        const bool in_token = i < v.size() && (is_ascii_letter(v[i]) || v[i] == '.');
        if (!in_token) {
            flush_token(true);
            continue;
        }
        token.push_back(v[i]);
    }

    std::string lower(v);
    for (char &ch : lower) {
        if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
    }
    const std::string_view lv(lower);
    if (contains(lv, "morning")) f.has_am = true;
    if (contains(lv, "afternoon")) f.has_pm = true;
    if (contains(lv, "evening") || contains(lv, "night")) f.has_pm = true;
    if (contains(lv, "noon") || contains(lv, "midnight")) f.has_any_time = true;
    if (contains(lv, "half past") || contains(lv, "thirty")) f.has_half = true;
    if (contains(lv, ":30")) f.has_half = true;

    // 中文侧（按 UTF-8 子串）。
    if (contains(v, "上午") || contains(v, "早上") || contains(v, "清晨")) f.has_am = true;
    if (contains(v, "下午") || contains(v, "晚上") || contains(v, "傍晚") ||
        contains(v, "夜里")) {
        f.has_pm = true;
    }
    if (contains(v, "中午") || contains(v, "午夜") || contains(v, "凌晨")) f.has_any_time = true;
    if (contains(v, "点半")) {
        f.has_half = true;
        f.has_any_time = true;
    }

    if ((f.has_am || f.has_pm) && has_digit_time(v)) f.has_meridiem_digit = true;
    if (f.has_am || f.has_pm || f.has_half || f.has_any_time || f.has_meridiem_digit) {
        f.has_any_time = true;
    }
    return f;
}

}  // namespace

int32_t gc_translate_repeat_classify(const char *text, size_t length) {
    if (text == nullptr || length == 0) return 0;
    const std::string_view view(text, length);
    const auto scalars = Utf8View(view).collect();

    // 0a) 拉丁/数字同一字符连续 ≥3 次 → 严重（181 个 Q；不适用汉字，「哈哈哈」误伤）。
    for (size_t i = 0; i + 2 < scalars.size(); ++i) {
        if ((is_ascii_letter(scalars[i].cp) || is_ascii_digit(scalars[i].cp)) &&
            scalars[i].cp == scalars[i + 1].cp && scalars[i].cp == scalars[i + 2].cp) {
            return 2;
        }
    }

    const auto tokens = tokenize_for_repeat(scalars, view);
    if (tokens.size() < 2) return 0;

    // 0b) 同一词元连续 ≥3 次 → 严重（「好 好 好」）。
    for (size_t i = 0; i + 2 < tokens.size(); ++i) {
        if (token_equal_lower(tokens[i], tokens[i + 1]) &&
            token_equal_lower(tokens[i], tokens[i + 2])) {
            return 2;
        }
    }

    // 0c) 整串即单元的两份以上复制（「thank you thank you」「会议会议」）→ 严重。
    for (size_t k = 2; k * 2 <= tokens.size(); ++k) {
        bool suffix_eq = true;
        for (size_t j = 0; j < k; ++j) {
            if (!token_equal_lower(tokens[tokens.size() - 1 - j],
                                   tokens[tokens.size() - 1 - k - j])) {
                suffix_eq = false;
                break;
            }
        }
        if (suffix_eq && k * 2 >= tokens.size()) return 2;
    }

    // 1) 尾部复制前文、但句子主体仍在（「参加会议 会议」）→ 可疑。
    for (size_t k = 1; k <= 4 && k * 2 <= tokens.size(); ++k) {
        bool suffix_eq = true;
        for (size_t j = 0; j < k; ++j) {
            if (!token_equal_lower(tokens[tokens.size() - 1 - j],
                                   tokens[tokens.size() - 1 - k - j])) {
                suffix_eq = false;
                break;
            }
        }
        if (suffix_eq) return 1;
    }

    // 2) ≥3 元短语非重叠复现（「明天见,你明天见」）→ 可疑。
    for (size_t i = 0; i + 5 < tokens.size(); ++i) {
        for (size_t j = i + 3; j + 2 < tokens.size(); ++j) {
            if (token_equal_lower(tokens[i], tokens[j]) &&
                token_equal_lower(tokens[i + 1], tokens[j + 1]) &&
                token_equal_lower(tokens[i + 2], tokens[j + 2])) {
                return 1;
            }
        }
    }
    return 0;
}

size_t gc_translate_t2s(const char *text, size_t length, char *buffer, size_t buffer_capacity) {
    std::string out;
    if (text != nullptr && length > 0) {
        Utf8View(std::string_view(text, length)).each([&](const Scalar &s) {
            const GcT2sEntry *entry = t2s_find(s.cp);
            if (entry != nullptr) {
                encode_utf8(entry->simp, out);
            } else {
                for (size_t k = s.begin; k < s.end; ++k) {
                    out.push_back(text[k]);  // 未映射或非法字节原样透传
                }
            }
        });
    }
    const size_t needed = out.size() + 1;
    if (buffer != nullptr && buffer_capacity >= needed) {
        std::copy(out.begin(), out.end(), buffer);
        buffer[out.size()] = '\0';
    }
    return needed;
}

int32_t gc_translate_has_traditional(const char *text, size_t length) {
    if (text == nullptr || length == 0) return 0;
    int32_t found = 0;
    Utf8View(std::string_view(text, length)).each([&](const Scalar &s) {
        if (t2s_find(s.cp) != nullptr) found = 1;
    });
    return found;
}

int32_t gc_translate_time_check(const char *source, size_t source_length,
                                const char *output, size_t output_length) {
    if (source == nullptr || output == nullptr) return 0;
    const std::string_view src(source, source_length);
    const std::string_view out(trim(std::string_view(output, output_length)));
    const TimeFacts sf = extract_facts(src);
    if (!sf.has_any_time) return 0;
    const TimeFacts of = extract_facts(out);

    // 1) 时段矛盾（a.m.→下午、上午→p.m.）。
    if (sf.has_am && of.has_pm) return 1;
    if (sf.has_pm && of.has_am) return 1;
    // 2) 源有显式数字时间、输出数字和时间词全丢 → 丢失。
    if (sf.has_meridiem_digit && !has_digit(out) && !of.has_any_time && !of.has_am &&
        !of.has_pm) {
        return 2;
    }
    // 3) 半点丢失（十点半→10 点整、half past→整点）。
    if (sf.has_half && !of.has_half) return 3;
    return 0;
}

int32_t gc_translate_script_check(const char *text, size_t length, char expected) {
    if (text == nullptr) return 2;
    const Counts c = count_scripts(Utf8View(std::string_view(text, length)).collect());
    if (c.han == 0 && c.latin == 0) return 2;
    if (expected == 'Z' || expected == 'z') {
        if (gc_translate_has_traditional(text, length) != 0) return 1;
        return (c.han > 0 && c.han >= c.latin) ? 0 : 1;
    }
    if (expected == 'E' || expected == 'e') {
        return (c.latin > 0 && c.latin > c.han) ? 0 : 1;
    }
    return 2;
}

int32_t gc_translate_length_check(const char *source, size_t source_length,
                                  const char *output, size_t output_length) {
    if (source == nullptr || output == nullptr) return 2;
    const auto src = Utf8View(std::string_view(source, source_length)).collect();
    const auto out = Utf8View(std::string_view(output, output_length)).collect();
    if (src.empty()) return 2;
    if (out.empty()) return 1;
    const long double s = static_cast<long double>(src.size());
    const long double o = static_cast<long double>(out.size());
    const bool src_zh = han_dominant(src);
    // 经验区间：中→英 1 汉字≈0.8–12 标量；英→中 1 标量≈0.10–1.2 汉字。短源放宽下限。
    const long double min_ratio = src_zh ? 0.8L : 0.10L;
    const long double max_ratio = src_zh ? 12.0L : 1.2L;
    const long double min_scalars = src_zh ? 2.0L : 1.0L;
    if (o < std::max(min_scalars, s * min_ratio)) return 1;  // 疑似截断
    if (o > s * max_ratio) return 2;                         // 疑似膨胀
    return 0;
}

size_t gc_translate_protection_scan(const char *text, size_t length,
                                    GcTextRange *out_ranges, size_t capacity) {
    if (text == nullptr || length == 0) return 0;
    const std::string_view view(text, length);
    const auto scalars = Utf8View(view).collect();
    std::vector<GcTextRange> found;

    // URL 优先整段扫描（含 ://?&= 等非词元字符）。
    std::vector<GcTextRange> url_ranges;
    {
        std::string lower(view);
        for (char &ch : lower) {
            if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
        }
        for (const std::string_view needle : {"http://", "https://", "www."}) {
            size_t pos = lower.find(needle);
            while (pos != std::string::npos) {
                size_t end = pos;
                while (end < view.size() && view[end] != ' ' && view[end] != '\t' &&
                       view[end] != '\n') {
                    ++end;
                }
                // 去掉尾部标点。
                while (end > pos && std::string_view(".),;:!?\"'").find(view[end - 1]) !=
                                         std::string_view::npos) {
                    --end;
                }
                url_ranges.push_back(GcTextRange{pos, end});
                pos = lower.find(needle, end);
            }
        }
    }
    auto in_url = [&](size_t begin) {
        for (const GcTextRange &r : url_ranges) {
            if (begin >= r.begin && begin < r.end) return true;
        }
        return false;
    };
    for (const GcTextRange &r : url_ranges) {
        bool dup = false;
        for (const GcTextRange &p : found) {
            if (p.begin == r.begin) dup = true;
        }
        if (!dup) found.push_back(r);
    }

    static const char *kStopwords[] = {
        "a", "an", "the", "i", "you", "we", "he", "she", "it", "they", "my", "your",
        "is", "are", "am", "was", "were", "be", "been", "do", "does", "did", "have",
        "has", "had", "will", "would", "can", "could", "should", "shall", "may",
        "in", "on", "at", "to", "for", "with", "by", "from", "of", "and", "but",
        "or", "if", "then", "so", "not", "no", "yes", "next", "this", "that",
        "these", "those", "there", "here", "please", "open", "meet", "good", "let",
        "see", "what", "when", "where", "how", "why", "who", "tomorrow", "today",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december", "morning", "afternoon",
        "evening", "night", "meeting", "email", "report", "file", "station"};

    auto ascii_at = [&](size_t idx) {
        return idx < scalars.size() && scalars[idx].cp < 0x80;
    };

    size_t i = 0;
    while (i < scalars.size()) {
        if (!ascii_at(i) || !is_ascii_letter(scalars[i].cp) || in_url(scalars[i].begin)) {
            ++i;
            continue;
        }
        size_t j = i;
        while (j < scalars.size() && ascii_at(j) &&
               (is_ascii_letter(scalars[j].cp) || is_ascii_digit(scalars[j].cp) ||
                scalars[j].cp == '.')) {
            ++j;
        }
        size_t end = j;
        while (end > i && scalars[end - 1].cp == '.') --end;  // 去掉句子结尾句点
        if (end > i) {
            const auto tok = view.substr(scalars[i].begin, scalars[end - 1].end - scalars[i].begin);
            std::string lower(tok);
            for (char &ch : lower) {
                if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
            }
            size_t upper = 0, lowerc = 0, digits = 0, dots = 0;
            bool internal_upper = false;
            for (size_t k = 0; k < tok.size(); ++k) {
                const char ch = tok[k];
                if (ch >= 'A' && ch <= 'Z') upper += 1;
                else if (ch >= 'a' && ch <= 'z') lowerc += 1;
                else if (ch >= '0' && ch <= '9') digits += 1;
                else if (ch == '.') dots += 1;
            }
            for (size_t k = 1; k < tok.size(); ++k) {
                if (tok[k] >= 'A' && tok[k] <= 'Z') internal_upper = true;
                if (k + 1 < tok.size() && tok[k] >= 'a' && tok[k] <= 'z' &&
                    tok[k + 1] >= 'A' && tok[k + 1] <= 'Z') {
                    internal_upper = true;  // iPhone 形
                }
            }
            int cls = 0;
            if (digits > 0 && dots > 0) {
                cls = 2;  // 版本号（v3.2.1）
            } else if (internal_upper) {
                cls = 3;  // 驼峰/异形大写（VSCode、iPhone）
            } else if (upper >= 2 && lowerc == 0 && digits == 0) {
                cls = 4;  // 全大写（VS、NASA）
            } else if (upper == 1 && lowerc >= 1 && digits == 0 && i > 0) {
                // 仅句中位置；句首无法与普通词区分（见 v1 局限）。
                bool in_stop = false;
                for (const char *w : kStopwords) {
                    if (lower == w) {
                        in_stop = true;
                        break;
                    }
                }
                if (!in_stop) cls = 5;
            }
            if (cls != 0) {
                found.push_back(GcTextRange{scalars[i].begin, scalars[end - 1].end});
            }
        }
        i = j > i ? j : i + 1;
    }

    const size_t total = found.size();
    if (out_ranges != nullptr) {
        const size_t n = std::min(total, capacity);
        for (size_t k = 0; k < n; ++k) out_ranges[k] = found[k];
    }
    return total;
}
