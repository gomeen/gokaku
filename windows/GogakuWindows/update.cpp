#include "update.h"
#include "third_party/monocypher-ed25519.h"
#include <winhttp.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <regex>
#include <set>
#include <stdexcept>
#include <thread>

// Monocypher 4.0.2's OPTIONAL Ed25519 is the RFC 8032 SHA-512 algorithm.
// The core library's crypto_eddsa_check is NOT Ed25519 (it uses BLAKE2b).
// Link both third_party/monocypher.c and third_party/monocypher-ed25519.c.
namespace gw {
namespace {
using Clock = std::chrono::steady_clock;
constexpr uint64_t ManifestLimit = 256 * 1024;
constexpr uint64_t SignatureLimit = 8 * 1024;
constexpr uint64_t ListLimit = 2 * 1024 * 1024;
constexpr uint64_t ReserveBytes = 64 * 1024 * 1024;
constexpr UINT WorkCompleteMessage = WM_APP + 0x471;
constexpr UINT AutoCheckMessage = WM_APP + 0x472;
constexpr UINT ShowWindowMessage = WM_APP + 0x473;

struct UpdateError : std::runtime_error {
    DWORD http = 0;
    explicit UpdateError(const std::string &code, DWORD status = 0) : std::runtime_error(code), http(status) {}
};
void cancelled(std::atomic_bool *cancel) {
    if (cancel && cancel->load()) throw UpdateError("cancelled");
}
Json parse(const std::string &bytes, size_t limit, const char *error) {
    if (bytes.empty() || bytes.size() > limit) throw UpdateError(error);
    try {
        return Json::parse(bytes, [error](int depth, Json::parse_event_t, Json &) {
            if (depth > 32) throw UpdateError(error);
            return true;
        });
    } catch (const UpdateError &) { throw; }
    catch (...) { throw UpdateError(error); }
}
std::string stringField(const Json &object, const char *key, size_t maximum, const char *error = "invalid_manifest") {
    if (!object.is_object() || !object.contains(key) || !object[key].is_string()) throw UpdateError(error);
    const auto value = object[key].get<std::string>();
    if (value.size() > maximum || value.find('\0') != std::string::npos) throw UpdateError(error);
    return value;
}
uint64_t positive(const Json &object, const char *key, const char *error = "invalid_manifest") {
    if (!object.is_object() || !object.contains(key)) throw UpdateError(error);
    const auto &value = object[key];
    if (!value.is_number_integer() || (value.is_number_integer() && !value.is_number_unsigned()
                                       && value.get<int64_t>() <= 0)) throw UpdateError(error);
    const auto number = value.get<uint64_t>();
    if (!number || number > static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) - ReserveBytes)
        throw UpdateError(error);
    return number;
}
bool boolean(const Json &object, const char *key, const char *error = "invalid_response") {
    if (!object.is_object() || !object.contains(key) || !object[key].is_boolean()) throw UpdateError(error);
    return object[key].get<bool>();
}
std::string lower(std::string value) {
    for (char &c : value) if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 'a' - 'A');
    return value;
}
bool validVersion(const std::string &value) {
    static const std::regex pattern(R"(^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(dev|rc)\.(0|[1-9][0-9]*))?$)");
    return value.size() <= 128 && std::regex_match(value, pattern);
}
std::vector<uint64_t> dotted(const std::string &value) {
    if (value.empty() || value.size() > 128) throw UpdateError("invalid_manifest");
    std::vector<uint64_t> parts;
    uint64_t number = 0;
    bool digit = false;
    for (char c : value + ".") {
        if (c == '.') {
            if (!digit || parts.size() >= 8) throw UpdateError("invalid_manifest");
            parts.push_back(number); number = 0; digit = false;
        } else {
            if (c < '0' || c > '9' || number > (std::numeric_limits<uint64_t>::max() - 9) / 10)
                throw UpdateError("invalid_manifest");
            number = number * 10 + static_cast<unsigned>(c - '0'); digit = true;
        }
    }
    return parts;
}
bool atLeastOS(const std::string &actual, const std::string &minimum) {
    auto a = dotted(actual), b = dotted(minimum);
    const size_t count = std::max(a.size(), b.size());
    a.resize(count); b.resize(count);
    return !std::lexicographical_compare(a.begin(), a.end(), b.begin(), b.end());
}

std::string decode64(const std::string &value, size_t limit, const char *error) {
    if (value.size() > (limit * 4 / 3 + 16)) throw UpdateError(error);
    std::string compact;
    for (unsigned char c : value) {
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
              || (c >= '0' && c <= '9') || c == '+' || c == '/' || c == '=')) throw UpdateError(error);
        compact.push_back(static_cast<char>(c));
    }
    try {
        const auto bytes = base64Decode(compact);
        if (bytes.size() > limit || base64Encode(bytes) != compact) throw UpdateError(error);
        return bytes;
    } catch (...) { throw UpdateError(error); }
}

struct Source {
    std::string owner, repo;
    Json keys;
    std::string baseURL() const { return "https://api.github.com/repos/" + owner + "/" + repo; }
};
Source loadSource() {
    try {
        auto path = installRoot() / "resources" / "update" / "windows.json";
        if (!fs::exists(path)) path = installRoot() / "update" / "windows.json";
        const auto config = parse(readFile(path, 64 * 1024), 64 * 1024, "unconfigured");
        if (positive(config, "schema", "unconfigured") != 1) throw UpdateError("unconfigured");
        Source source{stringField(config, "owner", 100, "unconfigured"),
                      stringField(config, "repo", 100, "unconfigured"), Json::array()};
        const auto component = [](const std::string &s) {
            return !s.empty() && s != "." && s != ".." && s.front() != '.'
                && std::all_of(s.begin(), s.end(), [](unsigned char c) {
                    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                        || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.';
                });
        };
        if (!component(source.owner) || !component(source.repo) || !config.contains("trustedKeys")
            || !config["trustedKeys"].is_array() || config["trustedKeys"].empty()) throw UpdateError("unconfigured");
        std::set<std::string> ids;
        for (const auto &key : config["trustedKeys"]) {
            const auto id = stringField(key, "keyId", 128, "unconfigured");
            const auto publicKey = decode64(stringField(key, "publicKey", 128, "unconfigured"), 32, "unconfigured");
            if (id.empty() || publicKey.size() != 32 || !ids.insert(id).second) throw UpdateError("unconfigured");
        }
        source.keys = config["trustedKeys"];
        return source;
    } catch (...) { throw UpdateError("unconfigured"); }
}
struct Installation {
    std::string version, channel, os;
    uint64_t build;
};
Installation installation() {
    try {
        const auto identity = parse(readFile(installRoot() / "build-identity.json", 1024 * 1024),
                                    1024 * 1024, "installation_identity");
        Installation value{stringField(identity, "fullVersion", 128, "installation_identity"),
                           stringField(identity, "channel", 16, "installation_identity"), "",
                           positive(identity, "buildNumber", "installation_identity")};
        if (!validVersion(value.version) || (value.channel != "stable" && value.channel != "dev")
            || value.channel != gw::channel()) throw UpdateError("installation_identity");
        using GetVersion = LONG (WINAPI *)(OSVERSIONINFOW *);
        const auto procedure = GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion");
        GetVersion getVersion = nullptr;
        static_assert(sizeof(getVersion) == sizeof(procedure), "Windows procedure pointer size");
        std::memcpy(&getVersion, &procedure, sizeof(getVersion));
        OSVERSIONINFOW os{}; os.dwOSVersionInfoSize = sizeof(os);
        if (!getVersion || getVersion(&os) != 0) throw UpdateError("system_version");
        SYSTEM_INFO info{}; GetNativeSystemInfo(&info);
        if (info.wProcessorArchitecture != PROCESSOR_ARCHITECTURE_AMD64) throw UpdateError("unsupported");
        value.os = std::to_string(os.dwMajorVersion) + "." + std::to_string(os.dwMinorVersion) + "." + std::to_string(os.dwBuildNumber);
        return value;
    } catch (const UpdateError &) { throw; }
    catch (...) { throw UpdateError("installation_identity"); }
}

