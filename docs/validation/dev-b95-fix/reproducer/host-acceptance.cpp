#define wWinMain historicalProbeMain
#include "helpers.cpp"
#undef wWinMain
#include <sstream>

HWND ownedWindow=nullptr;std::wstring ownedMarker;Json keyTrace=Json::array();
void guardedKey(WORD vk,bool control=false){
 if(!IsWindow(ownedWindow)||title(ownedWindow).find(ownedMarker)==std::wstring::npos)throw std::runtime_error("owned document title guard failed");
 GUITHREADINFO gi{sizeof(gi)};GetGUIThreadInfo(GetWindowThreadProcessId(ownedWindow,nullptr),&gi);
 if(!gi.hwndFocus||pid(gi.hwndFocus)!=pid(ownedWindow))throw std::runtime_error("focused control ownership changed");
 keyTrace.push_back({{"virtualKey",vk},{"control",control},{"focusClass",utf8(cls(gi.hwndFocus))},{"tick",GetTickCount64()},{"keyboardLayout",(uint64_t)GetKeyboardLayout(GetWindowThreadProcessId(ownedWindow,nullptr))}});
 key(ownedWindow,vk,control);
}
Json modulesFor(DWORD id){
 Json out=Json::array();HANDLE snap=CreateToolhelp32Snapshot(TH32CS_SNAPMODULE|TH32CS_SNAPMODULE32,id);MODULEENTRY32W m{sizeof(m)};
 HANDLE process=OpenProcess(PROCESS_VM_READ,FALSE,id);
 if(snap!=INVALID_HANDLE_VALUE&&Module32FirstW(snap,&m))do{if(std::wstring(m.szModule)==L"GogakuTsf.dll"){
  DWORD offset=0,stamp=0;SIZE_T read=0;bool ok=process&&ReadProcessMemory(process,m.modBaseAddr+0x3c,&offset,4,&read)&&offset<4096&&ReadProcessMemory(process,m.modBaseAddr+offset+8,&stamp,4,&read);
  out.push_back({{"path",utf8(m.szExePath)},{"memoryPeTimestamp",stamp},{"memoryRead",ok}});
 }}while(Module32NextW(snap,&m));
 if(process)CloseHandle(process);if(snap!=INVALID_HANDLE_VALUE)CloseHandle(snap);return out;
}
void activateDev(Json &r){
 ITfInputProcessorProfileMgr *p=nullptr;auto hr=CoCreateInstance(CLSID_TF_InputProcessorProfiles,nullptr,CLSCTX_INPROC_SERVER,IID_ITfInputProcessorProfileMgr,(void**)&p);
 if(FAILED(hr))throw std::runtime_error("profile manager unavailable");
 CLSID c={0xA3C5D7E9,0x1B2F,0x4A6C,{0x8E,0x0D,0x2F,0x4B,0x6A,0x8C,0x0E,0x13}};GUID g={0xC9E1F3A5,0x7B8D,0x4E2F,{0x6A,0x0C,0x1D,0x3E,0x5F,0x7A,0x9B,0x12}};
 constexpr DWORD profileForSession=0x20000000; // Microsoft WinSDK msctf.h TF_IPPMF_FORSESSION.
 auto start=GetTickCount64();hr=p->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR,0x804,c,g,nullptr,profileForSession);p->Release();r["activateHr"]=(long)hr;r["activationMilliseconds"]=GetTickCount64()-start;
 if(FAILED(hr))throw std::runtime_error("dev profile activation failed");
}
std::vector<DWORD> ownAgents(){
 std::vector<DWORD> ids;HANDLE list=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);PROCESSENTRY32W item{sizeof(item)};
 if(list!=INVALID_HANDLE_VALUE&&Process32FirstW(list,&item))do{
  if(_wcsicmp(item.szExeFile,L"GogakuAgent.exe")==0){
   HANDLE process=OpenProcess(SYNCHRONIZE,FALSE,item.th32ProcessID);bool gone=process?WaitForSingleObject(process,0)==WAIT_OBJECT_0:GetLastError()==ERROR_INVALID_PARAMETER;if(process)CloseHandle(process);if(gone)continue;
   auto path=image(item.th32ProcessID);if(path==installedRoot()+L"\\bin\\x64\\GogakuAgent.exe")ids.push_back(item.th32ProcessID);else {CloseHandle(list);throw std::runtime_error("unexpected broker image, no stop attempted");}
  }
 }while(Process32NextW(list,&item));if(list!=INVALID_HANDLE_VALUE)CloseHandle(list);return ids;
}
void stopOwnAgent(Json &r){
 auto ids=ownAgents();r["stoppedAgentPids"]=ids;
 for(auto id:ids){HANDLE process=OpenProcess(PROCESS_TERMINATE|SYNCHRONIZE,FALSE,id);bool stopped=process&&TerminateProcess(process,0)&&WaitForSingleObject(process,3000)==WAIT_OBJECT_0;if(process)CloseHandle(process);if(!stopped)throw std::runtime_error("own broker stop failed");}
 r["agentAbsentBeforeActivation"]=ownAgents().empty();
 if(!r["agentAbsentBeforeActivation"].get<bool>())throw std::runtime_error("broker restarted before cold activation");
}
std::string bytesOf(const fs::path &p){std::ifstream in(p,std::ios::binary);std::string s((std::istreambuf_iterator<char>(in)),{});if(s.substr(0,3)=="\xef\xbb\xbf")s.erase(0,3);return s;}
#include "browser-cases.h"
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR args,int){
 root=fs::path(L"C:\\Users\\iixm\\AppData\\Local\\Temp\\GogakuAcceptanceB94");fs::create_directories(root);
 std::wstring mode=args?args:L"notepad-basic";while(!mode.empty()&&iswspace(mode.back()))mode.pop_back();Json r={{"ok",false},{"mode",utf8(mode)},{"screenshots",Json::array()}};HWND prior=GetForegroundWindow();
 SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);Gdiplus::GdiplusStartupInput gi;ULONG_PTR token=0;Gdiplus::GdiplusStartup(&token,&gi,nullptr);
 try{
  if(mode.find(L"chrome-")==0)runChrome(mode,r);
  else if(mode==L"code-basic")runCode(r);
  else if(mode==L"terminal-basic")runTerminal(r);
  else {
  ownedMarker=L"GogakuAcceptanceB94-"+std::to_wstring(GetCurrentProcessId());auto file=root/(ownedMarker+L".txt");std::ofstream(file)<<"";
  if(mode==L"notepad-cold")stopOwnAgent(r);
  launch(L"C:\\Windows\\System32\\notepad.exe",L"\""+file.wstring()+L"\"");
  for(int i=0;i<60&&!ownedWindow;i++){for(auto h:all())if(IsWindowVisible(h)&&cls(h)==L"Notepad"&&title(h).find(ownedMarker)!=std::wstring::npos){ownedWindow=h;break;}if(!ownedWindow)wait(100);}
  if(!ownedWindow)throw std::runtime_error("dedicated Notepad document not found");r["target"]=info(ownedWindow);r["documentMarker"]=utf8(ownedMarker);foreground(ownedWindow);activateDev(r);wait(250);
  r["modulesBefore"]=modulesFor(pid(ownedWindow));
  bool current=false;for(auto &m:r["modulesBefore"])if(m["path"].get<std::string>()==utf8(installedRoot()+L"\\bin\\x64\\GogakuTsf.dll"))current=true;
  if(!current)throw std::runtime_error("Notepad did not load installed b94 TSF; no keys sent");
  auto type=[&](const char *text){for(auto p=text;*p;p++)guardedKey((WORD)*p);};
  std::string expected="你好";
  if(mode==L"notepad-raw-enter"){type("NIHC");guardedKey(VK_RETURN);expected="nihc";}
  else if(mode==L"notepad-escape"){type("NIHC");guardedKey(VK_ESCAPE);expected="";}
  else if(mode==L"notepad-zero"){type("NIHC");guardedKey('0');expected="你好0";}
  else if(mode==L"notepad-shift"){type("NIHC");guardedKey(VK_SHIFT);type("ABC");guardedKey(VK_SPACE);guardedKey(VK_SHIFT);expected="nihcabc ";}
  else {
   type("NIHC");wait(250);bool visible=false;r["candidateWindows"]=Json::array();
   for(auto h:all())if(cls(h)==L"GogakuCandidateWindowV2"&&pid(h)==pid(ownedWindow)&&IsWindowVisible(h)){visible=true;r["candidateWindows"].push_back(info(h));capture(h,"notepad-candidate.png",true);r["screenshots"].push_back("notepad-candidate.png");}
   r["candidateVisible"]=visible;if(!visible)throw std::runtime_error("candidate absent on first composition");
   guardedKey(mode==L"notepad-number"?'1':VK_SPACE);
   if(mode==L"notepad-replace"){guardedKey('A',true);type("NIHC");guardedKey(VK_SPACE);}
  }
  guardedKey('S',true);wait(300);auto got=bytesOf(file);r["savedText"]=got;r["expectedText"]=expected;r["textMatched"]=got==expected;r["modulesAfter"]=modulesFor(pid(ownedWindow));
  r["agentPidsAfter"]=ownAgents();r["agentImageAfter"]=utf8(installedRoot()+L"\\bin\\x64\\GogakuAgent.exe");r["ok"]=got==expected;
  guardedKey('W',true);r["syntheticDocumentClosed"]=true;
  }
 }catch(const std::exception &e){r["error"]=e.what();}
 if(prior&&IsWindow(prior)){try{foreground(prior);r["foregroundRestored"]=true;}catch(...){r["foregroundRestored"]=false;}}
 r["keyTrace"]=keyTrace;write("result.json",r);Gdiplus::GdiplusShutdown(token);CoUninitialize();return r.value("ok",false)?0:1;
}
