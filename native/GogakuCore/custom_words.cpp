// 自定义词语存储：custom-words.tsv 读写、校验与自动读音查询。
// 属于共享核心：不依赖 Apple 框架，两端共用同一格式与校验规则。
#include "gogaku_core.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#include <libime/pinyin/pinyinencoder.h>
#include <libime/pinyin/pinyindictionary.h>

namespace {

char *dup_cstr(const std::string &s) {
    auto *r = static_cast<char *>(std::malloc(s.size() + 1));
    if (r == nullptr) throw std::bad_alloc();
    memcpy(r, s.c_str(), s.size() + 1);
    return r;
}

constexpr const char *kVersionLine = "#gogaku-custom-words\tv1";
constexpr size_t kMaxCodeScalars = 32;
constexpr size_t kMaxContentScalars = 512;
constexpr size_t kMaxPinyinWordScalars = 16;

bool is_lower_letter(char c) { return c >= 'a' && c <= 'z'; }

// 统计 UTF-8 标量个数；无效序列返回负值。
ptrdiff_t scalar_count(const std::string &s) {
    ptrdiff_t n = 0;
    for (size_t i = 0; i < s.size();) {
        unsigned char lead = static_cast<unsigned char>(s[i]);
        size_t len = lead < 0x80 ? 1 : (lead & 0xE0) == 0xC0 ? 2
                                   : (lead & 0xF0) == 0xE0   ? 3
                                   : (lead & 0xF8) == 0xF0   ? 4
                                                             : 0;
        if (len == 0 || i + len > s.size()) return -1;
        for (size_t k = 1; k < len; ++k) {
            if ((static_cast<unsigned char>(s[i + k]) & 0xC0) != 0x80) return -1;
        }
        i += len;
        ++n;
    }
    return n;
}

// 取 UTF-8 串的第一个标量码点；无效返回 0。
uint32_t first_scalar(const std::string &s) {
    if (s.empty()) return 0;
    unsigned char c = static_cast<unsigned char>(s[0]);
    size_t len = c < 0x80 ? 1 : (c & 0xE0) == 0xC0 ? 2 : (c & 0xF0) == 0xE0 ? 3 : (c & 0xF8) == 0xF0 ? 4 : 0;
    if (len == 0 || len > s.size() || (len == 4 && s.size() > 4)) len = std::min<size_t>(len, s.size());
    uint32_t cp = c & (0xFF >> (len + 1));
    for (size_t k = 1; k < len && k < s.size(); ++k) {
        cp = (cp << 6) | (static_cast<unsigned char>(s[k]) & 0x3F);
    }
    return cp;
}

bool is_han_scalar(uint32_t cp) {
    return (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0x9FFF) ||
           (cp >= 0xF900 && cp <= 0xFAFF) || (cp >= 0x20000 && cp <= 0x2FA1F);
}

// 按标量迭代 UTF-8 串。
std::vector<std::string> scalar_split(const std::string &s) {
    std::vector<std::string> out;
    for (size_t i = 0; i < s.size();) {
        unsigned char lead = static_cast<unsigned char>(s[i]);
        size_t len = lead < 0x80 ? 1 : (lead & 0xE0) == 0xC0 ? 2
                                   : (lead & 0xF0) == 0xE0   ? 3
                                   : (lead & 0xF8) == 0xF0   ? 4
                                                             : 0;
        if (len == 0 || i + len > s.size()) break;
        out.emplace_back(s, i, len);
        i += len;
    }
    return out;
}

std::string escape_field(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        switch (c) {
        case '\\': out += "\\\\"; break;
        case '\t': out += "\\t"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        default: out += c;
        }
    }
    return out;
}

bool unescape_field(const std::string &s, std::string &out) {
    out.clear();
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] != '\\') {
            out += s[i];
            continue;
        }
        if (++i >= s.size()) return false;
        switch (s[i]) {
        case '\\': out += '\\'; break;
        case 't': out += '\t'; break;
        case 'n': out += '\n'; break;
        case 'r': out += '\r'; break;
        default: return false;
        }
    }
    return true;
}

