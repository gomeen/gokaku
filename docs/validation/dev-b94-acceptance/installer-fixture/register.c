#define UNICODE
#define _UNICODE
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <wchar.h>
#include <stdio.h>

static HMODULE instance;
static const wchar_t clsid_key[] = L"Software\\Classes\\CLSID\\{B74D13D2-0952-4B54-B124-671170C7A295}";
#ifdef _WIN64
#define ARCH L"x64"
#define VIEW KEY_WOW64_64KEY
#else
#define ARCH L"x86"
#define VIEW KEY_WOW64_32KEY
#endif

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) { instance = module; DisableThreadLibraryCalls(module); }
    return TRUE;
}

static BOOL parent(wchar_t *path) {
    wchar_t *separator = wcsrchr(path, L'\\');
    if (!separator) return FALSE;
    *separator = 0; return TRUE;
}

static BOOL locations(wchar_t *module, wchar_t *payload, wchar_t *root) {
    DWORD length = GetModuleFileNameW(instance, module, 32768);
    if (!length || length >= 32768) return FALSE;
    wcscpy(payload, module);
    for (int i = 0; i < 3; ++i) if (!parent(payload)) return FALSE;
    wcscpy(root, payload);
    return parent(root) && parent(root);
}

static void record(const wchar_t *root, const wchar_t *operation,
                   const wchar_t *module, HRESULT result, BOOL injected) {
    wchar_t path[32768], line[34000];
    char encoded[136000];
    SYSTEMTIME time; DWORD written;
    if (wcslen(root) + 32 >= 32768) return;
    swprintf(path, 32768, L"%ls\\fixture-register.log", root);
    GetSystemTime(&time);
    int count = swprintf(line, 34000,
        L"%04u-%02u-%02uT%02u:%02u:%02u.%03uZ\tpid=%lu\tarch=%ls\top=%ls\thr=0x%08lX\tinjected=%u\tmodule=%ls\r\n",
        time.wYear,time.wMonth,time.wDay,time.wHour,time.wMinute,time.wSecond,time.wMilliseconds,
        (unsigned long)GetCurrentProcessId(),ARCH,operation,(unsigned long)result,(unsigned)injected,module);
    if (count <= 0) return;
    int bytes = WideCharToMultiByte(CP_UTF8,0,line,count,encoded,sizeof(encoded),NULL,NULL);
    if (!bytes) return;
    HANDLE file = CreateFileW(path,FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
                              NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile(file,encoded,(DWORD)bytes,&written,NULL); FlushFileBuffers(file); CloseHandle(file);
}

static HRESULT set_registration(const wchar_t *module) {
    wchar_t key[256]; HKEY handle;
    swprintf(key,256,L"%ls\\InprocServer32",clsid_key);
    LSTATUS status = RegCreateKeyExW(HKEY_LOCAL_MACHINE,key,0,NULL,0,KEY_SET_VALUE|VIEW,NULL,&handle,NULL);
    if (status != ERROR_SUCCESS) return HRESULT_FROM_WIN32(status);
    status = RegSetValueExW(handle,NULL,0,REG_SZ,(const BYTE *)module,(DWORD)((wcslen(module)+1)*sizeof(wchar_t)));
    if (status == ERROR_SUCCESS) {
        const wchar_t model[] = L"Apartment";
        status = RegSetValueExW(handle,L"ThreadingModel",0,REG_SZ,(const BYTE *)model,sizeof(model));
    }
    RegCloseKey(handle);
    return status == ERROR_SUCCESS ? S_OK : HRESULT_FROM_WIN32(status);
}

HRESULT __stdcall DllRegisterServer(void) {
    wchar_t module[32768],payload[32768],root[32768],flag[32768];
    if (!locations(module,payload,root)) return E_FAIL;
    HRESULT result = set_registration(module); BOOL injected = FALSE;
    if (SUCCEEDED(result) && wcslen(payload) + 40 < 32768) {
        swprintf(flag,32768,L"%ls\\data\\fail-register-%ls.flag",payload,ARCH);
        DWORD attributes = GetFileAttributesW(flag);
        if (attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
            injected = TRUE; result = E_FAIL;
        }
    }
    record(root,L"register",module,result,injected);
    return result;
}

HRESULT __stdcall DllUnregisterServer(void) {
    wchar_t module[32768],payload[32768],root[32768],key[256];
    if (!locations(module,payload,root)) return E_FAIL;
    swprintf(key,256,L"%ls\\InprocServer32",clsid_key);
    LSTATUS first = RegDeleteKeyExW(HKEY_LOCAL_MACHINE,key,VIEW,0);
    LSTATUS second = RegDeleteKeyExW(HKEY_LOCAL_MACHINE,clsid_key,VIEW,0);
    HRESULT result = S_OK;
    if (first != ERROR_SUCCESS && first != ERROR_FILE_NOT_FOUND) result = HRESULT_FROM_WIN32(first);
    else if (second != ERROR_SUCCESS && second != ERROR_FILE_NOT_FOUND) result = HRESULT_FROM_WIN32(second);
    record(root,L"unregister",module,result,FALSE);
    return result;
}
