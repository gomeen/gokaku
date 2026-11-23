// 扩展词库元数据与官方清单向量：list／开关／删除／verify／加载校验／
// catalog 合同（kind、keyId、schema、防回滚、URL 前缀、字段校验）与安装保留开关。
// 合同见 docs/dictionaries.md §三／§五／§七。
#include "gogaku_core.h"

#include "../sha256.h"
#include "../../third_party/json.hpp"

#include <cstdio>
#include <cstring>
#include <sstream>
#include <filesystem>
#include <fstream>
#include <string>

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

std::string temp_dir() {
#ifdef _WIN32
    char base[MAX_PATH];
    if (GetTempPathA(MAX_PATH, base) == 0) return ".";
    static unsigned counter = 0;
    const std::string dir = std::string(base) + "gogaku-dict-catalog-" +
                            std::to_string(static_cast<unsigned>(GetCurrentProcessId())) + "-" +
                            std::to_string(++counter);
    std::filesystem::create_directories(dir);
    return dir;
#else
    char tpl[] = "/tmp/gogaku-dict-catalog-XXXXXX";
    if (mkdtemp(tpl) == nullptr) {
        std::fprintf(stderr, "FATAL 无法创建临时目录\n");
        std::exit(2);
    }
    return tpl;
#endif
}

Json parse_list(const char *json) {
    return Json::parse(json == nullptr ? "{}" : json, nullptr, false);
}

Json find_dict(const Json &list, const std::string &id) {
    for (const auto &d : list.value("dictionaries", Json::array())) {
        if (d.value("id", "") == id) return d;
    }
    return Json();
}

// 生成一个合法的 libime 二进制词库字节串。
std::string make_binary_dict(const std::string &dir, const std::string &text) {
    write_file(dir + "/mk.text", text);
    libime::PinyinDictionary d;
    d.load(0, (dir + "/mk.text").c_str(), libime::PinyinDictFormat::Text);
    std::ostringstream out;
    d.save(0, out, libime::PinyinDictFormat::Binary);
    return out.str();
}

const char *kCatalogConfig =
    "{\"trustedKeyIds\":[\"gogaku-prod-2026\"],"
    "\"downloadPrefix\":\"https://github.com/gomeen/gogaku-dicts/releases/download/\","
    "\"catalogVersion\":0}";

const char *kValidCatalog =
    "{\"kind\":\"gogaku-dictionary-catalog\",\"schemaVersion\":1,\"keyId\":\"gogaku-prod-2026\","
    "\"catalogVersion\":3,\"dictionaries\":["
    "{\"id\":\"zhwiki\",\"name\":\"维基百科词库\",\"category\":\"综合\",\"description\":\"维基百科词条\","
    "\"version\":\"0.3.1\",\"license\":\"CC BY-SA 4.0\",\"attribution\":\"维基百科贡献者\","
    "\"sourceUrl\":\"https://dumps.wikimedia.org\","
    "\"downloadUrl\":\"https://github.com/gomeen/gogaku-dicts/releases/download/catalog-3/zhwiki.dict\","
    "\"size\":1024,\"sha256\":\"abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\","
    "\"entryCount\":1734069},"
    "{\"id\":\"thuocl-it\",\"name\":\"IT 词库\",\"category\":\"领域\",\"description\":\"THUOCL IT\","
    "\"version\":\"1.0\",\"license\":\"MIT\",\"attribution\":\"THUOCL\","
    "\"sourceUrl\":\"https://github.com/thunlp/THUOCL\","
    "\"downloadUrl\":\"https://evil.example.com/thuocl.dict\","
    "\"size\":10,\"sha256\":\"zz\",\"entryCount\":-1}]}";

}  // namespace

