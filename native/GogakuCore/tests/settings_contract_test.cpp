// 设置契约向量：两端共跑的同一组输入与期望结论。
// 这里冻结的是「读侧规范化」的行为，不依赖词典数据、平台路径或会话。
#include "gogaku_core.h"

#include "json.hpp"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

using Json = nlohmann::json;

int failures = 0;

void check(bool condition, const char *name, const std::string &detail) {
    if (condition) return;
    std::fprintf(stderr, "FAIL %s: %s\n", name, detail.c_str());
    ++failures;
}

struct Result {
    int32_t code = -1;
    int32_t migrated = 0;
    std::string text;
    Json value;
};

Result normalize(const std::string &raw) {
    Result result;
    char *buffer = nullptr;
    size_t size = 0;
    result.code = gc_settings_normalize(raw.data(), raw.size(), &buffer, &size, &result.migrated);
    if (result.code == 0 && buffer) {
        result.text.assign(buffer, size);
        result.value = Json::parse(buffer, buffer + size, nullptr, false);
    }
    gc_contract_free(buffer);
    return result;
}

struct Case {
    const char *name;
    const char *input;
    Json expect;                     // 逐键深比较
    std::vector<std::string> absent; // 规范结果里必须不存在
    int32_t migrated;
};

void runCase(const Case &test) {
    Result result = normalize(test.input);
    check(result.code == 0, test.name, "返回码 " + std::to_string(result.code));
    if (result.code != 0) return;
    check(result.text.size() == std::strlen(result.text.c_str()), test.name,
          "输出没有按 out_len 以 NUL 结尾");
    check(!result.value.is_discarded() && result.value.is_object(), test.name,
          "输出不是 JSON 对象");
    check(result.migrated == test.migrated, test.name,
          "migrated=" + std::to_string(result.migrated) + " 期望 " +
              std::to_string(test.migrated));
    for (auto entry = test.expect.begin(); entry != test.expect.end(); ++entry) {
        auto found = result.value.find(entry.key());
        check(found != result.value.end() && *found == entry.value(), test.name,
              "字段 " + entry.key() + " = " +
                  (found == result.value.end() ? std::string("<缺失>") : found->dump()) +
                  " 期望 " + entry.value().dump());
    }
    for (const std::string &key : test.absent) {
        check(result.value.find(key) == result.value.end(), test.name,
              "字段 " + key + " 应已删除");
    }
}

}  // namespace