class Internet {
public:
    explicit Internet(HINTERNET value = nullptr) : value_(value) {}
    ~Internet() { close(); }
    Internet(const Internet &) = delete;
    Internet &operator=(const Internet &) = delete;
    HINTERNET get() const { return value_.load(); }
    void close() { if (const auto handle = value_.exchange(nullptr)) WinHttpCloseHandle(handle); }
private:
    std::atomic<HINTERNET> value_;
};
class Deadline {
public:
    Deadline(Internet &request, std::atomic_bool *cancel, Clock::time_point end)
        : request_(request), cancel_(cancel), end_(end), thread_([this] { watch(); }) {}
    ~Deadline() {
        { std::lock_guard<std::mutex> lock(mutex_); done_ = true; }
        wake_.notify_one(); thread_.join();
    }
    void check() const {
        cancelled(cancel_);
        if (Clock::now() >= end_) throw UpdateError("timeout");
    }
private:
    void watch() {
        std::unique_lock<std::mutex> lock(mutex_);
        while (!done_) {
            if ((cancel_ && cancel_->load()) || Clock::now() >= end_) { request_.close(); return; }
            wake_.wait_for(lock, std::chrono::milliseconds(20));
        }
    }
    Internet &request_;
    std::atomic_bool *cancel_;
    Clock::time_point end_;
    std::mutex mutex_;
    std::condition_variable wake_;
    bool done_ = false;
    std::thread thread_;
};
void networkFailure(Deadline &deadline) {
    const auto error = GetLastError();
    deadline.check();
    if (error == ERROR_WINHTTP_TIMEOUT) throw UpdateError("timeout");
    if (error == ERROR_WINHTTP_NAME_NOT_RESOLVED || error == ERROR_WINHTTP_CANNOT_CONNECT
        || error == ERROR_WINHTTP_CONNECTION_ERROR) throw UpdateError("offline");
    if (error == ERROR_WINHTTP_SECURE_FAILURE || error == ERROR_WINHTTP_SECURE_INVALID_CA
        || error == ERROR_WINHTTP_SECURE_CERT_DATE_INVALID || error == ERROR_WINHTTP_SECURE_CERT_CN_INVALID)
        throw UpdateError("tls_error");
    throw UpdateError("network_error");
}
struct URL { std::wstring host, path; std::string original; };
URL allowedURL(const std::string &value) {
    if (value.empty() || value.size() > 16384 || value.find_first_of("\r\n#") != std::string::npos
        || value.find('\0') != std::string::npos) throw UpdateError("blocked_url");
    const auto input = wide(value);
    URL_COMPONENTS parts{}; parts.dwStructSize = sizeof(parts);
    parts.dwSchemeLength = parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwExtraInfoLength = static_cast<DWORD>(-1);
    parts.dwUserNameLength = parts.dwPasswordLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(input.c_str(), static_cast<DWORD>(input.size()), 0, &parts)
        || parts.nScheme != INTERNET_SCHEME_HTTPS || parts.nPort != INTERNET_DEFAULT_HTTPS_PORT
        || parts.dwUserNameLength || parts.dwPasswordLength) throw UpdateError("blocked_url");
    const auto host = lower(utf8(std::wstring(parts.lpszHostName, parts.dwHostNameLength)));
    static const std::set<std::string> hosts{"api.github.com", "github.com", "objects.githubusercontent.com",
        "release-assets.githubusercontent.com", "github-releases.githubusercontent.com"};
    if (!hosts.count(host)) throw UpdateError("blocked_host");
    std::wstring path(parts.lpszUrlPath ? parts.lpszUrlPath : L"", parts.dwUrlPathLength);
    if (path.empty()) path = L"/";
    if (parts.dwExtraInfoLength) path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    return {wide(host), path, value};
}
std::wstring header(HINTERNET request, const wchar_t *name) {
    DWORD bytes = 0;
    WinHttpQueryHeaders(request, WINHTTP_QUERY_CUSTOM, name, nullptr, &bytes, WINHTTP_NO_HEADER_INDEX);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || bytes > 32768) return {};
    std::wstring value(bytes / sizeof(wchar_t), L'\0');
    if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_CUSTOM, name, value.data(), &bytes, WINHTTP_NO_HEADER_INDEX)) return {};
    value.resize(bytes / sizeof(wchar_t));
    while (!value.empty() && value.back() == 0) value.pop_back();
    return value;
}
struct HTTP {
    DWORD status = 0;
    std::string body, etag, remaining, reset;
    uint64_t bytes = 0;
};
bool safeETag(const std::string &etag) {
    return !etag.empty() && etag.size() <= 1024 && std::all_of(etag.begin(), etag.end(), [](unsigned char c) {
        return c >= 0x20 && c <= 0x7e;
    });
}
HTTP get(const std::string &address, uint64_t limit, std::atomic_bool *cancel,
         const std::string &etag = {}, const std::function<void(const char *, DWORD)> &sink = {}, int seconds = 20) {
    cancelled(cancel);
    auto url = allowedURL(address);
    Internet session(WinHttpOpen(L"Gogaku/1 (Windows updater)", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                 WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
    if (!session.get()) throw UpdateError("network_error");
    if (!WinHttpSetTimeouts(session.get(), 20000, 20000, 20000, 20000)) throw UpdateError("network_error");
    const auto end = Clock::now() + std::chrono::seconds(seconds);
    for (unsigned redirects = 0; redirects <= 5; ++redirects) {
        cancelled(cancel);
        if (Clock::now() >= end) throw UpdateError("timeout");
        Internet connection(WinHttpConnect(session.get(), url.host.c_str(), INTERNET_DEFAULT_HTTPS_PORT, 0));
        if (!connection.get()) throw UpdateError("network_error");
        Internet request(WinHttpOpenRequest(connection.get(), L"GET", url.path.c_str(), nullptr,
                                           WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE));
        if (!request.get()) throw UpdateError("network_error");
        DWORD noRedirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        DWORD disabled = WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
        DWORD logon = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
        if (!WinHttpSetOption(request.get(), WINHTTP_OPTION_REDIRECT_POLICY, &noRedirect, sizeof(noRedirect))
            || !WinHttpSetOption(request.get(), WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled))
            || !WinHttpSetOption(request.get(), WINHTTP_OPTION_AUTOLOGON_POLICY, &logon, sizeof(logon)))
            throw UpdateError("network_error");
        const bool api = url.host == L"api.github.com";
        std::wstring headers = api
            ? L"Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28\r\n"
            : L"Accept: application/octet-stream\r\n";
        headers += L"Cache-Control: no-cache\r\n";
        if (safeETag(etag)) headers += L"If-None-Match: " + wide(etag) + L"\r\n";
        Deadline deadline(request, cancel, end);
        if (!WinHttpSendRequest(request.get(), headers.c_str(), static_cast<DWORD>(headers.size()),
                                WINHTTP_NO_REQUEST_DATA, 0, 0, 0)
            || !WinHttpReceiveResponse(request.get(), nullptr)) networkFailure(deadline);
        deadline.check();
        HTTP result;
        DWORD statusSize = sizeof(result.status);
        if (!WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                  WINHTTP_HEADER_NAME_BY_INDEX, &result.status, &statusSize, WINHTTP_NO_HEADER_INDEX))
            networkFailure(deadline);
        if (result.status == 301 || result.status == 302 || result.status == 303
            || result.status == 307 || result.status == 308) {
            if (redirects == 5) throw UpdateError("redirect_limit");
            auto target = utf8(header(request.get(), L"Location"));
            if (target.rfind("//", 0) == 0) target = "https:" + target;
            else if (!target.empty() && target.front() == '/') target = "https://" + utf8(url.host) + target;
            else if (target.find("://") == std::string::npos) {
                auto base = utf8(url.path);
                base = base.substr(0, base.find('?'));
                target = "https://" + utf8(url.host) + base.substr(0, base.rfind('/') + 1) + target;
            }
            // Validate EVERY redirect ourselves; never hand an unchecked URL to
            // WinHTTP's default redirect policy or forward cookies/credentials.
            url = allowedURL(target);
            continue;
        }
        result.etag = utf8(header(request.get(), L"ETag"));
        result.remaining = utf8(header(request.get(), L"X-RateLimit-Remaining"));
        result.reset = utf8(header(request.get(), L"X-RateLimit-Reset"));
        if (result.status != 200) return result;
        const auto length = header(request.get(), L"Content-Length");
        if (!length.empty()) {
            uint64_t total = 0;
            for (auto c : length) {
                if (c < L'0' || c > L'9' || total > (std::numeric_limits<uint64_t>::max() - 9) / 10)
                    throw UpdateError("invalid_response");
                total = total * 10 + static_cast<unsigned>(c - L'0');
            }
            if (total > limit) throw UpdateError("response_too_large");
        }
        char buffer[64 * 1024];
        for (;;) {
            deadline.check();
            DWORD read = 0;
            if (!WinHttpReadData(request.get(), buffer, sizeof(buffer), &read)) networkFailure(deadline);
            if (!read) break;
            if (read > limit - result.bytes) throw UpdateError("response_too_large");
            result.bytes += read;
            if (sink) sink(buffer, read);
            else result.body.append(buffer, read);
        }
        deadline.check();
        return result;
    }
    throw UpdateError("redirect_limit");
}
void statusOK(const HTTP &response) {
    if ((response.status == 403 || response.status == 429) && response.remaining == "0")
        throw UpdateError("rate_limited", response.status);
    if (response.status == 429) throw UpdateError("rate_limited", response.status);
    if (response.status == 404) throw UpdateError("not_found", 404);
    if (response.status >= 500) throw UpdateError("server_error", response.status);
    if (response.status != 200) throw UpdateError("http_error", response.status);
}

