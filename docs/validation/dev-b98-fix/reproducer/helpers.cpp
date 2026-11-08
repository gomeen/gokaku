#define NOMINMAX
#include <windows.h>
#include <gdiplus.h>
#include <msctf.h>
#include <tlhelp32.h>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <stdexcept>
#include "json.hpp"
using Json=nlohmann::json;
namespace fs=std::filesystem;
fs::path root;
std::wstring installedRoot(){
 HKEY key=nullptr;wchar_t value[32768]{};DWORD size=sizeof(value),type=0;
 if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"Software\\Gogaku\\dev",0,KEY_QUERY_VALUE|KEY_WOW64_64KEY,&key)!=ERROR_SUCCESS)throw std::runtime_error("ActiveRoot missing");
 auto status=RegQueryValueExW(key,L"ActiveRoot",nullptr,&type,(BYTE*)value,&size);RegCloseKey(key);
 if(status!=ERROR_SUCCESS||type!=REG_SZ)throw std::runtime_error("ActiveRoot invalid");return value;
}

std::string utf8(const std::wstring &s){int n=WideCharToMultiByte(CP_UTF8,0,s.data(),(int)s.size(),nullptr,0,nullptr,nullptr);std::string v(n,0);WideCharToMultiByte(CP_UTF8,0,s.data(),(int)s.size(),v.data(),n,nullptr,nullptr);return v;}
std::wstring cls(HWND h){wchar_t s[256]{};GetClassNameW(h,s,256);return s;}
std::wstring title(HWND h){wchar_t s[512]{};GetWindowTextW(h,s,512);return s;}
void write(const char *name,const Json &v){std::ofstream(root/name)<<v.dump(2)<<"\n";}
void wait(DWORD ms){ULONGLONG until=GetTickCount64()+ms;MSG m{};do{while(PeekMessageW(&m,nullptr,0,0,PM_REMOVE)){TranslateMessage(&m);DispatchMessageW(&m);}Sleep(10);}while(GetTickCount64()<until);}
BOOL CALLBACK collectWindow(HWND h,LPARAM p){((std::vector<HWND>*)p)->push_back(h);return TRUE;}
std::vector<HWND> all(){std::vector<HWND> out;EnumWindows(collectWindow,(LPARAM)&out);return out;}
DWORD pid(HWND h){DWORD n=0;GetWindowThreadProcessId(h,&n);return n;}
std::wstring image(DWORD id){HANDLE p=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,id);wchar_t path[32768]{};DWORD n=32768;bool ok=p&&QueryFullProcessImageNameW(p,0,path,&n);if(p)CloseHandle(p);return ok?path:L"";}
Json info(HWND h){RECT r{};GetWindowRect(h,&r);return {{"handle",(uint64_t)h},{"pid",pid(h)},{"class",utf8(cls(h))},{"visible",bool(IsWindowVisible(h))},{"rect",{r.left,r.top,r.right-r.left,r.bottom-r.top}},{"dpi",GetDpiForWindow(h)}};}
void capture(HWND h,const char *name,bool screenOnly=false){RECT r{};GetWindowRect(h,&r);int w=r.right-r.left,hg=r.bottom-r.top;if(w<=0||hg<=0||w>6000||hg>6000)throw std::runtime_error("bad capture size");HDC screen=GetDC(nullptr),dc=CreateCompatibleDC(screen);HBITMAP b=CreateCompatibleBitmap(screen,w,hg);auto old=SelectObject(dc,b);BOOL ok=screenOnly?FALSE:PrintWindow(h,dc,2);if(!ok)BitBlt(dc,0,0,w,hg,screen,r.left,r.top,SRCCOPY|CAPTUREBLT);SelectObject(dc,old);Gdiplus::Bitmap bitmap(b,nullptr);CLSID png={0x557cf406,0x1a04,0x11d3,{0x9a,0x73,0x00,0x00,0xf8,0x1e,0xf3,0x2e}};auto status=bitmap.Save((root/name).c_str(),&png,nullptr);DeleteObject(b);DeleteDC(dc);ReleaseDC(nullptr,screen);if(status!=Gdiplus::Ok)throw std::runtime_error("capture failed");}
void launch(const std::wstring &path,const std::wstring &args=L""){std::wstring cmd=L"\""+path+L"\" "+args;STARTUPINFOW si{sizeof(si)};PROCESS_INFORMATION pi{};if(!CreateProcessW(path.c_str(),cmd.data(),nullptr,nullptr,FALSE,0,nullptr,nullptr,&si,&pi))throw std::runtime_error("CreateProcess failed: "+std::to_string(GetLastError()));CloseHandle(pi.hThread);CloseHandle(pi.hProcess);}
void foreground(HWND h){HWND current=GetForegroundWindow();DWORD thread=current?GetWindowThreadProcessId(current,nullptr):0,targetThread=GetWindowThreadProcessId(h,nullptr);if(thread&&thread!=GetCurrentThreadId())AttachThreadInput(GetCurrentThreadId(),thread,TRUE);if(targetThread!=GetCurrentThreadId()&&targetThread!=thread)AttachThreadInput(GetCurrentThreadId(),targetThread,TRUE);ShowWindow(h,SW_RESTORE);BringWindowToTop(h);SetForegroundWindow(h);if(targetThread!=GetCurrentThreadId()&&targetThread!=thread)AttachThreadInput(GetCurrentThreadId(),targetThread,FALSE);if(thread&&thread!=GetCurrentThreadId())AttachThreadInput(GetCurrentThreadId(),thread,FALSE);wait(150);if(GetForegroundWindow()!=h)throw std::runtime_error("foreground refused target="+std::to_string((uint64_t)h)+" foreground="+std::to_string((uint64_t)GetForegroundWindow())+" enabled="+std::to_string(IsWindowEnabled(h)));}
void key(HWND h,WORD vk,bool ctrl=false){if(GetForegroundWindow()!=h)throw std::runtime_error("focus guard failed");INPUT in[4]{};int n=0;if(ctrl){in[n].type=INPUT_KEYBOARD;in[n++].ki.wVk=VK_CONTROL;}in[n].type=INPUT_KEYBOARD;in[n++].ki.wVk=vk;in[n].type=INPUT_KEYBOARD;in[n].ki.wVk=vk;in[n++].ki.dwFlags=KEYEVENTF_KEYUP;if(ctrl){in[n].type=INPUT_KEYBOARD;in[n].ki.wVk=VK_CONTROL;in[n++].ki.dwFlags=KEYEVENTF_KEYUP;}if(SendInput(n,in,sizeof(INPUT))!=(UINT)n)throw std::runtime_error("SendInput failed");wait(150);}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR args,int){wchar_t path[32768]{};GetModuleFileNameW(nullptr,path,32768);root=fs::path(path).parent_path();write("phase.json",{{"phase","start"}});Json result={{"ok",false},{"screenshots",Json::array()}};
SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);Gdiplus::GdiplusStartupInput gi;ULONG_PTR token=0;Gdiplus::GdiplusStartup(&token,&gi,nullptr);
try{DWORD sid=0;ProcessIdToSessionId(GetCurrentProcessId(),&sid);result["session"]=sid;result["installedRoot"]=utf8(installedRoot());
std::wstring mode=args?args:L"";
if(mode==L"restart-agent"){
 HWND tray=FindWindowW(L"GogakuAgentTray",nullptr);if(!tray)throw std::runtime_error("agent tray not found");DWORD agentPid=pid(tray);
 if(image(agentPid)!=(installedRoot()+L"\\bin\\x64\\GogakuAgent.exe"))throw std::runtime_error("unexpected agent image");
 HANDLE process=OpenProcess(PROCESS_TERMINATE|SYNCHRONIZE,FALSE,agentPid);if(!process)throw std::runtime_error("cannot stop agent fixture");
 result["agentPidBefore"]=agentPid;result["ok"]=bool(TerminateProcess(process,0))&&WaitForSingleObject(process,1500)==WAIT_OBJECT_0;CloseHandle(process);
}else if(mode==L"settings-check"){
 for(auto h:all())if(image(pid(h)).find((installedRoot()+L"\\bin\\x64\\GogakuSettings"))==0)PostMessageW(h,WM_CLOSE,0,0);wait(500);
 const std::wstring exe=(installedRoot()+L"\\bin\\x64\\GogakuSettings.exe");launch(exe);wait(1000);HWND settings=nullptr;for(auto h:all())if(cls(h)==L"GogakuNativeSettings"&&image(pid(h))==exe)settings=h;
 if(!settings)throw std::runtime_error("new settings not found");ShowWindow(settings,SW_RESTORE);SetWindowPos(settings,HWND_TOP,40,40,0,0,SWP_NOSIZE|SWP_NOACTIVATE);wait(300);result["settings"]=info(settings);result["largeIcon"]=(uint64_t)SendMessageW(settings,WM_GETICON,ICON_BIG,0);result["smallIcon"]=(uint64_t)SendMessageW(settings,WM_GETICON,ICON_SMALL,0);
 auto nav=GetDlgItem(settings,10);if(SendMessageW(nav,LB_GETCOUNT,0,0)!=7)throw std::runtime_error("settings navigation count");result["pages"]=Json::array();
 for(int i=0;i<7;++i){SendMessageW(nav,LB_SETCURSEL,i,0);SendMessageW(settings,WM_COMMAND,MAKEWPARAM(10,LBN_SELCHANGE),(LPARAM)nav);wait(200);std::string file="settings-page-"+std::to_string(i)+".png";capture(settings,file.c_str());result["screenshots"].push_back(file);result["pages"].push_back({{"index",i},{"heading",utf8(title(GetDlgItem(settings,15)))}});}
 UINT dpi=GetDpiForWindow(settings);SetWindowPos(settings,nullptr,30,30,MulDiv(820,dpi,96),MulDiv(560,dpi,96),SWP_NOZORDER);SendMessageW(nav,LB_SETCURSEL,3,0);SendMessageW(settings,WM_COMMAND,MAKEWPARAM(10,LBN_SELCHANGE),(LPARAM)nav);wait(300);capture(settings,"settings-skin-minimum.png");result["screenshots"].push_back("settings-skin-minimum.png");PostMessageW(settings,WM_CLOSE,0,0);wait(200);result["ok"]=result["largeIcon"]!=0&&result["smallIcon"]!=0;
}else if(mode.find(L"classic")!=std::wstring::npos){
 WNDCLASSW wc{};wc.hInstance=GetModuleHandleW(nullptr);wc.lpfnWndProc=DefWindowProcW;wc.lpszClassName=L"GogakuScratchHost";RegisterClassW(&wc);
 HWND target=CreateWindowExW(0,wc.lpszClassName,L"Gogaku synthetic input host",WS_OVERLAPPEDWINDOW|WS_VISIBLE,100,100,800,600,nullptr,nullptr,wc.hInstance,nullptr);
 HWND field=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"",WS_CHILD|WS_VISIBLE|WS_TABSTOP|ES_MULTILINE,20,20,720,480,target,nullptr,wc.hInstance,nullptr);
 ITfThreadMgr *tm=nullptr;CoCreateInstance(CLSID_TF_ThreadMgr,nullptr,CLSCTX_INPROC_SERVER,IID_ITfThreadMgr,(void**)&tm);TfClientId client=0;if(tm)tm->Activate(&client);
 foreground(target);SetFocus(field);wait(200);
 if(mode.find(L"cold")!=std::wstring::npos){
  result["agentsStopped"]=Json::array();HANDLE list=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);PROCESSENTRY32W item{sizeof(item)};
  if(list!=INVALID_HANDLE_VALUE&&Process32FirstW(list,&item)){do{
   auto path=image(item.th32ProcessID);
   if(path==L"C:\\Program Files\\GogakuDev\\versions\\b93\\bin\\x64\\GogakuAgent.exe"||path==L"C:\\Program Files\\GogakuDev\\bin\\x64\\GogakuAgent.exe"||path==(installedRoot()+L"\\bin\\x64\\GogakuAgent.exe")){
    HANDLE process=OpenProcess(PROCESS_TERMINATE|SYNCHRONIZE,FALSE,item.th32ProcessID);if(!process)throw std::runtime_error("cannot stop own agent for cold test");
    bool stopped=TerminateProcess(process,0)&&WaitForSingleObject(process,3000)==WAIT_OBJECT_0;CloseHandle(process);
    if(!stopped)throw std::runtime_error("agent stop failed");result["agentsStopped"].push_back({{"pid",item.th32ProcessID},{"path",utf8(path)}});
   }
  }while(Process32NextW(list,&item));}if(list!=INVALID_HANDLE_VALUE)CloseHandle(list);
  result["coldStartTick"]=GetTickCount64();result["agentAbsentBeforeActivation"]=FindWindowW(L"GogakuAgentTray",nullptr)==nullptr;
 }

 if(mode.find(L"activate")!=std::wstring::npos){ITfInputProcessorProfileMgr* pm=nullptr;if(SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_ITfInputProcessorProfileMgr,(void**)&pm))){CLSID c={0xA3C5D7E9,0x1B2F,0x4A6C,{0x8E,0x0D,0x2F,0x4B,0x6A,0x8C,0x0E,0x13}};GUID p={0xC9E1F3A5,0x7B8D,0x4E2F,{0x6A,0x0C,0x1D,0x3E,0x5F,0x7A,0x9B,0x12}};auto stable=c;stable.Data4[7]=0x12;auto stableProfile=p;stableProfile.Data4[7]=0x11;result["deactivateStableHr"]=(long)pm->DeactivateProfile(TF_PROFILETYPE_INPUTPROCESSOR,0x804,stable,stableProfile,nullptr,0);result["deactivateDevHr"]=(long)pm->DeactivateProfile(TF_PROFILETYPE_INPUTPROCESSOR,0x804,c,p,nullptr,0);auto activationStart=GetTickCount64();result["activateHr"]=(long)pm->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR,0x804,c,p,nullptr,0);result["activationMilliseconds"]=GetTickCount64()-activationStart;pm->Release();}}
 wait(mode.find(L"cold")!=std::wstring::npos?0:600);
 result["agentPidAfter"]=pid(FindWindowW(L"GogakuAgentTray",nullptr));result["agentImageAfter"]=utf8(image(result["agentPidAfter"].get<DWORD>()));result["probePid"]=GetCurrentProcessId();
 result["modules"]=Json::array();HANDLE modules=CreateToolhelp32Snapshot(TH32CS_SNAPMODULE,GetCurrentProcessId());MODULEENTRY32W module{sizeof(module)};if(modules!=INVALID_HANDLE_VALUE){if(Module32FirstW(modules,&module)){do{if(std::wstring(module.szModule).find(L"GogakuTsf")!=std::wstring::npos)result["modules"].push_back(utf8(module.szExePath));}while(Module32NextW(modules,&module));}CloseHandle(modules);}
 ITfKeystrokeMgr *km=nullptr;if(tm&&SUCCEEDED(tm->QueryInterface(IID_ITfKeystrokeMgr,(void**)&km))){CLSID fg{};auto hr=km->GetForeground(&fg);wchar_t s[48]{};StringFromGUID2(fg,s,48);result["keyForeground"]={{"hr",(long)hr},{"clsid",utf8(s)}};km->Release();}
 ITfInputProcessorProfileMgr *pm=nullptr;if(SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_ITfInputProcessorProfileMgr,(void**)&pm))){TF_INPUTPROCESSORPROFILE p{};auto hr=pm->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD,&p);wchar_t s[48]{};StringFromGUID2(p.clsid,s,48);result["profile"]={{"hr",(long)hr},{"clsid",utf8(s)}};pm->Release();}
 result["steps"]=Json::array();for(auto k:{'N','I','H','C'}){key(target,(WORD)k);result["steps"].push_back({{"key",std::string(1,char(k))},{"text",utf8(title(field))}});}wait(300);
 result["candidateWindows"]=Json::array();bool visible=false;for(auto h:all())if(cls(h)==L"GogakuCandidateWindowV2"&&pid(h)==GetCurrentProcessId()){result["candidateWindows"].push_back(info(h));visible=visible||IsWindowVisible(h);}capture(target,"classic-input.png");result["screenshots"].push_back("classic-input.png");key(target,VK_SPACE);result["textAt150ms"]=utf8(title(field));result["foregroundAtCommit"]=(uint64_t)GetForegroundWindow();result["targetHandle"]=(uint64_t)target;wait(1000);result["text"]=utf8(title(field));result["candidateVisible"]=visible;result["ok"]=visible&&title(field)==L"你好";if(tm){tm->Deactivate();tm->Release();}DestroyWindow(target);
}else if(mode.find(L"input")!=std::wstring::npos){
 auto marker=L"GogakuSyntheticInputProbe-"+std::to_wstring(GetCurrentProcessId());auto file=root/(marker+L".txt");std::ofstream(file)<<"";
 launch(mode==L"input-direct"?L"C:\\Program Files\\WindowsApps\\Microsoft.WindowsNotepad_11.2607.14.0_x64__8wekyb3d8bbwe\\Notepad\\Notepad.exe":L"C:\\Windows\\System32\\notepad.exe",L"\""+file.wstring()+L"\"");wait(1400);HWND target=nullptr;for(int attempt=0;attempt<48&&!target;++attempt){for(auto h:all())if(IsWindowVisible(h)&&cls(h)==L"Notepad"&&title(h).find(marker)!=std::wstring::npos){target=h;break;}if(!target)wait(250);}
 if(!target)throw std::runtime_error("scratch Notepad not found");result["target"]=info(target);foreground(target);
 ITfInputProcessorProfileMgr *profiles=nullptr;HRESULT phr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_ITfInputProcessorProfileMgr,(void**)&profiles);result["profilesResult"]=(long)phr;
 if(profiles){TF_INPUTPROCESSORPROFILE p{};HRESULT hr=profiles->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD,&p);wchar_t a[48]{},b[48]{};StringFromGUID2(p.clsid,a,48);StringFromGUID2(p.guidProfile,b,48);result["activeProfile"]={{"hr",(long)hr},{"clsid",utf8(a)},{"profile",utf8(b)},{"lang",p.langid}};profiles->Release();}
 for(auto k:{'N','I','H','C'})key(target,(WORD)k);wait(400);
 result["candidateWindows"]=Json::array();for(auto h:all())if(cls(h)==L"GogakuCandidateWindowV2")result["candidateWindows"].push_back(info(h));
 bool candidateVisible=false;for(auto h:all())if(cls(h)==L"GogakuCandidateWindowV2"&&pid(h)==pid(target)&&IsWindowVisible(h))candidateVisible=true;result["candidateVisible"]=candidateVisible;
 for(auto h:all())if(cls(h)==L"GogakuCandidateWindowV2"&&pid(h)==pid(target)&&IsWindowVisible(h)){capture(h,"notepad-candidate.png",true);result["screenshots"].push_back("notepad-candidate.png");break;}
 capture(target,"notepad-input.png");result["screenshots"].push_back("notepad-input.png");
 key(target,VK_SPACE);key(target,'S',true);wait(400);std::ifstream f(file,std::ios::binary);std::string bytes((std::istreambuf_iterator<char>(f)),{});result["savedBytes"]=bytes;result["textCommitted"]=bytes=="\xe4\xbd\xa0\xe5\xa5\xbd"||bytes=="\xef\xbb\xbf\xe4\xbd\xa0\xe5\xa5\xbd";result["ok"]=candidateVisible&&result["textCommitted"].get<bool>();key(target,'W',true);
}else if(mode==L"notepad-close"){
 HWND target=nullptr;for(auto h:all())if(cls(h)==L"Notepad"&&image(pid(h)).find(L"Microsoft.WindowsNotepad_")!=std::wstring::npos){target=h;break;}
 if(!target)throw std::runtime_error("Notepad not found");DWORD processId=pid(target);HANDLE process=OpenProcess(SYNCHRONIZE,FALSE,processId);
 result["pid"]=processId;result["posted"]=bool(PostMessageW(target,WM_CLOSE,0,0));wait(2500);result["exited"]=process&&WaitForSingleObject(process,5000)==WAIT_OBJECT_0;result["foreground"]=info(GetForegroundWindow());result["ok"]=result["exited"];if(process)CloseHandle(process);
}else if(mode==L"window-state"){
 result["foreground"]=info(GetForegroundWindow());result["windows"]=Json::array();
 result["notepadModules"]=Json::array();for(auto h:all())if(cls(h)==L"Notepad"){
  HANDLE modules=CreateToolhelp32Snapshot(TH32CS_SNAPMODULE,pid(h));MODULEENTRY32W m{sizeof(m)};HANDLE process=OpenProcess(PROCESS_VM_READ,FALSE,pid(h));
  if(modules!=INVALID_HANDLE_VALUE&&Module32FirstW(modules,&m)){do{if(std::wstring(m.szModule).find(L"GogakuTsf")!=std::wstring::npos){DWORD offset=0,stamp=0;SIZE_T bytes=0;bool ok=process&&ReadProcessMemory(process,m.modBaseAddr+0x3c,&offset,4,&bytes)&&offset<4096&&ReadProcessMemory(process,m.modBaseAddr+offset+8,&stamp,4,&bytes);result["notepadModules"].push_back({{"path",utf8(m.szExePath)},{"stamp",stamp},{"read",ok}});}}while(Module32NextW(modules,&m));}
  if(process)CloseHandle(process);if(modules!=INVALID_HANDLE_VALUE)CloseHandle(modules);break;}
 for(auto h:all())if(IsWindowVisible(h)){
  auto exe=image(pid(h));if(exe.find(L"Notepad")!=std::wstring::npos||exe.find(L"Gogaku")!=std::wstring::npos){auto item=info(h);item["image"]=utf8(exe);item["enabled"]=bool(IsWindowEnabled(h));item["owner"]=(uint64_t)GetWindow(h,GW_OWNER);item["children"]=Json::array();
   std::vector<HWND> children;EnumChildWindows(h,collectWindow,(LPARAM)&children);for(auto child:children)if(IsWindowVisible(child))item["children"].push_back({{"class",utf8(cls(child))},{"id",GetDlgCtrlID(child)},{"style",(uint64_t)GetWindowLongPtrW(child,GWL_STYLE)}});result["windows"].push_back(item);}}
 result["ok"]=true;
}else{
 HWND settings=nullptr;for(auto h:all())if(cls(h)==L"GogakuSettingsWindow"||image(pid(h)).find(L"GogakuSettings.exe")!=std::wstring::npos)if(IsWindowVisible(h))settings=h;
 if(!settings){launch((installedRoot()+L"\\bin\\x64\\GogakuSettings.exe"));wait(700);for(auto h:all())if(image(pid(h)).find(L"GogakuSettings.exe")!=std::wstring::npos&&IsWindowVisible(h))settings=h;}
 result["windows"]=Json::array();for(auto h:all())if(image(pid(h)).find(L"Gogaku")!=std::wstring::npos){auto v=info(h);v["title"]=utf8(title(h));result["windows"].push_back(v);}
 if(!settings)throw std::runtime_error("settings window not found");capture(settings,"settings-before.png");result["screenshots"].push_back("settings-before.png");result["settings"]=info(settings);result["ok"]=true;
}
}catch(const std::exception &e){result["error"]=e.what();}write("result.json",result);Gdiplus::GdiplusShutdown(token);CoUninitialize();return result.value("ok",false)?0:1;}