std::vector<std::string> split_line(const std::string &line) {
    std::vector<std::string> fields;
    size_t start = 0;
    while (true) {
        size_t pos = line.find('\t', start);
        if (pos == std::string::npos) {
            fields.emplace_back(line, start);
            break;
        }
        fields.emplace_back(line, start, pos - start);
        start = pos + 1;
    }
    return fields;
}

void set_error(char *err, size_t err_len, const std::string &message) {
    if (err != nullptr && err_len > 0) {
        snprintf(err, err_len, "%s", message.c_str());
    }
}

bool valid_pinyin_word(const std::string &pinyin, const std::string &content, char *err, size_t err_len) {
    const auto chars = scalar_split(content);
    if (chars.empty() || chars.size() > kMaxPinyinWordScalars) {
        set_error(err, err_len, "内容必须是 1–16 个汉字");
        return false;
    }
    for (const auto &c : chars) {
        if (!is_han_scalar(first_scalar(c))) {
            set_error(err, err_len, "内容只能包含汉字");
            return false;
        }
    }
    std::vector<std::string> syllables;
    size_t start = 0;
    while (true) {
        size_t pos = pinyin.find('\'', start);
        if (pos == std::string::npos) {
            syllables.emplace_back(pinyin, start);
            break;
        }
        syllables.emplace_back(pinyin, start, pos - start);
        start = pos + 1;
    }
    if (syllables.size() != chars.size()) {
        set_error(err, err_len, "读音必须为每字一个音节");
        return false;
    }
    for (const auto &syl : syllables) {
        if (syl.empty()) {
            set_error(err, err_len, "读音音节不能为空");
            return false;
        }
        try {
            auto encoded = libime::PinyinEncoder::encodeFullPinyin(syl);
            if (encoded.empty() || !libime::PinyinEncoder::isValidUserPinyin(encoded)) {
                set_error(err, err_len, "读音含非规范音节：" + syl);
                return false;
            }
        } catch (...) {
            set_error(err, err_len, "读音含非规范音节：" + syl);
            return false;
        }
    }
    return true;
}

// 出厂词典单字读音缓存：设置进程首次查询时导出词典文本并解析。
struct CharReading {
    std::string pinyin;
    float cost = 0.0f;
};
std::mutex g_reading_mutex;
std::unordered_map<std::string, std::unordered_map<std::string, CharReading>> g_reading_cache;

bool parse_dump_line(const std::string &line, std::string &hanzi, std::string &pinyin, float &cost) {
    // libime 导出格式是空白分隔的 hanzi pinyin [score]，不是自定义文件的 TSV。
    // 这里只提取单字，带引号／空格的多字词在下方过滤。
    std::istringstream fields(line);
    if (!(fields >> hanzi >> pinyin)) return false;
    cost = 0.0f;
    fields >> std::ws;
    if (fields.eof()) return true;
    if (!(fields >> cost)) return false;
    fields >> std::ws;
    return fields.eof();
}

bool build_readings(const char *dict_path, char *err, size_t err_len) {
    try {
        libime::PinyinDictionary dict;
        dict.load(0, dict_path, libime::PinyinDictFormat::Binary);
        std::ostringstream out;
        dict.save(0, out, libime::PinyinDictFormat::Text);
        std::unordered_map<std::string, CharReading> readings;
        std::istringstream in(out.str());
        std::string line;
        while (std::getline(in, line)) {
            if (line.empty() || line[0] == '#') continue;
            std::string hanzi, pinyin;
            float cost = 0.0f;
            if (!parse_dump_line(line, hanzi, pinyin, cost)) continue;
            if (scalar_count(hanzi) != 1 || !is_han_scalar(first_scalar(hanzi))) continue;
            auto it = readings.find(hanzi);
            // 与 libime 解码一致：分数越大越常用（例如 角 的 jiao 高于 jue）。
            if (it == readings.end() || cost > it->second.cost) {
                readings[hanzi] = CharReading{pinyin, cost};
            }
        }
        std::lock_guard<std::mutex> lock(g_reading_mutex);
        g_reading_cache[dict_path] = std::move(readings);
        return true;
    } catch (const std::exception &e) {
        set_error(err, err_len, std::string("词典读取失败：") + e.what());
        return false;
    } catch (...) {
        set_error(err, err_len, "词典读取失败");
        return false;
    }
}

}  // namespace