Json verifyManifest(const std::string &raw, const std::string &signatureFile, const Source &source) {
    const auto manifest = parse(raw, ManifestLimit, "invalid_manifest");
    const auto id = stringField(manifest, "keyId", 128);
    std::string publicKey;
    for (const auto &key : source.keys) if (key["keyId"] == id)
        publicKey = decode64(key["publicKey"].get<std::string>(), 32, "invalid_public_key");
    if (publicKey.size() != 32) throw UpdateError("unknown_key");
    const auto signature = signatureFile.size() == 64 ? signatureFile
        : decode64(signatureFile, SignatureLimit, "invalid_signature");
    if (signature.size() != 64 || crypto_ed25519_check(
            reinterpret_cast<const uint8_t *>(signature.data()), reinterpret_cast<const uint8_t *>(publicKey.data()),
            reinterpret_cast<const uint8_t *>(raw.data()), raw.size()) != 0) throw UpdateError("invalid_signature");
    // Raw bytes above, not manifest.dump(): normalization would break the signed
    // byte contract and could conceal a publishing / transport mutation.
    if (positive(manifest, "schema") != 1) throw UpdateError("unsupported_schema");
    const auto version = stringField(manifest, "version", 128);
    if (!validVersion(version)) throw UpdateError("invalid_manifest");
    positive(manifest, "buildNumber");
    const auto channel = stringField(manifest, "channel", 16);
    if ((channel != "stable" && channel != "dev") || (channel == "stable" && version.find('-') != std::string::npos))
        throw UpdateError("invalid_manifest");
    if (id.empty()) throw UpdateError("invalid_manifest");
    stringField(manifest, "notes", 65536);
    if (!manifest.contains("assets") || !manifest["assets"].is_array() || manifest["assets"].empty())
        throw UpdateError("missing_asset");
    std::set<std::string> pairs;
    std::set<uint64_t> ids;
    for (const auto &asset : manifest["assets"]) {
        const auto platform = stringField(asset, "platform", 16);
        const auto arch = stringField(asset, "arch", 32);
        if ((platform != "macos" && platform != "windows") || arch.empty()
            || !pairs.insert(platform + "/" + arch).second) throw UpdateError("invalid_manifest");
        dotted(stringField(asset, "minOS", 128));
        if (!ids.insert(positive(asset, "assetId")).second) throw UpdateError("invalid_manifest");
        positive(asset, "size");
        const auto name = stringField(asset, "name", 255);
        if (name.empty() || name == "." || name == ".." || name.find_first_of("/\\") != std::string::npos)
            throw UpdateError("invalid_manifest");
        const auto digest = stringField(asset, "sha256", 64);
        if (digest.size() != 64 || !std::all_of(digest.begin(), digest.end(), [](char c) {
            return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        })) throw UpdateError("invalid_manifest");
    }
    // The v1 release is cross-platform; do not advertise a half-published build.
    if (!pairs.count("macos/x86_64") || !pairs.count("windows/x86_64")) throw UpdateError("missing_asset");
    return manifest;
}
Json windowsAsset(const Json &manifest, const Installation &current) {
    for (const auto &asset : manifest["assets"]) if (asset["platform"] == "windows" && asset["arch"] == "x86_64") {
        if (!atLeastOS(current.os, asset["minOS"].get<std::string>())) throw UpdateError("unsupported");
        const auto name = lower(asset["name"].get<std::string>());
        if (name.size() < 5 || name.substr(name.size() - 4) != ".exe") throw UpdateError("invalid_manifest");
        return asset;
    }
    throw UpdateError("unsupported");
}
void eligibleRelease(const Json &release, const Installation &current) {
    positive(release, "id", "invalid_response");
    if (boolean(release, "draft")) throw UpdateError("release_unavailable");
    if (boolean(release, "prerelease") && current.channel == "stable") throw UpdateError("channel_mismatch");
    stringField(release, "tag_name", 256, "invalid_response");
    if (!release.contains("assets") || !release["assets"].is_array()) throw UpdateError("invalid_response");
}
const Json *releaseAsset(const Json &release, const std::string &name) {
    const Json *found = nullptr;
    for (const auto &asset : release["assets"]) {
        if (stringField(asset, "name", 255, "invalid_response") == name) {
            if (found) throw UpdateError("invalid_manifest");
            found = &asset;
        }
    }
    return found;
}
std::string assetURL(const Json &asset) {
    const auto address = stringField(asset, "browser_download_url", 16384, "invalid_response");
    allowedURL(address);
    return address;
}
std::string smallAsset(const Json &asset, uint64_t limit, std::atomic_bool *cancel) {
    const auto expected = positive(asset, "size", "invalid_response");
    if (expected > limit) throw UpdateError("response_too_large");
    auto response = get(assetURL(asset), limit, cancel);
    statusOK(response);
    if (response.bytes != expected) throw UpdateError("size_mismatch");
    return response.body;
}
std::string bindAssets(const Json &release, const Json &manifest, const Json &selected) {
    std::set<uint64_t> ids;
    for (const auto &entry : release["assets"])
        if (!ids.insert(positive(entry, "id", "invalid_response")).second) throw UpdateError("invalid_response");
    std::string result;
    for (const auto &asset : manifest["assets"]) {
        const uint64_t id = positive(asset, "assetId");
        const Json *matched = nullptr;
        for (const auto &entry : release["assets"]) if (positive(entry, "id", "invalid_response") == id) matched = &entry;
        if (!matched || stringField(*matched, "name", 255, "invalid_response") != asset["name"].get<std::string>()
            || positive(*matched, "size", "invalid_response") != positive(asset, "size")) throw UpdateError("missing_asset");
        if (id == positive(selected, "assetId")) result = assetURL(*matched);
    }
    if (result.empty()) throw UpdateError("missing_asset");
    return result;
}

