/* Gogaku TSF——COM 入口与注册。
 * regsvr32 注册：CLSID + CTF TIP + zh-CN 语言档案 + 键盘类别。
 * 卸载（regsvr32 /u）对称移除；只动 Gogaku 自己的键，不碰其他输入法。
 */
#include "stdafx.h"
#include "text_service.h"

#include <string>

HINSTANCE g_hInst = nullptr;

static long g_locks = 0;
static long g_objects = 0;

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID /*reserved*/) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_hInst = (HINSTANCE)module;
        DisableThreadLibraryCalls((HMODULE)module);
    }
    return TRUE;
}

/* ---------- 类厂 ---------- */

class ClassFactory final : public IClassFactory {
public:
    STDMETHODIMP QueryInterface(REFIID riid, void **ppv) override {
        if (!ppv) return E_INVALIDARG;
        if (riid == IID_IUnknown || riid == IID_IClassFactory) {
            *ppv = (IClassFactory *)this;
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&m_ref); }
    STDMETHODIMP_(ULONG) Release() override {
        long r = InterlockedDecrement(&m_ref);
        if (r == 0) delete this;
        return r;
    }
    STDMETHODIMP CreateInstance(IUnknown *outer, REFIID riid, void **ppv) override {
        if (!ppv) return E_INVALIDARG;
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        TextService *svc = new TextService();
        HRESULT hr = svc->QueryInterface(riid, ppv);
        svc->Release();
        return hr;
    }
    STDMETHODIMP LockServer(BOOL lock) override {
        if (lock) InterlockedIncrement(&g_locks);
        else InterlockedDecrement(&g_locks);
        return S_OK;
    }

private:
    long m_ref = 1;
};

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void **ppv) {
    if (!ppv) return E_INVALIDARG;
    *ppv = nullptr;
    if (rclsid != CLSID_GogakuTsf) return CLASS_E_CLASSNOTAVAILABLE;
    ClassFactory *factory = new ClassFactory();
    HRESULT hr = factory->QueryInterface(riid, ppv);
    factory->Release();
    return hr;
}

STDAPI DllCanUnloadNow(void) {
    return (g_objects == 0 && g_locks == 0) ? S_OK : S_FALSE;
}

/* ---------- 注册表 ---------- */

static std::wstring guid_to_wstring(REFGUID guid) {
    wchar_t buf[64] = {};
    StringFromGUID2(guid, buf, 64);
    return buf;
}

static LONG create_key_value(HKEY root, const std::wstring &path, const std::wstring &name,
                             const std::wstring &value, DWORD dwordValue = 0,
                             bool isDword = false) {
    HKEY key = nullptr;
    LONG rc = RegCreateKeyExW(root, path.c_str(), 0, nullptr,
                              REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &key, nullptr);
    if (rc != ERROR_SUCCESS) return rc;
    if (isDword) {
        DWORD v = dwordValue;
        rc = RegSetValueExW(key, name.c_str(), 0, REG_DWORD, (const BYTE *)&v, sizeof(v));
    } else {
        rc = RegSetValueExW(key, name.c_str(), 0, REG_SZ,
                            (const BYTE *)value.c_str(),
                            (DWORD)((value.size() + 1) * sizeof(wchar_t)));
    }
    RegCloseKey(key);
    return rc;
}

STDAPI DllRegisterServer(void) {
    wchar_t modulePath[MAX_PATH] = {};
    GetModuleFileNameW(g_hInst, modulePath, MAX_PATH);
    const std::wstring clsidStr = guid_to_wstring(CLSID_GogakuTsf);
    const std::wstring profileStr = guid_to_wstring(GUID_GOGAKU_PROFILE);
    const std::wstring clsidPath = L"CLSID\\" + clsidStr;
    const std::wstring tipPath = L"SOFTWARE\\Microsoft\\CTF\\TIP\\" + clsidStr;
    const std::wstring langPath = tipPath + L"\\LanguageProfile\\0x00000804\\" + profileStr;
    // GUID_TFCAT_TIP_KEYBOARD：键盘类输入法（Win+Space 列表依据）。
    const std::wstring catKeyboard = L"SOFTWARE\\Microsoft\\CTF\\TIP\\" + clsidStr +
                                     L"\\Category\\{34745CFF-B52F-41FC-AAC2-DA6C280D7693}";

    HRESULT hr = S_OK;
    do {
        if (create_key_value(HKEY_CLASSES_ROOT, clsidPath, L"", L"Gogaku") != ERROR_SUCCESS ||
            create_key_value(HKEY_CLASSES_ROOT, clsidPath + L"\\InprocServer32", L"", modulePath) != ERROR_SUCCESS ||
            create_key_value(HKEY_CLASSES_ROOT, clsidPath + L"\\InprocServer32",
                             L"ThreadingModel", L"Apartment") != ERROR_SUCCESS) {
            hr = SELFREG_E_CLASS; break;
        }
        // TIP 主键与语言档案（zh-CN = 0x00000804）。
        if (create_key_value(HKEY_LOCAL_MACHINE, langPath, L"", L"Gogaku") != ERROR_SUCCESS ||
            create_key_value(HKEY_LOCAL_MACHINE, langPath, L"Enable", L"", 1, true) != ERROR_SUCCESS ||
            create_key_value(HKEY_LOCAL_MACHINE, langPath, L"Display Description",
                             L"Gogaku 拼音输入法") != ERROR_SUCCESS) {
            hr = SELFREG_E_CLASS; break;
        }
        // 类别登记：键盘类 TIP。
        if (create_key_value(HKEY_LOCAL_MACHINE, catKeyboard + L"\\" + profileStr, L"", L"") != ERROR_SUCCESS) {
            hr = SELFREG_E_CLASS; break;
        }
    } while (false);
    return hr;
}

static LONG delete_tree(HKEY root, const std::wstring &path) {
    // 先删子键再删自身（RegDeleteTreeW Win Vista+ 可用，直接用）。
    return RegDeleteTreeW(root, path.c_str());
}

STDAPI DllUnregisterServer(void) {
    const std::wstring clsidStr = guid_to_wstring(CLSID_GogakuTsf);
    const std::wstring profileStr = guid_to_wstring(GUID_GOGAKU_PROFILE);
    delete_tree(HKEY_LOCAL_MACHINE,
                L"SOFTWARE\\Microsoft\\CTF\\TIP\\" + clsidStr + L"\\LanguageProfile\\0x00000804\\" + profileStr);
    delete_tree(HKEY_LOCAL_MACHINE,
                L"SOFTWARE\\Microsoft\\CTF\\TIP\\" + clsidStr + L"\\Category\\{34745CFF-B52F-41FC-AAC2-DA6C280D7693}");
    delete_tree(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\CTF\\TIP\\" + clsidStr);
    delete_tree(HKEY_CLASSES_ROOT, L"CLSID\\" + clsidStr);
    return S_OK;
}
