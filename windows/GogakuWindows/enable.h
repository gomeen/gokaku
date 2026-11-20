#pragma once
/* 用户级启用（HKCU 输入法列表）的最小接缝。
 *
 * 检测与启用都不依赖 UI、网络或共享核心，所以安装器静默调用、设置页按钮和
 * 自检程序用的是同一份实现（enable.cpp）。调用方必须已以「原用户身份」运行。
 */
#include <string>

namespace gw {

/* enableProfile 的失败码；0 为成功（含「已启用，未写入」的幂等路径）。 */
inline constexpr long kEnableInvalidIdentity = -1; // 条目串为空：身份没拼出来
inline constexpr long kEnableUnavailable = -2;     // input.dll 或 InstallLayoutOrTip 不可用
inline constexpr long kEnableRejected = -3;        // 系统拒绝了这次启用

/* 枚举 HKCU\User Profile 下所有语言子键，判断本条目是否已在输入法列表里。 */
bool profileEnabled(const std::wstring &tip);

/* 已包含 → 直接返回 0；否则单次调用 InstallLayoutOrTip(tip, 0)。
 * 不设默认输入法、不改其它条目、失败不重试。 */
long enableProfile(const std::wstring &tip);

/* 用共享身份头拼出本通道条目串再启用。 */
long enableProfile();

} // namespace gw
