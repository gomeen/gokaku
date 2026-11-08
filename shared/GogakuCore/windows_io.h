// Windows 用户数据 I/O；不进入公共 C ABI，也不改变 POSIX 持久化路径。
#pragma once

#ifdef _WIN32

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <bcrypt.h>

#include <algorithm>
#include <climits>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

namespace gogaku::windows_io {

// 不依赖系统 ANSI code page；拒绝截断、过长、内嵌 NUL 与非法 UTF-8。
inline bool utf8_path(const std::string &path, std::wstring &wide) {
    wide.clear();
    if (path.empty() || path.size() > INT_MAX || path.find('\0') != std::string::npos) return false;
    const int size = static_cast<int>(path.size());
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(), size, nullptr, 0);
    if (count == 0) return false;
    wide.resize(static_cast<size_t>(count));
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.data(), size, wide.data(), count) != count) {
        wide.clear();
        return false;
    }
    return true;
}

inline std::filesystem::path file_path(const std::string &path) {
    std::wstring wide;
    if (!utf8_path(path, wide)) throw std::invalid_argument("Invalid UTF-8 file path");
    return std::filesystem::path(wide);
}

class Handle {
public:
    explicit Handle(HANDLE value = INVALID_HANDLE_VALUE) : value(value) {}
    ~Handle() { close(); }
    Handle(const Handle &) = delete;
    Handle &operator=(const Handle &) = delete;

    bool close() {
        if (value == INVALID_HANDLE_VALUE || value == nullptr) return true;
        const HANDLE old = value;
        value = INVALID_HANDLE_VALUE;
        return CloseHandle(old) != FALSE;
    }

    HANDLE value;
};

// CREATE_NEW 时即附上当前有效用户的唯一显式 ACE；不继承父目录的宽松 ACL。
// TSF 可能在模拟用户的线程上调用，优先线程令牌，仅在无令牌时退回进程令牌。
class PrivateFileSecurity {
public:
    bool initialize() {
        HANDLE token = nullptr;
        if (!OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &token)) {
            if (GetLastError() != ERROR_NO_TOKEN ||
                !OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
        }
        Handle tokenHandle(token);
        DWORD size = 0;
        if (GetTokenInformation(token, TokenUser, nullptr, 0, &size) ||
            GetLastError() != ERROR_INSUFFICIENT_BUFFER || size == 0) return false;
        user_.resize(size);
        if (!GetTokenInformation(token, TokenUser, user_.data(), size, &size)) return false;
        const auto *user = reinterpret_cast<const TOKEN_USER *>(user_.data());
        if (!IsValidSid(user->User.Sid)) return false;
        const DWORD aclSize = sizeof(ACL) + sizeof(ACCESS_ALLOWED_ACE) - sizeof(DWORD) + GetLengthSid(user->User.Sid);
        acl_.resize(aclSize);
        auto *acl = reinterpret_cast<ACL *>(acl_.data());
        return InitializeAcl(acl, aclSize, ACL_REVISION) &&
               AddAccessAllowedAceEx(acl, ACL_REVISION, 0, FILE_ALL_ACCESS, user->User.Sid) &&
               InitializeSecurityDescriptor(&descriptor_, SECURITY_DESCRIPTOR_REVISION) &&
               SetSecurityDescriptorOwner(&descriptor_, user->User.Sid, FALSE) &&
               SetSecurityDescriptorDacl(&descriptor_, TRUE, acl, FALSE) &&
               SetSecurityDescriptorControl(&descriptor_, SE_DACL_PROTECTED, SE_DACL_PROTECTED);
    }

    SECURITY_ATTRIBUTES attributes() {
        return SECURITY_ATTRIBUTES{sizeof(SECURITY_ATTRIBUTES), &descriptor_, FALSE};
    }

private:
    std::vector<unsigned char> user_, acl_;
    SECURITY_DESCRIPTOR descriptor_{};
};

inline bool replace_file(const std::wstring &source, const std::wstring &target) {
    // 同目录／同卷改名，不允许 COPY_ALLOWED 回退，不先删除旧目标。
    return MoveFileExW(source.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
}

inline bool backup_corrupt(const std::string &path) {
    std::wstring wide;
    return utf8_path(path, wide) && replace_file(wide, wide + L".corrupt");
}

struct TempFile {
    ~TempFile() {
        handle.close();
        if (created) (void)DeleteFileW(path.c_str());
    }
    std::wstring path;
    Handle handle;
    bool created = false;
};

inline bool atomic_write(const std::string &path, const std::string &data) {
    try {
        std::wstring target;
        if (!utf8_path(path, target)) return false;
        PrivateFileSecurity security;
        if (!security.initialize()) return false;
        auto attributes = security.attributes();
        TempFile temp;
        // 每次尝试 128 位系统随机数＋CREATE_NEW；绝不打开／截断同名旧临时文件。
        for (unsigned attempt = 0; attempt < 16; ++attempt) {
            unsigned char random[16];
            if (BCryptGenRandom(nullptr, random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) return false;
            temp.path = target + L".";
            for (unsigned char byte : random) {
                temp.path += L"0123456789abcdef"[byte >> 4];
                temp.path += L"0123456789abcdef"[byte & 15];
            }
            temp.path += L".tmp";
            temp.handle.value = CreateFileW(temp.path.c_str(), GENERIC_WRITE, 0, &attributes,
                                           CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (temp.handle.value != INVALID_HANDLE_VALUE) {
                temp.created = true;
                break;
            }
            const DWORD error = GetLastError();
            // 未创建成功的路径不属于我们（可能是别的进程的文件），不能清理它。
            temp.path.clear();
            if (error != ERROR_FILE_EXISTS && error != ERROR_ALREADY_EXISTS) return false;
        }
        if (temp.handle.value == INVALID_HANDLE_VALUE) return false;
        size_t offset = 0;
        while (offset < data.size()) {
            const DWORD size = static_cast<DWORD>(std::min<size_t>(data.size() - offset, MAXDWORD));
            DWORD written = 0;
            if (!WriteFile(temp.handle.value, data.data() + offset, size, &written, nullptr) ||
                written == 0 || written > size) return false;
            offset += written;
        }
        // 必须同步仍有 GENERIC_WRITE 权限的原句柄；只读重开＋_commit 不等价。
        if (!FlushFileBuffers(temp.handle.value) || !temp.handle.close()) return false;
        if (!replace_file(temp.path, target)) return false;
        temp.created = false;  // 提交成功，不再清理；失败只清理本次临时文件。
        return true;
    } catch (...) {
        return false;
    }
}

}  // namespace gogaku::windows_io

#endif  // _WIN32
