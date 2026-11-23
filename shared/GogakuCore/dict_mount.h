/* 扩展词库内部挂载实现（不出 ABI、不导出）。
 * GcDictHandle 与共享挂载逻辑住在这里；普通会话（normal_session.cpp）与
 * 学习会话（learning_session.cpp）经 dict_mount_apply 共用同一份挂载规则，
 * 见 docs/dictionaries.md §四。平台代码不得直接包含本头文件。 */
#ifndef GOGAKU_DICT_MOUNT_H
#define GOGAKU_DICT_MOUNT_H

#include <libime/pinyin/pinyindictionary.h>

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace gogaku {
struct DictSlot {
    std::string id;    // 已挂载词库 id；空串表示占位空槽（可复用）
    bool disabled = true;
    uint64_t sizeBytes = 0;
};

/* 学习会话挂载阈值（docs/dictionaries.md §四；常量集中在核心一处）。
 * 单本 ≤ 8MiB，且按挂载顺序（调用方传入的 ids 顺序）累计 ≤ 16MiB。 */
inline constexpr uint64_t kLearningPerDictMax = 8ull * 1024 * 1024;
inline constexpr uint64_t kLearningTotalMax = 16ull * 1024 * 1024;
}  // namespace gogaku

/* 已解析词库句柄（全局作用域：C ABI 的 GcDictHandle 与这是同一个类型）。
 * ABI 上不透明；非空句柄交给 gc_normal_dicts_apply／gc_learning_dicts_apply
 * 后一律由核心释放（含因学习阈值未挂载的），未移交的句柄用
 * gc_dict_handle_free 释放。sizeBytes 供学习阈值记账。 */
struct GcDictHandle {
    std::string id;
    uint64_t sizeBytes = 0;
    libime::PinyinDictionary::TrieType trie;
};

namespace gogaku {
/* 把完整目标集合应用到 dict（槽位从 2 起；0 出厂、1 用户词）。
 * wanted[i].second == NULL：保留该 id 现状（大小沿用旧值）；
 * 非 NULL：移入 trie（所有权转移，句柄随后由调用方 delete），即使该 id
 * 已在槽上也整体替换。consumed 收集被吞掉的 wanted 下标。
 * 尾部空槽 removeFrom 收掉；中间移除用空 trie＋Disabled 占位。
 * 返回 0 成功；2 libime 异常（槽位状态保持可复用的占位形态）。 */
int dict_mount_apply(libime::PinyinDictionary &dict,
                     std::vector<DictSlot> &state,
                     const std::vector<std::pair<std::string, ::GcDictHandle *>> &wanted,
                     std::vector<size_t> &consumed);

}  // namespace gogaku
#endif
