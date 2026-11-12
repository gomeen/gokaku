// 内置主题契约：四套主题的调色板与排版只有这一份数据。
// 2026-11-07 起 Sources/GogakuCore/CandidateTheme.swift 与
// windows/GogakuWindows/themes.cpp 都从这里取，删除「Exact semantic palettes
// from …」式的注释对照。形状见 theme_contract.h；锚点色由
// tests/theme_contract_test.cpp 冻结。
#include "include/gogaku_core.h"

#include "../third_party/json.hpp"

#include <cstdlib>
#include <cstring>
#include <string>

namespace {

using Json = nlohmann::json;

// 语义色位顺序两端一致：background, border, text, comment, index, highlight,
// highlightText, highlightComment, cursor, page。
Json palette(const uint32_t *values, size_t count) {
    static const char *keys[] = {"background", "border", "text", "comment", "index",
                                 "highlight", "highlightText", "highlightComment",
                                 "cursor", "page"};
    Json p = Json::object();
    for (size_t i = 0; i < count && i < 10; ++i) p[keys[i]] = values[i];
    p["visual"] = {{"radius", 8}, {"padding", 8}, {"rowHeight", 100},
                   {"opacity", 100}, {"bgOpacity", 100}, {"imageOpacity", 25}};
    return p;
}

Json typography() {
    return Json{{"fontCN", "system-ui"}, {"fontEN", "system-ui"},
                {"fontSize", 14}, {"indexSize", 11}};
}

Json theme(const char *id, const char *name, const uint32_t *light, size_t lightCount,
           const uint32_t *dark, size_t darkCount) {
    Json t = Json{{"id", id}, {"name", name}, {"light", palette(light, lightCount)},
                  {"typography", typography()}};
    if (dark && darkCount) t["dark"] = palette(dark, darkCount);
    return t;
}

// 出厂四套主题（唯一数据源）。gc_themes_builtin 与 gc_themes_effective 都
// 从这里取，空补丁时两者输出逐字节相同。
const Json &builtinThemes() {
    static const Json themes = [] {
        static const uint32_t gogakuLight[] = {0xffffff, 0xd7dfd9, 0x202925, 0x7d5800, 0x78837d,
                                               0x12996a, 0xffffff, 0xffffff, 0x53655a, 0x7b8880};
        static const uint32_t gogakuDark[] = {0x202823, 0x4b5a50, 0xf2f6f3, 0xe3a82e, 0xa8b3ab,
                                              0x168d64, 0xffffff, 0xffffff, 0xb8c7bc, 0xaab7ae};
        static const uint32_t claudeLight[] = {0xf5f4f1, 0xdcdad4, 0x1a1918, 0xb0532f, 0x66645f,
                                               0xdf9e87, 0x1a1918, 0x482519, 0xc4613f, 0x66645f};
        static const uint32_t claudeDark[] = {0x1a1917, 0x34322f, 0xecebe6, 0xf0a585, 0x9a9893,
                                              0xa3523c, 0xffffff, 0xffffff, 0xd77757, 0x9a9893};
        static const uint32_t grokLight[] = {0xf5f5f5, 0xe5e5e5, 0x1c1c1c, 0x0b6dd3, 0x656565,
                                             0x93bdeb, 0x1c1c1c, 0x102943, 0x1680f3, 0x656565};
        static const uint32_t grokDark[] = {0x161616, 0x262626, 0xededed, 0x93adff, 0xa9a9a9,
                                            0x28609b, 0xffffff, 0xffffff, 0x4d9bff, 0xa9a9a9};
        static const uint32_t witchLight[] = {0x15111c, 0x2a2238, 0xe4dcef, 0xc18cff, 0x9d90b3,
                                              0x75bc4c, 0x0f0b15, 0x142a0b, 0x8ef04f, 0x9d90b3};
        return Json::array({
            theme("gogaku", "Gogaku", gogakuLight, 10, gogakuDark, 10),
            theme("claude", "Claude", claudeLight, 10, claudeDark, 10),
            theme("grok", "Grok Bot", grokLight, 10, grokDark, 10),
            theme("witch", "女巫魔药", witchLight, 10, nullptr, 0),
        });
    }();
    return themes;
}

// 输出统一走这里：库内分配、NUL 结尾、长度与 strlen 一致。
int32_t emit(const Json &value, char **out, size_t *out_len) {
    const std::string text = value.dump();
    char *buffer = static_cast<char *>(std::malloc(text.size() + 1));
    if (!buffer) return 4;
    std::memcpy(buffer, text.data(), text.size());
    buffer[text.size()] = '\0';
    *out = buffer;
    *out_len = text.size();
    return 0;
}

// RFC 7386 求差：把 base（出厂）变成 edited（草稿）的最小补丁。
// changed 表示补丁非空；空对象即「与出厂一致」。
Json mergePatch(const Json &base, const Json &edited, bool &changed) {
    if (!base.is_object() || !edited.is_object()) {
        changed = !(base == edited);
        return edited;
    }
    Json patch = Json::object();
    bool any = false;
    for (auto it = base.begin(); it != base.end(); ++it) {
        if (!edited.contains(it.key())) {
            patch[it.key()] = nullptr;
            any = true;
        }
    }
    for (auto it = edited.begin(); it != edited.end(); ++it) {
        const auto found = base.find(it.key());
        if (found == base.end()) {
            patch[it.key()] = it.value();
            any = true;
            continue;
        }
        bool child = false;
        Json nested = mergePatch(*found, it.value(), child);
        if (child) {
            patch[it.key()] = nested;
            any = true;
        }
    }
    changed = any;
    return patch;
}

}  // namespace

