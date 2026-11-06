// Unicode 用户路径、重复替换、损坏备份与失败后重试。Windows 故障注入只替换
// 本测试包含的内部 helper 的 Win32 调用；DLL 仍使用真实 API，不设产品测试开关。
#include "gogaku_core.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>

namespace fs = std::filesystem;
namespace {
int failures = 0;
void check(bool ok, const char *what) {
    if (!ok) { ++failures; std::fprintf(stderr, "FAIL: %s\n", what); }
}
std::string utf8(const fs::path &path) {
    const auto value = path.u8string();
    return {reinterpret_cast<const char *>(value.data()), value.size()};
}
std::string read(const fs::path &path) {
    std::ifstream in(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}
void write(const fs::path &path, const std::string &data) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out.write(data.data(), static_cast<std::streamsize>(data.size()));
    check(out.good(), "write fixture");
}
}

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <bcrypt.h>
#include <aclapi.h>

namespace {
enum class Fault { None, ShortWrite, ZeroWrite, Write, Flush, Close, Move, Random, Collision };
Fault fault = Fault::None;
HANDLE writing = INVALID_HANDLE_VALUE;
std::string order;
std::wstring protectedTarget;

void check_private(PSECURITY_DESCRIPTOR descriptor) {
    PACL acl = nullptr;
    BOOL present = FALSE, defaulted = FALSE;
    SECURITY_DESCRIPTOR_CONTROL control = 0;
    DWORD revision = 0;
    check(GetSecurityDescriptorControl(descriptor, &control, &revision) && (control & SE_DACL_PROTECTED),
          "DACL is protected from inheritance");
    if (!GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted) || !present || !acl) {
        check(false, "explicit non-null DACL");
        return;
    }
    check(acl->AceCount == 1, "only current user has an ACE");
    void *entry = nullptr;
    if (!GetAce(acl, 0, &entry)) { check(false, "read user ACE"); return; }
    const auto *ace = static_cast<const ACCESS_ALLOWED_ACE *>(entry);
    check(ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE && ace->Header.AceFlags == 0 &&
          ace->Mask == FILE_ALL_ACCESS, "explicit full-access user ACE");
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) { check(false, "query user"); return; }
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    std::string data(size, '\0');
    if (GetTokenInformation(token, TokenUser, data.data(), size, &size)) {
        const auto *user = reinterpret_cast<const TOKEN_USER *>(data.data());
        check(EqualSid(const_cast<DWORD *>(&ace->SidStart), user->User.Sid), "ACE belongs to current user");
    } else { check(false, "read token user"); }
    CloseHandle(token);
}
HANDLE WINAPI create_file(LPCWSTR path, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES security,
                          DWORD disposition, DWORD attributes, HANDLE templateFile) {
    check(access == GENERIC_WRITE && share == 0 && disposition == CREATE_NEW, "exclusive new write handle");
    check(security && !security->bInheritHandle, "non-inheritable private file handle");
    if (security) check_private(security->lpSecurityDescriptor);
    writing = ::CreateFileW(path, access, share, security, disposition, attributes, templateFile);
    return writing;
}
BOOL WINAPI write_file(HANDLE file, LPCVOID data, DWORD size, LPDWORD written, LPOVERLAPPED overlapped) {
    order += 'W';
    if (fault == Fault::Write) return FALSE;
    if (fault == Fault::ZeroWrite) { *written = 0; return TRUE; }
    if (fault == Fault::ShortWrite) size = std::min<DWORD>(size, 3);
    return ::WriteFile(file, data, size, written, overlapped);
}
BOOL WINAPI flush_file(HANDLE file) {
    order += 'F';
    check(file == writing && file != INVALID_HANDLE_VALUE, "flush original write handle");
    return fault == Fault::Flush ? FALSE : ::FlushFileBuffers(file);
}
BOOL WINAPI close_handle(HANDLE file) {
    const bool isWrite = file == writing;
    if (isWrite) { order += 'C'; writing = INVALID_HANDLE_VALUE; }
    const BOOL result = ::CloseHandle(file);
    // 实际关闭后注入返回失败，既验证拒绝提交，也不泄漏测试句柄。
    return isWrite && fault == Fault::Close ? FALSE : result;
}
BOOL WINAPI move_file(LPCWSTR from, LPCWSTR to, DWORD flags) {
    order += 'M';
    check(writing == INVALID_HANDLE_VALUE, "close before replace");
    check(flags == (MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH), "replace/write-through only");
    return fault == Fault::Move ? FALSE : ::MoveFileExW(from, to, flags);
}
BOOL WINAPI delete_file(LPCWSTR path) {
    check(path != protectedTarget, "never delete target before replace");
    return ::DeleteFileW(path);
}
NTSTATUS WINAPI random_bytes(BCRYPT_ALG_HANDLE algorithm, PUCHAR data, ULONG size, ULONG flags) {
    if (fault == Fault::Random) return static_cast<NTSTATUS>(0xc0000001u);
    if (fault == Fault::Collision) { std::memset(data, 0, size); return 0; }
    return ::BCryptGenRandom(algorithm, data, size, flags);
}
}
#define CreateFileW create_file
#define WriteFile write_file
#define FlushFileBuffers flush_file
#define CloseHandle close_handle
#define MoveFileExW move_file
#define DeleteFileW delete_file
#define BCryptGenRandom random_bytes
#include "../windows_io.h"
#undef CreateFileW
#undef WriteFile
#undef FlushFileBuffers
#undef CloseHandle
#undef MoveFileExW
#undef DeleteFileW
#undef BCryptGenRandom

