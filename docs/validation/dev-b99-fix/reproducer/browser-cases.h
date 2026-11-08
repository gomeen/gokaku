#include <winhttp.h>
class Cdp {
 HINTERNET session=nullptr,connection=nullptr,socket=nullptr;int sequence=0;
 static std::string response(HINTERNET request){std::string out;DWORD n=0;char buffer[8192];do{if(!WinHttpReadData(request,buffer,sizeof(buffer),&n))throw std::runtime_error("CDP HTTP read failed");out.append(buffer,n);}while(n);return out;}
public:
 Cdp(int port,const std::string &marker){
  session=WinHttpOpen(L"GogakuAcceptance/1",WINHTTP_ACCESS_TYPE_NO_PROXY,nullptr,nullptr,0);WinHttpSetTimeouts(session,2500,2500,2500,2500);connection=WinHttpConnect(session,L"127.0.0.1",port,0);
  HINTERNET req=WinHttpOpenRequest(connection,L"GET",L"/json/list",nullptr,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,0);
  if(!req||!WinHttpSendRequest(req,WINHTTP_NO_ADDITIONAL_HEADERS,0,WINHTTP_NO_REQUEST_DATA,0,0,0)||!WinHttpReceiveResponse(req,nullptr))throw std::runtime_error("Chrome debug endpoint unavailable");
  auto pages=Json::parse(response(req));WinHttpCloseHandle(req);std::string url;
  for(auto &page:pages)if(page.value("type","")=="page"&&page.value("title","").find(marker)!=std::string::npos)url=page.value("webSocketDebuggerUrl","");
  if(url.empty())throw std::runtime_error("dedicated Chrome page missing");auto slash=url.find('/',url.find("://")+3);std::wstring path(url.begin()+slash,url.end());
  req=WinHttpOpenRequest(connection,L"GET",path.c_str(),nullptr,WINHTTP_NO_REFERER,WINHTTP_DEFAULT_ACCEPT_TYPES,0);WinHttpSetOption(req,WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET,nullptr,0);
  if(!WinHttpSendRequest(req,WINHTTP_NO_ADDITIONAL_HEADERS,0,WINHTTP_NO_REQUEST_DATA,0,0,0)||!WinHttpReceiveResponse(req,nullptr))throw std::runtime_error("CDP upgrade failed");
  socket=WinHttpWebSocketCompleteUpgrade(req,0);WinHttpCloseHandle(req);if(!socket)throw std::runtime_error("CDP WebSocket unavailable");
 }
 ~Cdp(){if(socket)WinHttpCloseHandle(socket);if(connection)WinHttpCloseHandle(connection);if(session)WinHttpCloseHandle(session);}
 Json call(const std::string &method,const Json &params=Json::object()){
  int id=++sequence;auto wire=Json{{"id",id},{"method",method},{"params",params}}.dump();
  if(WinHttpWebSocketSend(socket,WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE,(void*)wire.data(),(DWORD)wire.size()))throw std::runtime_error("CDP send failed");
  for(int i=0;i<100;i++){std::string message;WINHTTP_WEB_SOCKET_BUFFER_TYPE type;do{char buffer[16384];DWORD n=0;auto error=WinHttpWebSocketReceive(socket,buffer,sizeof(buffer),&n,&type);if(error)throw std::runtime_error("CDP receive failed: "+std::to_string(error));message.append(buffer,n);}while(type==WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE);auto parsed=Json::parse(message);if(parsed.value("id",0)==id){if(parsed.contains("error"))throw std::runtime_error(parsed["error"].dump());return parsed["result"];}}
  throw std::runtime_error("CDP response limit");
 }
 Json evaluate(const std::string &expression){auto result=call("Runtime.evaluate",{{"expression",expression},{"returnByValue",true},{"awaitPromise",true}});if(result.contains("exceptionDetails"))throw std::runtime_error("CDP expression failed");return result["result"].value("value",Json());}
};
void findOwnedWindow(const std::wstring &className){for(int i=0;i<100&&!ownedWindow;i++){for(auto h:all())if(cls(h)==className&&title(h).find(ownedMarker)!=std::wstring::npos){ownedWindow=h;break;}if(!ownedWindow)wait(100);}if(!ownedWindow)throw std::runtime_error("owned application window not found");foreground(ownedWindow);}
// TIP 激活完成（前台键盘 sink 指向 Gogaku）前发送的按键必然直通宿主——
// 这是 TSF 激活时序窗口，任何输入法都收不到。轮候就绪后再输入，
// 并把就绪耗时作为激活延迟证据记录。
static bool waitTipForeground(Json &r,const CLSID &expected){
 auto start=GetTickCount64();
 for(int i=0;i<80;++i){
  ITfThreadMgr *tm=nullptr;
  if(SUCCEEDED(CoCreateInstance(CLSID_TF_ThreadMgr,nullptr,CLSCTX_INPROC_SERVER,IID_ITfThreadMgr,(void**)&tm))&&tm){
   ITfKeystrokeMgr *km=nullptr;bool hit=false;
   if(SUCCEEDED(tm->QueryInterface(IID_ITfKeystrokeMgr,(void**)&km))&&km){
    CLSID fg{};if(SUCCEEDED(km->GetForeground(&fg))&&fg==expected)hit=true;
    km->Release();
   }
   tm->Release();
   if(hit){r["tipReadyMilliseconds"]=GetTickCount64()-start;return true;}
  }
  wait(100);
 }
 r["tipReadyMilliseconds"]=GetTickCount64()-start;r["tipReady"]=false;return false;
}
bool candidateVisibleForOwned(Json &r){bool visible=false;r["candidateWindows"]=Json::array();for(auto h:all())if(cls(h)==L"GogakuCandidateWindowV2"&&pid(h)==pid(ownedWindow)&&IsWindowVisible(h)){visible=true;r["candidateWindows"].push_back(info(h));capture(h,"candidate.png",true);r["screenshots"].push_back("candidate.png");}return visible;}
void runChrome(const std::wstring &mode,Json &r){
 ownedMarker=L"GogakuAcceptanceB94-"+std::to_wstring(GetCurrentProcessId());auto page=root/(ownedMarker+L".html");
 std::ofstream(page)<<"<!doctype html><meta charset=utf-8><title>"<<utf8(ownedMarker)<<"</title><style>body{font:24px sans-serif;padding:24px}textarea,input{display:block;width:600px;height:100px;margin:20px;font:28px sans-serif}</style><label>Synthetic source<textarea id=source autofocus></textarea></label><label>Synthetic target<textarea id=target></textarea></label><label>Synthetic password<input id=password type=password autocomplete=off></label>";
 auto exe=root/L"tools/chrome/chrome-win64/chrome.exe";auto profile=root/(L"chrome-profile-"+std::to_wstring(GetCurrentProcessId()));
 auto url=L"file:///"+page.generic_wstring();launch(exe.wstring(),L"--user-data-dir=\""+profile.wstring()+L"\" --no-first-run --disable-default-apps --disable-background-networking --disable-sync --disable-component-update --remote-debugging-port=9228 \""+url+L"\"");
 findOwnedWindow(L"Chrome_WidgetWin_1");wait(300);Cdp cdp(9228,utf8(ownedMarker));activateDev(r);wait(250);
 auto selector=mode==L"chrome-password"?"password":"source";cdp.evaluate(std::string("document.getElementById('")+selector+"').focus();true");wait(150);r["target"]=info(ownedWindow);r["modulesBefore"]=modulesFor(pid(ownedWindow));
 if(mode==L"chrome-focus"){
  guardedKey('N');guardedKey('I');cdp.evaluate("document.getElementById('target').focus();true");wait(250);guardedKey(VK_SPACE);
  auto values=cdp.evaluate("({source:document.getElementById('source').value,target:document.getElementById('target').value,active:document.activeElement.id})");r["values"]=values;r["candidateVisibleAfterFocus"]=candidateVisibleForOwned(r);r["ok"]=values["source"]==""&&values["target"]==" "&&!r["candidateVisibleAfterFocus"].get<bool>();
 }else{
  for(auto k:{'N','I','H','C'})guardedKey((WORD)k);wait(200);r["candidateVisible"]=candidateVisibleForOwned(r);guardedKey(VK_SPACE);wait(200);
  auto value=cdp.evaluate(std::string("document.getElementById('")+selector+"').value");std::string expected=mode==L"chrome-password"?"nihc ":"你好";r["savedText"]=value;r["expectedText"]=expected;r["ok"]=value==expected&&r["candidateVisible"].get<bool>()==(mode!=L"chrome-password");
 }
 r["modulesAfter"]=modulesFor(pid(ownedWindow));PostMessageW(ownedWindow,WM_CLOSE,0,0);wait(200);r["syntheticWindowClosed"]=!IsWindow(ownedWindow);
}
// 与代理端解读一致：settings 缺少 appDefaultEnglish 时视为无默认英文应用。
bool englishDefault(const std::string &name){
 auto path=fs::path(_wgetenv(L"LOCALAPPDATA"))/L"Gogaku/settings.json";if(!fs::exists(path))return false;std::ifstream input(path);auto settings=Json::parse(input);if(!settings.contains("appDefaultEnglish")||!settings["appDefaultEnglish"].is_array())return false;
 for(auto &entry:settings["appDefaultEnglish"]){auto id=entry.is_string()?entry.get<std::string>():entry.value("id","");if(id==name&&(entry.is_string()||entry.value("enabled",true)))return true;}return false;
}
void runCode(Json &r){
 ownedMarker=L"GogakuAcceptanceB94-"+std::to_wstring(GetCurrentProcessId());auto file=root/(ownedMarker+L".txt");std::ofstream(file)<<"";
 auto profile=root/(L"vscode-profile-"+std::to_wstring(GetCurrentProcessId()));fs::create_directories(profile/L"User");std::ofstream(profile/L"User/settings.json")<<Json{{"workbench.startupEditor","none"},{"security.workspace.trust.enabled",false},{"telemetry.telemetryLevel","off"},{"workbench.enableExperiments",false},{"update.mode","none"},{"extensions.autoUpdate",false},{"window.restoreWindows","none"}}.dump();
 launch((root/L"tools/vscode/Code.exe").wstring(),L"--user-data-dir=\""+profile.wstring()+L"\" --extensions-dir=\""+(profile/L"extensions").wstring()+L"\" --disable-extensions --disable-workspace-trust --new-window --skip-welcome --skip-release-notes \""+file.wstring()+L"\"");
 findOwnedWindow(L"Chrome_WidgetWin_1");wait(500);activateDev(r);
 // VS Code 等繁忙宿主的 TIP 激活可能晚于激活调用数秒；模拟真实用户等应用
 // 稳定后再按恢复 Shift。激活前发送的按键任何输入法都收不到（b98/b99 code
 // 轮实测直通）。
 wait(3000);
 r["defaultEnglish"]=englishDefault("code.exe");if(r["defaultEnglish"].get<bool>())guardedKey(VK_SHIFT);
 for(auto k:{'N','I','H','C'})guardedKey((WORD)k);wait(200);r["candidateVisible"]=candidateVisibleForOwned(r);guardedKey(VK_SPACE);guardedKey('S',true);wait(400);r["savedText"]=bytesOf(file);r["expectedText"]="你好";r["target"]=info(ownedWindow);r["modules"]=modulesFor(pid(ownedWindow));r["ok"]=r["savedText"]=="你好"&&r["candidateVisible"].get<bool>();PostMessageW(ownedWindow,WM_CLOSE,0,0);wait(200);r["syntheticWindowClosed"]=!IsWindow(ownedWindow);
}
void runTerminal(Json &r){
 ownedMarker=L"GogakuAcceptanceB94-"+std::to_wstring(GetCurrentProcessId());auto receipt=root/(ownedMarker+L"-receipt.txt");auto script=root/(ownedMarker+L".ps1");
 std::ofstream(script)<<"$Host.UI.RawUI.WindowTitle='"<<utf8(ownedMarker)<<"'\n[Console]::WriteLine('Synthetic Gogaku input; no shell command is executed')\n$value=[Console]::ReadLine()\n[IO.File]::WriteAllText('"<<utf8(receipt.wstring())<<"',$value,(New-Object Text.UTF8Encoding($false)))\nStart-Sleep -Seconds 2\n";
 auto wt=fs::path(_wgetenv(L"LOCALAPPDATA"))/L"Microsoft/WindowsApps/wt.exe";launch(wt.wstring(),L"-w new new-tab --title \""+ownedMarker+L"\" --suppressApplicationTitle powershell.exe -NoProfile -ExecutionPolicy Bypass -File \""+script.wstring()+L"\"");
 findOwnedWindow(L"CASCADIA_HOSTING_WINDOW_CLASS");wait(400);activateDev(r);wait(250);
 r["defaultEnglish"]=englishDefault("windowsterminal.exe");if(r["defaultEnglish"].get<bool>())guardedKey(VK_SHIFT);
 for(auto k:{'N','I','H','C'})guardedKey((WORD)k);wait(200);r["candidateVisible"]=candidateVisibleForOwned(r);guardedKey(VK_SPACE);r["target"]=info(ownedWindow);r["modules"]=modulesFor(pid(ownedWindow));guardedKey(VK_RETURN);
 for(int i=0;i<30&&!fs::exists(receipt);i++)wait(100);r["receiptExists"]=fs::exists(receipt);r["savedText"]=bytesOf(receipt);r["expectedText"]="你好";r["ok"]=r["receiptExists"].get<bool>()&&r["savedText"]=="你好"&&r["candidateVisible"].get<bool>();wait(2300);r["syntheticWindowClosed"]=!IsWindow(ownedWindow);
}
