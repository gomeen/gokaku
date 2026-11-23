// 扩展词库渠道（Windows 设置应用侧）：清单拉取、Ed25519 验签与安装编排。
// 合同见 docs/dictionaries.md §七：字段与合同校验只有共享核心一份实现
// （gc_dict_catalog_parse／gc_dict_install，由调用方从核心 DLL 动态加载后传入）；
// 这里只做 WinHTTP 传输（与 update.cpp 同主机白名单）和 monocypher Ed25519 验签。
// 网络只在用户点击「获取更多词库」时发生；请求不携带输入内容、凭据或设备标识。
#include "dictionaries.h"
#include "third_party/monocypher-ed25519.h"
#include <winhttp.h>
#include <algorithm>
#include <chrono>
#include <functional>
#include <set>
#include <stdexcept>

namespace gw {
namespace {

std::string decode64(const std::string &value, size_t limit, const char *error) {
    try {
        const auto decoded = base64Decode(value);
        if (decoded.empty() || decoded.size() > limit) throw std::runtime_error(error);
        return decoded;
    } catch (...) { throw std::runtime_error(error); }
}

}  // namespace

// 拉取并校验官方清单。catalogConfig：{owner, repo, trustedKeyIds}；
// updateKeys：检查更新配置里的 trustedKeys（公钥材料同源）；installed：本地列表。
// 返回 {ok, catalogVersion, entries, rejected} 或抛出可显示错误。
Json fetchDictionaryCatalog(const DictCoreApis &apis, const Json &catalogConfig,
                            const Json &updateKeys, const Json &installed,
                            std::atomic_bool *cancel) {
    const auto owner = catalogConfig.value("owner", std::string());
    const auto repo = catalogConfig.value("repo", std::string());
    auto trustedKeyIds = catalogConfig.value("trustedKeyIds", Json::array());
    if (owner.empty() || repo.empty() || !trustedKeyIds.is_array() || trustedKeyIds.empty())
        throw std::runtime_error("not_configured");
    const std::string base =
        "https://github.com/" + owner + "/" + repo + "/releases/latest/download/";
    // 条目 downloadUrl 必须在本仓库 releases/download/ 前缀下（合同）；
    // 清单本身从 latest/download 拉取。
    const std::string downloadPrefix =
        "https://github.com/" + owner + "/" + repo + "/releases/download/";

    const auto manifest = getReleaseAsset(base + "catalog.json", 4 * 1024 * 1024, cancel);
    const auto signature = getReleaseAsset(base + "catalog.json.sig", 4096, cancel);

    // Ed25519（monocypher；RFC 8032 SHA-512，与 update.cpp 同一实现与密钥）。
    auto manifestObject = Json::parse(manifest, nullptr, false);
    if (!manifestObject.is_object()) throw std::runtime_error("invalid_manifest");
    const auto keyId = manifestObject.value("keyId", std::string());
    bool trustedId = false;
    for (const auto &id : trustedKeyIds) if (id.is_string() && id.get<std::string>() == keyId) trustedId = true;
    if (!trustedId) throw std::runtime_error("unknown_key");
    std::string publicKey;
    if (updateKeys.is_array()) {
        for (const auto &key : updateKeys) {
            if (key.is_object() && key.value("keyId", std::string()) == keyId) {
                publicKey = decode64(key.value("publicKey", std::string()), 64, "invalid_public_key");
            }
        }
    }
    if (publicKey.size() != 32) throw std::runtime_error("unknown_key");
    std::string signatureBytes = signature;
    if (signatureBytes.size() != 64) {
        // 签名文件允许 base64 文本（含换行）。
        auto text = signatureBytes;
        text.erase(std::remove_if(text.begin(), text.end(), [](unsigned char c) {
            return c == '\r' || c == '\n' || c == ' ' || c == '\t';
        }), text.end());
        signatureBytes = decode64(text, 128, "invalid_signature");
    }
    if (signatureBytes.size() != 64 || crypto_ed25519_check(
            reinterpret_cast<const uint8_t *>(signatureBytes.data()),
            reinterpret_cast<const uint8_t *>(publicKey.data()),
            reinterpret_cast<const uint8_t *>(manifest.data()), manifest.size()) != 0)
        throw std::runtime_error("invalid_signature");

    // 防回滚本地记录：已安装官方词库元数据里的最大 catalogVersion。
    long long localVersion = 0;
    if (installed.is_array()) {
        for (const auto &entry : installed) {
            if (entry.is_object() && entry.value("origin", std::string()) == "official")
                localVersion = std::max(localVersion, entry.value("catalogVersion", 0ll));
        }
    }
    Json installedList = Json::array();
    if (installed.is_array()) {
        for (const auto &entry : installed) {
            if (entry.is_object() && entry.contains("id"))
                installedList.push_back({{"id", entry.value("id", std::string())},
                                         {"version", entry.value("version", std::string())}});
        }
    }
    // 核心：字段与合同校验（kind／schema／keyId／防回滚／URL 前缀／字段）。
    const Json configJson{{"trustedKeyIds", trustedKeyIds},
                          {"downloadPrefix", downloadPrefix},
                          {"catalogVersion", localVersion}};
    char *result = nullptr;
    char error[512]{};
    const int rc = apis.catalog_parse(reinterpret_cast<const uint8_t *>(manifest.data()),
                                      manifest.size(), configJson.dump().c_str(),
                                      installedList.dump().c_str(), &result, error, sizeof(error));
    std::unique_ptr<char, std::function<void(void *)>> holder(result, [&apis](void *p) {
        if (p) apis.contract_free(p);
    });
    if (rc != 0) {
        if (rc == 3 && error[0] == '\0') throw std::runtime_error("invalid_manifest");
        throw std::runtime_error(error[0] ? error : "invalid_manifest");
    }
    auto parsed = Json::parse(result ? result : "{}", nullptr, false);
    if (!parsed.is_object()) throw std::runtime_error("invalid_manifest");
    return Json{{"ok", true}, {"catalogVersion", parsed.value("catalogVersion", 0ll)},
                {"entries", parsed.value("dictionaries", Json::array())},
                {"rejected", parsed.value("rejected", Json::array())}};
}

// 下载并安装一个官方词库。entry：catalog 结果里的一项（含 catalogVersion 透传）。
void installDictionary(const DictCoreApis &apis, const std::string &dictionariesDir,
                       const Json &entry, long long catalogVersion, std::atomic_bool *cancel,
                       const std::function<void(double)> &progress) {
    const auto url = entry.value("downloadUrl", std::string());
    const auto size = entry.value("size", 0ll);
    if (size <= 0 || size > 256ll * 1024 * 1024) throw std::runtime_error("size_mismatch");
    std::string bytes;
    getReleaseAsset(url, static_cast<uint64_t>(size), cancel, [&](const char *data, DWORD read) {
        bytes.append(data, read);
        if (progress) progress(double(bytes.size()) / double(size));
    });
    if (cancel && cancel->load()) throw std::runtime_error("cancelled");
    if (static_cast<long long>(bytes.size()) != size) throw std::runtime_error("size_mismatch");

    // 写临时文件（核心从路径读取并做 sha256／大小校验后原子落盘）。
    const auto temp = fs::temp_directory_path() / ("gogaku-dict-download-" + std::to_string(GetCurrentProcessId())
                                                   + "-" + std::to_string(GetTickCount64()) + ".tmp");
    atomicWrite(temp.wstring(), bytes, false);
    try {
        Json entryWithVersion = entry;
        entryWithVersion["catalogVersion"] = catalogVersion;
        char error[512]{};
        const int rc = apis.install(dictionariesDir.c_str(), utf8(temp.wstring()).c_str(),
                                    entryWithVersion.dump().c_str(), error, sizeof(error));
        std::error_code ignored;
        fs::remove(temp, ignored);
        if (rc != 0) {
            if (rc == 4) throw std::runtime_error("checksum_mismatch");
            throw std::runtime_error(error[0] ? error : "install_failed");
        }
    } catch (...) {
        std::error_code ignored;
        fs::remove(temp, ignored);
        throw;
    }
}

}  // namespace gw
