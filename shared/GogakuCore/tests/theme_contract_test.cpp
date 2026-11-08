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

    // 参数错误路径。
    check(gc_themes_builtin(nullptr, &length) == 1, "bad-args", "out 为 NULL 应返回 1");

    if (failures == 0) {
        std::printf("theme contract: 4 builtin themes passed\n");
        return 0;
    }
    std::fprintf(stderr, "theme contract: %d 项失败\n", failures);
    return 1;
}
