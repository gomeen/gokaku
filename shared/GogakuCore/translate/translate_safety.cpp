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

// ---- URL 片段（脚本/长度统计与保护扫描共用）----
// URL 内的字母是地址而不是语言：既不能把「详情见 https://…」判成拉丁主导，
// 也不能让长 URL 把长度比率撑爆。
struct UrlSpan {
    size_t begin;
    size_t end;
};

std::vector<UrlSpan> find_url_spans(std::string_view view) {
    std::vector<UrlSpan> spans;
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
            while (end > pos && std::string_view(".),;:!?\"'").find(view[end - 1]) !=
                                     std::string_view::npos) {
                --end;
            }
            bool merged = false;
            for (UrlSpan &span : spans) {
                if (pos <= span.end && end >= span.begin) {
                    span.begin = std::min(span.begin, pos);
                    span.end = std::max(span.end, end);
                    merged = true;
                    break;
                }
            }
            if (!merged) spans.push_back(UrlSpan{pos, end});
            pos = lower.find(needle, end);
        }
    }
    return spans;
}

bool inside_spans(const std::vector<UrlSpan> &spans, size_t pos) {
    for (const UrlSpan &span : spans) {
        if (pos >= span.begin && pos < span.end) return true;
    }
    return false;
}

// ---- 时间事实抽取（源/输出共用；按「数值＋时段」逐条成对比较）----
// v1 的近似是「出现下午就算翻转」「出现半点就算丢半」，于是把
// 「上午九点到下午四点」这类合法区间和英文动词 am 判成矛盾。v2 改成抽取有序
// 时间点（时/分/是否半点/绑定时段），逐条比对数值、顺序和时段关系。
struct TimeMention {
    int hour = -1;
    int minute = -1;
    int meridiem = 0;  // 0=未绑定 1=上午 2=下午 3=正午/午夜类
    bool half = false;
};

struct TimeFacts {
    bool any = false;
    int loose = 0;  // 未绑定到具体数值的时段线索（in the morning / 中午）
    std::vector<TimeMention> mentions;
    std::vector<std::pair<long, std::string>> numbers;  // 未被时间表达解释的数字
};

int cjk_marker(std::string_view v, size_t pos, size_t &length) {
    struct Marker {
        std::string_view text;
        int cls;
    };
    static const Marker kMarkers[] = {
        {"上午", 1}, {"早上", 1}, {"早晨", 1}, {"清晨", 1}, {"凌晨", 1},
        {"下午", 2}, {"晚上", 2}, {"傍晚", 2}, {"夜里", 2}, {"夜晚", 2},
        {"中午", 3}, {"午夜", 3}, {"正午", 3},
    };
    for (const Marker &m : kMarkers) {
        if (pos + m.text.size() <= v.size() && v.compare(pos, m.text.size(), m.text) == 0) {
            length = m.text.size();
            return m.cls;
        }
    }
    return 0;
}

int chinese_digit(uint32_t cp) {
    switch (cp) {
        case 0x96F6:  // 零
        case 0x3007:  // 〇
            return 0;
        case 0x4E00: return 1;  // 一
        case 0x4E8C:            // 二
        case 0x4E24: return 2;  // 两
        case 0x4E09: return 3;  // 三
        case 0x56DB: return 4;  // 四
        case 0x4E94: return 5;  // 五
        case 0x516D: return 6;  // 六
        case 0x4E03: return 7;  // 七
        case 0x516B: return 8;  // 八
        case 0x4E5D: return 9;  // 九
        default: return -1;
    }
}

bool is_cn_ten(uint32_t cp) { return cp == 0x5341; }  // 十

// 解析 0–99 的中文数字（十一 / 二十 / 二十三）。返回消耗的标量个数；
// 不是可解释数字时返回 0，可解释但超出钟点范围时 value<0。
size_t parse_cn_number(const std::vector<Scalar> &scalars, size_t i, int &value) {
    size_t j = i;
    std::vector<int> parts;  // -10 表示「十」
    while (j < scalars.size() && parts.size() < 4) {
        if (is_cn_ten(scalars[j].cp)) {
            parts.push_back(-10);
            ++j;
            continue;
        }
        const int d = chinese_digit(scalars[j].cp);
        if (d < 0) break;
        parts.push_back(d);
        ++j;
    }
    if (parts.empty()) return 0;
    size_t ten_pos = parts.size();
    for (size_t k = 0; k < parts.size(); ++k) {
        if (parts[k] != -10) continue;
        if (ten_pos != parts.size()) { value = -1; return j - i; }  // 多个「十」不解释
        ten_pos = k;
    }
    if (ten_pos == parts.size()) {
        if (parts.size() > 2) { value = -1; return j - i; }  // 三零二 交给通用数字规则
        int v = 0;
        for (const int d : parts) v = v * 10 + d;
        value = v;
        return j - i;
    }
    if (ten_pos > 1 || parts.size() > 2) { value = -1; return j - i; }
    const int tens = ten_pos == 0 ? 1 : parts[0];
    const int ones = parts.size() == ten_pos + 1 ? 0 : parts[ten_pos + 1];
    value = tens * 10 + ones;
    return j - i;
}

