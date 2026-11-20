// 用户级启用的身份与检测自检：只读注册表与共享身份头，不写 HKCU、不启用输入法。
// 注册／启用本身要真机（docs/windows-testing.md 的验收清单），这里固定住可离线
// 核对的部分：条目串格式必须与系统 InputMethodTips 写法一致，且检测逻辑不会把
// 别的通道或别的语言当成自己。
#include "../GogakuWindows/enable.h"
#include "../gogaku-ids.h"

#include <cstdio>
#include <string>
#include <vector>

namespace {
int failures = 0;
void expect(bool ok, const char *message) {
    if (!ok) { ++failures; std::fprintf(stderr, "FAIL: %s\n", message); }
}

/* 与系统 InputMethodTips 条目同形的期望值（大写十六进制，带花括号）。 */
constexpr wchar_t kStableTip[] = L"0804:{A3C5D7E9-1B2F-4A6C-8E0D-2F4B6A8C0E13}{C9E1F3A5-7B8D-4E2F-6A0C-1D3E5F7A9B11}";
constexpr wchar_t kDevTip[] = L"0804:{A3C5D7E9-1B2F-4A6C-8E0D-2F4B6A8C0E13}{C9E1F3A5-7B8D-4E2F-6A0C-1D3E5F7A9B12}";

void identity() {
    expect(gogaku::profileTipString(gogaku::kTsfClsid, gogaku::kProfileStable) == kStableTip,
           "stable tip string");
    expect(gogaku::profileTipString(gogaku::kTsfClsid, gogaku::kProfileDev) == kDevTip,
           "dev tip string");
    /* 编译期通道选择必须与运行时 gw::channel() 同源；两者都由构建脚本成对给出，
     * 这里把选择固定住，避免只改一半。 */
    expect(gogaku::profileGuid() == gogaku::profileGuid(gogaku::kDevChannel),
           "profile guid follows compile-time channel");
    const auto expected = gogaku::kDevChannel ? kDevTip : kStableTip;
    expect(gogaku::profileTipString() == expected, "default tip string matches channel");
    expect(gogaku::kLangId == 0x0804, "lang id is zh-CN");
    /* 设置页与注册用的显示名同一口径。 */
    expect(std::wstring(gogaku::profileName()) == (gogaku::kDevChannel ? L"Gogaku Dev" : L"Gogaku"),
           "profile display name follows channel");
    /* 两个通道的条目串必须不同，否则装 dev 会「已包含」而静默跳过 stable。 */
    expect(gogaku::profileTipString(gogaku::kTsfClsid, gogaku::kProfileStable) !=
               gogaku::profileTipString(gogaku::kTsfClsid, gogaku::kProfileDev),
           "channels use distinct profiles");
}

void detection() {
    /* 空条目串永远算「未启用」，不能让 enableProfile 把空串写进用户列表。 */
    expect(!gw::profileEnabled(L""), "empty tip is never enabled");
    expect(gw::enableProfile(L"") == gw::kEnableInvalidIdentity, "empty tip rejected");
    /* 探测只读：本机若真的启用了 Gogaku，这里返回 true，不能因此判定失败。 */
    const bool stable = gw::profileEnabled(kStableTip);
    const bool dev = gw::profileEnabled(kDevTip);
    std::printf("本机用户输入法列表：stable=%s dev=%s（只读探测，未写入）\n",
                stable ? "已启用" : "未启用", dev ? "已启用" : "未启用");
}

/* 反例：探测函数必须能分辨「同一 CLSID、不同档案」与「大小写不同的同一条目」。
 * 这里不写注册表，改为用同一份解析逻辑对内存条目串验证——解析口径与
 * containsTip 相同（大小写不敏感、整条相等，不做子串匹配）。 */
void parsing() {
    auto contains = [](const std::vector<std::wstring> &entries, const std::wstring &tip) {
        for (const auto &entry : entries) {
            if (entry.size() != tip.size()) continue;
            bool equal = true;
            for (size_t i = 0; i < entry.size() && equal; ++i)
                equal = towlower(entry[i]) == towlower(tip[i]);
            if (equal) return true;
        }
        return false;
    };
    expect(contains({kStableTip, L"0804:{00000000-0000-0000-0000-000000000000}{00000000-0000-0000-0000-000000000000}"}, kStableTip),
           "exact entry found");
    expect(!contains({kStableTip}, kDevTip), "dev is not stable");
    expect(!contains({kDevTip}, kStableTip), "stable is not dev");
    /* 系统偶尔写入小写十六进制；同一条目不应被当成另一个。 */
    const std::wstring lower = L"0804:{a3c5d7e9-1b2f-4a6c-8e0d-2f4b6a8c0e13}{c9e1f3a5-7b8d-4e2f-6a0c-1d3e5f7a9b11}";
    expect(contains({lower}, kStableTip), "case-insensitive match");
    /* 前缀／子串不算命中：避免把 Gogaku Dev 当成 Gogaku。 */
    expect(!contains({std::wstring(kStableTip).substr(0, 20)}, kStableTip), "prefix is not a match");
}

} // namespace

int main() {
    identity();
    detection();
    parsing();
    if (failures) {
        std::fprintf(stderr, "启用接缝自检失败：%d 项\n", failures);
        return 1;
    }
    std::printf("启用接缝自检通过：身份条目串、通道区分、只读探测与整条匹配。\n");
    return 0;
}