extern "C" int gc_custom_words_read(const char *path, GcCustomWordList **out) {
    if (path == nullptr || out == nullptr) return 1;
    *out = static_cast<GcCustomWordList *>(std::calloc(1, sizeof(GcCustomWordList)));
    if (*out == nullptr) return 1;
    std::vector<GcCustomWord> words;
    bool corrupt = false;
    FILE *f = fopen(path, "rb");
    if (f != nullptr) {
        std::string contents;
        char buf[4096];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0) contents.append(buf, n);
        fclose(f);
        size_t start = 0;
        bool first = true;
        while (start <= contents.size()) {
            size_t pos = contents.find('\n', start);
            std::string line = contents.substr(start, pos == std::string::npos ? std::string::npos : pos - start);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            bool last = pos == std::string::npos;
            start = last ? contents.size() + 1 : pos + 1;
            if (first) {
                first = false;
                if (line != kVersionLine) {
                    corrupt = true;
                    break;
                }
                continue;
            }
            if (line.empty() || line[0] == '#') continue;
            auto fields = split_line(line);
            if (fields.size() != 5) {
                corrupt = true;
                break;
            }
            GcCustomWord w{};
            std::string code, pinyin, content;
            // 字段边界已在切分时确定；转义内容反转义后可含制表／换行。
            bool ok = (fields[0] == "0" || fields[0] == "1") && (fields[1] == "0" || fields[1] == "1") &&
                      unescape_field(fields[2], code) && unescape_field(fields[3], pinyin) &&
                      unescape_field(fields[4], content);
            if (!ok) {
                corrupt = true;
                break;
            }
            w.kind = fields[0] == "0" ? GC_WORD_SHORTCODE : GC_WORD_PINYIN;
            w.enabled = fields[1] == "1";
            try {
                w.code = dup_cstr(code);
                w.pinyin = dup_cstr(pinyin);
                w.content = dup_cstr(content);
            } catch (...) {
                corrupt = true;
                break;
            }
            words.push_back(w);
            if (last) break;
        }
        if (corrupt) {
            for (auto &w : words) {
                free(w.code);
                free(w.pinyin);
                free(w.content);
            }
            words.clear();
            // 备份损坏文件并以空表启动；rename 替换已存在的旧备份。
            std::string backup = std::string(path) + ".corrupt";
            (void)rename(path, backup.c_str());
        }
    }
    (*out)->words = static_cast<GcCustomWord *>(std::calloc(words.empty() ? 1 : words.size(), sizeof(GcCustomWord)));
    if ((*out)->words == nullptr) return 1;
    if (!words.empty()) memcpy((*out)->words, words.data(), words.size() * sizeof(GcCustomWord));
    (*out)->count = words.size();
    (*out)->corrupt = corrupt ? 1 : 0;
    return 0;
}