std::string cn_number(long value);

// 英文数词（含 half past 需要的钟点词）。
int english_number(std::string_view word) {
    static const struct {
        std::string_view text;
        int value;
    } kWords[] = {{"one", 1},       {"two", 2},     {"three", 3}, {"four", 4},
                  {"five", 5},     {"six", 6},     {"seven", 7}, {"eight", 8},
                  {"nine", 9},     {"ten", 10},    {"eleven", 11}, {"twelve", 12},
                  {"thirteen", 13}, {"fourteen", 14}, {"fifteen", 15},
                  {"sixteen", 16}, {"seventeen", 17}, {"eighteen", 18},
                  {"nineteen", 19}, {"twenty", 20}};
    for (const auto &entry : kWords) {
        if (word == entry.text) return entry.value;
    }
    return -1;
}

std::string lower_ascii(std::string_view v) {
    std::string out(v);
    for (char &ch : out) {
        if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
    }
    return out;
}

// 读取 pos 起的拉丁字母串（含点），去点后小写；返回结束字节位置。
size_t read_latin_word(std::string_view v, size_t pos, std::string &clean) {
    size_t end = pos;
    clean.clear();
    while (end < v.size() && (is_ascii_letter(static_cast<unsigned char>(v[end])) || v[end] == '.')) {
        if (v[end] != '.') clean.push_back(v[end]);
        ++end;
    }
    clean = lower_ascii(clean);
    return end;
}

