#pragma once
#include "platform.h"

namespace gw {
// Posted to the settings owner when the in-memory view state changes.
inline constexpr UINT UpdateStateMessage = WM_APP + 0x470;

struct UpdateViewState {
    std::wstring current, status, preferenceError, lastAutoAttempt;
    bool enabled = false, automatic = false, busy = false, canDownload = false, canInstall = false,
        canCancel = false, hasNotes = false;
};
enum class UpdateAction { Check, Download, Install, Cancel, ShowNotes };

// All UI calls run on the settings thread. The hidden controller/timer has no
// lifetime outside this window; worker threads only post completed results.
void startUpdateController(HWND owner, HINSTANCE instance);
void stopUpdateController();
UpdateViewState updateViewState();
void performUpdateAction(UpdateAction action);
void setUpdateAutoCheck(bool enabled);
}
