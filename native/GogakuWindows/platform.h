#pragma once
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <atomic>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>
#include "third_party/json.hpp"

// Windows 平台接缝。IPC 只传限长 UTF-8 JSON，不跨位数传指针或 C++ 对象。
namespace gw {
using Json = nlohmann::json;
namespace fs = std::filesystem;
constexpr uint32_t ProtocolVersion = 1;
constexpr uint32_t MaxMessageBytes = 1024 * 1024;
std::wstring wide(const std::string &s);
std::string utf8(const std::wstring &s);
fs::path modulePath(HMODULE module = nullptr);
fs::path installRoot(HMODULE module = nullptr);
fs::path userRoot();
std::string channel();
std::wstring userSid();
std::wstring pipeName();
std::string readFile(const fs::path &path, size_t limit = 20 * 1024 * 1024);
void atomicWrite(const fs::path &path, const std::string &bytes, bool privateFile = true);
Json defaultSettings();
Json readSettings();
void saveSettings(const Json &settings);
Json readCredentials();
void saveCredentials(const Json &credentials);
void removeCredentials();
std::string sha256(const std::string &bytes);
std::string hmac256(const std::string &key, const std::string &bytes); // raw 32 bytes
std::string hex(const std::string &bytes);
std::string base64Decode(const std::string &value);
std::string base64Encode(const std::string &value);
std::string currentMonth();
void addUsage(uint64_t characters);
Json readUsage();

// 后台网络/拼写。返回可显示的稳定错误码，不向日志输出源文/凭据。
// translate: {ok,target,characters,milliseconds,error}; direction: 0=中→英，1=英→中。
Json translate(const std::string &source, int direction, std::atomic_bool *cancel = nullptr);
// spell: {available,issues:[{location,length,explanation}]}，UTF-16 范围。
Json spell(const std::string &source, const Json &ignoredWords);
// 更新配置由 resources/update/windows.json 随包提供；缺失时明确未配置。
Json checkUpdate(std::atomic_bool *cancel = nullptr);
Json downloadUpdate(const Json &offer, std::atomic_bool *cancel = nullptr);
void launchUpdate(const Json &download); // 启动前再次核对哈希、大小和受控下载路径
void showUpdateWindow(HWND owner, HINSTANCE instance);

// 主题包纯数据；主题编辑与应用分别持久化。
Json builtinThemes();
Json resolvedTheme(const Json &settings);
void validateTheme(const Json &theme);
Json importTheme(const fs::path &path);
void exportTheme(const fs::path &path, const Json &theme);
Json normalizeImage(const fs::path &path); // {imageData: canonical PNG base64}

// Windows 私有管道，读取/写入均为 4 字节 LE 长度 + JSON，含超时。
bool readMessage(HANDLE pipe, Json &value, DWORD timeoutMs);
bool writeMessage(HANDLE pipe, const Json &value, DWORD timeoutMs);
class RpcClient {
public:
    ~RpcClient();
    bool connect(HMODULE callerModule = nullptr);
    void close();
    bool call(const Json &request, Json &response, DWORD timeoutMs = 60);
    bool connected() const { return pipe_ != INVALID_HANDLE_VALUE; }
private:
    HANDLE pipe_ = INVALID_HANDLE_VALUE;
    uint64_t sequence_ = 0;
};
}