TimeFacts extract_time(std::string_view v) {
    TimeFacts f;
    const auto scalars = Utf8View(v).collect();
    int pending = 0;
    size_t i = 0;
    auto advance_past = [&](size_t byte_end) {
        while (i < scalars.size() && scalars[i].begin < byte_end) ++i;
    };
    auto record_marker = [&](int cls) {
        pending = cls;
        f.loose = cls;
        f.any = true;
    };
    while (i < scalars.size()) {
        const Scalar &s = scalars[i];
        // 1) 中文时段标记
        size_t marker_len = 0;
        if (const int cls = cjk_marker(v, s.begin, marker_len); cls != 0) {
            record_marker(cls);
            advance_past(s.begin + marker_len);
            continue;
        }
        // 2) 拉丁时段词
        if (s.cp < 0x80 && is_ascii_letter(s.cp)) {
            std::string word;
            const size_t end = read_latin_word(v, s.begin, word);
            if (word == "morning") {
                record_marker(1);
            } else if (word == "afternoon" || word == "evening" || word == "night") {
                record_marker(2);
            } else if (word == "noon" || word == "midnight") {
                record_marker(3);
            } else if (word == "half") {
                // half past ten → 10:30
                size_t probe = end;
                while (probe < v.size() && v[probe] == ' ') ++probe;
                std::string next;
                const size_t past_end = read_latin_word(v, probe, next);
                if (next == "past") {
                    size_t hour_at = past_end;
                    while (hour_at < v.size() && v[hour_at] == ' ') ++hour_at;
                    std::string hour_word;
                    const size_t hour_end = read_latin_word(v, hour_at, hour_word);
                    const int hour = english_number(hour_word);
                    if (hour >= 0) {
                        TimeMention m;
                        m.hour = hour;
                        m.minute = 30;
                        m.half = true;
                        m.meridiem = pending;
                        pending = 0;
                        f.mentions.push_back(m);
                        f.any = true;
                        advance_past(hour_end);
                        continue;
                    }
                }
            }
            advance_past(end > s.begin ? end : s.begin + 1);
            continue;
        }
        // 3) ASCII 数字：可能是钟点，也可能是普通数字
        if (s.cp >= '0' && s.cp <= '9') {
            size_t end = s.begin;
            while (end < v.size() && v[end] >= '0' && v[end] <= '9') ++end;
            const std::string digits = std::string(v.substr(s.begin, end - s.begin));
            long value = digits.size() <= 9 ? 0 : -1;
            if (value == 0 && !digits.empty()) {
                for (const char ch : digits) value = value * 10 + (ch - '0');
            }
            size_t probe = end;
            int minute = -1;
            bool colon = false;
            if (probe < v.size() && v[probe] == ':') {
                size_t digits_end = probe + 1;
                while (digits_end < v.size() && v[digits_end] >= '0' && v[digits_end] <= '9') {
                    ++digits_end;
                }
                if (digits_end > probe + 1 && digits_end - probe - 1 <= 2) {
                    minute = 0;
                    for (size_t k = probe + 1; k < digits_end; ++k) {
                        minute = minute * 10 + (v[k] - '0');
                    }
                    colon = true;
                    probe = digits_end;
                }
            }
            size_t after = probe;
            bool unit = colon;
            // 点时／点／时
            size_t unit_len = 0;
            if (v.compare(after, 3, "\xE7\x82\xB9") == 0) {  // 点
                unit_len = 3;
            } else if (v.compare(after, 3, "\xE6\x97\xB6") == 0) {  // 时
                unit_len = 3;
            }
            if (unit_len != 0) {
                unit = true;
                after += unit_len;
                // 半 / 一刻 / 三刻 / N分
                size_t cursor = after;
                while (cursor < v.size() && v[cursor] == ' ') ++cursor;
                if (v.compare(cursor, 3, "\xE5\x8D\x8A") == 0) {  // 半
                    minute = 30;
                    after = cursor + 3;
                } else if (v.compare(cursor, 6, "\xE4\xB8\x80\xE5\x88\xBB") == 0) {  // 一刻
                    minute = 15;
                    after = cursor + 6;
                } else if (v.compare(cursor, 6, "\xE4\xB8\x89\xE5\x88\xBB") == 0) {  // 三刻
                    minute = 45;
                    after = cursor + 6;
                } else if (cursor < v.size() && v[cursor] >= '0' && v[cursor] <= '9') {
                    size_t digits_end = cursor;
                    while (digits_end < v.size() && v[digits_end] >= '0' && v[digits_end] <= '9') {
                        ++digits_end;
                    }
                    if (digits_end - cursor <= 2) {
                        minute = 0;
                        for (size_t k = cursor; k < digits_end; ++k) minute = minute * 10 + (v[k] - '0');
                    }
                    after = digits_end;
                    if (v.compare(after, 3, "\xE5\x88\x86") == 0) after += 3;  // 分
                }
            }
            // 可选 am/pm 紧邻（允许空格）：只有紧跟在数字后才算时段，
            // 这样英文动词 am（I am ...）不再触发时段检查。
            int meridiem = 0;
            {
                size_t cursor = after;
                while (cursor < v.size() && v[cursor] == ' ') ++cursor;
                std::string suffix;
                const size_t suffix_end = read_latin_word(v, cursor, suffix);
                if (suffix == "am") meridiem = 1;
                if (suffix == "pm") meridiem = 2;
                if (meridiem != 0) after = suffix_end;
            }
            if (unit || meridiem != 0) {
                TimeMention m;
                m.hour = value >= 0 && value <= 99 ? static_cast<int>(value) : -1;
                m.minute = minute;
                m.meridiem = meridiem != 0 ? meridiem : pending;
                m.half = minute == 30;
                pending = 0;
                f.mentions.push_back(m);
                f.any = true;
                advance_past(after > s.begin ? after : end);
                continue;
            }
            f.numbers.emplace_back(value, digits);
            advance_past(end);
            continue;
        }
        // 4) 中文数字钟点（三点、十点半、十二点）
        if (is_cn_ten(s.cp) || chinese_digit(s.cp) >= 0) {
            int hour = -1;
            const size_t used = parse_cn_number(scalars, i, hour);
            if (used == 0) {
                ++i;
                continue;
            }
            size_t cursor = scalars[i + used - 1].end;
            bool unit = false;
            if (v.compare(cursor, 3, "\xE7\x82\xB9") == 0 ||  // 点
                v.compare(cursor, 3, "\xE6\x97\xB6") == 0) {  // 时
                unit = true;
                cursor += 3;
            }
            if (unit && hour >= 0) {
                int minute_value = -1;
                if (v.compare(cursor, 3, "\xE5\x8D\x8A") == 0) {  // 半
                    minute_value = 30;
                    cursor += 3;
                } else if (v.compare(cursor, 6, "\xE4\xB8\x80\xE5\x88\xBB") == 0) {
                    minute_value = 15;
                    cursor += 6;
                } else if (v.compare(cursor, 6, "\xE4\xB8\x89\xE5\x88\xBB") == 0) {
                    minute_value = 45;
                    cursor += 6;
                } else {
                    size_t probe = i + used;
                    int cn_minute = -1;
                    const size_t cn_used = probe <= scalars.size()
                                               ? parse_cn_number(scalars, probe, cn_minute)
                                               : 0;
                    if (cn_used > 0 && cn_minute >= 0 &&
                        v.compare(scalars[probe + cn_used - 1].end, 3, "\xE5\x88\x86") == 0) {
                        minute_value = cn_minute;
                        cursor = scalars[probe + cn_used - 1].end + 3;
                    }
                }
                TimeMention m;
                m.hour = hour;
                m.minute = minute_value;
                m.meridiem = pending;
                m.half = minute_value == 30;
                pending = 0;
                f.mentions.push_back(m);
                f.any = true;
                advance_past(cursor);
                continue;
            }
            advance_past(cursor);
            continue;
        }
        ++i;
    }
    return f;
}

