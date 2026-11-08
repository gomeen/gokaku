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

}  // namespace

extern "C" int32_t gc_themes_builtin(char **out, size_t *out_len) {
    if (!out || !out_len) return 1;
    *out = nullptr;
    *out_len = 0;
    try {
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
        const Json themes = Json::array({
            theme("gogaku", "Gogaku", gogakuLight, 10, gogakuDark, 10),
            theme("claude", "Claude", claudeLight, 10, claudeDark, 10),
            theme("grok", "Grok Bot", grokLight, 10, grokDark, 10),
            theme("witch", "女巫魔药", witchLight, 10, nullptr, 0),
        });
        const std::string text = themes.dump();
        char *buffer = static_cast<char *>(std::malloc(text.size() + 1));
        if (!buffer) return 4;
        std::memcpy(buffer, text.data(), text.size());
        buffer[text.size()] = '\0';
        *out = buffer;
        *out_len = text.size();
        return 0;
    } catch (...) {
        if (out) *out = nullptr;
        if (out_len) *out_len = 0;
        return 5;
    }
}
