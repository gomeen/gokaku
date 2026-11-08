#include "gogaku_core.h"
#include <cstdint>
#include <string>

// 共享核心骨架：本阶段只固化 ABI 版本合同与 UTF-8 标量计数；
// 组合、调度、记录等规则在 G1 按事件轨迹逐模块迁入，不在此提前设计。
namespace {

// 返回 continues 的字节数；非法返回 0。
unsigned sequence_length(unsigned char lead) {
    if (lead < 0x80) return 1;
    if ((lead & 0xE0) == 0xC0) return 2;
    if ((lead & 0xF0) == 0xE0) return 3;
    if ((lead & 0xF8) == 0xF0) return 4;
    return 0;
}

}  // namespace

extern "C" int32_t gc_abi_version(void) { return GOGAKU_CORE_ABI_VERSION; }

extern "C" int32_t gc_abi_check(int32_t expected) {
    return expected == GOGAKU_CORE_ABI_VERSION ? 0 : 1;
}

extern "C" int64_t gc_utf8_scalar_count(const char *text, size_t length) {
    if (text == nullptr) return length == 0 ? 0 : -1;
    int64_t count = 0;
    size_t i = 0;
    while (i < length) {
        const auto lead = static_cast<unsigned char>(text[i]);
        const unsigned size = sequence_length(lead);
        if (size == 0 || i + size > length) return -1;
        for (unsigned n = 1; n < size; ++n) {
            if ((static_cast<unsigned char>(text[i + n]) & 0xC0) != 0x80) return -1;
        }
        // 排除超长编码与代理区。
        if (size == 2 && lead < 0xC2) return -1;
        if (size == 3 && lead == 0xE0 && static_cast<unsigned char>(text[i + 1]) < 0xA0) return -1;
        if (size == 3 && lead == 0xED && static_cast<unsigned char>(text[i + 1]) > 0x9F) return -1;
        if (size == 4 && lead == 0xF0 && static_cast<unsigned char>(text[i + 1]) < 0x90) return -1;
        if (size == 4 && lead == 0xF4 && static_cast<unsigned char>(text[i + 1]) > 0x8F) return -1;
        i += size;
        ++count;
    }
    return count;
}