extern "C" int32_t gc_themes_builtin(char **out, size_t *out_len) {
    if (!out || !out_len) return 1;
    *out = nullptr;
    *out_len = 0;
    try {
        return emit(builtinThemes(), out, out_len);
    } catch (...) {
        if (out) *out = nullptr;
        if (out_len) *out_len = 0;
        return 5;
    }
}

extern "C" int32_t gc_themes_effective(const char *overrides, size_t len, char **out,
                                         size_t *out_len) {
    if (!out || !out_len || (!overrides && len != 0)) return 1;
    *out = nullptr;
    *out_len = 0;
    try {
        Json patch = Json::object();
        if (overrides && len) {
            patch = Json::parse(overrides, overrides + len, nullptr, false);
            if (patch.is_discarded() || !patch.is_object()) return 2;
        }
        Json themes = builtinThemes();
        for (auto &entry : themes) {
            const std::string id = entry.value("id", std::string());
            const auto found = patch.find(id);
            if (found != patch.end() && found->is_object()) {
                Json value = *found;
                value.erase("id");  // 补丁不得改主题身份
                entry.merge_patch(value);
            }
            entry["id"] = id;
        }
        return emit(themes, out, out_len);
    } catch (...) {
        if (out) *out = nullptr;
        if (out_len) *out_len = 0;
        return 5;
    }
}

extern "C" int32_t gc_theme_override_make(const char *builtin_id, const char *edited,
                                            size_t edited_len, char **out, size_t *out_len) {
    if (!builtin_id || !edited || !out || !out_len) return 1;
    *out = nullptr;
    *out_len = 0;
    try {
        const Json &factory = builtinThemes();
        const Json *base = nullptr;
        for (const auto &entry : factory) {
            if (entry.value("id", std::string()) == builtin_id) {
                base = &entry;
                break;
            }
        }
        if (!base) return 1;
        Json value = Json::parse(edited, edited + edited_len, nullptr, false);
        if (value.is_discarded() || !value.is_object()) return 2;
        // 两边都剥除 id：主题身份不参与求差，补丁也不能改它。
        value.erase("id");
        Json origin = *base;
        origin.erase("id");
        bool changed = false;
        const Json patch = mergePatch(origin, value, changed);
        return emit(patch, out, out_len);
    } catch (...) {
        if (out) *out = nullptr;
        if (out_len) *out_len = 0;
        return 5;
    }
}

