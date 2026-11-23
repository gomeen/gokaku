// 扩展词库导入转换向量：五种格式、每个丢弃原因、每个错误码、取消与重复导入。
// 合同见 docs/dictionaries.md §二；合成 scel 由本文件按逆向布局生成，不含搜狗数据。
#include "gogaku_core.h"

#include "../../third_party/json.hpp"

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <libime/pinyin/pinyindictionary.h>

#ifdef _WIN32
#include "windows_io.h"
#include <windows.h>
#endif

namespace {

using Json = nlohmann::json;

int failures = 0;

void check(bool condition, const char *name, const std::string &detail) {
    if (condition) return;
    std::fprintf(stderr, "FAIL %s: %s\n", name, detail.c_str());
    ++failures;
}

void write_file(const std::string &path, const std::string &content) {
    std::ofstream out(path, std::ios::binary);
    out << content;
    if (!out) {
        std::fprintf(stderr, "FATAL 无法写出 %s\n", path.c_str());
        std::exit(2);
    }
}

std::string read_file(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

std::string temp_dir() {
#ifdef _WIN32
    char base[MAX_PATH];
    if (GetTempPathA(MAX_PATH, base) == 0) return ".";
    static unsigned counter = 0;
    const std::string dir = std::string(base) + "gogaku-dict-import-" +
                            std::to_string(static_cast<unsigned>(GetCurrentProcessId())) + "-" +
                            std::to_string(++counter);
    std::filesystem::create_directories(dir);
    return dir;
#else
    char tpl[] = "/tmp/gogaku-dict-import-XXXXXX";
    if (mkdtemp(tpl) == nullptr) {
        std::fprintf(stderr, "FATAL 无法创建临时目录\n");
        std::exit(2);
    }
    return tpl;
#endif
}

void put16_of(std::string &s, uint16_t v) {
    s.push_back(static_cast<char>(v & 0xFF));
    s.push_back(static_cast<char>((v >> 8) & 0xFF));
}

void put32_of(std::string &s, size_t off, uint32_t v) {
    for (int k = 0; k < 4; ++k) s[off + static_cast<size_t>(k)] = static_cast<char>((v >> (8 * k)) & 0xFF);
}

// 合成 scel：拼音表（索引 i → 音节）＋ 词表。按社区逆向布局写出，
// 音节来自本测试自造的拼音集合，不含任何搜狗数据。
// 拼音表区域固定填充到 0x2628−0x1540（解析器按固定偏移读词表）。
std::string make_scel(const std::vector<std::string> &syllables,
                      const std::vector<std::vector<size_t>> &pyIndexGroups,
                      const std::vector<std::vector<std::string>> &words) {
    std::string header(0x1540, '\0');
    put32_of(header, 0, 0x54504741u);
    put32_of(header, 0x1240, static_cast<uint32_t>(words.size()));
    auto utf16 = [&](const std::string &utf8) {
        std::string out;
        // 测试音节都是 ASCII；UTF-16LE 直接逐字节。
        for (char c : utf8) {
            out.push_back(c);
            out.push_back('\0');
        }
        return out;
    };
    std::string table;
    put16_of(table, static_cast<uint16_t>(syllables.size()));
    for (size_t i = 0; i < syllables.size(); ++i) {
        const std::string py = utf16(syllables[i]);
        put16_of(table, static_cast<uint16_t>(py.size()));
        table += py;
        put16_of(table, static_cast<uint16_t>(i + 1));
        table.append(2, '\0');  // 索引为 uint16 ＋ 2 字节保留
    }
    table.resize(0x2628 - 0x1540, '\0');
    std::string body;
    for (size_t g = 0; g < pyIndexGroups.size(); ++g) {
        put16_of(body, static_cast<uint16_t>(words[g].size()));
        std::string idx;
        for (size_t p : pyIndexGroups[g]) put16_of(idx, static_cast<uint16_t>(p + 1));
        put16_of(body, static_cast<uint16_t>(idx.size()));
        body += idx;
        for (const auto &w : words[g]) {
            const std::string enc = utf16(w);
            put16_of(body, static_cast<uint16_t>(enc.size()));
            body += enc;
            put16_of(body, 1);  // 词频（转换时统一丢弃）
        }
    }
    return header + table + body;
}

// 出厂词典（文本 → 二进制）。读音故意覆盖：单音节多读音「行」、双读音词、
// 单读音词与切分所需的单字。
const char *kFactoryText =
    "你 ni\n"
    "好 hao\n"
    "你好 ni'hao\n"
    "行 xing\n"
    "行 hang\n"
    "银行 yin'hang\n"
    "银河 yin'he\n"
    "星 xing\n"
    "河 he\n"
    "测试 ce'shi\n"
    "中 zhong\n"
    "国 guo\n"
    "中国 zhong'guo\n"
    "网 wang\n"
    "络 luo\n";

std::string import(const std::string &dir, const std::string &factoryDict,
                   const std::string &fileName, const std::string &content,
                   char **result = nullptr, char *err = nullptr, size_t errLen = 0) {
    write_file(dir + "/in-" + fileName, content);
    const std::string inputPath = dir + "/in-" + fileName;
    const std::string dictsDir = dir + "/dicts";
    GcDictImportRequest req{};
    req.input_path = inputPath.c_str();
    req.dictionaries_dir = dictsDir.c_str();
    req.system_dict_path = factoryDict.c_str();
    req.display_name = nullptr;
    return std::to_string(gc_dict_import(&req, nullptr, nullptr, result, err, errLen));
}

Json dropped_of(const char *result) {
    return Json::parse(result, nullptr, false).value("dropped", Json::object());
}

size_t dropped_count(const char *result, const char *reason) {
    const Json d = dropped_of(result);
    const auto it = d.find(reason);
    return it == d.end() ? 0 : it->get<size_t>();
}


}  // namespace

int main() {
    const std::string dir = temp_dir();
    // 出厂词典二进制。
    write_file(dir + "/factory.text", kFactoryText);
    std::string factoryDict = dir + "/factory.dict";
    try {
        libime::PinyinDictionary d;
        d.load(0, (dir + "/factory.text").c_str(), libime::PinyinDictFormat::Text);
        d.save(0, factoryDict.c_str(), libime::PinyinDictFormat::Binary);
    } catch (const std::exception &e) {
        std::fprintf(stderr, "FATAL 测试词典生成失败：%s\n", e.what());
        return 2;
    }

    {   // ── libime 文本：正常导入；entryCount 与 contentId ──
        char *result = nullptr;
        char err[512] = {0};
        const std::string code =
            import(dir, factoryDict, "words.txt", "初雪 chu'xue\n雪 xue\n测试 ce'shi\n", &result, err, sizeof(err));
        check(code == "0", "libime-txt 导入", code + " " + err);
        const Json r = Json::parse(result == nullptr ? "{}" : result, nullptr, false);
        check(r.value("entryCount", size_t(0)) == 2, "libime-txt entryCount", result == nullptr ? "" : result);
        check(dropped_count(result, "duplicateFactory") == 1, "duplicateFactory 计数",
              result == nullptr ? "" : result);
        check(r.value("contentId", std::string()).size() == 16, "contentId 形状", result);
        check(r.value("id", std::string()).rfind("import-", 0) == 0, "id 形状", result);
        // 落盘文件存在。
        const std::string id = r.value("id", "");
        check(!read_file(dir + "/dicts/" + id + ".dict").empty(), "libime-txt 落盘", id);
        gc_contract_free(result);
    }

    {   // ── 重复导入同一源文件被拒绝（错误码 4） ──
        char *result = nullptr;
        char err[512] = {0};
        const std::string code =
            import(dir, factoryDict, "words.txt", "初雪 chu'xue\n雪 xue\n测试 ce'shi\n", &result, err, sizeof(err));
        check(code == "4", "重复导入拒绝", code + " " + err);
        check(std::string(err).find("同一源文件") != std::string::npos, "重复导入提示", err);
        gc_contract_free(result);
    }

    {   // ── 每个丢弃原因（libime 文本；填充行使格式探测停在 libime） ──
        char *result = nullptr;
        std::string long32;
        for (int i = 0; i < 33; ++i) long32 += "字";  // 33 个汉字
        std::string content =
            "坏音 hao'xyz\n"                    // invalidLine：非法音节
            "\"带空格 词\" hao\n"               // invalidLine：词含空白
            "我们·异 wo'men'yi\n"               // middleDot
            + long32 + " chang'chang\n"          // tooLong
            "雪 xue\n"                          // duplicateEntry：文件内重复
            "雪 xue\n"                          // duplicateEntry
            "新品 xin'pin\n";                    // 存活
        // 填充行：合法第二列，保证 ≥95% 探测阈值（格式探测按计划合同执行）。
        const char *filler[] = {"样词甲", "样词乙", "样词丙", "样词丁", "样词戊", "样词己",
                                "样词庚", "样词辛", "样词壬", "样词癸", "样词子", "样词丑",
                                "样词寅", "样词卯", "样词辰", "样词巳", "样词午", "样词未",
                                "样词申", "样词酉", "样词戌", "样词亥", "样词壹", "样词贰",
                                "样词叁", "样词肆", "样词伍", "样词陆", "样词柒", "样词捌",
                                "样词玖", "样词拾"};
        for (const char *w : filler) content += std::string(w) + " yang'ci\n";
        const std::string code = import(dir, factoryDict, "drops.txt", content, &result);
        check(code == "0", "丢弃向量导入", code);
        check(dropped_count(result, "invalidLine") == 2, "invalidLine 计数", result);
        check(dropped_count(result, "middleDot") == 1, "middleDot 计数", result);
        check(dropped_count(result, "tooLong") == 1, "tooLong 计数", result);
        check(dropped_count(result, "duplicateEntry") == 1, "duplicateEntry 计数", result);
        check(dropped_count(result, "duplicateFactory") == 0, "pinyin 格式无重复出厂", result);
        check(dropped_count(result, "nonHan") == 0, "带拼音格式不判 nonHan", result);
        gc_contract_free(result);
    }

    {   // ── 纯词表：nonHan 与 ambiguousReading；读音推断 ──
        char *result = nullptr;
        const std::string content =
            "银行\n"      // duplicateFactory（整词单读音推断后命中出厂）
            "ABC\n"       // nonHan
            "行\n"        // ambiguousReading（出厂两个读音）
            "不存在的字\n"  // ambiguousReading（无读音）
            "星河\n"      // 切分 xing'he → 存活
            "中国\n";     // duplicateFactory
        const std::string code = import(dir, factoryDict, "pure.txt", content, &result);
        check(code == "0", "纯词表导入", code);
        check(dropped_count(result, "duplicateFactory") == 2, "纯词表 duplicateFactory 计数", result);
        check(dropped_count(result, "nonHan") == 1, "nonHan 计数", result);
        check(dropped_count(result, "ambiguousReading") == 2, "ambiguousReading 计数", result);
        const Json r = Json::parse(result == nullptr ? "{}" : result, nullptr, false);
        check(r.value("entryCount", size_t(0)) == 1, "纯词表存活条数", result);
        gc_contract_free(result);
    }

    {   // ── Rime：columns 缺省（text code weight）；空格音节 → 撇号 ──
        char *result = nullptr;
        const std::string content =
            "---\n"
            "name: test\n"
            "version: \"1\"\n"
            "sort: by_weight\n"
            "...\n"
            "星河\txing he\t100\n"
            "测试\tce shi\t50\n";
        const std::string code = import(dir, factoryDict, "rime.dict.yaml", content, &result);
        check(code == "0", "Rime 缺省 columns 导入", code);
        check(dropped_count(result, "duplicateFactory") == 1, "Rime duplicateFactory 计数", result);
        check(Json::parse(result, nullptr, false).value("entryCount", size_t(0)) == 1,
              "Rime 存活条数", result);
        gc_contract_free(result);
    }

    {   // ── Rime：columns 无 code 列 → 无拼音规则 ──
        char *result = nullptr;
        const std::string content =
            "---\n"
            "name: test\n"
            "columns: [text, weight]\n"
            "...\n"
            "星河\t9\n"
            "银行\t9\n";
        const std::string code = import(dir, factoryDict, "nocode.dict.yaml", content, &result);
        check(code == "0", "Rime 无 code 列导入", code);
        check(dropped_count(result, "duplicateFactory") == 1, "无 code 列 duplicateFactory 计数", result);
        check(Json::parse(result, nullptr, false).value("entryCount", size_t(0)) == 1,
              "无 code 列存活条数", result);
        gc_contract_free(result);
    }

    {   // ── Rime：import_tables 清单文件报错 ──
        char err[512] = {0};
        const std::string content =
            "---\n"
            "name: rime_ice\n"
            "import_tables: [cn_dicts.8105]\n"
            "...\n";
        const std::string code = import(dir, factoryDict, "plan.dict.yaml", content, nullptr, err, sizeof(err));
        check(code == "2", "import_tables 报错", code);
        check(std::string(err).find("cn_dicts") != std::string::npos, "import_tables 提示", err);
    }

    {   // ── scel：合成样本导入 ──
        char *result = nullptr;
        const std::string bytes = make_scel(
            {"xin", "pin", "chu", "xue"},
            {{0, 1}, {2, 3}},
            {{"新品"}, {"初雪", "初雪"}});
        write_file(dir + "/in-sample.scel", bytes);
        const std::string samplePath = dir + "/in-sample.scel";
        const std::string dictsDir = dir + "/dicts";
        GcDictImportRequest req{};
        req.input_path = samplePath.c_str();
        req.dictionaries_dir = dictsDir.c_str();
        req.system_dict_path = factoryDict.c_str();
        req.display_name = nullptr;
        const int code = gc_dict_import(&req, nullptr, nullptr, &result, nullptr, 0);
        check(code == 0, "scel 导入", std::to_string(code));
        check(dropped_count(result, "duplicateEntry") == 1, "scel duplicateEntry 计数", result);
        check(Json::parse(result, nullptr, false).value("entryCount", size_t(0)) == 2,
              "scel 存活条数", result);
        gc_contract_free(result);
    }

    {   // ── 非法 scel：magic 不符 → 错误码 2 ──
        char err[512] = {0};
        std::string bytes(0x3000, '\0');
        write_file(dir + "/in-bad.scel", bytes);
        const std::string badPath = dir + "/in-bad.scel";
        const std::string dictsDir = dir + "/dicts";
        GcDictImportRequest req{};
        req.input_path = badPath.c_str();
        req.dictionaries_dir = dictsDir.c_str();
        req.system_dict_path = factoryDict.c_str();
        req.display_name = nullptr;
        const int code = gc_dict_import(&req, nullptr, nullptr, nullptr, err, sizeof(err));
        check(code == 2, "非法 scel 拒绝", std::to_string(code));
        check(std::string(err).find("搜狗") != std::string::npos, "非法 scel 提示", err);
    }

    {   // ── libime 二进制输入：文本化后走同一过滤管线 ──
        char *result = nullptr;
        write_file(dir + "/bin.text", "网络 wang'luo\n雪 xue\n");
        try {
            libime::PinyinDictionary d;
            d.load(0, (dir + "/bin.text").c_str(), libime::PinyinDictFormat::Text);
            d.save(0, (dir + "/in-binary.dict").c_str(), libime::PinyinDictFormat::Binary);
        } catch (const std::exception &e) {
            std::fprintf(stderr, "FATAL 二进制样本生成失败：%s\n", e.what());
            return 2;
        }
        const std::string binPath = dir + "/in-binary.dict";
        const std::string dictsDir = dir + "/dicts";
        GcDictImportRequest req{};
        req.input_path = binPath.c_str();
        req.dictionaries_dir = dictsDir.c_str();
        req.system_dict_path = factoryDict.c_str();
        req.display_name = nullptr;
        const int code = gc_dict_import(&req, nullptr, nullptr, &result, nullptr, 0);
        check(code == 0, "libime 二进制导入", std::to_string(code));
        check(Json::parse(result == nullptr ? "{}" : result, nullptr, false)
                  .value("entryCount", size_t(0)) == 2, "二进制存活条数", result);
        gc_contract_free(result);
    }

    {   // ── 错误码：1 参数错误；2 格式错误；取消 3；大小上限 ──
        char err[512] = {0};
        const std::string dictsDir = dir + "/dicts";
        GcDictImportRequest req{};
        req.input_path = nullptr;
        req.dictionaries_dir = dictsDir.c_str();
        req.system_dict_path = factoryDict.c_str();
        req.display_name = nullptr;
        check(gc_dict_import(&req, nullptr, nullptr, nullptr, err, sizeof(err)) == 1, "参数错误码 1", err);

        write_file(dir + "/in-x.bin", "MAGIC");
        const std::string xPath = dir + "/in-x.bin";
        const std::string cPath = dir + "/in-c.txt";
        req.input_path = xPath.c_str();
        check(gc_dict_import(&req, nullptr, nullptr, nullptr, err, sizeof(err)) == 2, "不支持类型码 2", err);

        // 取消：进度回调首次调用即取消。
        write_file(dir + "/in-c.txt", "新品 xin'pin\n");
        req.input_path = cPath.c_str();
        const int cancelled = gc_dict_import(
            &req, [](void *, size_t, size_t) { return 1; }, nullptr, nullptr, err, sizeof(err));
        check(cancelled == 3, "取消码 3", std::to_string(cancelled));
        // 取消不留半成品。
        size_t count = 0;
        for (const auto &e : std::filesystem::directory_iterator(dir + "/dicts")) {
            const std::string name = e.path().filename().string();
            if (name.rfind("import-", 0) == 0 && name.size() == 28 &&
                name.compare(name.size() - 5, 5, ".json") == 0) {
                ++count;
            }
        }
        // 此前各向量已导入 7 本；取消不应新增。
        check(count == 7, "取消不留半成品", std::to_string(count));

        // 大小上限：256MiB＋1（稀疏写，只写 1 字节）。
        {
            std::ofstream big(dir + "/in-big.txt", std::ios::binary);
            big.seekp(256ull * 1024 * 1024);
            big << 'x';
        }
        const std::string bigPath = dir + "/in-big.txt";
        req.input_path = bigPath.c_str();
        const int over = gc_dict_import(&req, nullptr, nullptr, nullptr, err, sizeof(err));
        check(over == 2, "大小上限码 2", std::to_string(over));
        check(std::string(err).find("上限") != std::string::npos, "大小上限提示", err);
    }

    {   // ── 空文件报错 ──
        char err[512] = {0};
        const std::string code = import(dir, factoryDict, "empty.txt", "\n\n", nullptr, err, sizeof(err));
        check(code == "2", "空文件码 2", code + " " + err);
    }

    if (failures != 0) {
        std::fprintf(stderr, "dict_import: %d 项失败\n", failures);
        return 1;
    }
    std::printf("dict_import: 全部通过\n");
    return 0;
}
