#include "stdafx.h"
#include "text_service.h"
#include <olectl.h>
#include <new>

HINSTANCE g_hInst=nullptr;
LONG g_objects=0;
static LONG g_locks=0;
#ifdef GOGAKU_DEV
const GUID CLSID_GogakuTsf={0xA3C5D7E9,0x1B2F,0x4A6C,{0x8E,0x0D,0x2F,0x4B,0x6A,0x8C,0x0E,0x13}};
const GUID GUID_GOGAKU_PROFILE={0xC9E1F3A5,0x7B8D,0x4E2F,{0x6A,0x0C,0x1D,0x3E,0x5F,0x7A,0x9B,0x12}};
constexpr const wchar_t *description=L"Gogaku Dev";
#else
const GUID CLSID_GogakuTsf={0xA3C5D7E9,0x1B2F,0x4A6C,{0x8E,0x0D,0x2F,0x4B,0x6A,0x8C,0x0E,0x12}};
const GUID GUID_GOGAKU_PROFILE={0xC9E1F3A5,0x7B8D,0x4E2F,{0x6A,0x0C,0x1D,0x3E,0x5F,0x7A,0x9B,0x11}};
constexpr const wchar_t *description=L"Gogaku";
#endif
BOOL APIENTRY DllMain(HMODULE module,DWORD reason,LPVOID){
    if(reason==DLL_PROCESS_ATTACH){g_hInst=(HINSTANCE)module;DisableThreadLibraryCalls(module);}return TRUE;
}
class ClassFactory final:public IClassFactory {
    LONG refs_=1;
public:
    ClassFactory(){InterlockedIncrement(&g_objects);}
    ~ClassFactory(){InterlockedDecrement(&g_objects);}
    STDMETHODIMP QueryInterface(REFIID id,void **out) override{
        if(!out)return E_POINTER;*out=nullptr;
        if(id==IID_IUnknown||id==IID_IClassFactory){*out=(IClassFactory*)this;AddRef();return S_OK;}return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override{return InterlockedIncrement(&refs_);}
    STDMETHODIMP_(ULONG) Release() override{ULONG n=InterlockedDecrement(&refs_);if(!n)delete this;return n;}
    STDMETHODIMP CreateInstance(IUnknown *outer,REFIID id,void **out) override{
        if(!out)return E_POINTER;*out=nullptr;if(outer)return CLASS_E_NOAGGREGATION;
        try{auto service=new TextService();HRESULT hr=service->QueryInterface(id,out);service->Release();return hr;}catch(...){return E_OUTOFMEMORY;}
    }
    STDMETHODIMP LockServer(BOOL lock) override{if(lock)InterlockedIncrement(&g_locks);else InterlockedDecrement(&g_locks);return S_OK;}
};
STDAPI DllGetClassObject(REFCLSID clsid,REFIID id,void **out){
    if(!out)return E_POINTER;*out=nullptr;if(clsid!=CLSID_GogakuTsf)return CLASS_E_CLASSNOTAVAILABLE;
    auto factory=new(std::nothrow) ClassFactory();if(!factory)return E_OUTOFMEMORY;
    HRESULT hr=factory->QueryInterface(id,out);factory->Release();return hr;
}
STDAPI DllCanUnloadNow(){return !g_locks&&!g_objects?S_OK:S_FALSE;}
namespace {
std::wstring guidString(REFGUID value){wchar_t text[40]{};StringFromGUID2(value,text,40);return text;}
LONG stringValue(const std::wstring &path,const wchar_t *name,const std::wstring &value){
    HKEY key=nullptr;LONG status=RegCreateKeyExW(HKEY_CLASSES_ROOT,path.c_str(),0,nullptr,0,KEY_SET_VALUE,nullptr,&key,nullptr);
    if(status==ERROR_SUCCESS){status=RegSetValueExW(key,name,0,REG_SZ,(const BYTE*)value.c_str(),(DWORD)((value.size()+1)*sizeof(wchar_t)));RegCloseKey(key);}return status;
}
struct Apartment {
    HRESULT status=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    ~Apartment(){if(SUCCEEDED(status))CoUninitialize();}
    bool ok()const{return SUCCEEDED(status)||status==RPC_E_CHANGED_MODE;}
};
HRESULT profileManager(ITfInputProcessorProfileMgr **out){return CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_ITfInputProcessorProfileMgr,(void**)out);}
}
STDAPI DllRegisterServer(){
    try{
        auto path=gw::modulePath(g_hInst).wstring();if(path.empty())return SELFREG_E_CLASS;
        auto clsidPath=L"CLSID\\"+guidString(CLSID_GogakuTsf);
        if(stringValue(clsidPath,L"",description)!=ERROR_SUCCESS||
           stringValue(clsidPath+L"\\InprocServer32",L"",path)!=ERROR_SUCCESS||
           stringValue(clsidPath+L"\\InprocServer32",L"ThreadingModel",L"Apartment")!=ERROR_SUCCESS)return SELFREG_E_CLASS;
        Apartment apartment;if(!apartment.ok())return apartment.status;
        ITfInputProcessorProfileMgr *profiles=nullptr;HRESULT hr=profileManager(&profiles);
        if(FAILED(hr))return hr;
        // 官方 SDK vtable，字符数不含 NUL。不激活、不设语言默认、不改用户语言列表。
        hr=profiles->RegisterProfile(CLSID_GogakuTsf,MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED),GUID_GOGAKU_PROFILE,
            description,(ULONG)wcslen(description),path.c_str(),(ULONG)path.size(),0,nullptr,0,FALSE,0);
        profiles->Release();if(FAILED(hr))return hr;
        ITfCategoryMgr *categories=nullptr;hr=CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_ITfCategoryMgr,(void**)&categories);
        if(FAILED(hr))return hr;
        // 仅登记实际实现的键盘类。不伪造安全模式、AppContainer、UI-less 等能力。
        hr=categories->RegisterCategory(CLSID_GogakuTsf,GUID_TFCAT_TIP_KEYBOARD,CLSID_GogakuTsf);categories->Release();return hr;
    }catch(...){return SELFREG_E_CLASS;}
}
STDAPI DllUnregisterServer(){
    Apartment apartment;HRESULT result=S_OK;
    if(apartment.ok()){
        ITfInputProcessorProfileMgr *profiles=nullptr;if(SUCCEEDED(profileManager(&profiles))){profiles->UnregisterProfile(CLSID_GogakuTsf,MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED),GUID_GOGAKU_PROFILE,0);profiles->Release();}
        ITfCategoryMgr *categories=nullptr;if(SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr,nullptr,CLSCTX_INPROC_SERVER,IID_ITfCategoryMgr,(void**)&categories))){categories->UnregisterCategory(CLSID_GogakuTsf,GUID_TFCAT_TIP_KEYBOARD,CLSID_GogakuTsf);categories->Release();}
    }else result=apartment.status;
    auto path=L"CLSID\\"+guidString(CLSID_GogakuTsf);LONG status=RegDeleteTreeW(HKEY_CLASSES_ROOT,path.c_str());
    if(status!=ERROR_SUCCESS&&status!=ERROR_FILE_NOT_FOUND)result=SELFREG_E_CLASS;return result;
}
// 显式用户操作的辅助入口；安装器从不调用激活／默认设置入口。
extern "C" __declspec(dllexport) void CALLBACK GogakuActivateProfile(HWND,HINSTANCE,LPSTR,int){
    Apartment apartment;if(!apartment.ok())return;ITfInputProcessorProfileMgr *profiles=nullptr;
    if(SUCCEEDED(profileManager(&profiles))){profiles->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR,MAKELANGID(LANG_CHINESE,SUBLANG_CHINESE_SIMPLIFIED),CLSID_GogakuTsf,GUID_GOGAKU_PROFILE,nullptr,0);profiles->Release();}
}
