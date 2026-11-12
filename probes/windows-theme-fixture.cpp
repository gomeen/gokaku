// Windows 主题覆盖补丁夹具：验证 effectiveBuiltinThemes / resolvedTheme 在
// 真实平台代码上的行为（共享核心只提供合并与求差，平台侧的校验与回退是本
// 夹具的对象）。只构造内存里的设置对象，不读写用户设置、不加载词典。
// 构建：python3 probes/build-windows-theme-fixture.py；在 Windows 上运行产物。
#include "../windows/GogakuWindows/platform.h"

#include <cstdio>
#include <string>

namespace {

int failures = 0;

void check(bool condition, const char *name) {
    if (condition) return;
    std::printf("FAIL %s\n", name);
    ++failures;
}

}  // namespace

int main() {
    const gw::Json builtins = gw::builtinThemes();
    check(builtins.is_array() && builtins.size() == 4, "factory-count");

    // 补丁只改一个颜色：其余字段继续跟随出厂数据。
    gw::Json settings = {
        {"candidateTheme", "claude"},
        {"builtinThemeOverrides",
         {{"claude", {{"light", {{"highlight", 1218922}}}}}}},
    };
    gw::Json themes = gw::effectiveBuiltinThemes(settings);
    check(themes.is_array() && themes.size() == 4, "effective-count");
    if (themes.is_array() && themes.size() == 4) {
        check(themes[1]["light"]["highlight"] == 1218922, "effective-color");
        check(themes[1]["light"]["background"] == builtins[1]["light"]["background"],
              "effective-untouched");
        check(themes[1]["dark"] == builtins[1]["dark"], "effective-dark-untouched");
    }
    gw::Json resolved = gw::resolvedTheme(settings);
    check(resolved["id"] == "claude", "resolved-id");
    check(resolved["light"]["highlight"] == 1218922, "resolved-color");

    // double -> 单色：补丁里的 dark:null 在平台上按「没有深色配色」呈现。
    settings["builtinThemeOverrides"] = {{"claude", {{"dark", nullptr}}}};
    check(!gw::resolvedTheme(settings).contains("dark"), "resolved-drop-dark");

    // 单色 -> 双色：补丁写入完整 dark 对象后平台校验通过。
    gw::Json dark = builtins[3]["light"];
    dark["background"] = 0x101010;
    settings["candidateTheme"] = "witch";
    settings["builtinThemeOverrides"] = {{"witch", {{"dark", dark}}}};
    resolved = gw::resolvedTheme(settings);
    check(resolved["id"] == "witch" && resolved.contains("dark") &&
              resolved["dark"]["background"] == 0x101010,
          "resolved-add-dark");

    // 超出本端范围的覆盖：该条回退出厂版本，不拖累其他主题。
    settings["candidateTheme"] = "gogaku";
    settings["builtinThemeOverrides"] = {
        {"gogaku", {{"typography", {{"fontSize", 99}}}}},
        {"grok", {{"light", {{"highlight", 0x123456}}}}},
    };
    check(gw::resolvedTheme(settings) == builtins[0], "invalid-fallback");
    themes = gw::effectiveBuiltinThemes(settings);
    check(themes[2]["light"]["highlight"] == 0x123456, "invalid-isolated");

    // 旧默认别名不受覆盖影响。
    settings["candidateTheme"] = "rime-macos-like";
    settings["builtinThemeOverrides"] = {{"gogaku", {{"light", {{"highlight", 0x123456}}}}}};
    resolved = gw::resolvedTheme(settings);
    check(resolved["id"] == "rime-macos-like", "alias-id");
    check(resolved["light"]["highlight"] == builtins[0]["light"]["highlight"], "alias-ignores-override");

    // 没有覆盖时与出厂数据完全一致。
    gw::Json plain = {{"candidateTheme", "grok"}};
    check(gw::effectiveBuiltinThemes(plain) == builtins, "no-override-identity");

    if (failures == 0) {
        std::printf("windows theme fixture: effective builtin themes and resolvedTheme passed\n");
        return 0;
    }
    std::printf("windows theme fixture: %d failures\n", failures);
    return 1;
}
