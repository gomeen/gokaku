// Win32 inputs to the production TSF callbacks in the offline probe.
#pragma once
#include "../windows/GogakuTsf/src/stdafx.h"
#include <appmodel.h>

HWND WINAPI probeForegroundWindow();
DWORD WINAPI probeWindowThreadProcessId(HWND, LPDWORD);
SHORT WINAPI probeKeyState(int);
ULONGLONG WINAPI probeTickCount();
int WINAPI probeToUnicode(UINT, UINT, const BYTE *, LPWSTR, int, UINT, HKL);
LONG WINAPI probeAppUserModelId(HANDLE, UINT32 *, PWSTR);

#define GetForegroundWindow probeForegroundWindow
#define GetWindowThreadProcessId probeWindowThreadProcessId
#define GetKeyState probeKeyState
#define GetTickCount64 probeTickCount
#define ToUnicodeEx probeToUnicode
#define GetApplicationUserModelId probeAppUserModelId
