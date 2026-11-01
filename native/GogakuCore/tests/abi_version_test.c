/* 同一测试文件稍后也在 Windows（MSVC 加载 Clang64 DLL）构建运行；只用 C 标准库。 */
#include "gogaku_core.h"
#include <stdio.h>
#include <string.h>

static int failures = 0;

static void expect(const char *what, long long got, long long want) {
    if (got != want) {
        printf("FAIL %s: got %lld want %lld\n", what, got, want);
        ++failures;
    }
}

int main(void) {
    expect("abi_version", gc_abi_version(), GOGAKU_CORE_ABI_VERSION);
    expect("abi_check_same", gc_abi_check(GOGAKU_CORE_ABI_VERSION), 0);
    expect("abi_check_wrong", gc_abi_check(GOGAKU_CORE_ABI_VERSION + 1), 1);
    expect("abi_check_zero", gc_abi_check(0), 1);

    expect("empty", gc_utf8_scalar_count("", 0), 0);
    expect("null_zero", gc_utf8_scalar_count(NULL, 0), 0);
    expect("null_len", gc_utf8_scalar_count(NULL, 1), -1);
    expect("ascii", gc_utf8_scalar_count("nihc", 4), 4);
    /* 长度截断：只统计给定字节内的完整标量，尾部不完整序列非法。 */
    expect("length_truncates", gc_utf8_scalar_count("nihc\0xx", 4), 4);
    expect("chinese", gc_utf8_scalar_count("你好", 6), 2);
    expect("emoji", gc_utf8_scalar_count("\xF0\x9F\x98\x80", 4), 1);
    expect("mixed", gc_utf8_scalar_count("aä中\xF0\x9F\x98\x80", 1 + 2 + 3 + 4), 4);
    expect("invalid_lead", gc_utf8_scalar_count("\xFF", 1), -1);
    expect("invalid_continuation", gc_utf8_scalar_count("\xC3\x41", 2), -1);
    expect("overlong", gc_utf8_scalar_count("\xC0\x80", 2), -1);
    expect("surrogate", gc_utf8_scalar_count("\xED\xA0\x80", 3), -1);
    expect("truncated_tail", gc_utf8_scalar_count("你好", 5), -1);
    /* 明确的 UTF-16 范围不属于本 ABI：表情在标量计数下是 1，不是 UTF-16 的 2。 */
    expect("scalar_not_utf16", gc_utf8_scalar_count("\xF0\x9F\x98\x80", 4), 1);

    if (failures == 0) {
        printf("gogaku_core abi test: all passed\n");
        return 0;
    }
    printf("gogaku_core abi test: %d failures\n", failures);
    return 1;
}
