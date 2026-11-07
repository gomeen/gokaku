// 设置契约的读侧规范化。两端共用，规则由 tests/settings_contract_test.cpp
// 的向量冻结；这里不碰平台路径、不写盘、不建线程。
// gogaku_core.h 经相对路径引用，避免平台构建脚本为它加 -I。
#include "include/gogaku_core.h"
// 相对路径引用共享第三方（native/third_party），平台构建无需额外 -I。
#include "../third_party/json.hpp"

#include <cstdlib>
#include <cstring>
#include <limits>
#include <string>
#include <unordered_set>

namespace {

using Json = nlohmann::json;

const std::unordered_set<std::string> &knownKeys() {
    static const std::unordered_set<std::string> keys = {
        "schemaVersion", "recording", "excludedApplications", "ignoredWords",
        "applications", "modeShortcut", "directionShortcut", "candidateTheme",
        "userCandidateThemes", "inputScheme", "fuzzyPinyin", "candidateFontSize",
        "glossEnabled", "inputLettersEnabled", "fullPinyinPreedit", "frequencyEnabled",
        "englishCandidatesEnabled", "appDefaultEnglish", "learningTranslationEnabled",
        "preferredMode", "preferredDirection", "volcengineUsageMonth",
        "volcengineUsageCharacters",
    };
    return keys;
}

// 出厂默认值只含两端语义相同的字段。按应用默认英文的应用清单是平台身份
// （macOS bundle id 与 Windows 可执行文件名），缺键时由平台在空列表上自行补默认。
Json defaults() {
    return Json{
        {"schemaVersion", GC_SETTINGS_SCHEMA_VERSION},
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
        {"volcengineUsageCharacters", 0},
    };
}

bool booleanOr(const Json &value, bool fallback) {
    return value.is_boolean() ? value.get<bool>() : fallback;
}

const Json *member(const Json &object, const char *key) {
    auto it = object.find(key);
    return it == object.end() ? nullptr : &*it;
}

Json uniqueStrings(const Json &value) {
    Json out = Json::array();
    if (!value.is_array()) return out;
    std::unordered_set<std::string> seen;
    for (const auto &entry : value) {
        if (!entry.is_string()) continue;
        std::string text = entry.get<std::string>();
        if (!seen.insert(text).second) continue;
        out.push_back(text);
    }
    return out;
}

// 旧形状（字符串数组）与现形状（[{id,enabled}]）都收；顺序保留，重复 id 取首个。
Json appEntries(const Json &value) {
    Json out = Json::array();
    if (!value.is_array()) return out;
    std::unordered_set<std::string> seen;
    for (const auto &entry : value) {
        std::string id;
        bool enabled = true;
        if (entry.is_string()) {
            id = entry.get<std::string>();
        } else if (entry.is_object()) {
            const Json *identifier = member(entry, "id");
            if (!identifier || !identifier->is_string()) continue;
            id = identifier->get<std::string>();
            if (const Json *flag = member(entry, "enabled")) enabled = booleanOr(*flag, true);
        } else {
            continue;
        }
        if (id.empty() || !seen.insert(id).second) continue;
        out.push_back(Json{{"id", id}, {"enabled", enabled}});
    }
    return out;
}

// 读整数时先归一为 int64 并饱和：nlohmann 的 get<int>()／get<int64_t>() 对超出范围
// 的值会回绕，回绕后的负数会被当成合法值写回设置。
int64_t integerOr(const Json &value, int64_t fallback) {
    if (!value.is_number_integer()) return fallback;
    if (value.is_number_unsigned()) {
        uint64_t raw = value.get<uint64_t>();
        const uint64_t ceiling = static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
        return raw > ceiling ? std::numeric_limits<int64_t>::max() : static_cast<int64_t>(raw);
    }
    return value.get<int64_t>();
}

Json shortcut(const Json &value, const Json &fallback) {
    if (!value.is_object()) return fallback;
    const Json *key = member(value, "key");
    if (!key || !key->is_string()) return fallback;
    std::string text = key->get<std::string>();
    if (text.size() > 64) return fallback;
    // modifiers 是 NSEvent 位标志或 Windows 修饰键掩码；负数与超范围不写回。
    uint64_t mask = 0;
    if (const Json *modifiers = member(value, "modifiers")) {
        if (!modifiers->is_number_integer()) return fallback;
        int64_t raw = integerOr(*modifiers, 0);
        if (raw < 0 || raw > 0xFFFFFFFFll) return fallback;
        mask = static_cast<uint64_t>(raw);
    }
    bool disabled = false;
    if (const Json *flag = member(value, "disabled")) disabled = booleanOr(*flag, false);
    // 用户「清除快捷键」写的是空 key ＋ disabled：这是合法状态，不能回退成默认绑定。
    if (text.empty() && !disabled) return fallback;
    Json out{{"key", text}, {"modifiers", mask}};
    if (disabled) out["disabled"] = true;
    return out;
}

int clampInt(const Json &value, int fallback, int low, int high) {
    int64_t number = integerOr(value, fallback);
    if (number < low) return low;
    if (number > high) return high;
    return static_cast<int>(number);
}

// 形如 YYYY-MM；不合形状一律清空，避免设置页显示无意义的月份。
std::string monthOrEmpty(const Json &value) {
    if (!value.is_string()) return "";
    std::string text = value.get<std::string>();
    if (text.size() != 7 || text[4] != '-') return "";
    for (size_t index = 0; index < text.size(); ++index) {
        if (index == 4) continue;
        if (text[index] < '0' || text[index] > '9') return "";
    }
    return text;
}

std::string oneOf(const Json &value, std::initializer_list<const char *> allowed,
                  const char *fallback) {
    if (value.is_string()) {
        std::string text = value.get<std::string>();
        for (const char *candidate : allowed) {
            if (text == candidate) return text;
        }
    }
    return fallback;
}

Json themeObjects(const Json &value) {
    Json out = Json::array();
    if (!value.is_array()) return out;
    for (const auto &entry : value) {
        if (entry.is_object()) out.push_back(entry);
    }
    return out;
}

}  // namespace