double now() {
    return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
}
std::string messageFor(const std::string &code) {
    if (code == "unconfigured") return "未配置更新源（缺少有效发布仓库或可信公钥），不能判断是否有新版本。";
    if (code == "installation_identity") return "无法读取当前安装版本与构建号，已停止检查更新。";
    if (code == "system_version" || code == "unsupported") return "该版本不支持当前 Windows 系统版本或架构。";
    if (code == "invalid_signature" || code == "unknown_key" || code == "invalid_public_key") return "更新清单签名校验失败；不会下载或启动安装包。";
    if (code == "unsupported_schema") return "不支持的更新清单版本。";
    if (code == "invalid_manifest") return "更新清单校验失败。";
    if (code == "missing_asset") return "发布资产缺失，或资产 ID、名称、大小与签名清单不一致。";
    if (code == "channel_mismatch") return "当前安装通道没有可用发布；不会自动切换通道。";
    if (code == "release_unavailable") return "此发布未公开或已不可用。";
    if (code == "rate_limited") return "GitHub 更新服务请求受限，请稍后手动重试。";
    if (code == "timeout") return "连接更新服务超时。";
    if (code == "offline") return "无法连接更新服务，请检查网络。";
    if (code == "tls_error") return "更新服务 TLS 证书校验失败。";
    if (code == "not_found") return "更新源或资产不可用（404），请检查发布仓库配置。";
    if (code == "server_error") return "更新服务暂时故障（5xx）。";
    if (code == "http_error" || code == "network_error" || code == "invalid_response") return "更新服务响应异常，请稍后重试。";
    if (code == "blocked_host" || code == "blocked_url" || code == "redirect_limit") return "更新地址或重定向不在允许的 HTTPS 主机范围内。";
    if (code == "response_too_large") return "更新响应超过允许的大小。";
    if (code == "insufficient_space") return "磁盘空间不足；尚未开始下载安装包。";
    if (code == "size_mismatch") return "安装包大小与签名清单不符。";
    if (code == "hash_mismatch") return "安装包 SHA-256 与签名清单不符。";
    if (code == "cache_path") return "更新缓存路径不安全或不属于当前用户受控缓存。";
    if (code == "not_downloaded") return "安装包尚未下载，或缓存文件已不可用。";
    if (code == "disk_error") return "无法写入或读取更新缓存，请检查磁盘空间和权限。";
    if (code == "install_failed") return "无法启动安装向导；不会自动安装或重启。";
    if (code == "cancelled") return "已取消；未完成的下载文件已清理。";
    if (code == "not_newer") return "该构建号不高于当前安装，不执行降级或重复更新。";
    if (code == "busy") return "已有更新任务正在执行。";
    if (code == "preferences_error") return "保存自动检查偏好失败，尚未启用。";
    return "更新操作失败；可以手动重试。";
}
Json outcome(const std::string &status, const std::string &message, const Json &offer = nullptr) {
    return Json{{"ok", true}, {"status", status}, {"error", nullptr}, {"message", message},
                {"offer", offer}, {"checkedAt", now()}};
}
Json failed(const UpdateError &error) {
    const std::string code = error.what();
    std::string status = "networkError";
    if (code == "unconfigured") status = "unconfigured";
    else if (code == "unsupported" || code == "system_version") status = "unsupported";
    else if (code == "invalid_manifest" || code == "invalid_signature" || code == "unknown_key"
             || code == "invalid_public_key" || code == "unsupported_schema") status = "invalidManifest";
    else if (code == "missing_asset") status = "missingAsset";
    else if (code == "rate_limited") status = "rateLimited";
    else if (code == "channel_mismatch" || code == "release_unavailable") status = "noRelease";
    else if (code == "cancelled") status = "cancelled";
    else if (code == "busy") status = "busy";
    auto result = outcome(status, messageFor(code));
    result["ok"] = false; result["error"] = code;
    if (error.http) result["httpStatus"] = error.http;
    return result;
}

Json makeOffer(const Source &source, const Json &release, const Json &manifest, const Json &asset,
               const std::string &raw, const std::string &signature, const std::string &downloadURL) {
    std::string name = stringField(release, "tag_name", 256, "invalid_response");
    if (release.contains("name") && release["name"].is_string()) name = stringField(release, "name", 1024, "invalid_response");
    return Json{{"schema", 1}, {"owner", source.owner}, {"repo", source.repo},
                {"releaseId", positive(release, "id", "invalid_response")},
                {"releaseTag", release["tag_name"]}, {"releaseName", name},
                {"manifestBytes", base64Encode(raw)}, {"signature", base64Encode(signature)},
                {"version", manifest["version"]}, {"buildNumber", manifest["buildNumber"]},
                {"notes", manifest["notes"]}, {"asset", asset}, {"downloadURL", downloadURL}};
}
struct Verified {
    Json manifest, asset;
    std::string raw, signature;
    uint64_t releaseId;
};
Verified verifyOffer(const Json &offer, const Source &source, const Installation &current) {
    if (positive(offer, "schema") != 1 || stringField(offer, "owner", 100) != source.owner
        || stringField(offer, "repo", 100) != source.repo) throw UpdateError("invalid_manifest");
    const auto raw = decode64(stringField(offer, "manifestBytes", ManifestLimit * 2), ManifestLimit, "invalid_manifest");
    const auto signature = decode64(stringField(offer, "signature", SignatureLimit * 2), SignatureLimit, "invalid_signature");
    auto manifest = verifyManifest(raw, signature, source);
    if (manifest["channel"] != current.channel) throw UpdateError("channel_mismatch");
    if (positive(manifest, "buildNumber") <= current.build) throw UpdateError("not_newer");
    return {manifest, windowsAsset(manifest, current), raw, signature, positive(offer, "releaseId")};
}

