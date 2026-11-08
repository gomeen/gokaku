from pathlib import Path
import subprocess
root=Path.cwd(); out=root/'local/windows-tsf-diagnosis';out.mkdir(exist_ok=True)
s=(root/'windows/GogakuTsf/src/text_service.cpp').read_text()
s=s.replace('#include "text_service.h"',f'#include "{root}/windows/GogakuTsf/src/text_service.h"\n#include <fstream>\nstatic void trace(const char *name,long a=0,long b=0){{wchar_t temp[MAX_PATH]{{}};GetTempPathW(MAX_PATH,temp);std::ofstream f(std::filesystem::path(temp)/(L"GogakuTsfDiag-"+std::to_wstring(GetCurrentProcessId())+L".log"),std::ios::app);f<<GetTickCount64()<<" "<<name<<" "<<a<<" "<<b<<"\\n";}}')
s=s.replace('#include "native_edit_safety.h"',f'#include "{root}/windows/GogakuTsf/src/native_edit_safety.h"')
s=s.replace('if(!safe(context)) {loseFocus();return false;}','if(!safe(context)) {trace("unsafe",opened_,view_.value("raw",std::string()).size());loseFocus();return false;}')
s=s.replace('if(!bridge_.connect())return false;','if(!bridge_.connect()){trace("connect-fail");return false;}')
s=s.replace('opened_=true;apply(view);','trace("open",view.value("raw",std::string()).size(),sameObject(context_,context));opened_=true;apply(view);')
s=s.replace('if(syncContext(context))*eaten=shouldClaim(context,vk,lp);return S_OK;','trace("test-enter",opened_,view_.value("raw",std::string()).size());if(syncContext(context))*eaten=shouldClaim(context,vk,lp);trace("test-exit",*eaten,view_.value("raw",std::string()).size());return S_OK;')
s=s.replace('try{if(!safe(context)||!syncContext(context))return S_OK;Json event;if(buildEvent(vk,lp,event))*eaten=dispatch(event);}','try{trace("key-enter",opened_,view_.value("raw",std::string()).size());if(!safe(context)||!syncContext(context)){trace("key-unsafe");return S_OK;}Json event;if(buildEvent(vk,lp,event))*eaten=dispatch(event);trace("key-exit",*eaten,view_.value("raw",std::string()).size());}')
s=s.replace('session->Release();return SUCCEEDED(hr)&&SUCCEEDED(result);','trace(write?"edit-write":"edit-read",hr,result);session->Release();return SUCCEEDED(hr)&&SUCCEEDED(result);')
s=s.replace('return SUCCEEDED(request)&&result==S_OK;','trace("scope-read",request,result);return SUCCEEDED(request)&&result==S_OK;')
s=s.replace('bool consumed=view.value("consumed",false);apply(view);return consumed;','trace("rpc-event",view.value("consumed",false),view.value("raw",std::string()).size());bool consumed=view.value("consumed",false);apply(view);return consumed;')
s=s.replace('void TextService::loseFocus(){','void TextService::loseFocus(){trace("lose-focus",opened_,view_.value("raw",std::string()).size());')
s=s.replace('if(editing_||!composition_', 'trace("terminated",editing_,view_.value("raw",std::string()).size());if(editing_||!composition_')
s=s.replace('{range->SetText(cookie,0,L"",0);range->Release();}', '{auto cleared=range->SetText(cookie,0,L"",0);trace("terminated-clear",cleared,cookie);range->Release();}')
s=s.replace('if(editing_)return S_OK;','trace("terminated",editing_,view_.value("raw",std::string()).size());if(editing_)return S_OK;')
s=s.replace('if(!a||!b) return a==b;', 'if(!a||!b) return a==b;')
s=s.replace('return false;', '{trace("false",__LINE__);return false;}')
s=s.replace('auto value=gw::wide(inlineLetters?text:std::string());','trace("store-flags",status.dwStaticFlags,inlineLetters);auto value=gw::wide(inlineLetters?text:std::string());')
(out/'text_service.cpp').write_text(s)
p=(root/'windows/GogakuWindows/platform.cpp').read_text().replace('#include "platform.h"',f'#include "{root}/windows/GogakuWindows/platform.h"')
p=p.replace('return {own,{}};', 'return {active,previous};')
(out/'platform.cpp').write_text(p)
b=(root/'windows/GogakuTsf/src/core_bridge.cpp').read_text().replace('#include "core_bridge.h"',f'#include "{root}/windows/GogakuTsf/src/core_bridge.h"\n#include <fstream>\nstatic void trace(const char *name,long a=0,long b=0){{wchar_t temp[MAX_PATH]{{}};GetTempPathW(MAX_PATH,temp);std::ofstream f(std::filesystem::path(temp)/(L"GogakuTsfDiag-"+std::to_wstring(GetCurrentProcessId())+L".log"),std::ios::app);f<<GetTickCount64()<<" "<<name<<" "<<a<<" "<<b<<"\\n";}}')
b=b.replace('if (!rpc_.call(request,response,200)) return false;', 'auto start=GetTickCount64();bool ok=rpc_.call(request,response,200);auto error=GetLastError();auto name="rpc-"+request.value("op",std::string("unknown"));trace(name.c_str(),ok,GetTickCount64()-start);if(!ok){trace("rpc-error",error);return false;}')
b=b.replace('if (!response.value("ok",false)) return false;', 'if (!response.value("ok",false)){auto error=response.value("error",std::string());long code=error=="目标不在前台"?1:error=="焦点已变化，请重新输入"?2:error=="上次提交尚未确认"?3:error=="过期提交"?4:5;trace("rpc-rejected",code);return false;}')
(out/'core_bridge.cpp').write_text(b)
flags=['-std=c++20','-O2','-DNDEBUG','-DNOMINMAX','-D_WIN32_WINNT=0x0A00','-DUNICODE','-D_UNICODE','-DGOGAKU_SETTINGS_CONTRACT_STATIC','-DGOGAKU_CHANNEL="dev"','-DGOGAKU_DEV']
cxx='x86_64-w64-mingw32-g++'
for name in ['text_service','platform','core_bridge']:
 subprocess.run([cxx,*flags,'-c',str(out/(name+'.cpp')),'-o',str(out/(name+'.o'))],check=True)
obj=root/'.build/win-app/dev/obj64'
names=['dllmain','candidate_window','appearance','themes','settings_contract','theme_contract','app-resource']
libs=['user32','gdi32','ole32','oleaut32','uuid','advapi32','shell32','bcrypt','crypt32','d2d1','dwrite','windowscodecs','msimg32']
subprocess.run([cxx,'-shared','-static','-Wl,--kill-at','-o',str(out/'GogakuTsf.dll'),str(out/'text_service.o'),str(out/'platform.o'),str(out/'core_bridge.o'),*[str(obj/(n+'.o')) for n in names],str(root/'windows/GogakuTsf/gogaku_tsf.def'),*['-l'+n for n in libs]],check=True)
