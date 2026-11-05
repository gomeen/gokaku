/* Gogaku TSF——COM 入口与注册。
 * regsvr32 注册：CLSID + CTF TIP + zh-CN 语言档案 + 键盘类别。
 * 卸载（regsvr32 /u）对称移除；只动 Gogaku 自己的键，不碰其他输入法。
 */
#include "stdafx.h"
#include "text_service.h"

#include <string>
#include <olectl.h>

HINSTANCE g_hInst = nullptr;

/* {A3C5D7E9-1B2F-4A6C-8E0D-2F4B6A8C0E12} */
const GUID CLSID_GogakuTsf = {
    0xA3C5D7E9, 0x1B2F, 0x4A6C, {0x8E, 0x0D, 0x2F, 0x4B, 0x6A, 0x8C, 0x0E, 0x12}};
/* {C9E1F3A5-7B8D-4E2F-6A0C-1D3E5F7A9B11}（zh-CN 语言档案） */
const GUID GUID_GOGAKU_PROFILE = {
    0xC9E1F3A5, 0x7B8D, 0x4E2F, {0x6A, 0x0C, 0x1D, 0x3E, 0x5F, 0x7A, 0x9B, 0x11}};

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

/* 通过 TSF 自己的注册 API 落档案（Squirrel 同款路线）。
 * 手写 CTF 注册表键会被系统校验剔除（2026-11-06 实测），必须走 API。
 * 多 IID 探测：不同 Windows 版本的管理器接口 IID 不同，HRESULT 全部落日志。 */