fs::path cacheRoot() { return userRoot() / "updates" / "windows" / gw::channel(); }
std::mutex checkMutex, downloadMutex, preferencesMutex;
Json cacheRead(const Source &source) {
    try {
        const auto cached = parse(readFile(cacheRoot() / "github-cache.json", 16 * 1024 * 1024),
                                  16 * 1024 * 1024, "invalid_response");
        if (cached.value("schema", 0) == 1 && cached.value("source", "") == source.baseURL()
            && cached.contains("pages") && cached["pages"].is_object()) return cached;
    } catch (...) {}
    return Json{{"schema", 1}, {"source", source.baseURL()}, {"pages", Json::object()}};
}
Json listPage(const Source &source, int page, Json &cache, std::atomic_bool *cancel) {
    const auto address = source.baseURL() + "/releases?per_page=30&page=" + std::to_string(page);
    const auto key = std::to_string(page);
    std::string etag, body;
    if (cache["pages"].contains(key)) {
        const auto &old = cache["pages"][key];
        if (old.is_object() && old.contains("body") && old["body"].is_string()
            && old["body"].get_ref<const std::string &>().size() <= ListLimit) {
            try {
                body = old["body"].get<std::string>();
                if (!parse(body, ListLimit, "invalid_response").is_array()) body.clear();
                if (!body.empty() && old.contains("etag") && old["etag"].is_string()) etag = old["etag"].get<std::string>();
            } catch (...) { body.clear(); etag.clear(); }
        }
    }
    auto response = get(address, ListLimit, cancel, etag);
    if (response.status == 304 && body.empty()) response = get(address, ListLimit, cancel);
    if (response.status != 304) {
        statusOK(response); body = response.body;
        cache["pages"][key] = Json{{"etag", safeETag(response.etag) ? response.etag : ""}, {"body", body}};
    }
    const auto releases = parse(body, ListLimit, "invalid_response");
    if (!releases.is_array() || releases.size() > 30) throw UpdateError("invalid_response");
    return releases;
}

class Handle {
public:
    explicit Handle(HANDLE value = INVALID_HANDLE_VALUE) : value_(value) {}
    ~Handle() { if (valid()) CloseHandle(value_); }
    Handle(const Handle &) = delete;
    Handle &operator=(const Handle &) = delete;
    Handle(Handle &&other) noexcept : value_(other.value_) { other.value_ = INVALID_HANDLE_VALUE; }
    Handle &operator=(Handle &&other) noexcept {
        if (this != &other) { if (valid()) CloseHandle(value_); value_ = other.value_; other.value_ = INVALID_HANDLE_VALUE; }
        return *this;
    }
    bool valid() const { return value_ != INVALID_HANDLE_VALUE && value_ != nullptr; }
    HANDLE get() const { return value_; }
private:
    HANDLE value_;
};