int main() {
    const std::string dir = temp_dir();
    // 出厂词典（小；仅用于导入管线）。
    write_file(dir + "/factory.text", "你 ni\n好 hao\n你好 ni'hao\n网络 wang'luo\n");
    std::string factoryDict = dir + "/factory.dict";
    {
        libime::PinyinDictionary d;
        d.load(0, (dir + "/factory.text").c_str(), libime::PinyinDictFormat::Text);
        d.save(0, factoryDict.c_str(), libime::PinyinDictFormat::Binary);
    }
    const std::string dicts = dir + "/dicts";

    {   // ── 导入一本 → list 形状 ──
        write_file(dir + "/in.txt", "网络热词 wang'luo're'ci\n");
        const std::string inPath = dir + "/in.txt";
        GcDictImportRequest req{};
        req.input_path = inPath.c_str();
        req.dictionaries_dir = dicts.c_str();
        req.system_dict_path = factoryDict.c_str();
        req.display_name = nullptr;
        char *result = nullptr;
        char err[512] = {0};
        const int code = gc_dict_import(&req, nullptr, nullptr, &result, err, sizeof(err));
        check(code == 0, "导入", err);
        gc_contract_free(result);

        char *list = nullptr;
        check(gc_dict_list(dicts.c_str(), 1, &list) == 0, "list 成功", "");
        const Json l = parse_list(list);
        check(l.value("dictionaries", Json::array()).size() == 1, "list 条数", list);
        const Json item = l["dictionaries"][0];
        check(item.value("normal", false) == true, "list normal", list);
        check(item.value("learning", false) == true, "list learning（小词库＋flag）", list);
        check(item.value("enabled", false) == true, "list 默认启用", list);
        check(item.value("estimatedBytes", uint64_t(0)) ==
                  item.value("sizeBytes", uint64_t(0)) * 2, "list 估算内存", list);
        check(l.value("enabledEstimatedBytes", uint64_t(0)) ==
              item.value("sizeBytes", uint64_t(0)) * 2, "list 合计估算", list);
        check(l.value("warn", true) == false, "list 不提醒", list);
        gc_contract_free(list);

        // flags bit0 = 0 时 learning 一律 false。
        check(gc_dict_list(dicts.c_str(), 0, &list) == 0, "list 成功（无学习）", "");
        check(parse_list(list)["dictionaries"][0].value("learning", true) == false,
              "无 flag 时 learning=false", list);
        gc_contract_free(list);
    }

    {   // ── 开关与合计估算；200MB 提醒（伪造大 sizeBytes 元数据，不造大文件） ──
        const std::string fakeId = "fake-big";
        const Json fake{
            {"schemaVersion", 1}, {"id", fakeId}, {"name", "伪大词库"}, {"origin", "import"},
            {"sourceFormat", "plain-txt"}, {"sourceFileName", "x.txt"}, {"sourceContentId", "0"},
            {"version", ""}, {"license", ""}, {"attribution", ""}, {"sourceUrl", ""},
            {"addedAt", 2}, {"entryCount", 1}, {"dropped", Json::object()},
            {"sizeBytes", 130000000ull}, {"contentId", "0000000000000000"}, {"enabled", true}};
        write_file(dicts + "/" + fakeId + ".json", fake.dump());

        char *list = nullptr;
        check(gc_dict_list(dicts.c_str(), 1, &list) == 0, "list（含伪大词库）", "");
        const Json l = parse_list(list);
        check(l.value("warn", false) == true, "超过 200MB 提醒", list);
        check(l.value("enabledEstimatedBytes", uint64_t(0)) > 200ull * 1024 * 1024,
              "合计估算含伪大词库", list);
        // 伪大词库超学习单本阈值。
        bool learningBig = false, learningSmall = true;
        for (const auto &d : l["dictionaries"]) {
            if (d["id"] == fakeId) learningBig = d.value("learning", true);
            if (d["id"].get<std::string>().rfind("import-", 0) == 0) learningSmall = d.value("learning", false);
        }
        check(learningBig == false, "超阈值词库 learning=false", list);
        check(learningSmall == true, "小词库 learning=true", list);
        gc_contract_free(list);

        // 停用 → 合计归零（只剩伪大词库停用后为 0？另一本也停用验证开关）。
        char err[512] = {0};
        const std::string importedId = [&]() {
            std::error_code ec;
            for (const auto &e : std::filesystem::directory_iterator(dicts, ec)) {
                const std::string name = e.path().filename().string();
                if (name.rfind("import-", 0) == 0 && name.size() == 28 &&
                    name.compare(name.size() - 5, 5, ".json") == 0) {
                    return name.substr(0, 23);
                }
            }
            return std::string();
        }();
        check(!importedId.empty(), "找到导入词库 id", importedId);
        check(gc_dict_set_enabled(dicts.c_str(), importedId.c_str(), 0, err, sizeof(err)) == 0,
              "停用成功", err);
        check(gc_dict_set_enabled(dicts.c_str(), fakeId.c_str(), 0, err, sizeof(err)) == 0,
              "停用伪大词库", err);
        check(gc_dict_list(dicts.c_str(), 1, &list) == 0, "list（停用后）", "");
        check(parse_list(list).value("enabledEstimatedBytes", uint64_t(1)) == 0, "停用后合计为 0", list);
        check(parse_list(list).value("warn", true) == false, "停用后不提醒", list);
        gc_contract_free(list);
    }

    {   // ── verify：一致 / 篡改 ──
        char *json = nullptr;
        char err[512] = {0};
        // 先恢复启用再删除伪大词库，保持后续场景干净。
        (void)gc_dict_remove(dicts.c_str(), "fake-big", err, sizeof(err));
        std::error_code ec;
        std::string importedId;
        for (const auto &e : std::filesystem::directory_iterator(dicts, ec)) {
            const std::string name = e.path().filename().string();
            if (name.rfind("import-", 0) == 0 && name.size() == 28 &&
                name.compare(name.size() - 5, 5, ".json") == 0) {
                importedId = name.substr(0, 23);
            }
        }
        check(gc_dict_verify(dicts.c_str(), importedId.c_str(), &json, err, sizeof(err)) == 0,
              "verify 一致", err);
        gc_contract_free(json);
        // 篡改 .dict 一个字节。
        {
            std::string data;
            {
                std::ifstream in(dicts + "/" + importedId + ".dict", std::ios::binary);
                data.assign((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
            }
            data[10] = static_cast<char>(data[10] ^ 0xFF);
            std::ofstream out(dicts + "/" + importedId + ".dict", std::ios::binary);
            out.write(data.data(), static_cast<std::streamsize>(data.size()));
        }
        json = nullptr;
        check(gc_dict_verify(dicts.c_str(), importedId.c_str(), &json, err, sizeof(err)) == 2,
              "verify 篡改返回 2", err);
        check(json != nullptr, "verify 篡改输出 json", "");
        gc_contract_free(json);

        // gc_dict_load 同样拒绝篡改内容。
        GcDictHandle *handle = nullptr;
        check(gc_dict_load(dicts.c_str(), importedId.c_str(), &handle, err, sizeof(err)) == 2,
              "load 篡改返回 2", err);

        // 还原文件（重新导入替代词库继续测试）。
        (void)gc_dict_remove(dicts.c_str(), importedId.c_str(), err, sizeof(err));
        write_file(dir + "/in2.txt", "网络热词 wang'luo're'ci\n");
        const std::string in2Path = dir + "/in2.txt";
        GcDictImportRequest req{};
        req.input_path = in2Path.c_str();
        req.dictionaries_dir = dicts.c_str();
        req.system_dict_path = factoryDict.c_str();
        req.display_name = nullptr;
        check(gc_dict_import(&req, nullptr, nullptr, nullptr, err, sizeof(err)) == 0, "重新导入", err);
        handle = nullptr;
        importedId.clear();
        for (const auto &e : std::filesystem::directory_iterator(dicts, ec)) {
            const std::string name = e.path().filename().string();
            if (name.rfind("import-", 0) == 0 && name.size() == 28 &&
                name.compare(name.size() - 5, 5, ".json") == 0) {
                importedId = name.substr(0, 23);
            }
        }
        check(gc_dict_load(dicts.c_str(), importedId.c_str(), &handle, err, sizeof(err)) == 0,
              "load 成功", err);
        check(handle != nullptr, "load 句柄非空", "");
        gc_dict_handle_free(handle);
    }

    {   // ── 删除：先删元数据再删 .dict ──
        char err[512] = {0};
        std::error_code ec;
        std::string importedId;
        for (const auto &e : std::filesystem::directory_iterator(dicts, ec)) {
            const std::string name = e.path().filename().string();
            if (name.rfind("import-", 0) == 0 && name.size() == 28 &&
                name.compare(name.size() - 5, 5, ".json") == 0) {
                importedId = name.substr(0, 23);
            }
        }
        check(gc_dict_remove(dicts.c_str(), importedId.c_str(), err, sizeof(err)) == 0,
              "删除成功", err);
        check(!std::filesystem::exists(std::filesystem::path(dicts + "/" + importedId + ".json")) &&
                  !std::filesystem::exists(std::filesystem::path(dicts + "/" + importedId + ".dict")),
              "两个文件都已删除", importedId);
    }

    {   // ── 损坏元数据备份；孤立 .dict 忽略 ──
        write_file(dicts + "/broken.json", "{not json");
        const std::string source = dir + "/after-corruption.txt";
        write_file(source, "网络热词 wang'luo're'ci\n");
        GcDictImportRequest request{source.c_str(), dicts.c_str(), factoryDict.c_str(), nullptr};
        char *imported = nullptr;
        char error[512]{};
        if (gc_dict_import(&request, nullptr, nullptr, &imported, error, sizeof(error)) != 0) {
            std::fprintf(stderr, "FATAL 生成损坏恢复夹具失败：%s\n", error);
            return 2;
        }
        const auto id = parse_list(imported).at("id").get<std::string>();
        gc_contract_free(imported);
        std::ifstream valid(dicts + "/" + id + ".json", std::ios::binary);
        auto malformed = Json::parse(valid);
        malformed["id"] = "wrong-type";
        malformed["enabled"] = "true";
        write_file(dicts + "/wrong-type.json", malformed.dump());
        malformed["id"] = "other-id";
        malformed["enabled"] = true;
        write_file(dicts + "/wrong-id.json", malformed.dump());
        // 孤立 .dict（无元数据）。
        const std::string bin = make_binary_dict(dir, "网络 wang'luo\n");
        write_file(dicts + "/orphan.dict", bin);
        char *list = nullptr;
        check(gc_dict_list(dicts.c_str(), 1, &list) == 0, "list（损坏场景）", "");
        const Json l = parse_list(list);
        const auto entries = l.value("dictionaries", Json::array());
        check(entries.size() == 1 && entries[0]["id"] == id, "损坏与孤立文件不影响有效词库", list);
        check(l.value("corrupt", Json::array()).size() == 3, "损坏元数据报告", list);
        gc_contract_free(list);
        for (const std::string name : {"broken.json", "wrong-type.json", "wrong-id.json"}) {
            check(std::filesystem::exists(std::filesystem::path(dicts + "/" + name + ".corrupt")),
                  "损坏元数据已备份", name);
            check(!std::filesystem::exists(std::filesystem::path(dicts + "/" + name)),
                  "原损坏文件已改名", name);
        }
        check(gc_dict_list(dicts.c_str(), 1, &list) == 0, "再次读取已隔离的目录", "");
        check(parse_list(list).value("corrupt", Json::array()).size() == 3,
              "后打开设置也能看到损坏记录", list);
        gc_contract_free(list);
        (void)gc_dict_remove(dicts.c_str(), id.c_str(), nullptr, 0);
        (void)gc_dict_remove(dicts.c_str(), "orphan", nullptr, 0);  // 清理孤立文件
    }

    {   // ── 官方清单合同 ──
        char *json = nullptr;
        char err[512] = {0};
        // 有效清单：第二项 URL 越界且 sha/entryCount 非法 → rejected。
        int code = gc_dict_catalog_parse(reinterpret_cast<const uint8_t *>(kValidCatalog),
                                         strlen(kValidCatalog), kCatalogConfig, "[]", &json, err,
                                         sizeof(err));
        check(code == 0, "清单解析", err);
        const Json out = parse_list(json);
        check(out.value("dictionaries", Json::array()).size() == 1, "有效条目数", json);
        check(out.value("rejected", Json::array()).size() == 1, "越界条目被拒", json);
        check(out["rejected"][0].value("id", "") == "thuocl-it", "拒绝条目 id", json);
        check(out["dictionaries"][0].value("installed", true) == false, "未安装标记", json);
        check(out.value("catalogVersion", 0) == 3, "catalogVersion 透传", json);
        gc_contract_free(json);

        // installed 比对：旧版本 → updateAvailable。
        code = gc_dict_catalog_parse(reinterpret_cast<const uint8_t *>(kValidCatalog),
                                     strlen(kValidCatalog), kCatalogConfig,
                                     "[{\"id\":\"zhwiki\",\"version\":\"0.3.0\"}]", &json, err,
                                     sizeof(err));
        check(code == 0, "清单解析（已安装）", err);
        check(parse_list(json)["dictionaries"][0].value("updateAvailable", false) == true,
              "旧版本显示更新", json);
        gc_contract_free(json);
        // 相同版本 → 无更新。
        code = gc_dict_catalog_parse(reinterpret_cast<const uint8_t *>(kValidCatalog),
                                     strlen(kValidCatalog), kCatalogConfig,
                                     "[{\"id\":\"zhwiki\",\"version\":\"0.3.1\"}]", &json, err,
                                     sizeof(err));
        check(parse_list(json)["dictionaries"][0].value("updateAvailable", true) == false,
              "相同版本无更新", json);
        gc_contract_free(json);

        // kind 不符。
        const std::string wrongKind = R"({"kind":"gogaku-update-manifest","schemaVersion":1,"keyId":"gogaku-prod-2026","catalogVersion":1,"dictionaries":[]})";
        code = gc_dict_catalog_parse(reinterpret_cast<const uint8_t *>(wrongKind.data()),
                                     wrongKind.size(), kCatalogConfig, "[]", &json, err, sizeof(err));
        check(code == 2, "kind 不符返回 2", err);
        gc_contract_free(json);

        // keyId 不在信任列表。
        const std::string wrongKey = R"({"kind":"gogaku-dictionary-catalog","schemaVersion":1,"keyId":"other-key","catalogVersion":1,"dictionaries":[]})";
        code = gc_dict_catalog_parse(reinterpret_cast<const uint8_t *>(wrongKey.data()),
                                     wrongKey.size(), kCatalogConfig, "[]", &json, err, sizeof(err));
        check(code == 2, "未知 keyId 返回 2", err);
        gc_contract_free(json);

        // schema 不支持。
        const std::string wrongSchema = R"({"kind":"gogaku-dictionary-catalog","schemaVersion":2,"keyId":"gogaku-prod-2026","catalogVersion":1,"dictionaries":[]})";
        code = gc_dict_catalog_parse(reinterpret_cast<const uint8_t *>(wrongSchema.data()),
                                     wrongSchema.size(), kCatalogConfig, "[]", &json, err, sizeof(err));
        check(code == 2, "未知 schema 返回 2", err);
        gc_contract_free(json);

        // 版本回滚。
        const char *kOldConfig =
            "{\"trustedKeyIds\":[\"gogaku-prod-2026\"],"
            "\"downloadPrefix\":\"https://github.com/gomeen/gogaku-dicts/releases/download/\","
            "\"catalogVersion\":5}";
        code = gc_dict_catalog_parse(reinterpret_cast<const uint8_t *>(kValidCatalog),
                                     strlen(kValidCatalog), kOldConfig, "[]", &json, err, sizeof(err));
        check(code == 2, "版本回滚返回 2", err);
        gc_contract_free(json);

        // 合法 JSON 但缺 kind → 2；非法 JSON → 3。
        code = gc_dict_catalog_parse(reinterpret_cast<const uint8_t *>("{}"), 2, kCatalogConfig,
                                     "[]", &json, err, sizeof(err));
        check(code == 2, "缺字段返回 2", err);
        gc_contract_free(json);
        const std::string notJson = "not json";
        code = gc_dict_catalog_parse(reinterpret_cast<const uint8_t *>(notJson.data()),
                                     notJson.size(), kCatalogConfig, "[]", &json, err, sizeof(err));
        check(code == 3, "非法 JSON 返回 3", err);
        gc_contract_free(json);

        // 参数错误。
        check(gc_dict_catalog_parse(nullptr, 0, nullptr, "[]", &json, err, sizeof(err)) == 1,
              "清单参数错误", "");
    }

    {   // ── 安装：sha 不符 → 4；合法安装；更新保留开关 ──
        const std::string bin = make_binary_dict(dir, "网络用语 wang'luo'yong'yu\n涨知识 zhang'zhi'shi\n");
        const std::string sha = gogaku::sha256_hex(reinterpret_cast<const uint8_t *>(bin.data()), bin.size());
        write_file(dir + "/download.dict", bin);
        char err[512] = {0};

        const std::string badShaEntry = R"({"id":"wangluo","name":"网络流行语","version":"1.0","size":)" +
                                        std::to_string(bin.size()) +
                                        R"(,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","entryCount":2,"license":"CC BY-SA 4.0","attribution":"测试","sourceUrl":"","catalogVersion":3})";
        check(gc_dict_install(dicts.c_str(), (dir + "/download.dict").c_str(), badShaEntry.c_str(),
                              err, sizeof(err)) == 4, "sha 不符返回 4", err);

        const std::string entry = R"({"id":"wangluo","name":"网络流行语","version":"1.0","size":)" +
                                  std::to_string(bin.size()) +
                                  R"(,"sha256":")" + sha +
                                  R"(","entryCount":2,"license":"CC BY-SA 4.0","attribution":"测试署名","sourceUrl":"https://example.com","catalogVersion":3})";
        check(gc_dict_install(dicts.c_str(), (dir + "/download.dict").c_str(), entry.c_str(), err,
                              sizeof(err)) == 0, "安装成功", err);
        char *list = nullptr;
        check(gc_dict_list(dicts.c_str(), 1, &list) == 0, "安装后 list", "");
        const Json item = find_dict(parse_list(list), "wangluo");
        check(!item.is_null(), "官方 id", list);
        check(item.value("origin", "") == "official", "origin=official", list);
        check(item.value("enabled", false) == true, "新装默认启用", list);
        check(item.value("catalogVersion", 0) == 3, "catalogVersion 落盘", list);
        gc_contract_free(list);

        // 更新：先停用，再装新版本 → enabled 保留 false，addedAt 保留。
        check(gc_dict_set_enabled(dicts.c_str(), "wangluo", 0, err, sizeof(err)) == 0, "停用", err);
        const std::string bin2 = make_binary_dict(dir, "网络用语 wang'luo'yong'yu\n涨知识 zhang'zhi'shi\n新鲜词 xin'xian'ci\n");
        const std::string sha2 = gogaku::sha256_hex(reinterpret_cast<const uint8_t *>(bin2.data()), bin2.size());
        write_file(dir + "/download2.dict", bin2);
        const std::string entry2 = R"({"id":"wangluo","name":"网络流行语","version":"1.1","size":)" +
                                   std::to_string(bin2.size()) +
                                   R"(,"sha256":")" + sha2 +
                                   R"(","entryCount":3,"license":"CC BY-SA 4.0","attribution":"测试署名","sourceUrl":"https://example.com","catalogVersion":4})";
        check(gc_dict_install(dicts.c_str(), (dir + "/download2.dict").c_str(), entry2.c_str(), err,
                              sizeof(err)) == 0, "更新成功", err);
        check(gc_dict_list(dicts.c_str(), 1, &list) == 0, "更新后 list", "");
        const Json item2 = find_dict(parse_list(list), "wangluo");
        check(item2.value("enabled", true) == false, "更新保留停用状态", list);
        check(item2.value("version", "") == "1.1", "更新版本", list);
        gc_contract_free(list);
    }

    if (failures != 0) {
        std::fprintf(stderr, "dict_catalog: %d 项失败\n", failures);
        return 1;
    }
    std::printf("dict_catalog: 全部通过\n");
    return 0;
}
