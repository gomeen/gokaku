// 内置主题契约向量：与设置契约同一模式，两端跑同一份源码。
// 这里冻结的是「共享数据是什么」，不依赖词典、平台路径或渲染。
#include "gogaku_core.h"

#include "json.hpp"

#include <cstdio>
#include <cstring>
#include <string>

namespace {

using Json = nlohmann::json;

int failures = 0;

void check(bool condition, const std::string &name, const std::string &detail) {
    if (condition) return;
    std::fprintf(stderr, "FAIL %s: %s\n", name.c_str(), detail.c_str());
    ++failures;
}

void check(bool condition, const std::string &name, const char *detail) {
    check(condition, name, std::string(detail));
}

}  // namespace

int main() {
    char *buffer = nullptr;
    size_t length = 0;
    const int32_t code = gc_themes_builtin(&buffer, &length);
    check(code == 0, "call", "返回码 " + std::to_string(code));
    check(buffer && length > 0, "call", "输出为空");
    check(!buffer || length == std::strlen(buffer), "call", "输出没有按 out_len 以 NUL 结尾");
    if (code != 0 || !buffer) return 1;
    const Json themes = Json::parse(buffer, buffer + length, nullptr, false);
    gc_contract_free(buffer);
    check(!themes.is_discarded() && themes.is_array(), "parse", "输出不是 JSON 数组");
    if (!themes.is_array()) return 1;

    check(themes.size() == 4, "count", "共 " + std::to_string(themes.size()) + " 套");
    const char *expectedIds[] = {"gogaku", "claude", "grok", "witch"};
    const char *expectedNames[] = {"Gogaku", "Claude", "Grok Bot", "女巫魔药"};
    const char *colorKeys[] = {"background", "border", "text", "comment", "index",
                               "highlight", "highlightText", "highlightComment",
                               "cursor", "page"};
    bool sawWitchMissingDark = false;
    for (size_t i = 0; i < themes.size() && i < 4; ++i) {
        const auto &t = themes[i];
        const std::string name = expectedIds[i];
        check(t.value("id", std::string()) == expectedIds[i], name, "id 不符");
        check(t.value("name", std::string()) == expectedNames[i], name, "name 不符");
        for (const char *slot : {"light", "dark"}) {
            if (!t.contains(slot)) {
                check(std::string(slot) == "dark" && i == 3, name,
                      std::string(slot) + " 缺失");
                sawWitchMissingDark = sawWitchMissingDark || (i == 3 && std::string(slot) == "dark");
                continue;
            }
            const auto &p = t[slot];
            check(p.is_object(), name, std::string(slot) + " 不是对象");
            for (const char *key : colorKeys) {
                const auto found = p.find(key);
                check(found != p.end() && found->is_number_integer() &&
                          *found >= 0 && *found <= 0xffffff,
                      name, std::string(slot) + "." + key + " 不是 24 位整数");
            }
            const auto visual = p.find("visual");
            check(visual != p.end() && visual->is_object(), name,
                  std::string(slot) + ".visual 缺失");
            if (visual != p.end() && visual->is_object()) {
                check(visual->value("radius", 0.0) == 8.0 &&
                          visual->value("padding", 0.0) == 8.0 &&
                          visual->value("rowHeight", 0.0) == 100.0 &&
                          visual->value("opacity", 0.0) == 100.0 &&
                          visual->value("bgOpacity", 0.0) == 100.0 &&
                          visual->value("imageOpacity", -1.0) == 25.0,
                      name, std::string(slot) + ".visual 默认值不符");
            }
            check(p.find("imageData") == p.end(), name,
                  std::string(slot) + " 内置主题不应带背景图");
        }
        const auto typography = t.find("typography");
        check(typography != t.end() && typography->is_object(), name, "typography 缺失");
        if (typography != t.end() && typography->is_object()) {
            check(typography->value("fontCN", std::string()) == "system-ui" &&
                      typography->value("fontEN", std::string()) == "system-ui" &&
                      typography->value("fontSize", 0.0) == 14.0 &&
                      typography->value("indexSize", 0.0) == 11.0,
                  name, "typography 默认值不符");
        }
    }
    check(sawWitchMissingDark, "witch", "单色主题缺 dark 缺失标记未生效");
    check(themes.find("rime-macos-like") == themes.end(), "rime-alias",
          "别名 id 不应出现在数组里");

    // 锚点色：改调色板必须同时改这里，防止「顺手调色」造成两端漂移。
    const auto colorOf = [&](size_t index, const char *slot, const char *key) -> int64_t {
        const auto &p = themes[index][slot];
        const auto found = p.find(key);
        return found == p.end() || !found->is_number_integer() ? -1 : found->get<int64_t>();
    };
    check(colorOf(0, "light", "highlight") == 0x12996a, "gogaku-accent",
          "浅色强调色应为 #12996a（产品规格）");
    check(colorOf(0, "dark", "highlight") == 0x168d64, "gogaku-accent-dark",
          "深色强调色应为 #168d64");
    check(colorOf(3, "light", "background") == 0x15111c, "witch-bg", "女巫魔药底色不符");
    check(colorOf(1, "light", "highlight") == 0xdf9e87, "claude-accent", "Claude 浅色强调不符");
    check(colorOf(2, "dark", "highlight") == 0x28609b, "grok-accent-dark", "Grok 深色强调不符");

    // ── 覆盖补丁：套用与求差都只有共享核心一份实现 ─────────────────
    struct Out {
        int32_t code = -1;
        std::string text;
        Json value;
    };
    const auto effective = [](const std::string &overrides) {
        Out result;
        char *buffer = nullptr;
        size_t length = 0;
        result.code = gc_themes_effective(overrides.data(), overrides.size(), &buffer, &length);
        if (result.code == 0 && buffer) {
            result.text.assign(buffer, length);
            result.value = Json::parse(buffer, buffer + length, nullptr, false);
        }
        gc_contract_free(buffer);
        return result;
    };
    const auto makeRaw = [](const std::string &id, const std::string &text) {
        Out result;
        char *buffer = nullptr;
        size_t length = 0;
        result.code = gc_theme_override_make(id.c_str(), text.data(), text.size(), &buffer, &length);
        if (result.code == 0 && buffer) {
            result.text.assign(buffer, length);
            result.value = Json::parse(buffer, buffer + length, nullptr, false);
        }
        gc_contract_free(buffer);
        return result;
    };
    const auto make = [&makeRaw](const std::string &id, const Json &edited) {
        return makeRaw(id, edited.dump());
    };

    // 空补丁：与 gc_themes_builtin 逐字节相同。
    for (const char *empty : {"", "{}"}) {
        Out result = effective(empty);
        check(result.code == 0, "effective-empty", std::string("返回码 ") + std::to_string(result.code));
        check(result.text == themes.dump(), "effective-empty",
              std::string("空补丁 ") + (empty[0] ? "{}" : "空串") + " 输出应与出厂数据一致");
    }

    {
        Out result = effective(R"({"gogaku":{"name":"我的 Gogaku"}})");
        check(result.code == 0 && result.value.is_array() && result.value.size() == 4,
              "effective-name", "返回码或形状不符");
        if (result.code == 0 && result.value.is_array() && result.value.size() == 4) {
            check(result.value[0]["name"] == "我的 Gogaku", "effective-name", "改名未生效");
            check(result.value[0]["light"] == themes[0]["light"], "effective-name", "未改的配色被改动");
            check(result.value[1] == themes[1], "effective-name", "其他主题不应受影响");
        }
    }
    {
        Out result = effective(R"({"claude":{"light":{"highlight":1218922}}})");
        check(result.code == 0 && result.value.is_array() && result.value.size() == 4,
              "effective-color", "返回码或形状不符");
        if (result.code == 0 && result.value.is_array() && result.value.size() == 4) {
            check(result.value[1]["light"]["highlight"] == 1218922, "effective-color", "颜色补丁未生效");
            check(result.value[1]["light"]["background"] == themes[1]["light"]["background"],
                  "effective-color", "同一配色里未改的颜色应跟随出厂");
            check(result.value[1]["dark"] == themes[1]["dark"], "effective-color", "深色配色不应受影响");
        }
    }
    {
        Out result = effective(R"({"grok":{"light":{"visual":{"radius":12}}}})");
        check(result.code == 0 && result.value.is_array() && result.value.size() == 4,
              "effective-visual", "返回码或形状不符");
        if (result.code == 0 && result.value.is_array() && result.value.size() == 4) {
            const auto &visual = result.value[2]["light"]["visual"];
            check(visual.value("radius", 0.0) == 12.0, "effective-visual", "圆角补丁未生效");
            check(visual.value("padding", 0.0) == 8.0 && visual.value("rowHeight", 0.0) == 100.0,
                  "effective-visual", "同一 visual 里未改的字段应跟随出厂");
        }
    }
    {
        Out result = effective(R"({"claude":{"dark":null}})");
        check(result.code == 0 && result.value.is_array() && result.value.size() == 4,
              "effective-drop-dark", "返回码或形状不符");
        if (result.code == 0 && result.value.is_array() && result.value.size() == 4) {
            check(result.value[1].find("dark") == result.value[1].end(), "effective-drop-dark",
                  "dark:null 应把双色主题改为单色");
        }
    }
    {
        const Json patch = Json{{"witch", Json{{"dark", themes[3]["light"]}}}};
        Out result = effective(patch.dump());
        check(result.code == 0 && result.value.is_array() && result.value.size() == 4,
              "effective-add-dark", "返回码或形状不符");
        if (result.code == 0 && result.value.is_array() && result.value.size() == 4) {
            check(result.value[3].contains("dark") && result.value[3]["dark"] == themes[3]["light"],
                  "effective-add-dark", "为单色主题添加深色配色未生效");
        }
    }
    {
        Out result = effective(R"({"gogaku":{"id":"evil"}})");
        check(result.code == 0 && result.value.is_array() && result.value.size() == 4,
              "effective-id-ignored", "返回码或形状不符");
        if (result.code == 0 && result.value.is_array() && result.value.size() == 4) {
            check(result.value[0]["id"] == "gogaku", "effective-id-ignored", "补丁不得改主题身份");
            check(result.text == themes.dump(), "effective-id-ignored", "仅含 id 的补丁应等价于空补丁");
        }
    }
    {
        Out result = effective(R"({"unknown-theme":{"name":"x"}})");
        check(result.code == 0 && result.value.is_array() && result.value.size() == 4,
              "effective-unknown-id", "返回码或形状不符");
        if (result.code == 0) check(result.text == themes.dump(), "effective-unknown-id", "未知 ID 应忽略");
    }
    for (const char *bad : {"not json", "[1,2,3]", "{\"a\":}"}) {
        Out result = effective(bad);
        check(result.code == 2, "effective-malformed",
              std::string("输入 ") + bad + " 应返回 2，实际 " + std::to_string(result.code));
    }
    {
        char *buffer = nullptr;
        size_t length = 0;
        check(gc_themes_effective(nullptr, 5, &buffer, &length) == 1, "effective-bad-args",
              "overrides 为 NULL 但长度非 0 应返回 1");
        check(gc_themes_effective("{}", 2, nullptr, &length) == 1, "effective-bad-args",
              "out 为 NULL 应返回 1");
        check(gc_themes_effective("{}", 2, &buffer, nullptr) == 1, "effective-bad-args",
              "out_len 为 NULL 应返回 1");
    }

    // 求差：出厂数据直接回灌应该得到空补丁（含数值 14 与 14.0 等值）。
    for (size_t i = 0; i < themes.size() && i < 4; ++i) {
        const std::string id = themes[i]["id"];
        Out patch = make(id, themes[i]);
        check(patch.code == 0 && patch.text == "{}", "make-identity",
              id + " 的出厂数据应求差为 {}，实际 " + patch.text);
    }
    {
        Json edited = themes[1];
        edited["typography"]["fontSize"] = 14.0;
        Out patch = make("claude", edited);
        check(patch.code == 0 && patch.text == "{}", "make-number-equal",
              "14 与 14.0 应视为相同，实际 " + patch.text);
    }
    {
        Json edited = themes[1];
        edited["id"] = "user-copy";
        Out patch = make("claude", edited);
        check(patch.code == 0 && patch.text == "{}", "make-id-ignored",
              "id 不参与求差，实际 " + patch.text);
    }
    {
        Json edited = themes[0];
        edited["name"] = "夜行";
        edited["light"]["highlight"] = 0x123456;
        edited["typography"]["fontSize"] = 16;
        Out patch = make("gogaku", edited);
        const Json expected{{"name", "夜行"},
                            {"light", Json{{"highlight", 0x123456}}},
                            {"typography", Json{{"fontSize", 16}}}};
        check(patch.code == 0 && patch.value == expected, "make-minimal",
              "补丁应只含改动字段，实际 " + patch.text);
        Out applied = effective(Json{{"gogaku", patch.value}}.dump());
        check(applied.code == 0 && applied.value.is_array() && applied.value.size() == 4 &&
                  applied.value[0] == edited,
              "make-roundtrip", "套用补丁后应等于草稿");
    }
    {
        Json edited = themes[1];
        edited.erase("dark");
        Out patch = make("claude", edited);
        check(patch.code == 0 && patch.value == Json{{"dark", nullptr}}, "make-drop-dark",
              "删掉深色配色的补丁应为 {dark:null}，实际 " + patch.text);
    }
    {
        Json edited = themes[3];
        edited["dark"] = themes[3]["light"];
        edited["dark"]["background"] = 0x101010;
        Out patch = make("witch", edited);
        check(patch.code == 0 && patch.value.is_object() && patch.value.contains("dark") &&
                  patch.value["dark"].is_object(),
              "make-add-dark", "为单色主题添加深色配色应写入完整 dark 对象，实际 " + patch.text);
        Out applied = effective(Json{{"witch", patch.value}}.dump());
        check(applied.code == 0 && applied.value.is_array() && applied.value.size() == 4 &&
                  applied.value[3] == edited,
              "make-add-dark-roundtrip", "套用补丁后应等于草稿");
    }
    {
        Out patch = make("rime-macos-like", themes[0]);
        check(patch.code == 1, "make-unknown-id", "别名不是内置 ID，应返回 1");
        patch = makeRaw("claude", "not json");
        check(patch.code == 2, "make-malformed", "编辑内容不是 JSON 应返回 2");
        char *buffer = nullptr;
        size_t length = 0;
        check(gc_theme_override_make(nullptr, "{}", 2, &buffer, &length) == 1, "make-bad-args",
              "builtin_id 为 NULL 应返回 1");
        check(gc_theme_override_make("claude", nullptr, 0, &buffer, &length) == 1, "make-bad-args",
              "edited 为 NULL 应返回 1");
        check(gc_theme_override_make("claude", "{}", 2, nullptr, &length) == 1, "make-bad-args",
              "out 为 NULL 应返回 1");
    }

    // 参数错误路径。
    check(gc_themes_builtin(nullptr, &length) == 1, "bad-args", "out 为 NULL 应返回 1");

    if (failures == 0) {
        std::printf("theme contract: 4 builtin themes and override patches passed\n");
        return 0;
    }
    std::fprintf(stderr, "theme contract: %d 项失败\n", failures);
    return 1;
}
