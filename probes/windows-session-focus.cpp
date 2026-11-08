// Windows integration probe: a delayed blur from an inactive connection must
// preserve the active connection's composition. Uses only synthetic protocol
// input; no host text, credentials, translation requests or frequency commits.
#include "../windows/GogakuWindows/platform.h"
#include <fstream>
#include <objbase.h>
#include <stdexcept>
using gw::Json;
struct Client {
    HANDLE pipe=INVALID_HANDLE_VALUE;
    uint64_t sequence=0;
    Client() {
        pipe=CreateFileW(gw::pipeName().c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,nullptr);
        if(pipe==INVALID_HANDLE_VALUE)throw std::runtime_error("agent is not running");
        call({{"op","hello"},{"abi",4}});
    }
    Json call(Json request) {
        request["v"]=gw::ProtocolVersion;request["id"]=++sequence;
        Json response;
        if(!gw::writeMessage(pipe,request,2000)||!gw::readMessage(pipe,response,2000))throw std::runtime_error("RPC failed");
        if(response.value("id",uint64_t(0))!=sequence)throw std::runtime_error("response identity mismatch");
        return response;
    }
    ~Client(){if(pipe!=INVALID_HANDLE_VALUE){try{gw::writeMessage(pipe,{{"op","close"},{"v",gw::ProtocolVersion},{"id",++sequence}},1000);}catch(...){}CloseHandle(pipe);}}
};
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,PWSTR,int) {
    Json result={{"ok",false},{"screenshots",Json::array()}};
    CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    WNDCLASSW cls{};cls.hInstance=instance;cls.lpfnWndProc=DefWindowProcW;cls.lpszClassName=L"GogakuFocusProtocolProbe";RegisterClassW(&cls);
    HWND window=CreateWindowExW(0,cls.lpszClassName,L"Gogaku synthetic focus protocol probe",WS_OVERLAPPEDWINDOW|WS_VISIBLE,100,100,640,400,nullptr,nullptr,instance,nullptr);
    try {
        HWND foreground=GetForegroundWindow();DWORD thread=foreground?GetWindowThreadProcessId(foreground,nullptr):0;
        if(thread)AttachThreadInput(GetCurrentThreadId(),thread,TRUE);
        ShowWindow(window,SW_RESTORE);SetForegroundWindow(window);
        if(thread)AttachThreadInput(GetCurrentThreadId(),thread,FALSE);
        MSG message{};while(PeekMessageW(&message,nullptr,0,0,PM_REMOVE)){TranslateMessage(&message);DispatchMessageW(&message);}
        if(GetForegroundWindow()!=window)throw std::runtime_error("foreground refused");
        Client previous,active;
        auto open=[](const char *field){return Json{{"op","open"},{"app","gogaku-focus-probe.exe"},{"field",field}};};
        result["previousOpen"]=previous.call(open("previous"));
        result["activeOpen"]=active.call(open("active"));
        active.call({{"op","event"},{"kind",0},{"text","n"}});
        result["first"]=active.call({{"op","event"},{"kind",0},{"text","i"}});
        result["lateBlur"]=previous.call({{"op","focus"},{"app",""},{"field",""}});
        result["next"]=active.call({{"op","event"},{"kind",0},{"text","h"}});
        result["after"]=active.call({{"op","event"},{"kind",0},{"text","c"}});
        auto after=result["after"];
        result["ok"]=result["first"].value("ok",false)&&result["first"].value("view",Json::object()).value("raw",std::string())=="ni"&&after.value("ok",false)&&after.value("view",Json::object()).value("raw",std::string())=="nihc";
        active.call({{"op","focus"},{"app",""},{"field",""}});
    }catch(const std::exception &error){result["error"]=error.what();}
    DestroyWindow(window);
    std::ofstream(gw::modulePath().parent_path()/L"result.json")<<result.dump(2)<<"\n";
    CoUninitialize();return result.value("ok",false)?0:1;
}