static void register_profile_via_api(const std::wstring &modulePath) {
    HANDLE logf = CreateFileW(L"C:\\gogaku-test\\reg-api.log",
                              FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    auto log = [&](const wchar_t *msg, long hr) {
        if (!logf) return;
        wchar_t line[128] = {};
        swprintf_s(line, L"%s hr=0x%08X\r\n", msg, (unsigned)hr);
        DWORD written = 0;
        WriteFile(logf, line, (DWORD)(wcslen(line) * sizeof(wchar_t)), &written, nullptr);
    };

    ICatInformation *catInfo = nullptr; /* 未用；占位避免头文件差异 */

    GUID mgrClsid  = {0x33C53A50, 0xF456, 0x4884, {0xB0, 0x49, 0x85, 0xFD, 0x64, 0x3E, 0xCF, 0xED}};
    GUID mgrLegacy = {0x33C53A50, 0xF456, 0x11D1, {0xB6, 0x41, 0x00, 0xC0, 0x4F, 0xA3, 0x65, 0x47}};
    GUID mgrModern = {0x71C6E74C, 0x0F28, 0x11D8, {0xA8, 0x2A, 0x00, 0x06, 0x5B, 0x84, 0x43, 0x5C}};
    GUID mgrNewSdk = {0x1F02B6C5, 0x7842, 0x4EE6, {0x8A, 0x0B, 0x9A, 0x24, 0x18, 0x3A, 0x95, 0xCA}};

    IUnknown *unk = nullptr;
    HRESULT hr = CoCreateInstance(mgrClsid, nullptr, CLSCTX_INPROC_SERVER, IID_IUnknown, (void **)&unk);
    log(L"coclass-create", hr);
    if (FAILED(hr) || !unk) { if (logf) CloseHandle(logf); return; }
    {
        /* 服务聚合验证：TF_ThreadMgr coclass QI ProfileMgr（对照）。 */
        GUID threadMgrCls = {0x529A9E6B, 0x6587, 0x4F23, {0xAB, 0x9E, 0x9C, 0x7D, 0x68, 0x3E, 0x3C, 0x50}};
        IUnknown *tm = nullptr;
        HRESULT hrt = CoCreateInstance(threadMgrCls, nullptr, CLSCTX_INPROC_SERVER, IID_IUnknown, (void **)&tm);
        log(L"threadmgr-create", hrt);
        if (SUCCEEDED(hrt) && tm) {
            void *pm = nullptr;
            HRESULT hrq = tm->QueryInterface(mgrModern, &pm);
            log(L"threadmgr-qi-mgr", hrq);
            if (SUCCEEDED(hrq)) reinterpret_cast<IUnknown *>(pm)->Release();
            tm->Release();
        }
    }

    GUID clsid   = {0xA3C5D7E9, 0x1B2F, 0x4A6C, {0x8E, 0x0D, 0x2F, 0x4B, 0x6A, 0x8C, 0x0E, 0x12}};
    GUID profile = {0xC9E1F3A5, 0x7B8D, 0x4E2F, {0x6A, 0x0C, 0x1D, 0x3E, 0x5F, 0x7A, 0x9B, 0x11}};
    const WORD langid = 0x0804;

    /* 前置：老接口 Register(clsid) 登记 TIP（管理器 RegisterProfile 的前提）。 */
    {
        void *pold = nullptr;
        hr = unk->QueryInterface(mgrLegacy, &pold);
        log(L"qi-legacy-11D1", hr);
        if (SUCCEEDED(hr) && pold) {
            struct RegVtbl {
                void *qi_addref_release[3];
                HRESULT (STDMETHODCALLTYPE *Register)(void *, GUID &);
            };
            void **vtbl = *reinterpret_cast<void ***>(pold);
            RegVtbl *r = reinterpret_cast<RegVtbl *>(vtbl);
            hr = r->Register(pold, clsid);
            log(L"old-Register", hr);
            reinterpret_cast<IUnknown *>(pold)->Release();
        }
    }

    /* 路线 A：ITfInputProcessorProfileMgr（RegisterProfile + ActivateProfile） */
    {
        void *pmgr = nullptr;
        hr = unk->QueryInterface(mgrModern, &pmgr);
        log(L"qi-profilemgr", hr);
        if (SUCCEEDED(hr) && pmgr) {
            /* vtable: ActivateProfile/DeactivateProfile/GetProfile/EnumProfiles/
             * ReleaseInputProcessor/RegisterProfile/UnregisterProfile/GetActiveProfile */
            struct MgrVtbl {
                HRESULT (STDMETHODCALLTYPE *ActivateProfile)(void *, DWORD, WORD, GUID &, GUID &, HKL, DWORD);
                HRESULT (STDMETHODCALLTYPE *DeactivateProfile)(void *, DWORD, WORD, GUID &, GUID &, HKL, DWORD);
                HRESULT (STDMETHODCALLTYPE *GetProfile)(void *, DWORD, WORD, GUID &, GUID &, HKL, void *);
                HRESULT (STDMETHODCALLTYPE *EnumProfiles)(void *, WORD, void **);
                HRESULT (STDMETHODCALLTYPE *ReleaseInputProcessor)(void *, GUID &, DWORD);
                HRESULT (STDMETHODCALLTYPE *RegisterProfile)(void *, GUID &, WORD, GUID &, const WCHAR *, ULONG, const WCHAR *, ULONG, ULONG, HKL, DWORD, BOOL, DWORD);
                HRESULT (STDMETHODCALLTYPE *UnregisterProfile)(void *, GUID &, WORD, GUID &, DWORD);
                HRESULT (STDMETHODCALLTYPE *GetActiveProfile)(void *, GUID &, void *);
            };
            void **vtbl = *reinterpret_cast<void ***>(pmgr);
            MgrVtbl *m = reinterpret_cast<MgrVtbl *>(vtbl);
            std::wstring desc = L"Gogaku 拼音输入法";
            /* cch 语义两派：先试含 NUL，再试不含；图标先 DLL 路径后空。全落日志。
             * 任一成功即激活并返回；全失败则落路线 B。 */
            /* 变体二分：图标（DLL 路径/无图标）、描述（含中文/纯 ASCII）。 */
            struct RpVar { const WCHAR *desc; ULONG cchDesc; const WCHAR *icon; ULONG cchFile; HKL hkl; const wchar_t *tag; };
            std::wstring asciiDesc = L"Gogaku";
            RpVar vars[4] = {
                /* HKL 0x08040804 = zh-CN 输入法布局句柄（系统对每个 zh TIP
                 * 都要求键盘布局关联，缺失会导致启用后被剔除——实测推断）。 */
                {desc.c_str(), (ULONG)(desc.size() + 1), nullptr, 0, (HKL)(ULONG_PTR)0x08040804, L"rp-hkl-cn"},
                {asciiDesc.c_str(), (ULONG)(asciiDesc.size() + 1), nullptr, 0, (HKL)(ULONG_PTR)0x08040804, L"rp-hkl-ascii"},
                {desc.c_str(), (ULONG)(desc.size() + 1), modulePath.c_str(), (ULONG)(modulePath.size() + 1),
                 (HKL)(ULONG_PTR)0x08040804, L"rp-hkl-icon"},
                {desc.c_str(), (ULONG)desc.size(), modulePath.c_str(), (ULONG)modulePath.size(),
                 nullptr, L"rp-icon-nonull"},
            };
            for (int vi = 0; vi < 4; vi++) {
                hr = m->RegisterProfile(pmgr, clsid, langid, profile, vars[vi].desc,
                                        vars[vi].cchDesc, vars[vi].icon, vars[vi].cchFile,
                                        0, vars[vi].hkl, 0, TRUE, 0);
                log(vars[vi].tag, hr);
                if (SUCCEEDED(hr)) break;
            }
            if (SUCCEEDED(hr)) {
                hr = m->ActivateProfile(pmgr, 0, langid, clsid, profile, nullptr, 0);
                log(L"mgr-ActivateProfile", hr);
                unk->Release();
                if (logf) CloseHandle(logf);
                return;
            }
            /* A2 路：TF_ThreadMgr 的 ProfileMgr 再试一次。 */
            {
                GUID threadMgrCls = {0x529A9E6B, 0x6587, 0x4F23, {0xAB, 0x9E, 0x9C, 0x7D, 0x68, 0x3E, 0x3C, 0x50}};
                IUnknown *tm = nullptr;
                HRESULT hrt = CoCreateInstance(threadMgrCls, nullptr, CLSCTX_INPROC_SERVER, IID_IUnknown, (void **)&tm);
                if (SUCCEEDED(hrt) && tm) {
                    void *pm2 = nullptr;
                    HRESULT hrq = tm->QueryInterface(mgrModern, &pm2);
                    log(L"a2-threadmgr-qi", hrq);
                    if (SUCCEEDED(hrq) && pm2) {
                        void **vt2 = *reinterpret_cast<void ***>(pm2);
                        MgrVtbl *m2 = reinterpret_cast<MgrVtbl *>(vt2);
                        for (int vi = 0; vi < 2; vi++) {
                            ULONG cd = vi == 0 ? (ULONG)(desc.size() + 1) : (ULONG)desc.size();
                            ULONG cf = vi == 0 ? (ULONG)(modulePath.size() + 1) : (ULONG)modulePath.size();
                            hr = m2->RegisterProfile(pm2, clsid, langid, profile, desc.c_str(),
                                                     cd, modulePath.c_str(), cf, 0, nullptr, 0, TRUE, 0);
                            log(vi == 0 ? L"a2-rp-null-inc" : L"a2-rp-no-null", hr);
                            if (SUCCEEDED(hr)) break;
                        }
                        if (SUCCEEDED(hr)) {
                            hr = m2->ActivateProfile(pm2, 0, langid, clsid, profile, nullptr, 0);
                            log(L"a2-ActivateProfile", hr);
                        }
                        reinterpret_cast<IUnknown *>(pm2)->Release();
                    }
                    tm->Release();
                }
            }
            unk->Release();  /* A 路全败，落 B 路（老接口） */
        }
    }

    /* 路线 B：老 ITfInputProcessorProfiles（Register/AddLanguageProfile/Enable） */
    {
        void *pold = nullptr;
        hr = unk->QueryInterface(mgrLegacy, &pold);
        log(L"qi-legacy-33C53A50-11D1", hr);
        if (SUCCEEDED(hr) && pold) {
            /* 老 SDK 布局（ReactOS/wine 同源）：Register/Unregister/AddLanguageProfile/
             * RemoveLanguageProfile/EnumInputProcessorInfo/GetDefaultLanguageProfile/
             * SetDefaultLanguageProfile/ActivateLanguageProfile/GetActiveLanguageProfile/
             * GetLanguageProfileDescription/GetLanguageList/EnumLanguageProfiles/
             * EnableLanguageProfile/IsEnabledLanguageProfile */
            struct OldVtbl {
                void *q[3];
                HRESULT (STDMETHODCALLTYPE *Register)(void *, GUID &);
                HRESULT (STDMETHODCALLTYPE *Unregister)(void *, GUID &);
                HRESULT (STDMETHODCALLTYPE *AddLanguageProfile)(void *, GUID &, WORD, GUID &, const WCHAR *, ULONG, const WCHAR *, ULONG, ULONG);
                HRESULT (STDMETHODCALLTYPE *RemoveLanguageProfile)(void *, GUID &, WORD, GUID &);
                void *enumInfo;
                void *getDefault;
                HRESULT (STDMETHODCALLTYPE *SetDefaultLanguageProfile)(void *, WORD, GUID &, GUID &);
                HRESULT (STDMETHODCALLTYPE *ActivateLanguageProfile)(void *, GUID &, WORD, GUID &);
                void *getActive;
                void *getDesc;
                void *getCurLang;
                void *changeLang;
                void *getLangList;
                void *enumLangProfiles;
                HRESULT (STDMETHODCALLTYPE *EnableLanguageProfile)(void *, GUID &, WORD, GUID &, BOOL);
                void *isEnabled;
            };
            void **vtbl = *reinterpret_cast<void ***>(pold);
            OldVtbl *o = reinterpret_cast<OldVtbl *>(vtbl);
            std::wstring desc = L"Gogaku 拼音输入法";
            hr = o->Register(pold, clsid);
            log(L"old-Register", hr);
            hr = o->AddLanguageProfile(pold, clsid, langid, profile, desc.c_str(),
                                       (ULONG)desc.size(), modulePath.c_str(),
                                       (ULONG)modulePath.size(), 0);
            log(L"old-AddLanguageProfile", hr);
            hr = o->EnableLanguageProfile(pold, clsid, langid, profile, TRUE);
            log(L"old-EnableLanguageProfile", hr);
            hr = o->SetDefaultLanguageProfile(pold, langid, clsid, profile);
            log(L"old-SetDefaultLanguageProfile", hr);
            unk->Release();
            if (logf) CloseHandle(logf);
            return;
        }
    }
    unk->Release();
    if (logf) CloseHandle(logf);
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
                                     L"\\Category\\{34745C63-B2F0-4784-8B67-5E12C8701A31}";

    HRESULT hr = S_OK;
    do {
        if (create_key_value(HKEY_CLASSES_ROOT, clsidPath, L"", L"Gogaku") != ERROR_SUCCESS ||
            create_key_value(HKEY_CLASSES_ROOT, clsidPath + L"\\InprocServer32", L"", modulePath) != ERROR_SUCCESS ||
            create_key_value(HKEY_CLASSES_ROOT, clsidPath + L"\\InprocServer32",
                             L"ThreadingModel", L"Apartment") != ERROR_SUCCESS) {
            hr = SELFREG_E_CLASS; break;
        }
        // TIP 主键与语言档案（zh-CN = 0x00000804）。
        // 结构镜像微软拼音（Windows 按此校验用户语言列表里的 TIP：缺 Description
        // 或类别布局不对会被静默剔除——2026-11-06 实测）。
        if (create_key_value(HKEY_LOCAL_MACHINE, langPath, L"", L"Gogaku") != ERROR_SUCCESS ||
            create_key_value(HKEY_LOCAL_MACHINE, langPath, L"Description", L"Gogaku") != ERROR_SUCCESS ||
            create_key_value(HKEY_LOCAL_MACHINE, langPath, L"Enable", L"", 1, true) != ERROR_SUCCESS ||
            create_key_value(HKEY_LOCAL_MACHINE, langPath, L"Display Description",
                             L"Gogaku 拼音输入法") != ERROR_SUCCESS) {
            hr = SELFREG_E_CLASS; break;
        }
        // 类别登记：键盘类 TIP。
        // 类别登记：镜像微软拼音的完整类别集（Category\Category\{类别}\{CLSID}）
        // ＋键盘类的传统布局。类别集合不全时 Windows 会把 TIP 从用户语言列表
        // 静默剔除（2026-11-06 实测）。
        const wchar_t *cats[] = {
            L"{046B8C80-1647-40F7-9B21-B93B81AABC1B}",
            L"{13A016DF-560B-46CD-947A-4C3AF1E0E35D}",
            L"{25504FB4-7BAB-4BC1-9C69-CF81890F0EF5}",
            L"{34745C63-B2F0-4784-8B67-5E12C8701A31}",
            L"{364215D9-75BC-11D7-A6EF-00065B84435C}",
            L"{3AF314A2-D79F-4B1B-9992-15086D339B05}",
            L"{49D2F9CE-1F5E-11D7-A6D3-00065B84435C}",
            L"{49D2F9CF-1F5E-11D7-A6D3-00065B84435C}",
            L"{74769EE9-4A66-4F9D-90D6-BF8B7C3EB461}",
        };
        for (const wchar_t *cat : cats) {
            const std::wstring catPath = tipPath + L"\\Category\\Category\\" + cat;
            if (create_key_value(HKEY_LOCAL_MACHINE, catPath, L"", L"") != ERROR_SUCCESS ||
                create_key_value(HKEY_LOCAL_MACHINE, catPath + L"\\" + clsidStr, L"", L"") != ERROR_SUCCESS) {
                hr = SELFREG_E_CLASS; break;
            }
        }
        if (hr != S_OK) break;
        if (create_key_value(HKEY_LOCAL_MACHINE, catKeyboard + L"\\" + profileStr, L"", L"") != ERROR_SUCCESS) {
            hr = SELFREG_E_CLASS; break;
        }
        // 档案图标（镜像 MS 拼音的 IconFile/IconIndex；指向自身 DLL 第一个图标）。
        if (create_key_value(HKEY_LOCAL_MACHINE, langPath, L"IconFile",
                             std::wstring(modulePath) + L",0") != ERROR_SUCCESS ||
            create_key_value(HKEY_LOCAL_MACHINE, langPath, L"IconIndex", L"", 0, true) != ERROR_SUCCESS) {
            hr = SELFREG_E_CLASS; break;
        }
    } while (false);
    if (SUCCEEDED(hr)) {
        register_profile_via_api(std::wstring(modulePath));
    }
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
                L"SOFTWARE\\Microsoft\\CTF\\TIP\\" + clsidStr + L"\\Category");
    delete_tree(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\CTF\\TIP\\" + clsidStr);
    delete_tree(HKEY_CLASSES_ROOT, L"CLSID\\" + clsidStr);
    return S_OK;
}