namespace {
void test_windows_writer(const fs::path &dir) {
    namespace io = gogaku::windows_io;
    const auto path = dir / fs::path(u8"调频历史.bin");
    const auto name = utf8(path);
    protectedTarget = path.native();
    std::wstring wide;
    for (const auto &bad : {std::string(), std::string("\xc0\xaf"), std::string("\xed\xa0\x80"),
                            std::string("\xf4\x90\x80\x80"), std::string("\xe4\xb8"), std::string("a\0b", 3)}) {
        check(!io::utf8_path(bad, wide) && !io::atomic_write(bad, "bad"), "reject invalid UTF-8 path");
    }
    check(io::utf8_path(name, wide) && wide == path.native(), "Unicode path conversion");
    check(io::atomic_write(name, "old"), "first atomic write");
    const std::string payload("new\0完整内容", 16);
    fault = Fault::ShortWrite;
    order.clear();
    check(io::atomic_write(name, payload) && read(path) == payload, "loop over short writes");
    check(order.size() > 4 && order.ends_with("FCM"), "write/flush/close/move order");
    for (Fault value : {Fault::ZeroWrite, Fault::Write, Fault::Flush, Fault::Close, Fault::Move, Fault::Random}) {
        fault = value;
        check(!io::atomic_write(name, "replacement"), "injected failure is not success");
        check(read(path) == payload, "failure preserves old target");
        fault = Fault::None;
        check(io::atomic_write(name, payload), "retry after failure");
    }
    const auto collision = fs::path(path.native() + L".00000000000000000000000000000000.tmp");
    write(collision, "belongs to another writer");
    fault = Fault::Collision;
    check(!io::atomic_write(name, "replacement"), "bounded collision retry");
    check(read(path) == payload && read(collision) == "belongs to another writer", "never remove colliding temp");
    fault = Fault::None;
    fs::remove(collision);
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (GetNamedSecurityInfoW(path.c_str(), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
                              nullptr, nullptr, nullptr, nullptr, &descriptor) == ERROR_SUCCESS) {
        check_private(descriptor);
        LocalFree(descriptor);
    } else { check(false, "read final file DACL"); }
    fs::remove(path);
}
}
#endif

