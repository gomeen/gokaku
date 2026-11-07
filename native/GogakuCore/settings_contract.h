/* 设置契约（读侧规范化）的共享声明。
 *
 * 实现在 settings_contract.cpp；行为向量在 tests/settings_contract_test.cpp，
 * 两端跑同一份源码。本头文件是唯一声明处，gogaku_core.h 包含它；
 * Windows 平台进程（含 x86 TSF）以 GOGAKU_SETTINGS_CONTRACT_STATIC
 * 把实现直接编进自身——x86 TSF 无法加载 x64 核心 DLL。
 */
#ifndef GOGAKU_SETTINGS_CONTRACT_H
#define GOGAKU_SETTINGS_CONTRACT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GC_SETTINGS_SCHEMA_VERSION 2

/* 导出归属：
 * - GOGAKU_SETTINGS_CONTRACT_STATIC：直接编入 Windows 平台二进制，不导出；
 * - 已定义 GOGAKU_CORE_EXPORT（含 gogaku_core.h）：沿用其导入／导出归属；
 * - 直接编译本文件且未含 gogaku_core.h：按核心构建规则推导（仅核心自身）。 */
#if defined(GOGAKU_SETTINGS_CONTRACT_STATIC)
#  define GC_SETTINGS_CONTRACT_EXPORT
#elif defined(GOGAKU_CORE_EXPORT)
#  define GC_SETTINGS_CONTRACT_EXPORT GOGAKU_CORE_EXPORT
#elif defined(_WIN32) && defined(GOGAKU_CORE_BUILDING)
#  define GC_SETTINGS_CONTRACT_EXPORT __declspec(dllexport)
#elif defined(GOGAKU_CORE_BUILDING)
#  define GC_SETTINGS_CONTRACT_EXPORT __attribute__((visibility("default")))
#else
#  error "gc_settings_normalize 声明需要先包含 gogaku_core.h，或定义 GOGAKU_SETTINGS_CONTRACT_STATIC"
#endif

/* raw/raw_len 为磁盘原始字节；raw 为 NULL 且 raw_len==0 时按空对象规范化。
 * 成功时 *out 为库内分配的 NUL 结尾 UTF-8 规范 JSON，用 gc_contract_free 释放。
 * migrated 可为 NULL；非 NULL 时写入 1 表示读到的数据确实需要迁移。
 * appDefaultEnglish 在输入里缺键时不写入结果，由平台补自己的出厂清单；
 * 输入里是空数组时原样保留（用户删光了应用，不得复活）。
 * 返回 0 成功；1 参数错误；2 不是 JSON 对象；4 内存不足；
 * 5 内部错误（异常已被拦下，不跨 ABI）。 */
GC_SETTINGS_CONTRACT_EXPORT int32_t gc_settings_normalize(const char *raw, size_t raw_len,
                                                          char **out, size_t *out_len,
                                                          int32_t *migrated);
GC_SETTINGS_CONTRACT_EXPORT void gc_contract_free(void *buffer);

#ifdef __cplusplus
}
#endif
#endif
