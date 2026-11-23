// 用共享向量直接测试 Windows 渠道入口。只替换 HTTP 传输，加载正常构建的核心 DLL。
#include "../windows/GogakuWindows/dictionaries.h"

#include <cstdio>
#include <fstream>
#include <stdexcept>

namespace {
std::string manifestBytes;
std::string signatureBytes;
}

std::string gw::getReleaseAsset(const std::string &url, uint64_t limit, std::atomic_bool *,
                                const std::function<void(const char *, DWORD)> &sink) {
    const std::string prefix = "https://github.com/gomeen/gogaku-dicts/releases/latest/download/";
    const std::string *bytes = nullptr;
    if (url == prefix + "catalog.json") bytes = &manifestBytes;
    if (url == prefix + "catalog.json.sig") bytes = &signatureBytes;
    if (!bytes || sink || bytes->size() > limit) throw std::runtime_error("unexpected request");
    return *bytes;
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 3) return 2;
    try {
        std::ifstream file(gw::fs::path(argv[1]), std::ios::binary);
        const auto fixture = gw::Json::parse(file);
        const auto dll = LoadLibraryW(argv[2]);
        if (!dll) throw std::runtime_error("无法加载核心 DLL");
        gw::DictCoreApis apis{};
        apis.catalog_parse = reinterpret_cast<decltype(apis.catalog_parse)>(GetProcAddress(dll, "gc_dict_catalog_parse"));
        apis.contract_free = reinterpret_cast<decltype(apis.contract_free)>(GetProcAddress(dll, "gc_contract_free"));
        if (!apis.catalog_parse || !apis.contract_free) throw std::runtime_error("缺少词库 ABI");

        const auto keyId = fixture.at("keyId");
        const auto config = gw::Json{{"owner", "gomeen"}, {"repo", "gogaku-dicts"},
                                     {"trustedKeyIds", gw::Json::array({keyId})}};
        const auto keys = gw::Json::array({{{"keyId", keyId}, {"publicKey", fixture.at("publicKey")}}});
        int failures = 0;
        for (const auto &vector : fixture.at("vectors")) {
            manifestBytes = vector.at("manifest").get<std::string>();
            signatureBytes = vector.at("signature").get<std::string>();
            std::string actual;
            try {
                const auto result = gw::fetchDictionaryCatalog(apis, config, keys, gw::Json::array());
                actual = result.at("entries").size() == 1 ? "accepted" : "unexpected result";
            } catch (const std::runtime_error &error) {
                const std::string reason = error.what();
                if (reason == "unknown_key" || reason == "invalid_signature") actual = "signature";
                else if (reason.find("kind") != std::string::npos) actual = "contract";
                else actual = reason;
            }
            const auto name = vector.at("name").get<std::string>();
            const auto expected = vector.at("result").get<std::string>();
            std::printf("%s %s %s\n", actual == expected ? "PASS" : "FAIL", name.c_str(), actual.c_str());
            failures += actual != expected;
        }
        FreeLibrary(dll);
        return failures ? 1 : 0;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 2;
    }
}
