#pragma once
#include "platform.h"
#include <algorithm>

namespace gw {
// 核心普通快照：caret 是 UTF-8 字节，prefix 是标量；位图帧统一用 UTF-16。
// 只转换坐标单位，不推断光标位置或改写预编辑内容。
inline Json panelPreeditOffsets(const std::string &preedit, int64_t byteCaret, int64_t scalarPrefix) {
    int64_t caret = -1;
    if (byteCaret >= 0 && uint64_t(byteCaret) <= preedit.size() &&
        (size_t(byteCaret) == preedit.size() || (uint8_t(preedit[size_t(byteCaret)]) & 0xc0) != 0x80))
        caret = int64_t(wide(preedit.substr(0, size_t(byteCaret))).size());
    const auto utf16 = wide(preedit);
    size_t prefix = 0;
    for (int64_t n = 0; n < scalarPrefix && prefix < utf16.size(); ++n) {
        const auto c = uint16_t(utf16[prefix++]);
        if (c >= 0xd800 && c <= 0xdbff && prefix < utf16.size() &&
            uint16_t(utf16[prefix]) >= 0xdc00 && uint16_t(utf16[prefix]) <= 0xdfff) ++prefix;
    }
    return {{"preeditCaretUTF16", caret}, {"typedPrefixUTF16", prefix}};
}
} // namespace gw