// Pin each directory, reject reparse points and do not share DELETE. A cache
// file supplied over IPC never chooses the filesystem location or executable
// name; both are derived from the re-verified signed hash/build/channel.
std::vector<Handle> lockDirectories(const fs::path &directory, bool create) {
    const auto full = fs::absolute(directory).lexically_normal();
    if (!full.is_absolute() || full.wstring().rfind(L"\\\\", 0) == 0) throw UpdateError("cache_path");
    if (create) {
        std::error_code error; fs::create_directories(full, error);
        if (error) throw UpdateError("disk_error");
    }
    std::vector<Handle> handles;
    auto current = full.root_path();
    for (const auto &component : full.relative_path()) {
        if (component == L".." || component == L".") throw UpdateError("cache_path");
        current /= component;
        Handle handle(CreateFileW(current.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                   nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
        BY_HANDLE_FILE_INFORMATION info{};
        if (!handle.valid() || !GetFileInformationByHandle(handle.get(), &info)
            || !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
            || (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) throw UpdateError("cache_path");
        handles.push_back(std::move(handle));
    }
    return handles;
}
fs::path finalPath(const Verified &offer) {
    return cacheRoot() / (std::to_string(positive(offer.manifest, "buildNumber")) + "-"
                           + offer.asset["sha256"].get<std::string>() + ".exe");
}
class SHA256 {
public:
    SHA256() {
        if (BCryptOpenAlgorithmProvider(&algorithm_, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
            throw UpdateError("hash_error");
        DWORD bytes = 0, length = 0;
        if (BCryptGetProperty(algorithm_, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&length),
                              sizeof(length), &bytes, 0) < 0) { close(); throw UpdateError("hash_error"); }
        object_.resize(length);
        if (BCryptCreateHash(algorithm_, &hash_, object_.data(), length, nullptr, 0, 0) < 0) {
            close(); throw UpdateError("hash_error");
        }
    }
    ~SHA256() { close(); }
    void update(const char *data, DWORD size) {
        if (BCryptHashData(hash_, reinterpret_cast<PUCHAR>(const_cast<char *>(data)), size, 0) < 0)
            throw UpdateError("hash_error");
    }
    std::string finish() {
        std::string bytes(32, '\0');
        if (BCryptFinishHash(hash_, reinterpret_cast<PUCHAR>(bytes.data()), 32, 0) < 0) throw UpdateError("hash_error");
        return hex(bytes);
    }
private:
    void close() {
        if (hash_) { BCryptDestroyHash(hash_); hash_ = nullptr; }
        if (algorithm_) { BCryptCloseAlgorithmProvider(algorithm_, 0); algorithm_ = nullptr; }
    }
    BCRYPT_ALG_HANDLE algorithm_ = nullptr;
    BCRYPT_HASH_HANDLE hash_ = nullptr;
    std::vector<UCHAR> object_;
};
void verifyFile(HANDLE file, const Json &asset, std::atomic_bool *cancel = nullptr) {
    cancelled(cancel);
    BY_HANDLE_FILE_INFORMATION info{};
    LARGE_INTEGER size{}, zero{};
    if (!GetFileInformationByHandle(file, &info) || !GetFileSizeEx(file, &size)
        || (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))
        || GetFileType(file) != FILE_TYPE_DISK) throw UpdateError("cache_path");
    if (size.QuadPart < 0 || static_cast<uint64_t>(size.QuadPart) != positive(asset, "size")) throw UpdateError("size_mismatch");
    if (!SetFilePointerEx(file, zero, nullptr, FILE_BEGIN)) throw UpdateError("disk_error");
    SHA256 hash;
    char buffer[64 * 1024];
    uint64_t total = 0;
    for (;;) {
        cancelled(cancel);
        DWORD bytes = 0;
        if (!ReadFile(file, buffer, sizeof(buffer), &bytes, nullptr)) throw UpdateError("disk_error");
        if (!bytes) break;
        total += bytes;
        if (total > positive(asset, "size")) throw UpdateError("size_mismatch");
        hash.update(buffer, bytes);
    }
    if (total != positive(asset, "size")) throw UpdateError("size_mismatch");
    if (hash.finish() != asset["sha256"].get<std::string>()) throw UpdateError("hash_mismatch");
    cancelled(cancel);
}
Handle openVerified(const fs::path &path, const Json &asset, std::atomic_bool *cancel = nullptr) {
    Handle file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr));
    if (!file.valid()) throw UpdateError("not_downloaded");
    verifyFile(file.get(), asset, cancel);
    return file;
}
struct Partial {
    fs::path path;
    ~Partial() { if (!path.empty()) DeleteFileW(path.c_str()); }
};
std::string randomSuffix() {
    std::string bytes(16, '\0');
    if (BCryptGenRandom(nullptr, reinterpret_cast<PUCHAR>(bytes.data()), static_cast<ULONG>(bytes.size()),
                         BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) throw UpdateError("disk_error");
    return hex(bytes);
}

Json preferences() {
    try {
        auto value = parse(readFile(userRoot() / "update-preferences-windows.json", 64 * 1024),
                           64 * 1024, "preferences_error");
        if (value.value("schema", 0) != 1 || !value.contains("autoCheck") || !value["autoCheck"].is_boolean())
            throw UpdateError("preferences_error");
        if (!value.contains("lastAutoCheck") || !value["lastAutoCheck"].is_object()) value["lastAutoCheck"] = Json::object();
        return value;
    } catch (...) { return Json{{"schema", 1}, {"autoCheck", false}, {"lastAutoCheck", Json::object()}}; }
}
void savePreferences(const Json &value) {
    try { atomicWrite(userRoot() / "update-preferences-windows.json", value.dump(2), true); }
    catch (...) { throw UpdateError("preferences_error"); }
}
} // namespace

Json checkUpdate(std::atomic_bool *cancel) {
    std::unique_lock<std::mutex> lock(checkMutex, std::try_to_lock);
    if (!lock.owns_lock()) return failed(UpdateError("busy"));
    try {
        cancelled(cancel);
        const auto source = loadSource(); // Unconfigured is not "up to date".
        const auto current = installation();
        const auto cacheDirectories = lockDirectories(cacheRoot(), true);
        auto cache = cacheRead(source);
        Json releases = Json::array();
        for (int page = 1; page <= 3; ++page) {
            const auto entries = listPage(source, page, cache, cancel);
            for (const auto &entry : entries) releases.push_back(entry);
            if (entries.size() < 30) break;
        }
        // ETags cache each page's list, not an outcome that could conceal a
        // changed second/third page. Signed manifest assets are verified again.
        try { atomicWrite(cacheRoot() / "github-cache.json", cache.dump(), true); } catch (...) {}
        bool sawEligible = false, sawManifest = false, sawChannel = false;
        Json bestManifest, bestRelease;
        std::string bestRaw, bestSignature;
        uint64_t bestBuild = 0;
        for (const auto &release : releases) {
            cancelled(cancel);
            if (boolean(release, "draft") || (current.channel == "stable" && boolean(release, "prerelease"))) continue;
            eligibleRelease(release, current);
            sawEligible = true;
            const auto manifestAsset = releaseAsset(release, "update-manifest.json");
            const auto signatureAsset = releaseAsset(release, "update-manifest.json.sig");
            if (!manifestAsset || !signatureAsset) continue; // Never accept an unsigned release.
            sawManifest = true;
            const auto raw = smallAsset(*manifestAsset, ManifestLimit, cancel);
            const auto signature = smallAsset(*signatureAsset, SignatureLimit, cancel);
            const auto manifest = verifyManifest(raw, signature, source);
            if (manifest["channel"] != current.channel) continue;
            sawChannel = true;
            const auto build = positive(manifest, "buildNumber");
            if (build > bestBuild) {
                bestBuild = build; bestManifest = manifest; bestRelease = release;
                bestRaw = raw; bestSignature = signature;
            }
        }
        cancelled(cancel);
        if (!sawEligible) return outcome("noRelease", "当前通道没有公开的正式 Release。");
        if (!sawManifest) return outcome("noManifest", "当前通道的发布没有完整的 update-manifest.json 与独立签名。");
        if (!sawChannel) return failed(UpdateError("channel_mismatch"));
        if (bestBuild <= current.build) return outcome("upToDate", "已是最新（" + current.version + "，构建 " + std::to_string(current.build) + "）。");
        const auto asset = windowsAsset(bestManifest, current);
        const auto downloadURL = bindAssets(bestRelease, bestManifest, asset);
        const auto offer = makeOffer(source, bestRelease, bestManifest, asset, bestRaw, bestSignature, downloadURL);
        return outcome("available", "发现新版本 " + bestManifest["version"].get<std::string>() + "（构建 " + std::to_string(bestBuild) + "）。", offer);
    } catch (const UpdateError &error) { return failed(error); }
    catch (...) { return failed(UpdateError("internal_error")); }
}

Json downloadUpdate(const Json &offer, std::atomic_bool *cancel) {
    std::unique_lock<std::mutex> lock(downloadMutex, std::try_to_lock);
    if (!lock.owns_lock()) return failed(UpdateError("busy"));
    try {
        cancelled(cancel);
        const auto source = loadSource();
        const auto current = installation();
        const auto checked = verifyOffer(offer, source, current);
        // For an existing cache, the signed bytes/hash are sufficient: permit
        // offline reuse without replacing the trust check with a network error.
        // No caller-selected URL or executable path survives this normalization.
        Json canonical{{"schema", 1}, {"owner", source.owner}, {"repo", source.repo},
            {"releaseId", checked.releaseId}, {"manifestBytes", base64Encode(checked.raw)},
            {"signature", base64Encode(checked.signature)}, {"version", checked.manifest["version"]},
            {"buildNumber", checked.manifest["buildNumber"]}, {"notes", checked.manifest["notes"]},
            {"asset", checked.asset}, {"downloadURL", ""}};
        const auto directory = cacheRoot();
        const auto directories = lockDirectories(directory, true);
        const auto final = finalPath(checked);
        bool cached = false;
        Handle verifiedFile;
        try { verifiedFile = openVerified(final, checked.asset, cancel); cached = true; }
        catch (const UpdateError &error) {
            const std::string code = error.what();
            if (code == "cancelled" || code == "cache_path") throw;
            const auto attributes = GetFileAttributesW(final.c_str());
            if (attributes != INVALID_FILE_ATTRIBUTES
                && (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT))) throw UpdateError("cache_path");
        }
        if (!cached) {
            ULARGE_INTEGER free{};
            if (!GetDiskFreeSpaceExW(directory.c_str(), &free, nullptr, nullptr)) throw UpdateError("disk_error");
            if (free.QuadPart < positive(checked.asset, "size") + ReserveBytes) throw UpdateError("insufficient_space");
            // A fresh transfer re-queries the configured repository by release
            // ID and binds every signed asset ID/name/size to that release.
            const auto releaseResponse = get(source.baseURL() + "/releases/" + std::to_string(checked.releaseId), ListLimit, cancel);
            statusOK(releaseResponse);
            const auto release = parse(releaseResponse.body, ListLimit, "invalid_response");
            eligibleRelease(release, current);
            if (positive(release, "id", "invalid_response") != checked.releaseId) throw UpdateError("invalid_response");
            const auto address = bindAssets(release, checked.manifest, checked.asset);
            canonical = makeOffer(source, release, checked.manifest, checked.asset, checked.raw, checked.signature, address);
            Partial partial{directory / (final.filename().wstring() + L".partial-" + wide(randomSuffix()))};
            {
                Handle file(CreateFileW(partial.path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                                        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr));
                if (!file.valid()) throw UpdateError("disk_error");
                const auto response = get(address, positive(checked.asset, "size"), cancel, {}, [&](const char *data, DWORD size) {
                    cancelled(cancel);
                    DWORD written = 0;
                    if (!WriteFile(file.get(), data, size, &written, nullptr) || written != size) throw UpdateError("disk_error");
                }, 300);
                statusOK(response);
                if (response.bytes != positive(checked.asset, "size")) throw UpdateError("size_mismatch");
                if (!FlushFileBuffers(file.get())) throw UpdateError("disk_error");
                verifyFile(file.get(), checked.asset, cancel);
            }
            cancelled(cancel);
            if (!MoveFileExW(partial.path.c_str(), final.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                throw UpdateError("disk_error");
            partial.path.clear();
            // Reject a substituted reparse point after the atomic move, and
            // hold this read-only handle until the result has been constructed.
            verifiedFile = openVerified(final, checked.asset, cancel);
        }
        cancelled(cancel);
        return Json{{"ok", true}, {"status", "downloaded"}, {"error", nullptr},
                    {"message", "安装包已下载，并通过大小与 SHA-256 校验。"},
                    {"offer", canonical}, {"path", utf8(final.wstring())}, {"cached", cached},
                    {"bytes", positive(checked.asset, "size")}, {"sha256", checked.asset["sha256"]}};
    } catch (const UpdateError &error) { return failed(error); }
    catch (...) { return failed(UpdateError("internal_error")); }
}

void launchUpdate(const Json &download) {
    const auto source = loadSource();
    const auto current = installation();
    if (!download.is_object() || !download.value("ok", false) || !download.contains("offer")) throw UpdateError("not_downloaded");
    const auto checked = verifyOffer(download["offer"], source, current);
    const auto expected = fs::absolute(finalPath(checked)).lexically_normal();
    const auto supplied = fs::path(wide(stringField(download, "path", 32768, "cache_path")));
    if (!supplied.is_absolute() || supplied.lexically_normal() != expected) throw UpdateError("cache_path");
    const auto directories = lockDirectories(expected.parent_path(), false);
    // This handle denies replacement/write/delete through ShellExecute's lookup.
    // No unsigned manifest, unverified cached file, arbitrary path or web page
    // can be used as an installation fallback.
    auto file = openVerified(expected, checked.asset);
    SHELLEXECUTEINFOW execute{}; execute.cbSize = sizeof(execute);
    execute.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
    execute.lpVerb = L"open";
    execute.lpFile = expected.c_str();
    execute.lpParameters = L"/NORESTART"; // Interactive Inno Setup; never /SILENT.
    execute.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&execute)) throw UpdateError("install_failed");
    if (execute.hProcess) CloseHandle(execute.hProcess);
}