// 中文数字写法（供「数值保留」比对：302 ↔ 三百零二／三零二）。
std::string cn_number(long value) {
    static const char *kDigits[] = {"零", "一", "二", "三", "四",
                                    "五", "六", "七", "八", "九"};
    if (value < 0 || value > 9999) return {};
    if (value < 10) return kDigits[value];
    auto tail = [&](long v) -> std::string {
        if (v == 0) return {};
        if (v < 10) return kDigits[v];
        return cn_number(v);
    };
    if (value < 20) return std::string("十") + tail(value % 10);
    if (value < 100) return std::string(kDigits[value / 10]) + "十" + tail(value % 10);
    if (value < 1000) {
        std::string out = std::string(kDigits[value / 100]) + "百";
        const long rest = value % 100;
        if (rest == 0) return out;
        if (rest < 10) return out + "零" + kDigits[rest];
        return out + cn_number(rest);
    }
    std::string out = std::string(kDigits[value / 1000]) + "千";
    const long rest = value % 1000;
    if (rest == 0) return out;
    if (rest < 100) return out + "零" + cn_number(rest);
    return out + cn_number(rest);
}

// 数字保留定位：优先同形 ASCII，其次中文写法（含逐位写法）。
size_t find_number(std::string_view out, std::string_view digits, long value) {
    size_t pos = out.find(digits);
    if (pos != std::string_view::npos) return pos;
    const std::string place = cn_number(value);
    if (!place.empty()) {
        pos = out.find(place);
        if (pos != std::string_view::npos) return pos;
    }
    if (digits.size() <= 4) {
        static const char *kDigits[] = {"零", "一", "二", "三", "四",
                                        "五", "六", "七", "八", "九"};
        std::string spelled;
        for (const char ch : digits) spelled += kDigits[ch - '0'];
        pos = out.find(spelled);
        if (pos != std::string_view::npos) return pos;
    }
    return std::string_view::npos;
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

    // 合法叠词：单字汉字叠用（看看／试试／慢慢／哈哈）与数量叠用（一个一个／一天一天）。
    // 它们与模型复读的形态相同，但是正常汉语，不能因此回退原文。
    auto is_single_han = [](std::string_view token) {
        return token.size() == 3 && static_cast<unsigned char>(token[0]) >= 0xE0;
    };
    auto is_numeral_token = [](std::string_view token) {
        if (token.size() == 1) return token[0] >= '0' && token[0] <= '9';
        if (token.size() != 3) return false;
        const auto *p = reinterpret_cast<const unsigned char *>(token.data());
        const uint32_t cp = (static_cast<uint32_t>(p[0] & 0x0F) << 12) |
                            (static_cast<uint32_t>(p[1] & 0x3F) << 6) |
                            static_cast<uint32_t>(p[2] & 0x3F);
        static const uint32_t kNumerals[] = {0x4E00, 0x4E8C, 0x4E24, 0x4E09, 0x56DB,
                                             0x4E94, 0x516D, 0x4E03, 0x516B, 0x4E5D,
                                             0x5341, 0x767E, 0x5343, 0x4E07};
        for (const uint32_t numeral : kNumerals) {
            if (cp == numeral) return true;
        }
        return false;
    };
    if (tokens.size() == 2 && token_equal_lower(tokens[0], tokens[1]) &&
        is_single_han(tokens[0])) {
        return 0;
    }
    if (tokens.size() == 4 && token_equal_lower(tokens[0], tokens[2]) &&
        token_equal_lower(tokens[1], tokens[3]) && is_numeral_token(tokens[0])) {
        return 0;
    }
    if (tokens.size() == 4 && is_single_han(tokens[0]) &&
        token_equal_lower(tokens[0], tokens[1]) && is_single_han(tokens[2]) &&
        token_equal_lower(tokens[2], tokens[3])) {
        return 0;  // 多多少少、高高兴兴
    }

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
    const std::string_view out(trim(std::string_view(output, output_length)));
    const TimeFacts sf = extract_time(std::string_view(source, source_length));
    const TimeFacts of = extract_time(out);

    // 1) 逐条时间点对比：数值、顺序、时段关系。
    if (!sf.mentions.empty()) {
        if (of.mentions.empty()) return 2;  // 源时间点整体丢失
        if (of.mentions.size() < sf.mentions.size()) return 2;
        if (of.mentions.size() > sf.mentions.size()) return 4;  // 增义
        for (size_t i = 0; i < sf.mentions.size(); ++i) {
            const TimeMention &a = sf.mentions[i];
            const TimeMention &b = of.mentions[i];
            if (a.hour >= 0 && b.hour >= 0 && a.hour != b.hour) return 4;
            if (a.half && !b.half) return 3;
            if (a.minute >= 0 && b.minute >= 0 && a.minute != b.minute) return 4;
            const int am = a.meridiem != 0 ? a.meridiem : sf.loose;
            const int bm = b.meridiem != 0 ? b.meridiem : of.loose;
            if (am != 0 && bm != 0 && am != bm) return 1;
        }
    } else if (sf.loose != 0 && of.loose != 0 && sf.loose != of.loose) {
        return 1;
    }

    // 2) 未被时间表达解释的数字必须原样保留（顺序不得打乱）。
    size_t cursor = 0;
    for (const auto &number : sf.numbers) {
        const size_t pos = find_number(out, number.second, number.first);
        if (pos == std::string_view::npos) return 2;
        if (pos < cursor) return 4;
        cursor = pos;
    }
    return 0;
}