namespace {
void test_custom_words(const fs::path &dir) {
    const auto path = dir / fs::path(u8"自定义词语.tsv");
    const auto name = utf8(path);
    char code[] = "abc", first[] = "第一次", second[] = "第二次\n完整内容";
    GcCustomWord word{GC_WORD_SHORTCODE, 1, code, nullptr, first};
    GcCustomWordList list{&word, 1, 0};
    check(gc_custom_words_write(name.c_str(), &list) == 0, "custom first write");
    word.content = second;
    check(gc_custom_words_write(name.c_str(), &list) == 0, "custom replace existing");
    GcCustomWordList *loaded = nullptr;
    check(gc_custom_words_read(name.c_str(), &loaded) == 0 && loaded && loaded->count == 1 &&
          std::string(loaded->words[0].content) == second, "read Unicode path and escaped content");
    gc_custom_word_list_free(loaded);
#ifdef _WIN32
    const auto old = read(path);
    HANDLE locked = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    check(locked != INVALID_HANDLE_VALUE, "lock destination against replacement");
    if (locked != INVALID_HANDLE_VALUE) {
        check(gc_custom_words_write(name.c_str(), &list) == 2 && read(path) == old, "locked target is preserved");
        CloseHandle(locked);
        check(gc_custom_words_write(name.c_str(), &list) == 0, "retry unlocked target");
    }
    const std::string bad = utf8(dir) + "/\xc0\xaf.tsv";
    check(gc_custom_words_write(bad.c_str(), &list) == 2, "C ABI rejects invalid UTF-8 path");
    loaded = nullptr;
    check(gc_custom_words_read(bad.c_str(), &loaded) == 2, "read rejects invalid UTF-8 path");
    gc_custom_word_list_free(loaded);
#endif
    auto backup = path;
    backup += ".corrupt";
    write(backup, "old backup");
    for (const auto &broken : {std::string("broken one"), std::string("broken two")}) {
        write(path, broken);
        loaded = nullptr;
        check(gc_custom_words_read(name.c_str(), &loaded) == 0 && loaded && loaded->corrupt,
              "read corrupt custom file");
        check(!fs::exists(path) && read(backup) == broken, "atomically replace existing corrupt backup");
        gc_custom_word_list_free(loaded);
    }
#ifdef _WIN32
    write(path, "backup must not be lost");
    HANDLE backupLock = CreateFileW(backup.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    check(backupLock != INVALID_HANDLE_VALUE, "lock corrupt backup");
    if (backupLock != INVALID_HANDLE_VALUE) {
        loaded = nullptr;
        check(gc_custom_words_read(name.c_str(), &loaded) == 2, "backup failure is I/O failure");
        check(read(path) == "backup must not be lost" && read(backup) == "broken two", "failed backup preserves both files");
        gc_custom_word_list_free(loaded);
        CloseHandle(backupLock);
    }
#endif
    write(path, "peek only");
    loaded = nullptr;
    check(gc_custom_words_peek(name.c_str(), &loaded) == 0 && loaded && loaded->corrupt, "peek corrupt file");
    check(read(path) == "peek only" && read(backup) == "broken two", "peek does not rename");
    gc_custom_word_list_free(loaded);
    const auto directory = dir / fs::path(u8"不可替换的目录");
    fs::create_directory(directory);
    const auto directoryName = utf8(directory);
    check(gc_custom_words_write(directoryName.c_str(), &list) == 2 && fs::is_directory(directory),
          "failed replacement preserves directory target");
    loaded = nullptr;
    check(gc_custom_words_read(directoryName.c_str(), &loaded) == 2, "directory read is I/O failure");
    gc_custom_word_list_free(loaded);
    for (const auto &entry : fs::directory_iterator(dir))
        check(entry.path().extension() != ".tmp", "no owned temporary files left behind");
}
}

int main() {
    auto dir = fs::temp_directory_path() / fs::path(u8"gogaku-持久化-");
    dir += std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
    if (!fs::create_directory(dir)) return 1;
    try {
#ifdef _WIN32
        test_windows_writer(dir);
#endif
        test_custom_words(dir);
    } catch (const std::exception &e) {
        ++failures;
        std::fprintf(stderr, "FAIL: %s\n", e.what());
    }
    fs::remove_all(dir);
    std::fprintf(stderr, "persistence: %d failures\n", failures);
    return failures ? 1 : 0;
}
