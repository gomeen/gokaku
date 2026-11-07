#include "platform.h"
#include "../GogakuCore/settings_contract.h"
#include <bcrypt.h>
#include <wincrypt.h>
#include <sddl.h>
#include <shlobj.h>
#include <algorithm>
#include <fstream>
#include <memory>
#include <mutex>
#include <stdexcept>

#ifndef GOGAKU_CHANNEL
#define GOGAKU_CHANNEL "dev"
#endif
namespace gw {
namespace {
[[noreturn]] void ioError(const char *message) { throw std::runtime_error(message); }
struct Lock {
    HANDLE h = nullptr;
    explicit Lock(const wchar_t *purpose) {
        std::wstring name = L"Local\\Gogaku-" + userSid() + L"-" + purpose;
        h = CreateMutexW(nullptr, FALSE, name.c_str());
        if (!h) ioError("无法创建数据锁");
        DWORD r = WaitForSingleObject(h, 5000);
        if (r != WAIT_OBJECT_0 && r != WAIT_ABANDONED) { CloseHandle(h); h = nullptr; ioError("数据正忙，请重试"); }
    }
    ~Lock() { if (h) { ReleaseMutex(h); CloseHandle(h); } }
};
struct Security {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), nullptr, FALSE};
    Security() {
        std::wstring dacl = L"D:P(A;;FA;;;SY)(A;;FA;;;" + userSid() + L")";
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(dacl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) ioError("无法设置当前用户权限");
        attributes.lpSecurityDescriptor = descriptor;
    }
    ~Security() { LocalFree(descriptor); }
};
std::string hashBytes(const std::string &bytes, const std::string *key) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    auto fail = [&]() { if (hash) BCryptDestroyHash(hash); if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0); ioError("加密服务失败"); };
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, key ? BCRYPT_ALG_HANDLE_HMAC_FLAG : 0) < 0) fail();
    DWORD count = 0, size = 0;
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, (PUCHAR)&size, sizeof(size), &count, 0) < 0) fail();
    std::vector<unsigned char> storage(size);
    if (BCryptCreateHash(algorithm, &hash, storage.data(), size, key ? (PUCHAR)key->data() : nullptr, key ? (ULONG)key->size() : 0, 0) < 0) fail();
    if (bytes.size() > MAXDWORD || BCryptHashData(hash, (PUCHAR)bytes.data(), (ULONG)bytes.size(), 0) < 0) fail();
    std::string result(32, '\0');
    if (BCryptFinishHash(hash, (PUCHAR)result.data(), 32, 0) < 0) fail();
    BCryptDestroyHash(hash); BCryptCloseAlgorithmProvider(algorithm, 0);
    return result;
}
bool transfer(HANDLE pipe, void *buffer, DWORD length, bool write, ULONGLONG deadline) {
    auto *data = static_cast<unsigned char *>(buffer);
    while (length) {
        OVERLAPPED operation{};
        operation.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!operation.hEvent) return false;
        DWORD done = 0;
        BOOL ok = write ? WriteFile(pipe, data, length, &done, &operation) : ReadFile(pipe, data, length, &done, &operation);
        if (!ok && GetLastError() == ERROR_IO_PENDING) {
            ULONGLONG now = GetTickCount64();
            DWORD wait = now < deadline ? (DWORD)std::min<ULONGLONG>(deadline - now, MAXDWORD - 1) : 0;
            if (WaitForSingleObject(operation.hEvent, wait) != WAIT_OBJECT_0) {
                CancelIoEx(pipe, &operation);
                GetOverlappedResult(pipe, &operation, &done, TRUE); // OVERLAPPED 的生命周期必须覆盖取消完成
                CloseHandle(operation.hEvent);
                return false;
            }
            ok = GetOverlappedResult(pipe, &operation, &done, FALSE);
        }
        CloseHandle(operation.hEvent);
        if (!ok || !done) return false;
        data += done; length -= done;
    }
    return true;
}
}
std::wstring wide(const std::string &s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), (int)s.size(), nullptr, 0);
    if (!n) ioError("非法 UTF-8");
    std::wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), (int)s.size(), out.data(), n);
    return out;
}
std::string utf8(const std::wstring &s) {
    if (s.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), (int)s.size(), nullptr, 0, nullptr, nullptr);
    if (!n) ioError("非法 UTF-16");
    std::string out(n, '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), (int)s.size(), out.data(), n, nullptr, nullptr);
    return out;
}
fs::path modulePath(HMODULE module) {
    std::wstring path(32768, L'\0');
    DWORD n = GetModuleFileNameW(module, path.data(), (DWORD)path.size());
    if (!n || n >= path.size()) ioError("无法读取程序路径");
    path.resize(n); return fs::path(path);
}
fs::path installRoot(HMODULE module) { return modulePath(module).parent_path().parent_path().parent_path(); }
std::string channel() { return GOGAKU_CHANNEL; }
std::wstring userSid() {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) ioError("无法读取用户身份");
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    std::vector<unsigned char> bytes(size);
    if (!GetTokenInformation(token, TokenUser, bytes.data(), size, &size)) { CloseHandle(token); ioError("无法读取用户身份"); }
    LPWSTR value = nullptr;
    if (!ConvertSidToStringSidW(((TOKEN_USER *)bytes.data())->User.Sid, &value)) { CloseHandle(token); ioError("无法读取用户身份"); }
    std::wstring sid(value); LocalFree(value); CloseHandle(token); return sid;
}
fs::path userRoot() {
    PWSTR value = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &value))) ioError("无法读取用户数据目录");
    fs::path path = fs::path(value) / L"Gogaku"; CoTaskMemFree(value);
    fs::create_directories(path);
    Security security;
    if (!SetFileSecurityW(path.c_str(), DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, security.descriptor)) ioError("无法保护用户数据目录");
    return path;
}
std::wstring pipeName() {
    DWORD session = 0; ProcessIdToSessionId(GetCurrentProcessId(), &session);
    return L"\\\\.\\pipe\\Gogaku-" + userSid() + L"-" + std::to_wstring(session) + L"-" + wide(channel());
}
std::string readFile(const fs::path &path, size_t limit) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) ioError("无法读取文件");
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(h, &size) || size.QuadPart < 0 || (uint64_t)size.QuadPart > limit) { CloseHandle(h); ioError("文件过大或不可读取"); }
    std::string bytes((size_t)size.QuadPart, '\0');
    DWORD read = 0;
    bool ok = bytes.empty() || (ReadFile(h, bytes.data(), (DWORD)bytes.size(), &read, nullptr) && read == bytes.size());
    CloseHandle(h);
    if (!ok) ioError("文件读取不完整");
    return bytes;
}
void atomicWrite(const fs::path &path, const std::string &bytes, bool privateFile) {
    fs::create_directories(path.parent_path());
    unsigned char random[12];
    if (BCryptGenRandom(nullptr, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) ioError("无法创建安全临时文件");
    fs::path temp = path; temp += L".tmp-" + wide(hex(std::string((char *)random, sizeof(random))));
    Security security;
    HANDLE h = CreateFileW(temp.c_str(), GENERIC_WRITE, 0, privateFile ? &security.attributes : nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) ioError("无法创建临时文件");
    DWORD written = 0;
    bool ok = bytes.size() <= MAXDWORD && (bytes.empty() || (WriteFile(h, bytes.data(), (DWORD)bytes.size(), &written, nullptr) && written == bytes.size()));
    if (ok) ok = FlushFileBuffers(h) != FALSE;
    if (!CloseHandle(h)) ok = false;
    if (!ok || !MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) { DeleteFileW(temp.c_str()); ioError("保存失败，旧文件保持不变"); }
}
Json defaultSettings() {
    // 默认值来自共享契约（空对象规范化），字段语义见 settings_contract.cpp；
    // 平台只补应用身份项：按应用默认英文的出厂清单是 Windows 可执行文件名。
    char *buffer = nullptr;
    size_t length = 0;
    if (gc_settings_normalize(nullptr, 0, &buffer, &length, nullptr) != 0 || !buffer)
        ioError("共享设置契约不可用");
    std::unique_ptr<char, void (*)(void *)> holder(buffer, gc_contract_free);
    Json base = Json::parse(buffer, buffer + length);
    base["appDefaultEnglish"] = Json::array(
        {"code.exe", "obsidian.exe", "cursor.exe", "zed.exe", "windowsterminal.exe", "warp.exe"});
    return base;
}
Json readSettings() {
    auto path = userRoot() / L"settings.json";
    if (!fs::exists(path)) return defaultSettings();
    // 读侧规范化在共享核心：默认值、类型鉗制、schema 迁移与 Mac 走同一个
    // gc_settings_normalize（编译期把实现直接链进本进程，x86 TSF 同样生效）。
    const auto bytes = readFile(path);
    char *normalized = nullptr;
    size_t length = 0;
    int32_t migrated = 0;
    const int32_t code =
        gc_settings_normalize(bytes.data(), bytes.size(), &normalized, &length, &migrated);
    if (code == 2) ioError("设置文件损坏，请先恢复备份");
    if (code != 0 || !normalized) ioError("设置规范化失败，请先恢复备份");
    std::unique_ptr<char, void (*)(void *)> holder(normalized, gc_contract_free);
    Json value = Json::parse(normalized, normalized + length);
    if (!value.is_object()) ioError("设置文件损坏，请先恢复备份");
    // 契约对缺键不写 appDefaultEnglish（缺键≠用户删光），这里补出厂清单。
    if (!value.contains("appDefaultEnglish"))
        value["appDefaultEnglish"] = defaultSettings()["appDefaultEnglish"];
    return value;
}
void saveSettings(const Json &settings) {
    if (!settings.is_object() || settings.value("schemaVersion",2) != 2) ioError("不支持的设置版本");
    Lock lock(L"settings");
    atomicWrite(userRoot() / L"settings.json", settings.dump(2));
}
Json readCredentials() {
    auto path = userRoot() / L"translation" / L"volcengine-credentials.json";
    if (!fs::exists(path)) return Json::object();
    auto value = Json::parse(readFile(path,65536));
    if (!value.is_object()) ioError("凭据文件损坏");
    return value;
}
void saveCredentials(const Json &credentials) {
    if (!credentials.is_object() || credentials.value("accessKeyId",std::string()).empty() || credentials.value("secretAccessKey",std::string()).empty()) ioError("请填写完整凭据");
    Lock lock(L"credentials");
    atomicWrite(userRoot() / L"translation" / L"volcengine-credentials.json", credentials.dump());
}
void removeCredentials() {
    Lock lock(L"credentials");
    auto path = userRoot() / L"translation" / L"volcengine-credentials.json";
    if (!DeleteFileW(path.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND) ioError("移除凭据失败");
}
std::string hex(const std::string &bytes) {
    constexpr char digits[] = "0123456789abcdef";
    std::string out; out.reserve(bytes.size()*2);
    for (unsigned char c : bytes) { out += digits[c >> 4]; out += digits[c & 15]; }
    return out;
}
std::string sha256(const std::string &bytes) { return hex(hashBytes(bytes,nullptr)); }
std::string hmac256(const std::string &key, const std::string &bytes) { return hashBytes(bytes,&key); }
std::string base64Decode(const std::string &value) {
    DWORD size = 0;
    if (!CryptStringToBinaryA(value.c_str(), (DWORD)value.size(), CRYPT_STRING_BASE64 | CRYPT_STRING_STRICT, nullptr, &size, nullptr, nullptr)) ioError("非法 Base64");
    std::string out(size, '\0');
    if (!CryptStringToBinaryA(value.c_str(), (DWORD)value.size(), CRYPT_STRING_BASE64 | CRYPT_STRING_STRICT, (BYTE *)out.data(), &size, nullptr, nullptr)) ioError("非法 Base64");
    out.resize(size); return out;
}
std::string base64Encode(const std::string &value) {
    DWORD size = 0;
    if (!CryptBinaryToStringA((BYTE *)value.data(), (DWORD)value.size(), CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &size)) ioError("Base64 编码失败");
    std::string out(size, '\0');
    if (!CryptBinaryToStringA((BYTE *)value.data(), (DWORD)value.size(), CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, out.data(), &size)) ioError("Base64 编码失败");
    out.resize(size); if (!out.empty() && !out.back()) out.pop_back(); return out;
}
std::string currentMonth() { SYSTEMTIME time{}; GetSystemTime(&time); char value[8]; snprintf(value,sizeof(value),"%04u-%02u",time.wYear,time.wMonth); return value; }
Json readUsage() {
    auto path = userRoot()/L"translation"/L"usage.json";
    if (!fs::exists(path)) return {{"month",currentMonth()},{"characters",0}};
    auto value = Json::parse(readFile(path,65536));
    return value.value("month",std::string()) == currentMonth() ? value : Json{{"month",currentMonth()},{"characters",0}};
}
void addUsage(uint64_t characters) {
    Lock lock(L"usage"); auto usage = readUsage();
    usage["characters"] = usage.value("characters",uint64_t(0)) + characters;
    atomicWrite(userRoot()/L"translation"/L"usage.json",usage.dump());
}
bool readMessage(HANDLE pipe, Json &value, DWORD timeoutMs) {
    unsigned char header[4]; ULONGLONG deadline = GetTickCount64()+timeoutMs;
    if (!transfer(pipe,header,4,false,deadline)) return false;
    uint32_t length = uint32_t(header[0]) | uint32_t(header[1])<<8 | uint32_t(header[2])<<16 | uint32_t(header[3])<<24;
    if (!length || length > MaxMessageBytes) return false;
    std::string bytes(length,'\0');
    if (!transfer(pipe,bytes.data(),length,false,deadline)) return false;
    value = Json::parse(bytes,nullptr,false);
    return value.is_object();
}
bool writeMessage(HANDLE pipe, const Json &value, DWORD timeoutMs) {
    std::string bytes = value.dump();
    if (bytes.empty() || bytes.size() > MaxMessageBytes) return false;
    uint32_t length = (uint32_t)bytes.size();
    unsigned char header[4] = {(unsigned char)length,(unsigned char)(length>>8),(unsigned char)(length>>16),(unsigned char)(length>>24)};
    ULONGLONG deadline = GetTickCount64()+timeoutMs;
    return transfer(pipe,header,4,true,deadline) && transfer(pipe,bytes.data(),length,true,deadline);
}
RpcClient::~RpcClient() { close(); }
void RpcClient::close() { if (pipe_ != INVALID_HANDLE_VALUE) { CancelIoEx(pipe_,nullptr); CloseHandle(pipe_); pipe_ = INVALID_HANDLE_VALUE; } }
bool RpcClient::connect(HMODULE callerModule) {
    if (connected()) return true;
    try {
        auto name = pipeName();
        pipe_ = CreateFileW(name.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED|SECURITY_SQOS_PRESENT|SECURITY_IDENTIFICATION,nullptr);
        auto agent = installRoot(callerModule)/L"bin"/L"x64"/L"GogakuAgent.exe";
        if (!connected()) {
            static std::atomic<ULONGLONG> lastStart{0};
            auto now = GetTickCount64(); auto before = lastStart.load();
            if (now-before > 2000 && lastStart.compare_exchange_strong(before,now)) {
                std::wstring cmd = L"\""+agent.wstring()+L"\"";
                STARTUPINFOW si{sizeof(si)}; PROCESS_INFORMATION pi{};
                if (CreateProcessW(agent.c_str(),cmd.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,agent.parent_path().c_str(),&si,&pi)) { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
            }
            return false;
        }
        ULONG pid = 0;
        if (!GetNamedPipeServerProcessId(pipe_,&pid)) { close(); return false; }
        HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
        std::wstring server(32768,L'\0'); DWORD length = (DWORD)server.size();
        bool trusted = process && QueryFullProcessImageNameW(process,0,server.data(),&length);
        if (process) CloseHandle(process);
        server.resize(length);
        if (!trusted || _wcsicmp(server.c_str(),agent.c_str()) != 0) { close(); return false; }
        Json response;
        if (!call({{"op","hello"},{"abi",4}},response,200) || !response.value("ok",false)) { close(); return false; }
        return true;
    } catch (...) { close(); return false; }
}
bool RpcClient::call(const Json &request, Json &response, DWORD timeoutMs) {
    if (!connected()) return false;
    Json message = request; message["v"] = ProtocolVersion; message["id"] = ++sequence_;
    ULONGLONG start = GetTickCount64();
    if (!writeMessage(pipe_,message,timeoutMs)) { close(); return false; }
    ULONGLONG used = GetTickCount64()-start;
    if (used >= timeoutMs || !readMessage(pipe_,response,timeoutMs-(DWORD)used) || response.value("v",0u) != ProtocolVersion || response.value("id",uint64_t(0)) != sequence_) { close(); return false; }
    return true;
}
}