namespace {
enum class Work { Check, Download, Install };
struct Job { std::atomic_bool cancel{false}; Work work; explicit Job(Work value) : work(value) {} };
struct Completion { std::shared_ptr<Job> job; Json result; };
struct UpdateUI {
    HWND controller = nullptr, window = nullptr, owner = nullptr;
    HWND status = nullptr, current = nullptr, notes = nullptr, automatic = nullptr;
    HWND check = nullptr, download = nullptr, install = nullptr, cancel = nullptr;
    HINSTANCE instance = nullptr;
    Json last = nullptr, offer = nullptr, downloaded = nullptr;
    std::shared_ptr<Job> job;
    bool autoCheck = false;
};
HWND controllerWindow = nullptr;

void setText(HWND window, const std::string &text) { if (window) SetWindowTextW(window, wide(text).c_str()); }
void refresh(UpdateUI &ui) {
    const bool busy = static_cast<bool>(ui.job);
    const bool ready = ui.downloaded.is_object() && ui.downloaded.value("ok", false);
    if (ui.check) EnableWindow(ui.check, !busy);
    if (ui.download) EnableWindow(ui.download, !busy && ui.offer.is_object());
    if (ui.install) EnableWindow(ui.install, !busy && ready);
    if (ui.cancel) EnableWindow(ui.cancel, busy && ui.job->work != Work::Install);
    if (ui.automatic) SendMessageW(ui.automatic, BM_SETCHECK, ui.autoCheck ? BST_CHECKED : BST_UNCHECKED, 0);
    if (ui.last.is_object()) setText(ui.status, ui.last.value("message", std::string()));
    if (ui.offer.is_object()) {
        setText(ui.notes, "新版 " + ui.offer.value("version", std::string()) + "，构建 "
            + std::to_string(ui.offer.value("buildNumber", uint64_t(0))) + "\r\n\r\n"
            + ui.offer.value("notes", std::string()));
    } else setText(ui.notes, "下载和安装分别由你点击触发。独立 Ed25519 清单签名不等于 Windows Authenticode；不会自动安装、重启或关闭输入应用。");
}
void begin(UpdateUI &ui, Work work) {
    if (ui.job) return;
    auto job = std::make_shared<Job>(work);
    const auto payload = work == Work::Download ? ui.offer : ui.downloaded;
    ui.job = job;
    ui.last = outcome("working", work == Work::Check ? "正在检查更新…"
        : work == Work::Download ? "正在下载安装包（最多 5 分钟，可取消）…" : "正在重新校验安装包并启动安装向导…");
    refresh(ui);
    const HWND controller = ui.controller;
    try {
        std::thread([controller, job, payload] {
            Json result;
            try {
                if (job->work == Work::Check) result = checkUpdate(&job->cancel);
                else if (job->work == Work::Download) result = downloadUpdate(payload, &job->cancel);
                else {
                    launchUpdate(payload);
                    result = outcome("launched", "已启动安装向导；按向导完成后重新打开设置，不会自动重启。 ");
                }
            } catch (const UpdateError &error) { result = failed(error); }
            catch (...) { result = failed(UpdateError("internal_error")); }
            auto completion = std::make_unique<Completion>(Completion{job, std::move(result)});
            if (PostMessageW(controller, WorkCompleteMessage, 0, reinterpret_cast<LPARAM>(completion.get()))) completion.release();
        }).detach();
    } catch (...) {
        ui.job.reset(); ui.last = failed(UpdateError("internal_error")); refresh(ui);
    }
}
void automaticCheck(UpdateUI &ui) {
    if (ui.job) return;
    try {
        loadSource(); // Missing source does not generate daily network attempts.
        std::lock_guard<std::mutex> lock(preferencesMutex);
        auto prefs = preferences();
        ui.autoCheck = prefs["autoCheck"].get<bool>();
        if (!ui.autoCheck) return;
        const auto key = gw::channel();
        const double current = now();
        double last = 0;
        if (prefs["lastAutoCheck"].contains(key) && prefs["lastAutoCheck"][key].is_number())
            last = prefs["lastAutoCheck"][key].get<double>();
        if (last != 0 && current - last < 24 * 60 * 60) return;
        // Record the ATTEMPT before starting it, including offline/failed checks.
        prefs["lastAutoCheck"][key] = current;
        savePreferences(prefs);
        begin(ui, Work::Check);
    } catch (const UpdateError &error) {
        if (std::string(error.what()) != "unconfigured") { ui.last = failed(error); refresh(ui); }
    } catch (...) {}
}
HWND control(UpdateUI &ui, const wchar_t *kind, const wchar_t *text, DWORD style, int id) {
    HWND result = CreateWindowExW(0, kind, text, WS_CHILD | WS_VISIBLE | style,
                                   0, 0, 10, 10, ui.window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)), ui.instance, nullptr);
    if (result) SendMessageW(result, WM_SETFONT, reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)), TRUE);
    return result;
}
void layout(UpdateUI &ui) {
    if (!ui.window) return;
    RECT rect{}; GetClientRect(ui.window, &rect);
    const int width = std::max(360L, rect.right), height = std::max(320L, rect.bottom);
    MoveWindow(ui.current, 20, 18, width - 40, 24, TRUE);
    MoveWindow(ui.status, 20, 52, width - 40, 64, TRUE);
    MoveWindow(ui.notes, 20, 120, width - 40, std::max(70, height - 292), TRUE);
    MoveWindow(ui.automatic, 20, height - 158, width - 40, 28, TRUE);
    const HWND detail = GetDlgItem(ui.window, 106);
    MoveWindow(detail, 20, height - 126, width - 40, 48, TRUE);
    const int buttonWidth = (width - 64) / 4;
    MoveWindow(ui.check, 20, height - 58, buttonWidth, 32, TRUE);
    MoveWindow(ui.download, 28 + buttonWidth, height - 58, buttonWidth, 32, TRUE);
    MoveWindow(ui.install, 36 + 2 * buttonWidth, height - 58, buttonWidth, 32, TRUE);
    MoveWindow(ui.cancel, 44 + 3 * buttonWidth, height - 58, buttonWidth, 32, TRUE);
}
LRESULT CALLBACK updateProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    auto ui = reinterpret_cast<UpdateUI *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        ui = static_cast<UpdateUI *>(reinterpret_cast<CREATESTRUCTW *>(lParam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(ui));
    }
    if (!ui) return DefWindowProcW(window, message, wParam, lParam);
    try {
        switch (message) {
        case WM_CREATE: {
            ui->window = window;
            ui->current = control(*ui, L"STATIC", L"检查更新", SS_LEFT, 100);
            ui->status = control(*ui, L"STATIC", L"尚未检查。自动检查默认关闭。", SS_LEFT, 101);
            ui->notes = control(*ui, L"EDIT", L"", ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL | WS_BORDER | WS_TABSTOP, 102);
            ui->automatic = control(*ui, L"BUTTON", L"自动检查更新（默认关闭）", BS_AUTOCHECKBOX | WS_TABSTOP, 103);
            control(*ui, L"STATIC", L"仅在设置应用运行期间，每 24 小时最多尝试一次；只连接 GitHub，不携带输入内容、翻译凭据或学习记录。", SS_LEFT, 106);
            ui->check = control(*ui, L"BUTTON", L"检查 / 重试", BS_PUSHBUTTON | WS_TABSTOP, 110);
            ui->download = control(*ui, L"BUTTON", L"下载 / 重试", BS_PUSHBUTTON | WS_TABSTOP, 111);
            ui->install = control(*ui, L"BUTTON", L"安装更新", BS_PUSHBUTTON | WS_TABSTOP, 112);
            ui->cancel = control(*ui, L"BUTTON", L"取消任务", BS_PUSHBUTTON | WS_TABSTOP, 113);
            try {
                const auto current = installation();
                setText(ui->current, "当前 " + current.version + "（构建 " + std::to_string(current.build) + "）· " + current.channel);
            } catch (...) { setText(ui->current, "无法读取当前安装版本身份"); }
            if (ui->last.is_null()) {
                try { loadSource(); } catch (const UpdateError &error) { ui->last = failed(error); }
            }
            layout(*ui); refresh(*ui);
            return 0;
        }
        case WM_SIZE: layout(*ui); return 0;
        case WM_GETMINMAXINFO: {
            auto info = reinterpret_cast<MINMAXINFO *>(lParam);
            info->ptMinTrackSize.x = 540; info->ptMinTrackSize.y = 460;
            return 0;
        }
        case WM_CLOSE: ShowWindow(window, SW_HIDE); return 0;
        case WM_COMMAND:
            if (HIWORD(wParam) != BN_CLICKED) break;
            switch (LOWORD(wParam)) {
            case 110: begin(*ui, Work::Check); return 0;
            case 111: if (ui->offer.is_object()) begin(*ui, Work::Download); return 0;
            case 112: if (ui->downloaded.is_object()) begin(*ui, Work::Install); return 0;
            case 113:
                if (ui->job && ui->job->work != Work::Install) {
                    ui->job->cancel = true; ui->last = outcome("cancelling", "正在取消并清理临时文件…"); refresh(*ui);
                }
                return 0;
            case 103: {
                const bool enabled = SendMessageW(ui->automatic, BM_GETCHECK, 0, 0) == BST_CHECKED;
                try {
                    std::lock_guard<std::mutex> lock(preferencesMutex);
                    auto prefs = preferences(); prefs["autoCheck"] = enabled; savePreferences(prefs);
                    ui->autoCheck = enabled;
                } catch (...) { ui->last = failed(UpdateError("preferences_error")); }
                refresh(*ui);
                if (ui->autoCheck) PostMessageW(ui->controller, AutoCheckMessage, 0, 0);
                return 0;
            }
            }
            break;
        }
    } catch (const UpdateError &error) { ui->last = failed(error); refresh(*ui); return 0; }
    catch (...) { return 0; } // Never unwind a C++ exception through User32.
    return DefWindowProcW(window, message, wParam, lParam);
}
void show(UpdateUI &ui, HWND owner) {
    if (owner) ui.owner = owner;
    if (!ui.window) {
        ui.window = CreateWindowExW(WS_EX_CONTROLPARENT, L"GogakuSignedUpdateWindow", L"Gogaku 检查更新",
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT, 660, 520,
            owner, nullptr, ui.instance, &ui);
    }
    if (ui.window) { refresh(ui); ShowWindow(ui.window, SW_SHOWNORMAL); SetForegroundWindow(ui.window); }
}
LRESULT CALLBACK controllerProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    auto ui = reinterpret_cast<UpdateUI *>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
        ui = static_cast<UpdateUI *>(reinterpret_cast<CREATESTRUCTW *>(lParam)->lpCreateParams);
        ui->controller = window;
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(ui));
    }
    if (!ui) return DefWindowProcW(window, message, wParam, lParam);
    try {
        if (message == WM_TIMER || message == AutoCheckMessage) { automaticCheck(*ui); return 0; }
        if (message == ShowWindowMessage) { show(*ui, reinterpret_cast<HWND>(wParam)); return 0; }
        if (message == WorkCompleteMessage) {
            std::unique_ptr<Completion> completion(reinterpret_cast<Completion *>(lParam));
            if (!completion || completion->job != ui->job) return 0;
            const auto work = ui->job->work;
            ui->job.reset();
            const auto &result = completion->result;
            if (work == Work::Check) {
                if (result.value("status", "") == "available") {
                    ui->offer = result["offer"]; ui->downloaded = nullptr;
                    if (ui->owner) PostMessageW(ui->owner, UpdateAvailableMessage, 1, 0);
                } else if (result.value("status", "") != "networkError" && result.value("status", "") != "rateLimited"
                           && result.value("status", "") != "cancelled") {
                    ui->offer = nullptr; ui->downloaded = nullptr;
                    if (ui->owner) PostMessageW(ui->owner, UpdateAvailableMessage, 0, 0);
                }
            } else if (work == Work::Download) {
                if (result.value("ok", false)) ui->downloaded = result;
                else ui->downloaded = nullptr;
            }
            ui->last = result; refresh(*ui);
            return 0;
        }
    } catch (...) { return 0; }
    return DefWindowProcW(window, message, wParam, lParam);
}
} // namespace

