// 只调用 C ABI：Unicode 用户目录的 dirty 重试、重载、清空和损坏模型备份。
// 需要出厂 sc.dict / zh_CN.lm；不启动输入源或注入真实按键。
#include "gogaku_core.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
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
    out << data;
    check(out.good(), "write fixture");
}
using Session = std::unique_ptr<GcNormalSession, decltype(&gc_normal_session_destroy)>;
using Snapshot = std::unique_ptr<GcSnapshot, decltype(&gc_snapshot_free)>;
Snapshot send(GcNormalSession *session, int32_t kind, const char *text = "") {
    GcKeyEvent event{};
    event.kind = kind;
    event.text = text;
    event.app = "persistence.test";
    event.field = "field";
    GcSnapshot *snapshot = nullptr;
    check(gc_normal_handle(session, &event, &snapshot) == 0 && snapshot, "C ABI event");
    return Snapshot(snapshot, gc_snapshot_free);
}
void type(GcNormalSession *session, const char *keys) {
    for (const char *key = keys; *key; ++key) {
        const char text[] = {*key, '\0'};
        send(session, GC_EV_TEXT, text);
    }
}
void learn(GcNormalSession *session, const char *keys, const char *expected) {
    type(session, keys);
    const auto snapshot = send(session, GC_EV_SPACE);
    check(snapshot && snapshot->commit && snapshot->commit == std::string(expected), "complete Chinese commit");
    send(session, GC_EV_COMMIT_CONFIRMED);
}
Session create(const GcNormalConfig &config) {
    GcNormalSession *session = nullptr;
    char error[512]{};
    const int rc = gc_normal_session_create(&config, &session, error, sizeof(error));
    if (rc != 0) std::fprintf(stderr, "create failed: %s\n", error);
    check(rc == 0 && session, "create session");
    return Session(session, gc_normal_session_destroy);
}
void test(const fs::path &root, const fs::path &data) {
    const auto dictionary = root / fs::path(u8"中文词典.dict");
    fs::copy_file(data / "sc.dict", dictionary);
    const auto user = root / fs::path(u8"中文用户");
    const auto saved = root / "saved";
    const auto model = user / "model.userlm";
    const auto learned = user / "learned.txt";
    const auto backup = user / "model.userlm.corrupt";
    const std::string dictName = utf8(dictionary), modelName = utf8(data / "zh_CN.lm"), userName = utf8(user);
    GcNormalConfig config{};
    config.dict_path = dictName.c_str();
    config.model_path = modelName.c_str();
    config.user_dir = userName.c_str();
    config.scheme = GC_SCHEME_FULLPINYIN;
    config.freq_enabled = 1;
    auto session = create(config);
    if (!session) return;
    learn(session.get(), "nihao", "你好");
    check(gc_normal_flush(session.get()) == 0 && fs::is_regular_file(model) && fs::is_regular_file(learned),
          "first flush creates Unicode user directory");
    const auto oldModel = read(model), oldLearned = read(learned);
    // 现有学习登记要求至少两个词分段，不能用出厂词典中的单个词作夹具。
    learn(session.get(), "nihaoxuexi", "你好学习");
    // 不依赖 chmod/root 身份：把目录移开，用普通文件阻断原路径。
    fs::rename(user, saved);
    write(user, "not a directory");
    check(gc_normal_flush(session.get()) == 0, "failed flush retains existing ABI result");
    check(read(saved / "model.userlm") == oldModel && read(saved / "learned.txt") == oldLearned,
          "failed flush preserves both old files");
    fs::remove(user);
    fs::rename(saved, user);
    check(gc_normal_flush(session.get()) == 0, "retry same dirty session without another commit");
    check(read(model) != oldModel && read(learned).find("你好学习\t") != std::string::npos,
          "both dirty flags survived failure");
    session.reset();
    session = create(config);
    if (!session) return;
    type(session.get(), "nihaoxuexi");
    const auto snapshot = send(session.get(), GC_EV_DOWN);
    bool found = false;
    if (snapshot) for (size_t i = 0; i < snapshot->count; ++i)
        found |= snapshot->candidates[i].kind == GC_CAND_LEARNED &&
                 std::string(snapshot->candidates[i].text) == "你好学习";
    check(found, "reload learned words from Unicode directory");
    check(gc_normal_clear_user_data(session.get()) == 0 && !fs::exists(model) && !fs::exists(learned),
          "clear Unicode persisted paths");
    session.reset();
    for (const auto &broken : {std::string("broken model one"), std::string("broken model two")}) {
        write(model, broken);
        session = create(config);
        check(session && !fs::exists(model) && read(backup) == broken, "replace corrupt model backup");
        session.reset();
    }
}
}

int main() {
    const char *configured = std::getenv("GOGAKU_CORE_TEST_DATA");
    const char *home = std::getenv("HOME");
    const std::string base = configured ? configured : (home ? home : "");
    auto data = fs::path(std::u8string(base.begin(), base.end()));
    if (!configured) data /= "Library/Caches/Gogaku/libime-1.1.17/data";
    if (!fs::is_regular_file(data / "sc.dict") || !fs::is_regular_file(data / "zh_CN.lm")) {
        std::fprintf(stderr, "SKIP: GOGAKU_CORE_TEST_DATA must contain sc.dict and zh_CN.lm\n");
        return 3;
    }
    auto root = fs::temp_directory_path() / fs::path(u8"gogaku-调频-重试-");
    root += std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
    if (!fs::create_directory(root)) return 1;
    try { test(root, data); }
    catch (const std::exception &e) { ++failures; std::fprintf(stderr, "FAIL: %s\n", e.what()); }
    fs::remove_all(root);
    std::fprintf(stderr, "normal persistence: %d failures\n", failures);
    return failures ? 1 : 0;
}
