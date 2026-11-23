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

using Clock = std::chrono::steady_clock;

void cancelled(std::atomic_bool *cancel) {
    if (cancel && cancel->load()) throw std::runtime_error("已取消");
}

std::string lower(std::string value) {
    for (char &c : value) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    return value;
}

// 与 update.cpp 同一主机白名单：只允许更新渠道的 GitHub 下载主机。
struct CatalogUrl {
    std::wstring host, path;
};
CatalogUrl catalogUrl(const std::string &value) {
    if (value.empty() || value.size() > 16384 || value.find_first_of("\r\n#") != std::string::npos
        || value.find('\0') != std::string::npos) throw std::runtime_error("blocked_url");
    const auto input = wide(value);
    URL_COMPONENTS parts{}; parts.dwStructSize = sizeof(parts);
    parts.dwSchemeLength = parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwExtraInfoLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(input.c_str(), static_cast<DWORD>(input.size()), 0, &parts)
        || parts.nScheme != INTERNET_SCHEME_HTTPS || parts.nPort != INTERNET_DEFAULT_HTTPS_PORT
        || parts.dwUserNameLength || parts.dwPasswordLength) throw std::runtime_error("blocked_url");
    const auto host = lower(utf8(std::wstring(parts.lpszHostName, parts.dwHostNameLength)));
    static const std::set<std::string> hosts{"github.com", "objects.githubusercontent.com",
        "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"};
    if (!hosts.count(host)) throw std::runtime_error("blocked_host");
    std::wstring path(parts.lpszUrlPath ? parts.lpszUrlPath : L"", parts.dwUrlPathLength);
    if (path.empty()) path = L"/";
    if (parts.dwExtraInfoLength) path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    return {std::wstring(parts.lpszHostName, parts.dwHostNameLength), path};
}

struct HttpResult {
    DWORD status = 0;
    std::string body;
};

HttpResult catalogGet(const std::string &address, uint64_t limit, std::atomic_bool *cancel,
                      const std::function<void(const char *, DWORD)> &sink = {}) {
    cancelled(cancel);
    auto url = catalogUrl(address);
    using Internet = std::unique_ptr<void, decltype(&WinHttpCloseHandle)>;
    Internet session(WinHttpOpen(L"Gogaku/1 (Windows dictionaries)", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                 WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0), &WinHttpCloseHandle);
    if (!session.get()) throw std::runtime_error("network_error");
    if (!WinHttpSetTimeouts(session.get(), 20000, 20000, 20000, 20000)) throw std::runtime_error("network_error");
    const auto end = Clock::now() + std::chrono::seconds(60);
    for (unsigned redirects = 0; redirects <= 5; ++redirects) {
        cancelled(cancel);
        if (Clock::now() >= end) throw std::runtime_error("timeout");
        Internet connection(WinHttpConnect(session.get(), url.host.c_str(), INTERNET_DEFAULT_HTTPS_PORT, 0), &WinHttpCloseHandle);
        if (!connection.get()) throw std::runtime_error("network_error");
        Internet request(WinHttpOpenRequest(connection.get(), L"GET", url.path.c_str(), nullptr,
                                            WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE), &WinHttpCloseHandle);
        if (!request.get()) throw std::runtime_error("network_error");
        DWORD noRedirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        DWORD disabled = WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
        DWORD logon = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
        if (!WinHttpSetOption(request.get(), WINHTTP_OPTION_REDIRECT_POLICY, &noRedirect, sizeof(noRedirect))
            || !WinHttpSetOption(request.get(), WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled))
            || !WinHttpSetOption(request.get(), WINHTTP_OPTION_AUTOLOGON_POLICY, &logon, sizeof(logon)))
            throw std::runtime_error("network_error");
        std::wstring headers = L"Accept: application/octet-stream\r\nCache-Control: no-cache\r\n";
        if (!WinHttpSendRequest(request.get(), headers.c_str(), static_cast<DWORD>(headers.size()),
                                WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) throw std::runtime_error("network_error");
        if (!WinHttpReceiveResponse(request.get(), nullptr)) throw std::runtime_error("network_error");
        DWORD status = 0, size = sizeof(status);
        WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX);
        if (status == 301 || status == 302 || status == 307 || status == 308) {
            wchar_t location[2048]{}; DWORD length = sizeof(location);
            if (WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_LOCATION, WINHTTP_HEADER_NAME_BY_INDEX,
                                    location, &length, WINHTTP_NO_HEADER_INDEX)) {
                const auto next = catalogUrl(utf8(std::wstring(location)));
                // 重定向只允许同一主机白名单内的地址。
                if (next.host != url.host) throw std::runtime_error("blocked_host");
                url.host = next.host; url.path = next.path;
                continue;
            }
            throw std::runtime_error("network_error");
        }
        if (status == 404) throw std::runtime_error("not_found");
        if (status != 200) throw std::runtime_error("http_error");
        HttpResult result; result.status = status;
        char buffer[65536];
        for (;;) {
            cancelled(cancel);
            DWORD read = 0;
            if (!WinHttpReadData(request.get(), buffer, sizeof(buffer), &read)) throw std::runtime_error("network_error");
            if (!read) break;
            if (read > limit - result.body.size()) throw std::runtime_error("response_too_large");
            if (sink) sink(buffer, read);
            else result.body.append(buffer, read);
        }
        return result;
    }
    throw std::runtime_error("redirect_limit");
}

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

    const auto manifest = catalogGet(base + "catalog.json", 4 * 1024 * 1024, cancel);
    const auto signature = catalogGet(base + "catalog.json.sig", 4096, cancel);

    // Ed25519（monocypher；RFC 8032 SHA-512，与 update.cpp 同一实现与密钥）。
    auto manifestObject = Json::parse(manifest.body, nullptr, false);
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
    std::string signatureBytes = signature.body;
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
            reinterpret_cast<const uint8_t *>(manifest.body.data()), manifest.body.size()) != 0)
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
    const int rc = apis.catalog_parse(reinterpret_cast<const uint8_t *>(manifest.body.data()),
                                      manifest.body.size(), configJson.dump().c_str(),
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
    std::string bytes;
    bytes.reserve(size_t(size > 0 ? size : 0));
    catalogGet(url, size > 0 ? uint64_t(size) + 1024 : 256ull * 1024 * 1024, cancel,
               [&](const char *data, DWORD read) {
                   bytes.append(data, read);
                   if (size > 0 && progress) progress(double(bytes.size()) / double(size));
               });
    if (size > 0 && static_cast<long long>(bytes.size()) != size) throw std::runtime_error("size_mismatch");

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
