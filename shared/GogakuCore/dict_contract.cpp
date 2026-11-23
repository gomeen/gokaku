// 扩展词库契约：导入转换、元数据、清单校验、加载与共享挂载。
// 属于共享核心：五种格式的解析、读音推断与过滤只有这一份实现，
// 设置应用导入与发布侧构建（gogaku_dict_tool）共用；合同见 docs/dictionaries.md。
// 不引用 Apple 框架；核心不建线程，进度回调在调用方线程执行。
#include "include/gogaku_core.h"
#include "dict_mount.h"
#include "sha256.h"

using gogaku::kLearningPerDictMax;
using gogaku::kLearningTotalMax;

#include "../third_party/json.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <random>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <libime/pinyin/pinyinencoder.h>
#include <libime/pinyin/pinyindictionary.h>

#include <sys/stat.h>
#include <ctime>
#ifdef _WIN32
#include "windows_io.h"
#include <shellapi.h>
#else
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#include <filesystem>
#endif

namespace {

using Json = nlohmann::json;

// ── 常量（docs/dictionaries.md §九：默认值集中在核心一处） ──
constexpr size_t kMaxInputBytes = 256ull * 1024 * 1024;      // 输入文件 256MiB
constexpr size_t kMaxEntries = 5000000;                       // 输出上限 500 万条
constexpr uint64_t kMemoryWarnBytes = 200ull * 1024 * 1024;   // 内存提醒阈值
constexpr uint64_t kEstimateFactor = 2;                       // 预计内存 = 2×文件大小
// 学习阈值 kLearningPerDictMax／kLearningTotalMax 在 dict_mount.h（挂载实现共用）。

char *dup_cstr(const std::string &s) {
    auto *r = static_cast<char *>(std::malloc(s.size() + 1));
    if (r == nullptr) throw std::bad_alloc();
    memcpy(r, s.c_str(), s.size() + 1);
    return r;
}

void set_error(char *err, size_t err_len, const std::string &message) {
    if (err != nullptr && err_len > 0) snprintf(err, err_len, "%s", message.c_str());
}

// ── UTF-8 工具 ──
// 取 s[i] 处标量的码点与字节长度；非法序列返回 false。
bool next_scalar(const std::string &s, size_t i, uint32_t &cp, size_t &len) {
    const auto *p = reinterpret_cast<const unsigned char *>(s.data()) + i;
    const size_t remain = s.size() - i;
    if (p[0] < 0x80) { cp = p[0]; len = 1; return true; }
    if ((p[0] & 0xE0) == 0xC0 && remain >= 2 && (p[1] & 0xC0) == 0x80) {
        cp = (static_cast<uint32_t>(p[0] & 0x1F) << 6) | (p[1] & 0x3F);
        len = 2;
        return cp >= 0x80;
    }
    if ((p[0] & 0xF0) == 0xE0 && remain >= 3 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80) {
        cp = (static_cast<uint32_t>(p[0] & 0x0F) << 12) | (static_cast<uint32_t>(p[1] & 0x3F) << 6) | (p[2] & 0x3F);
        len = 3;
        return cp >= 0x800;
    }
    if ((p[0] & 0xF8) == 0xF0 && remain >= 4 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80 &&
        (p[3] & 0xC0) == 0x80) {
        cp = (static_cast<uint32_t>(p[0] & 0x07) << 18) | (static_cast<uint32_t>(p[1] & 0x3F) << 12) |
             (static_cast<uint32_t>(p[2] & 0x3F) << 6) | (p[3] & 0x3F);
        len = 4;
        return cp >= 0x10000 && cp <= 0x10FFFF;
    }
    return false;
}

size_t scalar_count(const std::string &s) {
    size_t n = 0;
    for (size_t i = 0; i < s.size();) {
        uint32_t cp;
        size_t len;
        if (!next_scalar(s, i, cp, len)) return static_cast<size_t>(-1);
        i += len;
        ++n;
    }
    return n;
}

bool is_han_scalar(uint32_t cp) {
    return (cp >= 0x4E00 && cp <= 0x9FFF) ||   // CJK 统一表意
           (cp >= 0x3400 && cp <= 0x4DBF) ||   // 扩展 A
           (cp >= 0xF900 && cp <= 0xFAFF);     // 兼容表意
}

bool is_middle_dot(uint32_t cp) {
    return cp == 0x00B7 || cp == 0x2022 || cp == 0x30FB;
}

bool is_forbidden_in_word(uint32_t cp) {
    // 词内不允许：空白与控制字符（合同：invalidLine）。
    if (cp < 0x20 || cp == 0x7F) return true;
    return cp == ' ' || cp == 0x00A0 || (cp >= 0x2000 && cp <= 0x200A) || cp == 0x2028 ||
           cp == 0x2029 || cp == 0x3000 || cp == 0xFEFF;
}

bool word_has_forbidden(const std::string &s) {
    for (size_t i = 0; i < s.size();) {
        uint32_t cp;
        size_t len;
        if (!next_scalar(s, i, cp, len)) return true;  // 非法 UTF-8 视为非法词
        if (is_forbidden_in_word(cp)) return true;
        i += len;
    }
    return false;
}

bool word_has_middle_dot(const std::string &s) {
    for (size_t i = 0; i < s.size();) {
        uint32_t cp;
        size_t len;
        if (!next_scalar(s, i, cp, len)) return false;
        if (is_middle_dot(cp)) return true;
        i += len;
    }
    return false;
}

bool word_all_han(const std::string &s) {
    if (s.empty()) return false;
    for (size_t i = 0; i < s.size();) {
        uint32_t cp;
        size_t len;
        if (!next_scalar(s, i, cp, len)) return false;
        if (!is_han_scalar(cp)) return false;
        i += len;
    }
    return true;
}

std::string ascii_lower(const std::string &s) {
    std::string r = s;
    for (char &c : r) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return r;
}

// ── libime 文本词库的记号解析（镜像 fcitx stringutils 的转义表） ──
char unescape_char(char c) {
    switch (c) {
    case '\\': return '\\';
    case '"': return '"';
    case 'n': return '\n';
    case 'f': return '\f';
    case 'r': return '\r';
    case 't': return '\t';
    case 'v': return '\v';
    default: return '\0';
    }
}

char escape_of(char c) {
    switch (c) {
    case '\\': return '\\';
    case '"': return '"';
    case '\n': return 'n';
    case '\f': return 'f';
    case '\r': return 'r';
    case '\t': return 't';
    case '\v': return 'v';
    default: return '\0';
    }
}

// 与 consumeMaybeEscapedValue 一致：跳过 skip 集合，处理引号与转义。
bool tokenize_line(const std::string &line, std::vector<std::string> &tokens) {
    tokens.clear();
    size_t i = 0;
    const std::string skip = " \t\f\r\v";
    while (i < line.size()) {
        while (i < line.size() && skip.find(line[i]) != std::string::npos) ++i;
        if (i >= line.size()) break;
        std::string token;
        if (line[i] == '"') {
            ++i;
            bool closed = false;
            while (i < line.size()) {
                char c = line[i];
                if (c == '\\' && i + 1 < line.size()) {
                    char un = unescape_char(line[i + 1]);
                    token.push_back(un != '\0' ? un : line[i + 1]);
                    i += 2;
                    continue;
                }
                if (c == '"') { closed = true; ++i; break; }
                token.push_back(c);
                ++i;
            }
            if (!closed) return false;
        } else {
            while (i < line.size() && skip.find(line[i]) == std::string::npos) {
                token.push_back(line[i]);
                ++i;
            }
        }
        tokens.push_back(std::move(token));
    }
    return true;
}

std::string escape_for_value(const std::string &s) {
    const bool need = s.find_first_of("\f\r\t\v \"\\\n") != std::string::npos;
    std::string v;
    if (need) v.push_back('"');
    for (char c : s) {
        char e = escape_of(c);
        if (e != '\0') {
            v.push_back('\\');
            v.push_back(e);
        } else {
            v.push_back(c);
        }
    }
    if (need) v.push_back('"');
    return v;
}

// ── 文件 I/O（用户数据；沿用自定义词语的原子写规范） ──
bool read_file_bytes(const std::string &path, std::string &out, size_t limit, std::string *why) {
    auto fail = [&](const std::string &m) {
        if (why) *why = m;
        return false;
    };
#ifdef _WIN32
    std::error_code ec;
    const auto p = gogaku::windows_io::file_path(path);
    const auto size = std::filesystem::file_size(p, ec);
    if (ec) return fail("无法读取输入文件");
    if (size > limit) return fail("输入文件超过大小上限");
    std::ifstream in(p, std::ios::binary);
#else
    std::error_code ec;
    const auto size = std::filesystem::file_size(std::filesystem::path(path), ec);
    if (ec) return fail("无法读取输入文件");
    if (size > limit) return fail("输入文件超过大小上限");
    std::ifstream in(std::filesystem::path(path), std::ios::binary);
#endif
    if (!in) return fail("无法读取输入文件");
    out.resize(static_cast<size_t>(size));
    in.read(out.data(), static_cast<std::streamsize>(size));
    if (static_cast<size_t>(in.gcount()) != static_cast<size_t>(size)) return fail("输入文件读取不完整");
    return true;
}

int atomic_write_bytes(const std::string &path, const std::string &data) {
#ifdef _WIN32
    return gogaku::windows_io::atomic_write(path, data) ? 0 : 2;
#else
    std::string temp = path + "." + std::to_string(static_cast<long>(::getpid())) + ".tmp";
    FILE *f = fopen(temp.c_str(), "wb");
    if (f == nullptr) return 2;
    bool ok = fwrite(data.data(), 1, data.size(), f) == data.size();
    ok = fflush(f) == 0 && ok;
    fclose(f);
    if (!ok) {
        remove(temp.c_str());
        return 2;
    }
    (void)chmod(temp.c_str(), 0600);
    {
        int fd = ::open(temp.c_str(), O_RDONLY);
        if (fd >= 0) {
            ::fsync(fd);
            ::close(fd);
        }
    }
    if (rename(temp.c_str(), path.c_str()) != 0) {
        remove(temp.c_str());
        return 2;
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
    return 0;
#endif
}

bool ensure_dir(const std::string &path) {
#ifdef _WIN32
    std::error_code ec;
    std::filesystem::create_directories(gogaku::windows_io::file_path(path), ec);
    return !ec;
#else
    std::error_code ec;
    std::filesystem::create_directories(std::filesystem::path(path), ec);
    return !ec;
#endif
}

// 锁住读改写及两文件提交，同一用户的 stable／dev 也使用同一把锁。
class DirectoryWriteLock {
public:
    explicit DirectoryWriteLock(const std::string &dir) {
#ifdef _WIN32
        auto path = gogaku::windows_io::file_path(dir + "/.write-lock");
        handle_.value = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
                                   FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                   OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        OVERLAPPED range{};
        if (handle_.value == INVALID_HANDLE_VALUE || !LockFileEx(handle_.value, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &range))
            throw std::runtime_error("无法锁定词库目录");
#else
        fd_ = ::open((dir + "/.write-lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
        if (fd_ < 0 || flock(fd_, LOCK_EX) != 0) {
            if (fd_ >= 0) ::close(fd_);
            throw std::runtime_error("无法锁定词库目录");
        }
#endif
    }
    DirectoryWriteLock(const DirectoryWriteLock &) = delete;
    DirectoryWriteLock &operator=(const DirectoryWriteLock &) = delete;
    ~DirectoryWriteLock() {
#ifndef _WIN32
        ::close(fd_);
#endif
    }
private:
#ifdef _WIN32
    gogaku::windows_io::Handle handle_;
#else
    int fd_ = -1;
#endif
};

bool remove_file_quiet(const std::string &path) {
#ifdef _WIN32
    std::error_code ec;
    std::filesystem::remove(gogaku::windows_io::file_path(path), ec);
    return !ec;
#else
    std::error_code ec;
    std::filesystem::remove(std::filesystem::path(path), ec);
    return !ec;
#endif
}

bool rename_file(const std::string &from, const std::string &to, std::error_code &ec) {
#ifdef _WIN32
    std::filesystem::rename(gogaku::windows_io::file_path(from), gogaku::windows_io::file_path(to), ec);
#else
    std::filesystem::rename(std::filesystem::path(from), std::filesystem::path(to), ec);
#endif
    return !ec;
}

// 列出目录下 *.json（不含 .corrupt）；目录不存在返回空。
std::vector<std::string> list_meta_files(const std::string &dir) {
    std::vector<std::string> names;
#ifdef _WIN32
    std::error_code ec;
    for (const auto &entry : std::filesystem::directory_iterator(gogaku::windows_io::file_path(dir), ec)) {
        if (ec) break;
        const auto name = entry.path().filename().string();
        if (name.size() > 5 && name.compare(name.size() - 5, 5, ".json") == 0) names.push_back(name);
    }
#else
    std::error_code ec;
    for (const auto &entry : std::filesystem::directory_iterator(std::filesystem::path(dir), ec)) {
        if (ec) break;
        const std::string name = entry.path().filename().string();
        if (name.size() > 5 && name.compare(name.size() - 5, 5, ".json") == 0) names.push_back(name);
    }
#endif
    std::sort(names.begin(), names.end());
    return names;
}

// ── 拼音校验（与 libime 文本加载同一规则：VE_UE 标志） ──
bool valid_full_pinyin(const std::string &pinyin) {
    if (pinyin.empty()) return false;
    size_t start = 0;
    while (true) {
        const size_t pos = pinyin.find('\'', start);
        const std::string syl = pos == std::string::npos ? pinyin.substr(start)
                                                         : pinyin.substr(start, pos - start);
        if (syl.empty()) return false;
        try {
            auto encoded = libime::PinyinEncoder::encodeFullPinyinWithFlags(
                syl, libime::PinyinFuzzyFlag::VE_UE);
            if (encoded.empty() || !libime::PinyinEncoder::isValidUserPinyin(encoded)) return false;
        } catch (...) {
            return false;
        }
        if (pos == std::string::npos) break;
        start = pos + 1;
    }
    return true;
}

// ── 出厂词典索引（去重与读音推断共用；导入进程内缓存一份） ──
class FactoryIndex {
public:
    void load(const std::string &path) {
        libime::PinyinDictionary dict;
#ifdef _WIN32
        std::ifstream in(gogaku::windows_io::file_path(path), std::ios::binary);
        if (!in) throw std::runtime_error("出厂词典读取失败");
        dict.load(0, in, libime::PinyinDictFormat::Binary);
#else
        dict.load(0, path.c_str(), libime::PinyinDictFormat::Binary);
#endif
        std::ostringstream dump;
        dict.save(0, dump, libime::PinyinDictFormat::Text);
        std::istringstream lines(dump.str());
        std::string line;
        while (std::getline(lines, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty()) continue;
            std::vector<std::string> tokens;
            if (!tokenize_line(line, tokens) || tokens.size() < 2) continue;
            auto &set = readings_[tokens[0]];
            if (set.insert(ascii_lower(tokens[1])).second) {
                maxBytes_ = std::max(maxBytes_, tokens[0].size());
            }
        }
    }

    bool hasEntry(const std::string &word, const std::string &lowerPinyin) const {
        auto it = readings_.find(word);
        return it != readings_.end() && it->second.count(lowerPinyin) > 0;
    }

    // 整词只有一个读音时写入 out 并返回 true。
    bool inferWhole(const std::string &word, std::string &out) const {
        auto it = readings_.find(word);
        if (it == readings_.end() || it->second.size() != 1) return false;
        out = *it->second.begin();
        return true;
    }

    // 最长匹配切分：每一段都必须恰好一个读音；任一段不满足返回 false。
    bool segment(const std::string &word, std::string &out) const {
        std::vector<std::string> parts;
        size_t pos = 0;
        while (pos < word.size()) {
            bool matched = false;
            for (size_t len = std::min(maxBytes_, word.size() - pos); len >= 1; --len) {
                // 只在 UTF-8 标量边界上切。
                if ((static_cast<unsigned char>(word[pos]) & 0xC0) == 0x80) break;
                if (pos + len < word.size() && (static_cast<unsigned char>(word[pos + len]) & 0xC0) == 0x80) {
                    continue;
                }
                auto it = readings_.find(word.substr(pos, len));
                if (it == readings_.end()) continue;
                if (it->second.size() != 1) return false;
                parts.push_back(*it->second.begin());
                pos += len;
                matched = true;
                break;
            }
            if (!matched) return false;
        }
        out.clear();
        for (size_t i = 0; i < parts.size(); ++i) {
            if (i > 0) out.push_back('\'');
            out += parts[i];
        }
        return true;
    }

private:
    std::unordered_map<std::string, std::set<std::string>> readings_;
    size_t maxBytes_ = 0;
};

// ── 源条目与解析 ──
struct RawEntry {
    std::string text;
    std::string pinyin;      // 有拼音格式：撇号分隔全拼
    bool hasPinyin = false;
};

struct ParseFailure : std::runtime_error {
    explicit ParseFailure(const std::string &m) : std::runtime_error(m) {}
};

// UTF-16LE → UTF-8（scel 用）。返回空串表示遇到非法数据。
bool utf16le_to_utf8(const uint8_t *data, size_t bytes, std::string &out) {
    out.clear();
    if (bytes % 2 != 0) return false;
    for (size_t i = 0; i < bytes; i += 2) {
        const uint32_t u = static_cast<uint32_t>(data[i]) | (static_cast<uint32_t>(data[i + 1]) << 8);
        if (u >= 0xD800 && u <= 0xDBFF) {
            if (i + 3 >= bytes) return false;
            const uint32_t lo = static_cast<uint32_t>(data[i + 2]) | (static_cast<uint32_t>(data[i + 3]) << 8);
            if (!(lo >= 0xDC00 && lo <= 0xDFFF)) return false;
            const uint32_t cp = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
            // 4 字节 UTF-8
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
            i += 2;
        } else if (u >= 0xDC00 && u <= 0xDFFF) {
            return false;  // 孤立低位代理
        } else if (u < 0x80) {
            out.push_back(static_cast<char>(u));
        } else if (u < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (u >> 6)));
            out.push_back(static_cast<char>(0x80 | (u & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xE0 | (u >> 12)));
            out.push_back(static_cast<char>(0x80 | ((u >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (u & 0x3F)));
        }
    }
    return true;
}

uint16_t le_u16(const uint8_t *p) {
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

uint32_t le_u32(const uint8_t *p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) |
           (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}

// SCEL 字段布局参考 fcitx5-chinese-addons 的工具说明。这里独立处理长度与偏移。
void parse_scel(const std::string &bytes, std::vector<RawEntry> &entries) {
    constexpr size_t tableOffset = 0x1540;
    const auto *data = reinterpret_cast<const uint8_t *>(bytes.data());
    if (bytes.size() < tableOffset + 4 || le_u32(data) != tableOffset || le_u32(data + 8) != 1) {
        throw ParseFailure("不是有效的搜狗词库文件");
    }
    const auto signature = le_u32(data + 4);
    if (signature != 0x01534344 && signature != 0x01534345 && signature != 0x01536dd2) {
        throw ParseFailure("不支持的搜狗词库版本");
    }
    size_t offset = tableOffset + 4;
    auto take = [&](size_t length) {
        if (length > bytes.size() - offset) throw ParseFailure("搜狗词库字段不完整");
        auto start = data + offset;
        offset += length;
        return start;
    };
    auto read16 = [&] { return le_u16(take(2)); };
    auto text = [&] {
        const auto length = read16();
        std::string value;
        if (!utf16le_to_utf8(take(length), length, value)) value.clear();
        return value;
    };
    std::unordered_map<uint16_t, std::string> syllables;
    const auto tableSize = le_u32(data + tableOffset);
    if (tableSize == 0 || tableSize > 65536) throw ParseFailure("搜狗词库缺少可用的拼音表");
    for (uint32_t i = 0; i < tableSize; ++i) {
        const auto index = read16();
        auto syllable = text();
        if (syllable.empty() || !syllables.emplace(index, std::move(syllable)).second)
            throw ParseFailure("搜狗词库拼音表损坏");
    }
    auto readPinyin = [&] {
        const size_t length = read16();
        if (length % 2 != 0) throw ParseFailure("搜狗词库拼音索引损坏");
        const auto *indices = take(length);
        std::string result;
        for (size_t i = 0; i < length; i += 2) {
            const auto found = syllables.find(le_u16(indices + i));
            if (found == syllables.end()) return std::string();
            if (!result.empty()) result += '\'';
            result += found->second;
        }
        return result;
    };
    const auto groups = le_u32(data + 0x120);
    for (uint32_t group = 0; group < groups; ++group) {
        const auto count = read16();
        const auto pinyin = readPinyin();
        for (uint16_t i = 0; i < count; ++i) {
            entries.push_back({text(), pinyin, true});
            const auto extra = read16();
            take(extra);
        }
    }
    const auto phraseCount = le_u32(data + 0x5c);
    if (phraseCount) {
        const auto start = le_u32(data + 0x60);
        if (start < offset || start > bytes.size()) throw ParseFailure("搜狗词库短语偏移非法");
        offset = start;
        for (uint32_t i = 0; i < phraseCount; ++i) {
            const bool hasPinyin = take(17)[2] == 1;
            auto code = hasPinyin ? readPinyin() : text();
            entries.push_back({text(), hasPinyin ? std::move(code) : std::string(), true});
        }
    }
}

// Rime .dict.yaml：只解析需要的头字段（columns／import_tables）与制表符正文。
void parse_rime(const std::string &bytes, std::vector<RawEntry> &entries) {
    std::vector<std::string> columns{"text", "code", "weight"};
    bool hasImportTables = false;
    size_t textCol = 0, codeCol = 1;
    bool hasCodeCol = true;
    std::istringstream in(bytes);
    std::string line;
    enum { BeforeDoc, InHeader, InBody } state = BeforeDoc;
    bool dotsSeen = false;
    size_t entryLines = 0;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (state == BeforeDoc) {
            if (line == "---") state = InHeader;
            continue;
        }
        if (state == InHeader) {
            if (line == "..." || line == "---") {
                state = InBody;
                continue;
            }
            // 行内列表 columns: [text, code, weight]
            auto parseInlineList = [](const std::string &v) {
                std::vector<std::string> items;
                size_t p = 0;
                while (p < v.size()) {
                    const size_t comma = v.find(',', p);
                    std::string item = v.substr(p, comma == std::string::npos ? std::string::npos : comma - p);
                    // 去引号与空白
                    while (!item.empty() && (item.front() == ' ' || item.front() == '\t' || item.front() == '[' ||
                                             item.front() == ']'))
                        item.erase(item.begin());
                    while (!item.empty() && (item.back() == ' ' || item.back() == '\t' || item.back() == ']' ||
                                             item.back() == '['))
                        item.pop_back();
                    if (item.size() >= 2 && item.front() == '"' && item.back() == '"') item = item.substr(1, item.size() - 2);
                    if (!item.empty()) items.push_back(item);
                    if (comma == std::string::npos) break;
                    p = comma + 1;
                }
                return items;
            };
            if (line.rfind("columns:", 0) == 0) {
                std::string rest = line.substr(8);
                if (rest.find('[') != std::string::npos) {
                    columns = parseInlineList(rest);
                } else {
                    // 块列表：后续 "- xxx" 行
                    columns.clear();
                    while (std::getline(in, line)) {
                        if (!line.empty() && line.back() == '\r') line.pop_back();
                        if (line.size() >= 2 && line[0] == '-' && line[1] == ' ') {
                            std::string item = line.substr(2);
                            while (!item.empty() && (item.front() == ' ' || item.front() == '\t')) item.erase(item.begin());
                            while (!item.empty() && (item.back() == ' ' || item.back() == '\t')) item.pop_back();
                            if (item.size() >= 2 && item.front() == '"' && item.back() == '"') item = item.substr(1, item.size() - 2);
                            if (!item.empty()) columns.push_back(item);
                        } else {
                            // 非列表项：回到当前行处理
                            if (!(line == "..." || line == "---")) continue;
                            state = InBody;
                            break;
                        }
                    }
                    if (state == InBody) continue;
                    if (columns.empty()) columns = {"text", "code", "weight"};
                }
                textCol = codeCol = columns.size();
                hasCodeCol = false;
                for (size_t i = 0; i < columns.size(); ++i) {
                    if (columns[i] == "text") textCol = i;
                    if (columns[i] == "code") { codeCol = i; hasCodeCol = true; }
                }
                if (textCol >= columns.size()) throw ParseFailure("Rime 词库缺少 text 列");
                continue;
            }
            if (line.rfind("import_tables:", 0) == 0) {
                std::string rest = line.substr(14);
                hasImportTables = !parseInlineList(rest).empty() || rest.find_first_not_of(" \t") == std::string::npos;
                if (rest.find('[') != std::string::npos && parseInlineList(rest).empty()) hasImportTables = false;
                continue;
            }
            continue;
        }
        // 正文
        if (line.empty() || line[0] == '#') continue;
        std::vector<std::string> fields;
        {
            size_t start = 0;
            while (true) {
                const size_t tab = line.find('\t', start);
                if (tab == std::string::npos) {
                    fields.push_back(line.substr(start));
                    break;
                }
                fields.push_back(line.substr(start, tab - start));
                start = tab + 1;
            }
        }
        if (fields.size() <= textCol || fields[textCol].empty()) continue;
        ++entryLines;
        RawEntry e;
        e.text = fields[textCol];
        if (hasCodeCol && fields.size() > codeCol && !fields[codeCol].empty()) {
            // code 内空格分隔音节 → 撇号分隔；逐音节校验交给统一管线。
            std::string pinyin;
            std::istringstream syllables(fields[codeCol]);
            std::string syl;
            bool first = true;
            while (syllables >> syl) {
                if (!first) pinyin.push_back('\'');
                pinyin += syl;
                first = false;
            }
            e.pinyin = ascii_lower(pinyin);
            e.hasPinyin = !e.pinyin.empty();
        }
        entries.push_back(std::move(e));
    }
    (void)dotsSeen;
    if (hasImportTables && entryLines == 0) {
        throw ParseFailure("这是只含 import_tables 的清单文件，请导入 cn_dicts/ 下的具体词库");
    }
    if (state != InBody && entryLines == 0) {
        throw ParseFailure("不是有效的 Rime 词库（缺少 YAML 头）");
    }
}

// libime 文本：word pinyin [weight]（转义规则与 libime 一致）。
void parse_libime_text(const std::string &bytes, std::vector<RawEntry> &entries) {
    std::istringstream in(bytes);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        std::vector<std::string> tokens;
        if (!tokenize_line(line, tokens)) continue;
        if (tokens.size() != 2 && tokens.size() != 3) continue;
        RawEntry e;
        e.text = tokens[0];
        e.pinyin = ascii_lower(tokens[1]);
        e.hasPinyin = true;
        entries.push_back(std::move(e));
    }
}

// 纯词表：只取第一列（制表符或空白分隔），兼容 CR、LF 和 CRLF。
void parse_plain_text(const std::string &bytes, std::vector<RawEntry> &entries) {
    std::string_view remaining(bytes);
    if (remaining.starts_with("\xef\xbb\xbf")) remaining.remove_prefix(3);
    while (!remaining.empty()) {
        const auto end = remaining.find_first_of("\r\n");
        auto line = remaining.substr(0, end);
        remaining.remove_prefix(end == std::string_view::npos ? remaining.size() : end + 1);
        if (end != std::string_view::npos && remaining.starts_with('\n')) remaining.remove_prefix(1);
        auto field = line.substr(0, line.find('\t'));
        const auto first = field.find_first_not_of(' ');
        if (first == std::string_view::npos) continue;
        const auto last = field.find_last_not_of(' ');
        field = field.substr(first, last - first + 1);
        if (line.find('\t') == std::string_view::npos) field = field.substr(0, field.find(' '));
        entries.push_back({std::string(field), {}, false});
    }
}

// .txt 的两种格式探测：抽样前 1000 个非空行，≥95% 第二列可编码为全拼 → libime。
bool probe_libime_text(const std::string &bytes) {
    std::istringstream in(bytes);
    std::string line;
    size_t sampled = 0, valid = 0;
    while (std::getline(in, line) && sampled < 1000) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        ++sampled;
        std::vector<std::string> tokens;
        if (tokenize_line(line, tokens) && tokens.size() >= 2 && valid_full_pinyin(ascii_lower(tokens[1]))) {
            ++valid;
        }
    }
    return sampled > 0 && valid * 20 >= sampled * 19;
}

enum class SourceFormat { Scel, RimeYaml, LibimeText, LibimeDict, PlainText };

const char *format_id(SourceFormat f) {
    switch (f) {
    case SourceFormat::Scel: return "scel";
    case SourceFormat::RimeYaml: return "rime-yaml";
    case SourceFormat::LibimeText: return "libime-txt";
    case SourceFormat::LibimeDict: return "libime-dict";
    case SourceFormat::PlainText: return "plain-txt";
    }
    return "";
}

SourceFormat detect_format(const std::string &fileName, const std::string &bytes, std::string &why) {
    std::string lower = ascii_lower(fileName);
    if (lower.size() >= 10 && lower.compare(lower.size() - 10, 10, ".dict.yaml") == 0) {
        return SourceFormat::RimeYaml;
    }
    if (lower.size() >= 5 && lower.compare(lower.size() - 5, 5, ".yaml") == 0) {
        return SourceFormat::RimeYaml;
    }
    if (lower.size() >= 5 && lower.compare(lower.size() - 5, 5, ".scel") == 0) {
        return SourceFormat::Scel;
    }
    if (lower.size() >= 5 && lower.compare(lower.size() - 5, 5, ".dict") == 0) {
        // 二进制合法性由加载阶段校验。
        return SourceFormat::LibimeDict;
    }
    if (lower.size() >= 4 && lower.compare(lower.size() - 4, 4, ".txt") == 0) {
        return probe_libime_text(bytes) ? SourceFormat::LibimeText : SourceFormat::PlainText;
    }
    why = "不支持的文件类型（支持 .scel、.dict.yaml、.dict、.txt）";
    throw ParseFailure(why);
}

// libime 二进制 → 文本条目（统一走过滤管线；entryCount 与过滤口径与文本源一致）。
void parse_libime_dict(const std::string &bytes, std::vector<RawEntry> &entries) {
    libime::PinyinDictionary dict;
    std::istringstream in(bytes);
    try {
        dict.load(0, in, libime::PinyinDictFormat::Binary);
    } catch (const std::exception &) {
        throw ParseFailure("不是有效的 libime 二进制词库");
    }
    std::ostringstream dump;
    dict.save(0, dump, libime::PinyinDictFormat::Text);
    std::istringstream lines(dump.str());
    std::string line;
    while (std::getline(lines, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty()) continue;
        std::vector<std::string> tokens;
        if (!tokenize_line(line, tokens) || tokens.size() < 2) continue;
        RawEntry e;
        e.text = tokens[0];
        e.pinyin = ascii_lower(tokens[1]);
        e.hasPinyin = true;
        entries.push_back(std::move(e));
    }
}

// ── 过滤与读音推断（docs/dictionaries.md §二；每个条目只记第一个命中原因） ──
struct DropCounters {
    size_t invalidLine = 0, middleDot = 0, tooLong = 0, duplicateFactory = 0, duplicateEntry = 0,
           nonHan = 0, ambiguousReading = 0;
    size_t total() const {
        return invalidLine + middleDot + tooLong + duplicateFactory + duplicateEntry + nonHan +
               ambiguousReading;
    }
    Json toJson() const {
        return Json{{"invalidLine", invalidLine},
                    {"middleDot", middleDot},
                    {"tooLong", tooLong},
                    {"duplicateFactory", duplicateFactory},
                    {"duplicateEntry", duplicateEntry},
                    {"nonHan", nonHan},
                    {"ambiguousReading", ambiguousReading}};
    }
};

struct Cancelled {};

void drop_reason_json(const DropCounters &c, Json &out) { out = c.toJson(); }

// 返回存活条目；取消时抛 Cancelled。
std::vector<RawEntry> filter_entries(std::vector<RawEntry> &entries, bool pureText,
                                     const FactoryIndex &factory, DropCounters &drops,
                                     int (*progress)(void *, size_t, size_t), void *ctx) {
    std::vector<RawEntry> kept;
    kept.reserve(entries.size());
    std::unordered_set<std::string> seen;  // text + '\x1f' + pinyin
    const size_t total = entries.size();
    for (size_t i = 0; i < entries.size(); ++i) {
        RawEntry &e = entries[i];
        if (progress != nullptr && i % 8192 == 0) {
            if (progress(ctx, i, total) != 0) throw Cancelled();
        }
        if (e.text.empty() || word_has_forbidden(e.text)) { ++drops.invalidLine; continue; }
        if (word_has_middle_dot(e.text)) { ++drops.middleDot; continue; }
        if (scalar_count(e.text) == static_cast<size_t>(-1) || scalar_count(e.text) > 32) {
            ++drops.tooLong;
            continue;
        }
        // 纯词表（文件级）与无拼音条目（Rime 无 code 列）都走读音推断；
        // 带拼音格式的条目走拼音校验。
        const bool pureEntry = pureText || !e.hasPinyin;
        std::string pinyin;
        if (!pureEntry) {
            if (!valid_full_pinyin(e.pinyin)) { ++drops.invalidLine; continue; }
            pinyin = e.pinyin;
        } else {
            // 纯词表：先结构检查，再定读音。
            if (!word_all_han(e.text)) { ++drops.nonHan; continue; }
            std::string inferred;
            if (!factory.inferWhole(e.text, inferred) && !factory.segment(e.text, inferred)) {
                ++drops.ambiguousReading;
                continue;
            }
            pinyin = inferred;
        }
        if (factory.hasEntry(e.text, pinyin)) { ++drops.duplicateFactory; continue; }
        const std::string key = e.text + '\x1f' + pinyin;
        if (!seen.insert(key).second) { ++drops.duplicateEntry; continue; }
        if (kept.size() == kMaxEntries) throw ParseFailure("输出词库超过 500 万条上限");
        e.pinyin = std::move(pinyin);
        kept.push_back(std::move(e));
    }
    return kept;
}

// 生成 libime 二进制词库字节（统一权重 0）。
std::string build_binary_dict(const std::vector<RawEntry> &entries) {
    std::ostringstream text;
    for (const auto &e : entries) {
        text << escape_for_value(e.text) << ' ' << e.pinyin << " 0\n";
    }
    libime::PinyinDictionary dict;
    std::istringstream in(text.str());
    dict.load(0, in, libime::PinyinDictFormat::Text);
    std::ostringstream out;
    dict.save(0, out, libime::PinyinDictFormat::Binary);
    return out.str();
}

// ── 元数据 ──
constexpr const char *kDictSchemaVersion = "schemaVersion";

bool valid_dict_id(const std::string &id) {
    if (id.starts_with("import-")) {
        return id.size() == 23 && id.find_first_not_of("0123456789abcdef", 7) == std::string::npos;
    }
    if (id.empty() || id.size() > 64) return false;
    for (char c : id) {
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
    }
    return true;
}

bool read_meta(const std::string &dir, const std::string &name, Json &meta) {
    std::string bytes;
    if (!read_file_bytes(dir + "/" + name, bytes, 4 * 1024 * 1024, nullptr)) return false;
    meta = Json::parse(bytes, nullptr, false);
    return !meta.is_discarded() && meta.is_object();
}

Json make_meta(const std::string &id, const std::string &name, const char *origin,
               const char *sourceFormat, const std::string &sourceFileName,
               const std::string &sourceContentId, const std::string &version,
               const std::string &license, const std::string &attribution,
               const std::string &sourceUrl, int64_t addedAt, size_t entryCount,
               const Json &dropped, uint64_t sizeBytes, const std::string &contentId,
               bool enabled) {
    return Json{{kDictSchemaVersion, 1},
                {"id", id},
                {"name", name},
                {"origin", origin},
                {"sourceFormat", sourceFormat},
                {"sourceFileName", sourceFileName},
                {"sourceContentId", sourceContentId},
                {"version", version},
                {"license", license},
                {"attribution", attribution},
                {"sourceUrl", sourceUrl},
                {"addedAt", addedAt},
                {"entryCount", entryCount},
                {"dropped", dropped},
                {"sizeBytes", sizeBytes},
                {"contentId", contentId},
                {"enabled", enabled}};
}

// 学习可用性：单本 ≤8MiB 且按挂载顺序累计 ≤16MiB（挂载顺序 = addedAt）。
bool learning_fits(uint64_t sizeBytes, uint64_t &runningTotal) {
    if (sizeBytes > kLearningPerDictMax) return false;
    if (runningTotal + sizeBytes > kLearningTotalMax) return false;
    return true;
}

}  // namespace

// ── C ABI：导入 ──
extern "C" int gc_dict_import(const GcDictImportRequest *req,
                              int (*progress)(void *ctx, size_t done, size_t total), void *ctx,
                              char **result_json, char *err, size_t err_len) {
    if (result_json != nullptr) *result_json = nullptr;
    try {
        if (req == nullptr || req->input_path == nullptr || req->dictionaries_dir == nullptr ||
            req->system_dict_path == nullptr) {
            set_error(err, err_len, "参数错误");
            return 1;
        }
        ensure_dir(req->dictionaries_dir);

        std::string bytes;
        std::string why;
        if (!read_file_bytes(req->input_path, bytes, kMaxInputBytes, &why)) {
            set_error(err, err_len, why);
            return 2;
        }

        // 源内容哈希与重复导入检查。
        const std::string sourceContentId =
            gogaku::fnv1a64_hex(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size());
        Json selfCheck;
        for (const std::string &name : list_meta_files(req->dictionaries_dir)) {
            Json meta;
            if (!read_meta(req->dictionaries_dir, name, meta)) continue;
            const auto it = meta.find("sourceContentId");
            if (it != meta.end() && it->is_string() && it->get<std::string>() == sourceContentId) {
                const auto idIt = meta.find("id");
                const std::string conflict =
                    idIt != meta.end() && idIt->is_string() ? idIt->get<std::string>() : name;
                set_error(err, err_len, "同一源文件已导入过（" + conflict + "）");
                return 4;
            }
        }

        // 识别格式并解析。
        std::string fileName = req->input_path;
        {
            const size_t slash = fileName.find_last_of("/\\");
            if (slash != std::string::npos) fileName = fileName.substr(slash + 1);
        }
        const SourceFormat format = detect_format(fileName, bytes, why);
        std::vector<RawEntry> entries;
        switch (format) {
        case SourceFormat::Scel: parse_scel(bytes, entries); break;
        case SourceFormat::RimeYaml: parse_rime(bytes, entries); break;
        case SourceFormat::LibimeText: parse_libime_text(bytes, entries); break;
        case SourceFormat::LibimeDict: parse_libime_dict(bytes, entries); break;
        case SourceFormat::PlainText: parse_plain_text(bytes, entries); break;
        }
        if (progress != nullptr && progress(ctx, 0, entries.size()) != 0) throw Cancelled();

        FactoryIndex factory;
        factory.load(req->system_dict_path);

        DropCounters drops;
        const bool pureText = format == SourceFormat::PlainText;
        std::vector<RawEntry> kept =
            filter_entries(entries, pureText, factory, drops, progress, ctx);
        if (kept.empty() && drops.total() == 0) {
            set_error(err, err_len, "文件为空或没有可导入的词条");
            return 2;
        }

        const std::string binary = build_binary_dict(kept);
        if (progress && progress(ctx, entries.size(), entries.size()) != 0) throw Cancelled();
        DirectoryWriteLock lock(req->dictionaries_dir);
        for (const auto &name : list_meta_files(req->dictionaries_dir)) {
            Json meta;
            if (read_meta(req->dictionaries_dir, name, meta) &&
                meta.contains("sourceContentId") && meta["sourceContentId"] == sourceContentId) {
                set_error(err, err_len, "同一源文件已导入过");
                return 4;
            }
        }
        // 生成 id 并写出（先 .dict 后 .json；元数据是提交点）。
        std::random_device rd;
        std::mt19937_64 gen(rd());
        std::string id;
        do {
            char hex[17];
            snprintf(hex, sizeof(hex), "%016llx", static_cast<unsigned long long>(gen()));
            id = std::string("import-") + hex;
        } while (read_meta(req->dictionaries_dir, id + ".json", selfCheck));

        if (atomic_write_bytes(std::string(req->dictionaries_dir) + "/" + id + ".dict", binary) != 0) {
            set_error(err, err_len, "写盘失败");
            return 2;
        }
        std::string displayName = req->display_name == nullptr ? std::string() : std::string(req->display_name);
        if (displayName.empty()) {
            displayName = fileName;
            const size_t dot = displayName.rfind('.');
            if (dot != std::string::npos && dot != 0) displayName = displayName.substr(0, dot);
        }
        const Json meta = make_meta(id, displayName, "import", format_id(format), fileName,
                                    sourceContentId, "", "", "", "",
                                    static_cast<int64_t>(std::time(nullptr)), kept.size(),
                                    drops.toJson(), binary.size(),
                                    gogaku::fnv1a64_hex(reinterpret_cast<const uint8_t *>(binary.data()),
                                                        binary.size()),
                                    true);
        if (atomic_write_bytes(std::string(req->dictionaries_dir) + "/" + id + ".json", meta.dump()) != 0) {
            remove_file_quiet(std::string(req->dictionaries_dir) + "/" + id + ".dict");
            set_error(err, err_len, "写盘失败");
            return 2;
        }

        if (result_json != nullptr) {
            const Json result{{"id", id},
                              {"name", displayName},
                              {"entryCount", kept.size()},
                              {"dropped", drops.toJson()},
                              {"sizeBytes", binary.size()},
                              {"contentId", meta["contentId"]}};
            *result_json = dup_cstr(result.dump());
        }
        return 0;
    } catch (const Cancelled &) {
        set_error(err, err_len, "已取消");
        return 3;
    } catch (const ParseFailure &e) {
        set_error(err, err_len, e.what());
        return 2;
    } catch (const std::exception &e) {
        set_error(err, err_len, std::string("导入失败：") + e.what());
        return 2;
    } catch (...) {
        set_error(err, err_len, "导入失败");
        return 2;
    }
}

// ── C ABI：列表／开关／删除／校验 ──
extern "C" int gc_dict_list(const char *dir, uint32_t flags, char **json) {
    if (json == nullptr || dir == nullptr) return 1;
    *json = nullptr;
    try {
        const bool learningAvailable = (flags & 1u) != 0;
        Json dicts = Json::array();
        Json corrupt = Json::array();
        struct Entry {
            Json meta;
            uint64_t size;
            int64_t addedAt;
            std::string id;
            bool enabled;
        };
        std::vector<Entry> list;
        for (const std::string &name : list_meta_files(dir)) {
            Json meta;
            std::string bytes;
            std::string why;
            if (!read_file_bytes(dir + std::string("/") + name, bytes, 4 * 1024 * 1024, &why) ||
                (meta = Json::parse(bytes, nullptr, false)).is_discarded() || !meta.is_object() ||
                meta.value("id", std::string()).empty()) {
                // 损坏元数据：备份 .corrupt 并报告（与自定义词语同规范）。
                std::error_code ec;
                (void)rename_file(dir + std::string("/") + name, dir + std::string("/") + name + ".corrupt", ec);
                corrupt.push_back(Json{{"file", name}, {"reason", "元数据损坏，已备份为 .corrupt"}});
                continue;
            }
            Entry e;
            e.meta = meta;
            e.size = meta.value("sizeBytes", static_cast<uint64_t>(0));
            e.addedAt = meta.value("addedAt", static_cast<int64_t>(0));
            e.id = meta.value("id", std::string());
            e.enabled = meta.value("enabled", false);
            list.push_back(std::move(e));
        }
        std::sort(list.begin(), list.end(), [](const Entry &a, const Entry &b) {
            if (a.addedAt != b.addedAt) return a.addedAt < b.addedAt;
            return a.id < b.id;
        });
        uint64_t enabledBytes = 0, running = 0;
        for (const auto &e : list) {
            const bool fits = learning_fits(e.size, running);
            if (e.enabled) {
                enabledBytes += e.size * kEstimateFactor;
                if (fits) running += e.size;
            }
            Json item = e.meta;
            item["normal"] = true;
            item["learning"] = learningAvailable && fits;
            item["estimatedBytes"] = e.size * kEstimateFactor;
            dicts.push_back(std::move(item));
        }
        const Json out{{"dictionaries", dicts},
                       {"enabledEstimatedBytes", enabledBytes},
                       {"warn", enabledBytes > kMemoryWarnBytes},
                       {"corrupt", corrupt}};
        *json = dup_cstr(out.dump());
        return 0;
    } catch (...) {
        return 2;
    }
}

extern "C" int gc_dict_set_enabled(const char *dir, const char *id, int32_t enabled, char *err,
                                   size_t err_len) {
    try {
        if (dir == nullptr || id == nullptr || !valid_dict_id(id)) {
            set_error(err, err_len, "参数错误");
            return 1;
        }
        DirectoryWriteLock lock(dir);
        Json meta;
        if (!read_meta(dir, std::string(id) + ".json", meta)) {
            set_error(err, err_len, "未找到词库元数据");
            return 2;
        }
        meta["enabled"] = enabled != 0;
        if (atomic_write_bytes(dir + std::string("/") + id + ".json", meta.dump()) != 0) {
            set_error(err, err_len, "写盘失败");
            return 2;
        }
        return 0;
    } catch (...) {
        set_error(err, err_len, "操作失败");
        return 2;
    }
}

extern "C" int gc_dict_remove(const char *dir, const char *id, char *err, size_t err_len) {
    try {
        if (dir == nullptr || id == nullptr || !valid_dict_id(id)) {
            set_error(err, err_len, "参数错误");
            return 1;
        }
        DirectoryWriteLock lock(dir);
        // 先删元数据（提交点），再删 .dict；残留孤立 .dict 会被 list 忽略。
        const std::string metaPath = dir + std::string("/") + id + ".json";
        if (!remove_file_quiet(metaPath)) {
            set_error(err, err_len, "未找到词库");
            return 2;
        }
        remove_file_quiet(dir + std::string("/") + id + ".dict");
        return 0;
    } catch (...) {
        set_error(err, err_len, "删除失败");
        return 2;
    }
}

extern "C" int gc_dict_verify(const char *dir, const char *id, char **json, char *err,
                              size_t err_len) {
    if (json != nullptr) *json = nullptr;
    try {
        if (dir == nullptr || id == nullptr || !valid_dict_id(id)) {
            set_error(err, err_len, "参数错误");
            return 1;
        }
        Json meta;
        if (!read_meta(dir, std::string(id) + ".json", meta)) {
            set_error(err, err_len, "未找到词库元数据");
            return 3;
        }
        std::string bytes;
        std::string why;
        if (!read_file_bytes(dir + std::string("/") + id + ".dict", bytes, kMaxInputBytes, &why)) {
            set_error(err, err_len, why.empty() ? "词库文件缺失" : why);
            return 3;
        }
        const std::string actual =
            gogaku::fnv1a64_hex(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size());
        const std::string expected = meta.value("contentId", std::string());
        if (json != nullptr) {
            *json = dup_cstr(Json{{"expected", expected}, {"actual", actual}}.dump());
        }
        if (actual != expected) {
            set_error(err, err_len, "词库内容与元数据不一致（contentId 不符）");
            return 2;
        }
        return 0;
    } catch (...) {
        set_error(err, err_len, "校验失败");
        return 2;
    }
}

// ── C ABI：官方清单 ──
namespace {

// 语义化版本比较：<0 / 0 / >0；数字段按数值，非数字段按字典序，缺段补 0。
int compare_versions(const std::string &a, const std::string &b) {
    std::vector<std::string> pa, pb;
    auto split = [](const std::string &s, std::vector<std::string> &out) {
        size_t start = 0;
        while (true) {
            const size_t dot = s.find('.', start);
            out.push_back(s.substr(start, dot == std::string::npos ? std::string::npos : dot - start));
            if (dot == std::string::npos) break;
            start = dot + 1;
        }
    };
    split(a, pa);
    split(b, pb);
    const size_t n = std::max(pa.size(), pb.size());
    for (size_t i = 0; i < n; ++i) {
        const std::string &x = i < pa.size() ? pa[i] : "0";
        const std::string &y = i < pb.size() ? pb[i] : "0";
        const bool xn = !x.empty() && x.find_first_not_of("0123456789") == std::string::npos;
        const bool yn = !y.empty() && y.find_first_not_of("0123456789") == std::string::npos;
        if (xn && yn) {
            const long long xi = std::strtoll(x.c_str(), nullptr, 10);
            const long long yi = std::strtoll(y.c_str(), nullptr, 10);
            if (xi != yi) return xi < yi ? -1 : 1;
        } else if (x != y) {
            return x < y ? -1 : 1;
        }
    }
    return 0;
}

}  // namespace

extern "C" int gc_dict_catalog_parse(const uint8_t *bytes, size_t len, const char *config_json,
                                     const char *installed_json, char **json, char *err,
                                     size_t err_len) {
    if (json != nullptr) *json = nullptr;
    try {
        if (bytes == nullptr && len != 0) {
            set_error(err, err_len, "参数错误");
            return 1;
        }
        if (json == nullptr || config_json == nullptr) {
            set_error(err, err_len, "参数错误");
            return 1;
        }
        const Json config = Json::parse(config_json, nullptr, false);
        if (config.is_discarded() || !config.is_object()) {
            set_error(err, err_len, "参数错误");
            return 1;
        }
        Json installed = Json::array();
        if (installed_json != nullptr && *installed_json != '\0') {
            installed = Json::parse(installed_json, nullptr, false);
            if (installed.is_discarded() || !installed.is_array()) {
                set_error(err, err_len, "参数错误");
                return 1;
            }
        }
        const Json doc = Json::parse(reinterpret_cast<const char *>(bytes),
                                     reinterpret_cast<const char *>(bytes) + len, nullptr, false);
        if (doc.is_discarded() || !doc.is_object()) {
            set_error(err, err_len, "清单不是合法 JSON");
            return 3;
        }
        const auto kind = doc.find("kind");
        if (kind == doc.end() || !kind->is_string() || kind->get<std::string>() != "gogaku-dictionary-catalog") {
            set_error(err, err_len, "清单类型不符（kind）");
            return 2;
        }
        const auto schema = doc.find("schemaVersion");
        if (schema == doc.end() || !schema->is_number_integer() || schema->get<int>() != 1) {
            set_error(err, err_len, "清单 schema 不支持");
            return 2;
        }
        const auto keyId = doc.find("keyId");
        if (keyId == doc.end() || !keyId->is_string()) {
            set_error(err, err_len, "清单缺少 keyId");
            return 2;
        }
        const auto trusted = config.find("trustedKeyIds");
        bool trustedOk = trusted != config.end() && trusted->is_array();
        if (trustedOk) {
            trustedOk = false;
            for (const auto &k : *trusted) {
                if (k.is_string() && k.get<std::string>() == keyId->get<std::string>()) trustedOk = true;
            }
        }
        if (!trustedOk) {
            set_error(err, err_len, "清单 keyId 不在信任列表");
            return 2;
        }
        const auto versionField = doc.find("catalogVersion");
        if (versionField == doc.end() || !versionField->is_number_integer() ||
            versionField->get<long long>() < 0) {
            set_error(err, err_len, "清单缺少 catalogVersion");
            return 2;
        }
        const long long catalogVersion = versionField->get<long long>();
        const auto localVersion = config.find("catalogVersion");
        if (localVersion != config.end() && localVersion->is_number_integer() &&
            catalogVersion < localVersion->get<long long>()) {
            set_error(err, err_len, "清单版本回滚");
            return 2;
        }
        std::string prefix;
        if (const auto p = config.find("downloadPrefix"); p != config.end() && p->is_string()) {
            prefix = p->get<std::string>();
        }

        if (prefix.empty() || !prefix.starts_with("https://github.com/")) {
            set_error(err, err_len, "下载前缀未配置");
            return 1;
        }
        std::unordered_map<std::string, std::string> installedVersions;
        for (const auto &entry : installed) {
            if (entry.is_object() && entry.contains("id") && entry["id"].is_string()) {
                installedVersions[entry["id"].get<std::string>()] =
                    entry.contains("version") && entry["version"].is_string()
                        ? entry["version"].get<std::string>()
                        : std::string();
            }
        }

        Json items = Json::array();
        Json rejected = Json::array();
        const auto dictionaries = doc.find("dictionaries");
        if (dictionaries != doc.end() && dictionaries->is_array()) {
            for (const auto &entry : *dictionaries) {
                std::string reason;
                std::string id;
                if (!entry.is_object()) {
                    reason = "条目不是对象";
                } else {
                    const auto getStr = [&](const char *key) -> std::string {
                        const auto it = entry.find(key);
                        return it != entry.end() && it->is_string() ? it->get<std::string>() : std::string();
                    };
                    id = getStr("id");
                    bool idOk = !id.empty() && id.size() <= 64;
                    for (char c : id) {
                        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) idOk = false;
                    }
                    const std::string downloadUrl = getStr("downloadUrl");
                    const auto sizeIt = entry.find("size");
                    const auto countIt = entry.find("entryCount");
                    const std::string sha = getStr("sha256");
                    const bool shaOk = sha.size() == 64 &&
                                       sha.find_first_not_of("0123456789abcdef") == std::string::npos;
                    if (!idOk) reason = "id 非法";
                    else if (getStr("name").empty()) reason = "缺少名称";
                    else if (downloadUrl.rfind(prefix, 0) != 0) reason = "downloadUrl 越界";
                    else if (downloadUrl.find("..") != std::string::npos) reason = "downloadUrl 越界";
                    else if (sizeIt == entry.end() || !sizeIt->is_number_integer() ||
                             sizeIt->get<long long>() <= 0)
                        reason = "size 非法";
                    else if (!shaOk) reason = "sha256 非法";
                    else if (countIt == entry.end() || !countIt->is_number_integer() ||
                             countIt->get<long long>() < 0)
                        reason = "entryCount 非法";
                }
                if (!reason.empty()) {
                    rejected.push_back(Json{{"id", id}, {"reason", reason}});
                    continue;
                }
                Json item = entry;
                const auto iv = installedVersions.find(id);
                const auto versionIt = entry.find("version");
                const std::string version =
                    versionIt != entry.end() && versionIt->is_string() ? versionIt->get<std::string>() : "";
                item["installed"] = iv != installedVersions.end();
                item["updateAvailable"] =
                    iv != installedVersions.end() && compare_versions(version, iv->second) > 0;
                items.push_back(std::move(item));
            }
        }
        const Json out{{"dictionaries", items},
                       {"rejected", rejected},
                       {"catalogVersion", catalogVersion}};
        *json = dup_cstr(out.dump());
        return 0;
    } catch (...) {
        set_error(err, err_len, "清单解析失败");
        return 3;
    }
}

// ── C ABI：安装官方词库 ──
extern "C" int gc_dict_install(const char *dir, const char *downloaded_path,
                              const char *entry_json, char *err, size_t err_len) {
    try {
        if (dir == nullptr || downloaded_path == nullptr || entry_json == nullptr) {
            set_error(err, err_len, "参数错误");
            return 1;
        }
        const Json entry = Json::parse(entry_json, nullptr, false);
        if (entry.is_discarded() || !entry.is_object()) {
            set_error(err, err_len, "参数错误");
            return 1;
        }
        const auto strField = [&](const char *key) {
            const auto it = entry.find(key);
            return it != entry.end() && it->is_string() ? it->get<std::string>() : std::string();
        };
        const std::string id = strField("id");
        if (!valid_dict_id(id)) {
            set_error(err, err_len, "条目 id 非法");
            return 1;
        }
        std::string bytes;
        std::string why;
        if (!read_file_bytes(downloaded_path, bytes, kMaxInputBytes, &why)) {
            set_error(err, err_len, why.empty() ? "无法读取下载文件" : why);
            return 2;
        }
        // 完整性：大小与 SHA-256 必须与清单一致（清单已验签）。
        const auto sizeIt = entry.find("size");
        if (sizeIt == entry.end() || !sizeIt->is_number_integer() ||
            static_cast<uint64_t>(sizeIt->get<long long>()) != bytes.size()) {
            set_error(err, err_len, "下载文件大小与清单不符");
            return 4;
        }
        const std::string actualSha =
            gogaku::sha256_hex(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size());
        if (actualSha != strField("sha256")) {
            set_error(err, err_len, "下载文件哈希与清单不符");
            return 4;
        }
        // 内容合法性：必须是可加载的 libime 二进制词库。
        {
            libime::PinyinDictionary probe;
            std::istringstream in(bytes);
            try {
                probe.load(0, in, libime::PinyinDictFormat::Binary);
            } catch (const std::exception &) {
                set_error(err, err_len, "下载文件不是有效的 libime 词库");
                return 2;
            }
        }
        if (!ensure_dir(dir)) throw std::runtime_error("无法创建词库目录");
        DirectoryWriteLock lock(dir);

        // 更新已有词库时保留 enabled 与用户不可见的其他未知字段。
        Json existing;
        const bool updating = read_meta(dir, id + ".json", existing);
        if (updating && (existing.value("origin", std::string()) != "official" ||
                         compare_versions(strField("version"), existing.value("version", std::string())) < 0 ||
                         entry.value("catalogVersion", 0ll) < existing.value("catalogVersion", 0ll))) {
            throw std::runtime_error("拒绝词库版本回滚");
        }
        const bool enabled = updating ? existing.value("enabled", true) : true;
        const Json meta = make_meta(
            id, strField("name"), "official",
            strField("sourceFormat").c_str(), strField("sourceFileName"), "", strField("version"),
            strField("license"), strField("attribution"), strField("sourceUrl"),
            updating ? existing.value("addedAt", static_cast<int64_t>(std::time(nullptr)))
                     : static_cast<int64_t>(std::time(nullptr)),
            entry.contains("entryCount") && entry["entryCount"].is_number_integer()
                ? static_cast<size_t>(entry["entryCount"].get<long long>())
                : 0,
            Json::object(), bytes.size(),
            gogaku::fnv1a64_hex(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size()), enabled);
        // catalogVersion 随官方词库元数据持久化（防回滚的本地记录）。
        Json metaOut = meta;
        if (entry.contains("catalogVersion") && entry["catalogVersion"].is_number_integer()) {
            metaOut["catalogVersion"] = entry["catalogVersion"];
        }
        const std::string dictPath = std::string(dir) + "/" + id + ".dict";
        const auto encodedMeta = metaOut.dump();
        std::string previous;
        if (updating && !read_file_bytes(dictPath, previous, kMaxInputBytes, nullptr))
            throw std::runtime_error("原词库读取失败");
        if (atomic_write_bytes(dictPath, bytes) != 0) {
            set_error(err, err_len, "写盘失败");
            return 2;
        }
        if (atomic_write_bytes(dir + std::string("/") + id + ".json", encodedMeta) != 0) {
            if (updating) (void)atomic_write_bytes(dictPath, previous);
            else remove_file_quiet(dictPath);
            set_error(err, err_len, "写盘失败");
            return 2;
        }
        return 0;
    } catch (const std::exception &e) {
        set_error(err, err_len, std::string("安装失败：") + e.what());
        return 2;
    } catch (...) {
        set_error(err, err_len, "安装失败");
        return 2;
    }
}

// ── C ABI：加载 ──
extern "C" int gc_dict_load(const char *dir, const char *id, GcDictHandle **handle,
                           char *err, size_t err_len) {
    if (handle != nullptr) *handle = nullptr;
    try {
        if (dir == nullptr || id == nullptr || handle == nullptr || !valid_dict_id(id)) {
            set_error(err, err_len, "参数错误");
            return 1;
        }
        Json meta;
        if (!read_meta(dir, std::string(id) + ".json", meta)) {
            set_error(err, err_len, "未找到词库元数据");
            return 3;
        }
        std::string bytes;
        std::string why;
        if (!read_file_bytes(dir + std::string("/") + id + ".dict", bytes, kMaxInputBytes, &why)) {
            set_error(err, err_len, why.empty() ? "词库文件缺失" : why);
            return 3;
        }
        const std::string actual =
            gogaku::fnv1a64_hex(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size());
        if (actual != meta.value("contentId", std::string())) {
            set_error(err, err_len, "词库内容与元数据不一致（contentId 不符）");
            return 2;
        }
        std::istringstream in(bytes);
        libime::PinyinDictionary::TrieType trie;
        try {
            trie = libime::PinyinDictionary::load(in, libime::PinyinDictFormat::Binary);
        } catch (const std::exception &) {
            set_error(err, err_len, "词库文件损坏");
            return 3;
        }
        auto h = std::make_unique<::GcDictHandle>();
        h->id = id;
        h->sizeBytes = meta.value("sizeBytes", static_cast<uint64_t>(0));
        h->trie = std::move(trie);
        *handle = h.release();
        return 0;
    } catch (...) {
        set_error(err, err_len, "加载失败");
        return 2;
    }
}

extern "C" void gc_dict_handle_free(GcDictHandle *handle) {
    delete handle;
}

// ── 共享挂载实现（普通会话与学习会话共用） ──
namespace gogaku {

int dict_mount_apply(libime::PinyinDictionary &dict,
                     std::vector<DictSlot> &state,
                     const std::vector<std::pair<std::string, GcDictHandle *>> &wanted,
                     std::vector<size_t> &consumed) {
    consumed.clear();
    try {
        // 目标集合；句柄为 NULL 表示保留现状。
        std::unordered_map<std::string, size_t> wantedIndex;
        for (size_t i = 0; i < wanted.size(); ++i) wantedIndex.emplace(wanted[i].first, i);

        // 1) 标记不再需要的槽（占位）；尾部收缩在最后统一做。
        for (size_t s = 0; s < state.size(); ++s) {
            if (state[s].id.empty()) continue;
            if (wantedIndex.count(state[s].id) == 0) {
                dict.setTrie(2 + s, libime::PinyinDictionary::TrieType{});
                dict.setFlags(2 + s, libime::PinyinDictFlag::Disabled);
                state[s].id.clear();
                state[s].disabled = true;
                state[s].sizeBytes = 0;
            }
        }

        // 2) 挂载/替换。
        for (size_t i = 0; i < wanted.size(); ++i) {
            const auto &id = wanted[i].first;
            GcDictHandle *handle = wanted[i].second;
            if (handle == nullptr) continue;  // 保留现状
            // 已在槽上：整体替换。
            bool placed = false;
            for (size_t s = 0; s < state.size(); ++s) {
                if (state[s].id == id) {
                    dict.setTrie(2 + s, std::move(handle->trie));
                    dict.setFlags(2 + s, libime::PinyinDictFlag::NoFlag);
                    state[s].disabled = false;
                    state[s].sizeBytes = handle->sizeBytes;
                    consumed.push_back(i);
                    placed = true;
                    break;
                }
            }
            if (placed) continue;
            // 复用占位空槽，否则尾部追加。
            size_t slot = state.size();
            for (size_t s = 0; s < state.size(); ++s) {
                if (state[s].disabled && state[s].id.empty()) { slot = s; break; }
            }
            while (dict.dictSize() < 2 + slot + 1) dict.addEmptyDict();
            dict.setTrie(2 + slot, std::move(handle->trie));
            dict.setFlags(2 + slot, libime::PinyinDictFlag::NoFlag);
            if (slot == state.size()) state.push_back(DictSlot{});
            state[slot].id = id;
            state[slot].disabled = false;
            state[slot].sizeBytes = handle->sizeBytes;
            consumed.push_back(i);
        }

        // 3) 尾部空槽收拢：removeFrom 会移除下标及之后全部槽。
        while (!state.empty() && state.back().disabled) {
            const size_t idx = 2 + state.size() - 1;
            if (dict.dictSize() > idx) dict.removeFrom(idx);
            state.pop_back();
        }
        return 0;
    } catch (...) {
        return 2;
    }
}

}  // namespace gogaku
