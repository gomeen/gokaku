#pragma once
#include "platform.h"

namespace gw {
// Posted only to the settings owner. wParam: nonzero = available, zero = cleared;
// lParam is unused. Receiving this message must not show or activate a window.
inline constexpr UINT UpdateAvailableMessage = WM_APP + 0x470;

// Call on the settings UI thread with its main window; starts only the hidden
// controller/timer. Manual checks still open the separate showUpdateWindow UI.
void startUpdateController(HWND owner, HINSTANCE instance);
}