void startUpdateController(HWND owner, HINSTANCE instance) {
    // Bind notifications to the settings main window even before the separate
    // update UI is opened. Startup never shows a window or activates its owner.
    // Never call from TSF or start a background updater outside settings lifetime.
    if (!owner) return;
    if (!controllerWindow) {
        WNDCLASSW controller{}; controller.hInstance = instance;
        controller.lpfnWndProc = controllerProcedure; controller.lpszClassName = L"GogakuUpdateController";
        if (!RegisterClassW(&controller) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return;
        WNDCLASSW window{}; window.hInstance = instance; window.lpfnWndProc = updateProcedure;
        window.lpszClassName = L"GogakuSignedUpdateWindow"; window.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        window.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1);
        if (!RegisterClassW(&window) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return;
        // The controller lives exactly as long as this settings process. It has
        // no worker service, scheduled task, Run key, or cross-process timer.
        auto ui = std::make_unique<UpdateUI>(); ui->instance = instance; ui->owner = owner;
        { std::lock_guard<std::mutex> lock(preferencesMutex); ui->autoCheck = preferences().value("autoCheck", false); }
        controllerWindow = CreateWindowExW(0, controller.lpszClassName, L"", 0, 0, 0, 0, 0,
                                           HWND_MESSAGE, nullptr, instance, ui.get());
        if (!controllerWindow) return;
        ui.release(); // Message-only controller is process-lifetime, not window-lifetime.
        SetTimer(controllerWindow, 1, 60 * 60 * 1000, nullptr);
        PostMessageW(controllerWindow, AutoCheckMessage, 0, 0);
    }
}

void showUpdateWindow(HWND owner, HINSTANCE instance) {
    startUpdateController(owner, instance);
    if (owner && controllerWindow) PostMessageW(controllerWindow, ShowWindowMessage, reinterpret_cast<WPARAM>(owner), 0);
}
} // namespace gw