int32_t gc_translate_script_check(const char *text, size_t length, char expected) {
    if (text == nullptr) return 2;
    const std::string_view view(text, length);
    const auto urls = find_url_spans(view);
    std::vector<Scalar> kept;
    for (const Scalar &scalar : Utf8View(view).collect()) {
        if (!inside_spans(urls, scalar.begin)) kept.push_back(scalar);
    }
    const Counts c = count_scripts(kept);
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

// 长度统计排除 URL：地址长度与译文长度无关，否则「打开 https://…」永远判膨胀。
static std::vector<Scalar> scalars_without_urls(std::string_view view) {
    const auto urls = find_url_spans(view);
    std::vector<Scalar> kept;
    for (const Scalar &scalar : Utf8View(view).collect()) {
        if (!inside_spans(urls, scalar.begin)) kept.push_back(scalar);
    }
    return kept;
}

int32_t gc_translate_length_check(const char *source, size_t source_length,
                                  const char *output, size_t output_length) {
    if (source == nullptr || output == nullptr) return 2;
    const std::string_view src_view(source, source_length);
    const std::string_view out_view(output, output_length);
    const auto src = scalars_without_urls(src_view);
    const size_t o_count = scalars_without_urls(out_view).size();
    if (src.empty()) return 2;
    if (o_count == 0) return 1;
    const long double s = static_cast<long double>(src.size());
    const long double o = static_cast<long double>(o_count);
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
    const auto url_spans = find_url_spans(view);
    auto in_url = [&](size_t begin) { return inside_spans(url_spans, begin); };
    for (const UrlSpan &span : url_spans) {
        bool dup = false;
        for (const GcTextRange &p : found) {
            if (p.begin == span.begin) dup = true;
        }
        if (!dup) found.push_back(GcTextRange{span.begin, span.end});
    }

    // 已审阅品牌词表：句首大写词无法与普通句首词区分，只能靠已知品牌表
    //（Round2 已知错误：句首 Gogaku 未计入保护词，模型改成「古巴」）。
    static const char *kBrands[] = {
        "gogaku", "github", "vscode", "iphone", "ipad", "macos", "ios",
        "figma", "jira", "gmail", "outlook",
        "powerpoint", "xcode", "whatsapp", "openai", "chatgpt", "kubernetes", "docker",
        "telegram", "linkedin", "youtube", "netflix", "wechat", "alipay",
        "taobao", "weibo", "bilibili", "douyin", "tiktok", "instagram",
        "facebook", "twitter", "microsoft", "tencent", "huawei", "xiaomi"};

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
            bool in_brands = false;
            for (const char *brand : kBrands) {
                if (lower == brand) {
                    in_brands = true;
                    break;
                }
            }
            if (digits > 0 && dots > 0) {
                cls = 2;  // 版本号（v3.2.1）
            } else if (in_brands) {
                cls = 6;  // 已知品牌（含句首，可硬保留）
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