namespace {

int32_t settingsNormalize(const char *raw, size_t raw_len, char **out,
                          size_t *out_len, int32_t *migrated) {
    if (!out || !out_len || (!raw && raw_len != 0)) return 1;
    *out = nullptr;
    *out_len = 0;
    if (migrated) *migrated = 0;

    Json input = Json::object();
    if (raw && raw_len != 0) {
        input = Json::parse(raw, raw + raw_len, nullptr, false);
        if (input.is_discarded() || !input.is_object()) return 2;
    }

    Json canonical = defaults();
    for (const auto &entry : input.items()) {
        if (knownKeys().count(entry.key()) == 0) canonical[entry.key()] = entry.value();
    }

    // 缺 schemaVersion 视为 schema 1（与两端历史行为一致）：新安装写盘时
    // 两步都会写 2，缺这个字段的就是旧文件。
    int schema = 1;
    if (const Json *value = member(input, "schemaVersion")) {
        int64_t declared = integerOr(*value, 1);
        schema = declared < 1 ? 1 : static_cast<int>(declared > 1000 ? 1000 : declared);
    }

    // 类型不对一律回到默认值，不让一份坏字段把整份设置打成默认。
    auto applyBool = [&](const char *key) {
        if (const Json *value = member(input, key); value && value->is_boolean()) {
            canonical[key] = value->get<bool>();
        }
    };
    for (const char *key : {"recording", "glossEnabled", "inputLettersEnabled",
                            "fullPinyinPreedit", "frequencyEnabled",
                            "englishCandidatesEnabled"}) {
        applyBool(key);
    }
    if (const Json *value = member(input, "excludedApplications")) {
        canonical["excludedApplications"] = uniqueStrings(*value);
    }
    if (const Json *value = member(input, "ignoredWords")) {
        canonical["ignoredWords"] = uniqueStrings(*value);
    }
    if (const Json *value = member(input, "applications"); value && value->is_object()) {
        canonical["applications"] = *value;
    }
    if (const Json *value = member(input, "modeShortcut")) {
        canonical["modeShortcut"] = shortcut(*value, defaults()["modeShortcut"]);
    }
    if (const Json *value = member(input, "directionShortcut")) {
        canonical["directionShortcut"] = shortcut(*value, defaults()["directionShortcut"]);
    }
    if (const Json *value = member(input, "candidateTheme"); value && value->is_string()) {
        std::string theme = value->get<std::string>();
        if (!theme.empty() && theme.size() <= 128) canonical["candidateTheme"] = theme;
    }
    if (const Json *value = member(input, "userCandidateThemes")) {
        canonical["userCandidateThemes"] = themeObjects(*value);
    }
    if (const Json *value = member(input, "inputScheme"); value && value->is_string()) {
        canonical["inputScheme"] = oneOf(*value, {"xiaohe", "fullPinyin"}, "xiaohe");
    }
    if (const Json *value = member(input, "fuzzyPinyin")) {
        canonical["fuzzyPinyin"] = uniqueStrings(*value);
    }
    if (const Json *value = member(input, "candidateFontSize")) {
        canonical["candidateFontSize"] = clampInt(*value, 14, 12, 16);
    }
    if (const Json *value = member(input, "appDefaultEnglish")) {
        // 缺这个键与「用户把列表清空」不是同一件事：缺键时下面不写这个键，
        // 交给平台补自己的出厂清单；空数组原样保留，不复活已删应用。
        canonical["appDefaultEnglish"] = appEntries(*value);
    }
    if (const Json *value = member(input, "preferredMode"); value && value->is_string()) {
        canonical["preferredMode"] = oneOf(*value, {"normal", "learning"}, "normal");
    }
    if (const Json *value = member(input, "preferredDirection"); value && value->is_string()) {
        canonical["preferredDirection"] = oneOf(*value, {"zhToEn", "enToZh"}, "zhToEn");
    }
    if (const Json *value = member(input, "volcengineUsageMonth")) {
        canonical["volcengineUsageMonth"] = monthOrEmpty(*value);
    }
    if (const Json *value = member(input, "volcengineUsageCharacters"); value) {
        int64_t characters = integerOr(*value, 0);
        canonical["volcengineUsageCharacters"] =
            characters < 0 ? 0 : static_cast<int>(characters > 2147483647ll ? 2147483647ll : characters);
    }

    // 迁移（2026-11-06 裁决）：schema 1 的本地模型后端一律关闭学习翻译，
    // 避免升级后把输入发到云端；原本已启用火山的配置保留开关。
    if (schema < GC_SETTINGS_SCHEMA_VERSION) {
        bool storedKnown = false;
        bool storedEnabled = false;
        if (const Json *value = member(input, "learningTranslationEnabled");
            value && value->is_boolean()) {
            storedKnown = true;
            storedEnabled = value->get<bool>();
        }
        std::string backend;
        bool hasBackend = false;
        if (const Json *value = member(input, "learningTranslationBackend");
            value && value->is_string()) {
            hasBackend = true;
            backend = value->get<std::string>();
        }
        bool enabled = backend == "volcengine" ? (storedKnown ? storedEnabled : true) : false;
        canonical["learningTranslationEnabled"] = enabled;
        // 显式声明旧版本、带遗留后端键、或开关值与旧读法不同，都算迁移；
        // 缺 schemaVersion 且值等价的普通文件不算，避免每次读都报迁移。
        bool declared = false;
        if (const Json *value = member(input, "schemaVersion"); value && value->is_number_integer()) {
            declared = true;
        }
        bool changed = declared || hasBackend || enabled != (storedKnown ? storedEnabled : false);
        if (migrated && changed) *migrated = 1;
    } else if (const Json *value = member(input, "learningTranslationEnabled");
               value && value->is_boolean()) {
        canonical["learningTranslationEnabled"] = value->get<bool>();
    }
    // 退役字段不再出现在规范结果里（写入方也不会再生成它）。
    canonical.erase("learningTranslationBackend");
    canonical["schemaVersion"] = GC_SETTINGS_SCHEMA_VERSION;

    std::string text = canonical.dump();
    char *buffer = static_cast<char *>(std::malloc(text.size() + 1));
    if (!buffer) return 4;
    std::memcpy(buffer, text.data(), text.size());
    buffer[text.size()] = '\0';
    *out = buffer;
    *out_len = text.size();
    return 0;
}

}  // namespace

extern "C" int32_t gc_settings_normalize(const char *raw, size_t raw_len, char **out,
                                         size_t *out_len, int32_t *migrated) {
    // C++ 异常不能跨 C ABI：归一化内部任何抛出都在这里转成返回码。
    try {
        return settingsNormalize(raw, raw_len, out, out_len, migrated);
    } catch (...) {
        if (out) *out = nullptr;
        if (out_len) *out_len = 0;
        if (migrated) *migrated = 0;
        return 5;
    }
}

extern "C" void gc_contract_free(void *buffer) {
    std::free(buffer);
}