int main() {
    // 空输入与默认值：缺字段全部回落到默认，两个平台看到同一份对象。
    {
        Result result = normalize("{}");
        check(result.code == 0, "empty-object", "返回码 " + std::to_string(result.code));
        check(result.migrated == 0, "empty-object", "空对象不应算迁移");
        Json expected{{"schemaVersion", 2},
                      {"recording", true},
                      {"excludedApplications", Json::array()},
                      {"ignoredWords", Json::array()},
                      {"applications", Json::object()},
                      {"modeShortcut", Json{{"key", "k"}, {"modifiers", 393216}}},
                      {"directionShortcut", Json{{"key", "j"}, {"modifiers", 393216}}},
                      {"candidateTheme", "rime-macos-like"},
                      {"userCandidateThemes", Json::array()},
                      {"inputScheme", "xiaohe"},
                      {"fuzzyPinyin", Json::array()},
                      {"candidateFontSize", 14},
                      {"glossEnabled", true},
                      {"inputLettersEnabled", true},
                      {"fullPinyinPreedit", true},
                      {"frequencyEnabled", true},
                      {"englishCandidatesEnabled", true},
                      {"learningTranslationEnabled", false},
                      {"preferredMode", "normal"},
                      {"preferredDirection", "zhToEn"},
                      {"volcengineUsageMonth", ""},
                      {"volcengineUsageCharacters", 0}};
        for (auto entry = expected.begin(); entry != expected.end(); ++entry) {
            auto found = result.value.find(entry.key());
            check(found != result.value.end() && *found == entry.value(), "empty-object",
                  "默认字段 " + entry.key());
        }
        check(result.value.size() == expected.size(), "empty-object",
              "默认对象有多余字段：" + result.value.dump());
        // 缺键与空数组必须区分：缺键交给平台补出厂清单，空数组不复活。
        check(result.value.find("appDefaultEnglish") == result.value.end(), "empty-object",
              "缺 appDefaultEnglish 时不应输出空数组");
    }

    // NULL／空缓冲：按空对象处理，不崩。
    {
        char *buffer = nullptr;
        size_t size = 0;
        int32_t migrated = -1;
        int32_t code = gc_settings_normalize(nullptr, 0, &buffer, &size, &migrated);
        check(code == 0, "null-input", "返回码 " + std::to_string(code));
        check(buffer && size > 0 && migrated == 0, "null-input", "空缓冲应产出默认对象");
        gc_contract_free(buffer);
    }

    // 畸形输入：不是 JSON、不是对象，都明确拒绝而不是猜。
    for (const char *input : {"not json", "[1,2,3]", "\"text\"", "{\"a\":}"}) {
        Result result = normalize(input);
        check(result.code == 2, "malformed", std::string("输入 ") + input + " 返回码 " +
                                                     std::to_string(result.code));
    }
    {
        char *buffer = nullptr;
        size_t size = 0;
        check(gc_settings_normalize("{}", 2, &buffer, nullptr, nullptr) == 1, "bad-args",
              "out_len 为 NULL 应返回 1");
        check(gc_settings_normalize(nullptr, 5, &buffer, &size, nullptr) == 1, "bad-args",
              "raw 为 NULL 但长度非 0 应返回 1");
    }

    const std::vector<Case> cases = {
        {"schema1-quickmt",
         R"({"schemaVersion":1,"learningTranslationBackend":"quickmt","learningTranslationEnabled":true})",
         Json{{"schemaVersion", 2}, {"learningTranslationEnabled", false}},
         {"learningTranslationBackend"},
         1},
        {"schema1-small100",
         R"({"schemaVersion":1,"learningTranslationBackend":"small100"})",
         Json{{"learningTranslationEnabled", false}},
         {"learningTranslationBackend"},
         1},
        {"schema1-volcengine-default-on",
         R"({"schemaVersion":1,"learningTranslationBackend":"volcengine"})",
         Json{{"learningTranslationEnabled", true}},
         {"learningTranslationBackend"},
         1},
        {"schema1-volcengine-stored-off",
         R"({"schemaVersion":1,"learningTranslationBackend":"volcengine","learningTranslationEnabled":false})",
         Json{{"learningTranslationEnabled", false}},
         {"learningTranslationBackend"},
         1},
        {"schema1-missing-backend",
         R"({"schemaVersion":1,"learningTranslationEnabled":true})",
         Json{{"learningTranslationEnabled", false}},
         {"learningTranslationBackend"},
         1},
        {"no-schemaVersion-legacy-backend",
         R"({"learningTranslationBackend":"quickmt","learningTranslationEnabled":true})",
         Json{{"schemaVersion", 2}, {"learningTranslationEnabled", false}},
         {"learningTranslationBackend"},
         1},
        {"no-schemaVersion-plain-file-stays-quiet",
         R"({"candidateFontSize":13})",
         Json{{"schemaVersion", 2}, {"candidateFontSize", 13}},
         {},
         0},
        {"app-list-absent-key-omitted",
         R"({"candidateFontSize":14})",
         Json{{"candidateFontSize", 14}},
         {"appDefaultEnglish"},
         0},
        {"app-list-empty-stays-empty",
         R"({"appDefaultEnglish":[]})",
         Json{{"appDefaultEnglish", Json::array()}},
         {},
         0},
        {"shortcut-cleared-preserved",
         R"({"directionShortcut":{"key":"","modifiers":0,"disabled":true}})",
         Json{{"directionShortcut",
               Json{{"key", ""}, {"modifiers", 0}, {"disabled", true}}}},
         {},
         0},
        {"shortcut-empty-key-without-disabled-falls-back",
         R"({"modeShortcut":{"key":"","modifiers":0}})",
         Json{{"modeShortcut", Json{{"key", "k"}, {"modifiers", 393216}}}},
         {},
         0},
        {"shortcut-negative-modifiers-falls-back",
         R"({"modeShortcut":{"key":"k","modifiers":-1}})",
         Json{{"modeShortcut", Json{{"key", "k"}, {"modifiers", 393216}}}},
         {},
         0},
        {"huge-integer-clamps-instead-of-wrapping",
         R"({"candidateFontSize":9999999999999999999,"volcengineUsageCharacters":9999999999999999999})",
         Json{{"candidateFontSize", 16}, {"volcengineUsageCharacters", 2147483647}},
         {},
         0},
        {"schemaVersion-wrong-type-reads-as-legacy",
         R"({"schemaVersion":"2","learningTranslationBackend":"quickmt","learningTranslationEnabled":true})",
         Json{{"schemaVersion", 2}, {"learningTranslationEnabled", false}},
         {"learningTranslationBackend"},
         1},
        {"schema2-enabled",
         R"({"schemaVersion":2,"learningTranslationEnabled":true})",
         Json{{"schemaVersion", 2}, {"learningTranslationEnabled", true}},
         {"learningTranslationBackend"},
         0},
        {"schema2-legacy-key-dropped",
         R"({"schemaVersion":2,"learningTranslationBackend":"volcengine","learningTranslationEnabled":false})",
         Json{{"learningTranslationEnabled", false}},
         {"learningTranslationBackend"},
         0},
        {"future-schema-reads-known",
         R"({"schemaVersion":9,"candidateFontSize":15})",
         Json{{"schemaVersion", 2}, {"candidateFontSize", 15}},
         {},
         0},
        {"font-size-clamped-high",
         R"({"candidateFontSize":99})",
         Json{{"candidateFontSize", 16}},
         {},
         0},
        {"font-size-clamped-low",
         R"({"candidateFontSize":0})",
         Json{{"candidateFontSize", 12}},
         {},
         0},
        {"font-size-wrong-type",
         R"({"candidateFontSize":"big"})",
         Json{{"candidateFontSize", 14}},
         {},
         0},
        {"app-list-legacy-strings",
         R"({"appDefaultEnglish":["com.a","com.b"]})",
         Json{{"appDefaultEnglish",
               Json::array({Json{{"id", "com.a"}, {"enabled", true}},
                            Json{{"id", "com.b"}, {"enabled", true}}})}},
         {},
         0},
        {"app-list-mixed-and-duplicate",
         R"({"appDefaultEnglish":[{"id":"a","enabled":false},"a",{"id":"c"},{"enabled":true},7]})",
         Json{{"appDefaultEnglish",
               Json::array({Json{{"id", "a"}, {"enabled", false}},
                            Json{{"id", "c"}, {"enabled", true}}})}},
         {},
         0},
        {"string-arrays-deduped",
         R"({"fuzzyPinyin":["an","an","en",5],"excludedApplications":["x","x","y"]})",
         Json{{"fuzzyPinyin", Json::array({"an", "en"})},
              {"excludedApplications", Json::array({"x", "y"})}},
         {},
         0},
        {"shortcut-invalid-falls-back",
         R"({"modeShortcut":{"key":"","modifiers":5},"directionShortcut":{"key":"j","modifiers":"nope"}})",
         Json{{"modeShortcut", Json{{"key", "k"}, {"modifiers", 393216}}},
              {"directionShortcut", Json{{"key", "j"}, {"modifiers", 393216}}}},
         {},
         0},
        {"shortcut-disabled-preserved",
         R"({"modeShortcut":{"key":"k","modifiers":393216,"disabled":true}})",
         Json{{"modeShortcut",
               Json{{"key", "k"}, {"modifiers", 393216}, {"disabled", true}}}},
         {},
         0},
        {"input-scheme-enum",
         R"({"inputScheme":"doublePinyin"})",
         Json{{"inputScheme", "xiaohe"}},
         {},
         0},
        {"preference-enums",
         R"({"preferredMode":"auto","preferredDirection":"enToZh"})",
         Json{{"preferredMode", "normal"}, {"preferredDirection", "enToZh"}},
         {},
         0},
        {"usage-month-shape",
         R"({"volcengineUsageMonth":"2026-11","volcengineUsageCharacters":42})",
         Json{{"volcengineUsageMonth", "2026-11"}, {"volcengineUsageCharacters", 42}},
         {},
         0},
        {"usage-month-garbage",
         R"({"volcengineUsageMonth":"November","volcengineUsageCharacters":-9})",
         Json{{"volcengineUsageMonth", ""}, {"volcengineUsageCharacters", 0}},
         {},
         0},
        {"theme-id-kept",
         R"({"candidateTheme":"claude"})",
         Json{{"candidateTheme", "claude"}},
         {},
         0},
        {"theme-id-empty-falls-back",
         R"({"candidateTheme":""})",
         Json{{"candidateTheme", "rime-macos-like"}},
         {},
         0},
        {"user-themes-non-objects-dropped",
         R"({"userCandidateThemes":[{"id":"mine"},7,"text"]})",
         Json{{"userCandidateThemes", Json::array({Json{{"id", "mine"}}})}},
         {},
         0},
        {"unknown-keys-preserved",
         R"({"schemaVersion":2,"windowsApplicationMetadata":{"code.exe":"Code"},"applications":{"com.a":"english"}})",
         Json{{"windowsApplicationMetadata", Json{{"code.exe", "Code"}}},
              {"applications", Json{{"com.a", "english"}}}},
         {},
         0},
        {"bool-wrong-type-keeps-default",
         R"({"recording":"yes","glossEnabled":null})",
         Json{{"recording", true}, {"glossEnabled", true}},
         {},
         0},
        {"bool-explicit-false",
         R"({"recording":false,"englishCandidatesEnabled":false})",
         Json{{"recording", false}, {"englishCandidatesEnabled", false}},
         {},
         0},
    };

    for (const Case &test : cases) runCase(test);

    if (failures == 0) {
        std::printf("settings contract: %zu cases passed\n", cases.size());
        return 0;
    }
    std::fprintf(stderr, "settings contract: %d 项失败\n", failures);
    return 1;
}
