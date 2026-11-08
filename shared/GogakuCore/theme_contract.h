/* 内置主题契约（调色板与排版的单一数据源）的共享声明。
 *
 * 实现在 theme_contract.cpp；行为向量在 tests/theme_contract_test.cpp，
 * 两端跑同一份源码。声明只此一处，gogaku_core.h 包含它；Windows 平台
 * 进程以 GOGAKU_SETTINGS_CONTRACT_STATIC 把实现直接编进自身，
 * 归属规则与 settings_contract.h 相同。
 */
#ifndef GOGAKU_THEME_CONTRACT_H
#define GOGAKU_THEME_CONTRACT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(GOGAKU_SETTINGS_CONTRACT_STATIC)
#  define GC_THEME_CONTRACT_EXPORT
#elif defined(GOGAKU_CORE_EXPORT)
#  define GC_THEME_CONTRACT_EXPORT GOGAKU_CORE_EXPORT
#elif defined(_WIN32) && defined(GOGAKU_CORE_BUILDING)
#  define GC_THEME_CONTRACT_EXPORT __declspec(dllexport)
#elif defined(GOGAKU_CORE_BUILDING)
#  define GC_THEME_CONTRACT_EXPORT __attribute__((visibility("default")))
#else
#  error "gc_themes_builtin 声明需要先包含 gogaku_core.h，或定义 GOGAKU_SETTINGS_CONTRACT_STATIC"
#endif

/* 输出四套内置主题（gogaku、claude、grok、witch）的规范 JSON 数组，形状
 * 与两端消费的主题对象一致：[{id, name, light: {10 个语义色＋visual},
 * dark?: 同 light, typography: {fontCN, fontEN, fontSize, indexSize}}]。
 * rime-macos-like 不在数组内，两端各自把它别名到数组首项并覆盖 id。
 * 成功时 *out 为库内分配的 NUL 结尾 UTF-8，用 gc_contract_free 释放。
 * 返回 0 成功；1 参数错误；4 内存不足；5 内部错误（不跨 ABI 抛异常）。 */
GC_THEME_CONTRACT_EXPORT int32_t gc_themes_builtin(char **out, size_t *out_len);

#ifdef __cplusplus
}
#endif
#endif
