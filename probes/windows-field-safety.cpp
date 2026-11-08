// Native field fallback regression. Synthetic controls only; no host text read.
#include "../windows/GogakuTsf/src/native_edit_safety.h"
#include "../windows/GogakuWindows/third_party/json.hpp"
#include <richedit.h>
#include <filesystem>
#include <fstream>
#include <stdexcept>
using Json = nlohmann::json;
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,PWSTR,int) {
    Json result={{"ok",false},{"screenshots",Json::array()},{"checks",Json::array()}};
    HWND parent=nullptr;
    HMODULE rich=LoadLibraryW(L"Msftedit.dll");
    try {
        if(!rich)throw std::runtime_error("Msftedit.dll unavailable");
        WNDCLASSW cls{};cls.hInstance=instance;cls.lpfnWndProc=DefWindowProcW;cls.lpszClassName=L"GogakuFieldSafetyProbe";RegisterClassW(&cls);
        parent=CreateWindowW(cls.lpszClassName,L"Synthetic field safety",WS_OVERLAPPED,0,0,640,400,nullptr,nullptr,instance,nullptr);
        auto field=[&](const wchar_t *type,DWORD style=0){
            auto h=CreateWindowW(type,L"",WS_CHILD|style,0,0,200,100,parent,nullptr,instance,nullptr);
            if(!h)throw std::runtime_error("control creation failed");return h;
        };
        auto check=[&](const char *name,bool actual,bool expected){
            result["checks"].push_back({{"name",name},{"actual",actual},{"expected",expected}});
            if(actual!=expected)throw std::runtime_error(name);
        };
        HWND plain=field(L"Edit"),richEdit=field(MSFTEDIT_CLASS),sibling=field(L"Edit");
        check("plain document",nativeEditFallbackSafe(plain,plain),true);
        check("rich document",nativeEditFallbackSafe(richEdit,richEdit),true);
        check("rich child of document",nativeEditFallbackSafe(richEdit,parent),true);
        check("sibling is not document",nativeEditFallbackSafe(richEdit,sibling),false);
        check("missing document",nativeEditFallbackSafe(richEdit,nullptr),false);
        check("missing focus",nativeEditFallbackSafe(nullptr,parent),false);
        check("unknown class",nativeEditFallbackSafe(field(L"Static"),parent),false);
        check("plain password",nativeEditFallbackSafe(field(L"Edit",ES_PASSWORD),parent),false);
        check("rich password",nativeEditFallbackSafe(field(MSFTEDIT_CLASS,ES_PASSWORD),parent),false);
        check("rich readonly",nativeEditFallbackSafe(field(MSFTEDIT_CLASS,ES_READONLY),parent),false);
        SendMessageW(richEdit,EM_SETPASSWORDCHAR,L'*',0);
        check("rich runtime password",nativeEditFallbackSafe(richEdit,parent),false);
        SendMessageW(richEdit,EM_SETPASSWORDCHAR,0,0);
        check("rich password removed",nativeEditFallbackSafe(richEdit,parent),true);
        EnableWindow(richEdit,FALSE);
        check("disabled rich",nativeEditFallbackSafe(richEdit,parent),false);
        result["ok"]=true;
    } catch(const std::exception &error){result["error"]=error.what();}
    if(parent)DestroyWindow(parent);
    if(rich)FreeLibrary(rich);
    wchar_t path[32768]{};GetModuleFileNameW(nullptr,path,32768);
    std::ofstream(std::filesystem::path(path).parent_path()/L"result.json")<<result.dump(2)<<"\n";
    return result.value("ok",false)?0:1;
}