extern "C" int gc_custom_words_write(const char *path, const GcCustomWordList *list) {
    if (path == nullptr || list == nullptr || (list->count > 0 && list->words == nullptr)) return 1;
    std::string contents = kVersionLine;
    contents += "\n";
    for (size_t i = 0; i < list->count; ++i) {
        const auto &w = list->words[i];
        contents += w.kind == GC_WORD_SHORTCODE ? "0" : "1";
        contents += '\t';
        contents += w.enabled ? "1" : "0";
        contents += '\t';
        contents += escape_field(w.code == nullptr ? "" : w.code);
        contents += '\t';
        contents += escape_field(w.pinyin == nullptr ? "" : w.pinyin);
        contents += '\t';
        contents += escape_field(w.content == nullptr ? "" : w.content);
        contents += '\n';
    }
    std::string temp = std::string(path) + "." + std::to_string(::getpid()) + ".tmp";
    FILE *f = fopen(temp.c_str(), "wb");
    if (f == nullptr) return 2;
    bool ok = fwrite(contents.data(), 1, contents.size(), f) == contents.size();
    ok = fflush(f) == 0 && ok;
    fclose(f);
    if (!ok) {
        remove(temp.c_str());
        return 2;
    }
    // 仅当前用户可读写。
    (void)chmod(temp.c_str(), 0600);
    // fsync 保证进程被杀或掉电后目标文件不出现半截内容；rename 后同步父目录。
    {
        int fd = ::open(temp.c_str(), O_RDONLY);
        if (fd >= 0) {
            ::fsync(fd);
            ::close(fd);
        }
    }
    if (rename(temp.c_str(), path) != 0) {
        remove(temp.c_str());
        return 2;
    }
    {
        const size_t slash = std::string(path).find_last_of('/');
        const std::string dir = slash == std::string::npos ? "." : std::string(path).substr(0, slash);
        int dfd = ::open(dir.c_str(), O_RDONLY);
        if (dfd >= 0) {
            ::fsync(dfd);
            ::close(dfd);
        }
    }
    return 0;
}

extern "C" void gc_custom_word_list_free(GcCustomWordList *list) {
    if (list == nullptr) return;
    for (size_t i = 0; i < list->count; ++i) {
        free(list->words[i].code);
        free(list->words[i].pinyin);
        free(list->words[i].content);
    }
    free(list->words);
    free(list);
}

extern "C" int gc_custom_words_validate(int32_t kind, const char *code, const char *pinyin,
                                        const char *content, char *err, size_t err_len) {
    std::string c = code == nullptr ? "" : code;
    std::string p = pinyin == nullptr ? "" : pinyin;
    std::string t = content == nullptr ? "" : content;
    if (t.empty()) {
        set_error(err, err_len, "内容不能为空");
        return 1;
    }
    auto scalars = scalar_count(t);
    if (scalars < 0) {
        set_error(err, err_len, "内容含无效 UTF-8");
        return 1;
    }
    if (static_cast<size_t>(scalars) > kMaxContentScalars) {
        set_error(err, err_len, "内容超过 512 个字符");
        return 1;
    }
    if (kind == GC_WORD_SHORTCODE) {
        if (c.empty() || c.size() > kMaxCodeScalars) {
            set_error(err, err_len, "编码必须是 1–32 个小写字母");
            return 1;
        }
        for (char ch : c) {
            if (!is_lower_letter(static_cast<unsigned char>(ch))) {
                set_error(err, err_len, "编码只能包含小写字母，不含数字");
                return 1;
            }
        }
        return 0;
    }
    if (kind == GC_WORD_PINYIN) {
        if (!valid_pinyin_word(p, t, err, err_len)) return 1;
        return 0;
    }
    set_error(err, err_len, "未知词条类型");
    return 1;
}

extern "C" int gc_custom_pinyin_lookup(const char *dict_path, const char *hanzi, char **out) {
    if (dict_path == nullptr || hanzi == nullptr || out == nullptr) return 1;
    *out = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_reading_mutex);
        if (g_reading_cache.count(dict_path) == 0) {
            g_reading_cache[dict_path] = {};  // 占位，避免并发重复构建
        }
    }
    if (!build_readings(dict_path, nullptr, 0)) return 2;
    std::unordered_map<std::string, CharReading> readings;
    {
        std::lock_guard<std::mutex> lock(g_reading_mutex);
        readings = g_reading_cache[dict_path];
    }
    std::string result;
    for (const auto &c : scalar_split(hanzi)) {
        if (!is_han_scalar(first_scalar(c))) return 1;
        auto it = readings.find(c);
        if (it == readings.end()) return 2;
        if (!result.empty()) result += '\'';
        result += it->second.pinyin;
    }
    try {
        *out = dup_cstr(result);
    } catch (...) {
        return 1;
    }
    return 0;
}
