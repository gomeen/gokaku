// Exercises the production TSF callbacks with synthetic COM contexts and ranges.
// No host input, real user data, agent process or translations are accessed.
#include "../windows/GogakuTsf/src/stdafx.h"
#include "../shared/third_party/json.hpp"
#include <atomic>
#include <filesystem>
#define private public
#include "../windows/GogakuTsf/src/core_bridge.h"
#undef private
#include "../windows/GogakuTsf/src/candidate_window.h"
#include <map>
#define private public
#include "../windows/GogakuTsf/src/text_service.h"
#undef private
#include <inputscope.h>
#include <textstor.h>
#include <fstream>
#include <stdexcept>

HINSTANCE g_hInst=nullptr;
LONG g_objects=0;
using gw::Json;
static std::vector<Json> requests;
static std::vector<RECT> toastAnchors;
static bool connectReady,openReady,failEvent;
static ULONG foregroundPid;
static ULONGLONG now;
static SHORT controlState;
static Json openView,eventView;

HWND WINAPI probeForegroundWindow(){return nullptr;}
DWORD WINAPI probeWindowThreadProcessId(HWND,LPDWORD pid){*pid=foregroundPid;return 1;}
SHORT WINAPI probeKeyState(int vk){return vk==VK_CONTROL?controlState:0;}
ULONGLONG WINAPI probeTickCount(){return now;}
int WINAPI probeToUnicode(UINT vk,UINT,const BYTE *,LPWSTR out,int,UINT,HKL){
    if(vk!='A')return 0;
    *out=L'a';return 1;
}
LONG WINAPI probeAppUserModelId(HANDLE,UINT32 *,PWSTR){return APPMODEL_ERROR_NO_APPLICATION;}
bool CoreBridge::connect(){
    if(connectReady&&!connected())rpc_.pipe_=CreateEventW(nullptr,FALSE,FALSE,nullptr);
    return connected();
}
bool CoreBridge::warmUp(){return connect();}
bool CoreBridge::request(const Json &request,Json &view){
    requests.push_back(request);
    view=Json::object();
    if(request["op"]=="open"){view=openView;return openReady;}
    if(request["op"]=="event"){view=eventView;return !failEvent;}
    return true;
}
struct gw::CandidateRenderer::Impl {};
gw::CandidateRenderer::~CandidateRenderer()=default;
bool CandidateWindow::create(HINSTANCE){return true;}
void CandidateWindow::destroy(){}
void CandidateWindow::hide(){}
void CandidateWindow::updateSettings(const Json &){}
void CandidateWindow::showView(const Json &view,const RECT &caret){
    m_caret=caret;m_haveCaret=true;
    if(view.value("toast",0))toastAnchors.push_back(caret);
}
std::string Utf16ToUtf8(const std::wstring &v){return gw::utf8(v);}
std::wstring Utf8ToUtf16(const std::string &v){return gw::wide(v);}
#define REFS \
 ULONG refs=1; \
 STDMETHODIMP_(ULONG) AddRef() override{return ++refs;} \
 STDMETHODIMP_(ULONG) Release() override{return --refs;}
#define OBJECT \
 REFS \
 STDMETHODIMP QueryInterface(REFIID iid,void **out) override{if(!out)return E_POINTER;*out=nullptr;if(iid!=IID_IUnknown)return E_NOINTERFACE;*out=static_cast<IUnknown*>(this);AddRef();return S_OK;}
#define UNUSED(name,args) STDMETHODIMP name args override{return E_NOTIMPL;}
struct Range:ITfRange {
 OBJECT
 std::wstring text=L"ni";TfEditCookie clearedWith=0;HRESULT writeResult=S_OK;
 STDMETHODIMP SetText(TfEditCookie cookie,DWORD,const WCHAR *value,LONG count) override{clearedWith=cookie;if(SUCCEEDED(writeResult))text.assign(value,count);return writeResult;}
 UNUSED(GetText,(TfEditCookie,DWORD,WCHAR*,ULONG,ULONG*))
 UNUSED(GetFormattedText,(TfEditCookie,IDataObject**))
 UNUSED(GetEmbedded,(TfEditCookie,REFGUID,REFIID,IUnknown**))
 UNUSED(InsertEmbedded,(TfEditCookie,DWORD,IDataObject*))
 UNUSED(ShiftStart,(TfEditCookie,LONG,LONG*,const TF_HALTCOND*))
 UNUSED(ShiftEnd,(TfEditCookie,LONG,LONG*,const TF_HALTCOND*))
 UNUSED(ShiftStartToRange,(TfEditCookie,ITfRange*,TfAnchor))
 UNUSED(ShiftEndToRange,(TfEditCookie,ITfRange*,TfAnchor))
 UNUSED(ShiftStartRegion,(TfEditCookie,TfShiftDir,BOOL*))
 UNUSED(ShiftEndRegion,(TfEditCookie,TfShiftDir,BOOL*))
 UNUSED(IsEmpty,(TfEditCookie,BOOL*))
 UNUSED(Collapse,(TfEditCookie,TfAnchor))
 UNUSED(IsEqualStart,(TfEditCookie,ITfRange*,TfAnchor,BOOL*))
 UNUSED(IsEqualEnd,(TfEditCookie,ITfRange*,TfAnchor,BOOL*))
 UNUSED(CompareStart,(TfEditCookie,ITfRange*,TfAnchor,LONG*))
 UNUSED(CompareEnd,(TfEditCookie,ITfRange*,TfAnchor,LONG*))
 UNUSED(AdjustForInsert,(TfEditCookie,ULONG,BOOL*))
 UNUSED(GetGravity,(TfGravity*,TfGravity*))
 UNUSED(SetGravity,(TfEditCookie,TfGravity,TfGravity))
 UNUSED(Clone,(ITfRange**))
 UNUSED(GetContext,(ITfContext**))
};
struct Scope:ITfInputScope {
 REFS
 bool privateInput=false;
 STDMETHODIMP QueryInterface(REFIID iid,void **out) override{
  *out=nullptr;if(iid!=IID_ITfInputScope&&iid!=IID_IUnknown)return E_NOINTERFACE;*out=this;AddRef();return S_OK;
 }
 STDMETHODIMP GetInputScopes(InputScope **out,UINT *count) override{
  *out=static_cast<InputScope*>(CoTaskMemAlloc(sizeof(InputScope)));if(!*out)return E_OUTOFMEMORY;
  **out=privateInput?IS_PASSWORD:IS_DEFAULT;*count=1;return S_OK;
 }
 UNUSED(GetPhrase,(BSTR**,UINT*))
 UNUSED(GetRegularExpression,(BSTR*))
 UNUSED(GetSRGS,(BSTR*))
 UNUSED(GetXML,(BSTR*))
};
struct ScopeProperty:ITfReadOnlyProperty {
 OBJECT
 Scope scope;
 STDMETHODIMP GetValue(TfEditCookie,ITfRange*,VARIANT *value) override{
  value->vt=VT_UNKNOWN;value->punkVal=&scope;scope.AddRef();return S_OK;
 }
 UNUSED(GetType,(GUID*))
 UNUSED(EnumRanges,(TfEditCookie,IEnumTfRanges**,ITfRange*))
 UNUSED(GetContext,(ITfContext**))
};
struct Compartment:ITfCompartment {
 OBJECT
 UNUSED(SetValue,(TfClientId,const VARIANT*))
 STDMETHODIMP GetValue(VARIANT *value) override{value->vt=VT_I4;value->lVal=0;return S_OK;}
};
struct ContextView:ITfContextView {
 OBJECT
 RECT rect{10,20,30,40};bool available=true;
 STDMETHODIMP GetTextExt(TfEditCookie,ITfRange*,RECT *out,BOOL *clipped) override{
  if(!available)return E_FAIL;
  *out=rect;*clipped=FALSE;return S_OK;
 }
 UNUSED(GetRangeFromPoint,(TfEditCookie,const POINT*,DWORD,ITfRange**))
 UNUSED(GetScreenExt,(RECT*))
 UNUSED(GetWnd,(HWND*))
};
struct Context:ITfContext,ITfCompartmentMgr {
 REFS
 Range selection;
 ScopeProperty property;
 Compartment compartment;
 ContextView view;
 STDMETHODIMP QueryInterface(REFIID iid,void **out) override{
  *out=nullptr;
  if(iid==IID_ITfCompartmentMgr)*out=static_cast<ITfCompartmentMgr*>(this);
  else if(iid==IID_IUnknown)*out=static_cast<ITfContext*>(this);
  else return E_NOINTERFACE;
  AddRef();return S_OK;
 }
 STDMETHODIMP GetCompartment(REFGUID,ITfCompartment **out) override{*out=&compartment;compartment.AddRef();return S_OK;}
 UNUSED(ClearCompartment,(TfClientId,REFGUID))
 UNUSED(EnumCompartments,(IEnumGUID**))
 STDMETHODIMP RequestEditSession(TfClientId,ITfEditSession *session,DWORD,HRESULT *result) override{
  *result=session->DoEditSession(42);return S_OK;
 }
 UNUSED(InWriteSession,(TfClientId,BOOL*))
 STDMETHODIMP GetSelection(TfEditCookie,ULONG,ULONG,TF_SELECTION *out,ULONG *count) override{
  *out={&selection,{TF_AE_END,FALSE}};selection.AddRef();*count=1;return S_OK;
 }
 UNUSED(SetSelection,(TfEditCookie,ULONG,const TF_SELECTION*))
 UNUSED(GetStart,(TfEditCookie,ITfRange**))
 UNUSED(GetEnd,(TfEditCookie,ITfRange**))
 STDMETHODIMP GetActiveView(ITfContextView **out) override{*out=&view;view.AddRef();return S_OK;}
 UNUSED(EnumViews,(IEnumTfContextViews**))
 STDMETHODIMP GetStatus(TF_STATUS *status) override{*status={};return S_OK;}
 UNUSED(GetProperty,(REFGUID,ITfProperty**))
 STDMETHODIMP GetAppProperty(REFGUID,ITfReadOnlyProperty **out) override{*out=&property;property.AddRef();return S_OK;}
 UNUSED(TrackProperties,(const GUID**,ULONG,const GUID**,ULONG,ITfReadOnlyProperty**))
 UNUSED(EnumProperties,(IEnumTfProperties**))
 UNUSED(GetDocumentMgr,(ITfDocumentMgr**))
 UNUSED(CreateRangeBackup,(TfEditCookie,ITfRange*,ITfRangeBackup**))
};
struct Document:ITfDocumentMgr {
 OBJECT
 Context *top=nullptr;
 STDMETHODIMP GetTop(ITfContext **out) override{*out=top;if(top)top->AddRef();return S_OK;}
 UNUSED(CreateContext,(TfClientId,DWORD,IUnknown*,ITfContext**,TfEditCookie*))
 UNUSED(Push,(ITfContext*))
 UNUSED(Pop,(DWORD))
 UNUSED(GetBase,(ITfContext**))
 UNUSED(EnumContexts,(IEnumTfContexts**))
};
struct Manager:ITfThreadMgr {
 OBJECT
 Document document;
 STDMETHODIMP GetFocus(ITfDocumentMgr **out) override{*out=&document;document.AddRef();return S_OK;}
 UNUSED(Activate,(TfClientId*))
 UNUSED(Deactivate,())
 UNUSED(CreateDocumentMgr,(ITfDocumentMgr**))
 UNUSED(EnumDocumentMgrs,(IEnumTfDocumentMgrs**))
 UNUSED(SetFocus,(ITfDocumentMgr*))
 UNUSED(AssociateFocus,(HWND,ITfDocumentMgr*,ITfDocumentMgr**))
 UNUSED(IsThreadFocus,(BOOL*))
 UNUSED(GetFunctionProvider,(REFCLSID,ITfFunctionProvider**))
 UNUSED(EnumFunctionProviders,(IEnumTfFunctionProviders**))
 UNUSED(GetGlobalCompartment,(ITfCompartmentMgr**))
};
struct Composition:ITfComposition {
 OBJECT
 Range &range;unsigned ended=0;
 explicit Composition(Range &value):range(value){}
 STDMETHODIMP GetRange(ITfRange **out) override{*out=&range;range.AddRef();return S_OK;}
 STDMETHODIMP EndComposition(TfEditCookie) override{++ended;return S_OK;}
 UNUSED(ShiftStart,(TfEditCookie,ITfRange*))
 UNUSED(ShiftEnd,(TfEditCookie,ITfRange*))
};
#undef OBJECT
#undef REFS
#undef UNUSED
static void check(bool value,const char *message){if(!value)throw std::runtime_error(message);}
static void runCase(bool denied){
 Context context;Range range;Composition composition(range),unrelated(range);
 {
  TextService service;
  context.AddRef();service.context_=&context;
  composition.AddRef();service.composition_=&composition;
  range.AddRef();service.anchor_=&range;
  context.AddRef();service.fields_.emplace(static_cast<ITfContext*>(&context),1);service.nextField_=1;
  service.opened_=true;service.field_="probe:1";service.view_={{"raw","ni"},{"composing",true}};
  requests.clear();
  service.OnCompositionTerminated(42,&unrelated);
  check(service.opened_&&service.composition_==&composition&&requests.empty(),"unrelated termination changed live composition");
  service.editing_=true;service.OnCompositionTerminated(42,&composition);service.editing_=false;
  check(service.opened_&&service.composition_==&composition&&requests.empty(),"own edit termination changed live composition");
  if(denied)range.writeResult=E_ACCESSDENIED;
  service.OnCompositionTerminated(42,&composition);
  check(requests.size()==1&&requests[0].value("op","")=="focus"&&requests[0].value("field","missing").empty(),"terminated composition retained agent commit eligibility");
  check(!service.context_&&!service.composition_&&!service.anchor_&&!service.opened_&&service.view_.empty(),"terminated composition retained local input state");
  check(range.clearedWith==42&&composition.ended==0,"termination must use old range cookie without ending it twice");
  check(service.fields_.at(static_cast<ITfContext*>(&context))!=1,"reused context can expose old field draft");
  check(denied?range.text==L"ni":range.text.empty(),"old range clear result mismatch");
  service.OnCompositionTerminated(42,&composition);
  check(requests.size()==1,"duplicate termination resent blur");
 }
 check(context.refs==1&&range.refs==1&&composition.refs==1,"COM ownership leak");
}
struct Fixture {
 Context context,other;
 Manager manager;
 TextService service;
 Fixture(){
  foregroundPid=GetCurrentProcessId();now=1000;controlState=0;
  connectReady=false;openReady=true;failEvent=false;
  openView={{"english",0}};eventView={{"english",1},{"consumed",true},{"toast",2}};
  requests.clear();toastAnchors.clear();
  manager.document.top=&context;
  manager.AddRef();service.manager_=&manager;
 }
 bool testDown(WPARAM vk){BOOL eaten;service.OnTestKeyDown(&context,vk,0,&eaten);return eaten;}
 bool testUp(){BOOL eaten;service.OnTestKeyUp(&context,VK_LSHIFT,0,&eaten);return eaten;}
 bool up(){BOOL eaten;service.OnKeyUp(&context,VK_LSHIFT,0,&eaten);return eaten;}
 bool tap(){testDown(VK_LSHIFT);return testUp()&&up();}
};
static size_t requestCount(const char *op){
 return std::count_if(requests.begin(),requests.end(),[&](const Json &r){return r["op"]==op;});
}
static void coldTap(bool defaultEnglish,bool timer){
 Fixture f;
 openView["english"]=defaultEnglish?1:0;
 eventView["english"]=defaultEnglish?0:1;
 eventView["toast"]=defaultEnglish?1:2;
 check(!f.testDown(VK_LSHIFT),"Shift down was eaten");
 check(f.testUp(),"TSF would skip cold Shift up");
 check(!f.up()&&requests.empty(),"cold Shift reported an agent dispatch");
 check(!f.testDown('A')&&requests.empty(),"ordinary key was intercepted before the agent was ready");
 connectReady=true;openReady=false;
 f.service.idle();
 check(requestCount("event")==0,"Shift reached the agent before focus sync");
 requests.clear();openReady=true;
 if(timer)f.service.idle();
 check(f.testDown('A')==defaultEnglish,"next key still followed pre-Shift mode");
 f.service.idle();
 check(requests.size()>=2&&requests[0]["op"]=="open"&&requests[1]["kind"]==GC_EV_SHIFT_CLICK&&requestCount("event")==1,
       "deferred Shift did not follow focus sync exactly once");
}
static void warmTap(bool consumed){
 Fixture f;
 connectReady=true;f.service.idle();requests.clear();eventView["consumed"]=consumed;
 check(f.testDown(VK_LSHIFT)==false&&f.testUp(),"TSF would skip warm Shift up");
 check(f.up()==consumed&&requestCount("event")==1,"Shift up did not return agent consumed status");
}
static void droppedTap(const char *when){
 Fixture f;
 f.testDown(VK_LSHIFT);
 check(f.testUp(),"TSF would skip cold Shift up");
 f.up();
 const std::string trigger=when;
 if(trigger=="expiry")now+=600;
 if(trigger=="context")f.manager.document.top=&f.other;
 if(trigger=="foreground"){foregroundPid=0;f.service.idle();foregroundPid=GetCurrentProcessId();}
 if(trigger=="private"){f.context.property.scope.privateInput=true;f.service.idle();f.context.property.scope.privateInput=false;}
 if(trigger=="document")f.service.OnSetFocus(&f.manager.document,&f.manager.document);
 if(trigger=="keyboard"){f.service.OnSetFocus(FALSE);connectReady=true;f.service.OnSetFocus(TRUE);}
 connectReady=true;f.service.idle();
 check(requestCount("open")==1&&requestCount("event")==0,"deferred Shift crossed a focus or expiry boundary");
}
static void invalidTap(){
 Fixture f;
 connectReady=true;f.service.idle();
 controlState=static_cast<SHORT>(0x8000);f.testDown(VK_LSHIFT);controlState=0;
 check(!f.testUp(),"modified Shift was claimed");
 f.testDown(VK_LSHIFT);f.testDown('A');
 check(!f.testUp(),"Shift chord was claimed");
 f.testDown(VK_LSHIFT);now+=600;
 check(!f.testUp(),"long Shift hold was claimed");
 f.testDown(VK_LSHIFT);f.context.property.scope.privateInput=true;
 check(!f.testUp(),"private Shift was claimed");
 f.context.property.scope.privateInput=false;
 f.testDown(VK_LSHIFT);f.manager.document.top=&f.other;
 BOOL eaten;f.service.OnTestKeyUp(&f.other,VK_LSHIFT,0,&eaten);
 check(!eaten&&requestCount("event")==0,"Shift up in another context was claimed");
}
static void missedRelease(){
 Fixture f;
 connectReady=true;f.service.idle();
 f.testDown(VK_LSHIFT);
 now+=600;
 BOOL eaten;
 f.service.OnTestKeyDown(&f.context,VK_LSHIFT,1L<<30,&eaten);
 check(!f.testUp(),"auto-repeat restarted an expired Shift press");
 f.testDown(VK_LSHIFT);
 now+=600;
 check(f.tap()&&requestCount("event")==1,"missing release blocked the next Shift tap");
}
static void noReplay(){
 Fixture f;
 f.testDown(VK_LSHIFT);
 check(f.testUp(),"TSF would skip cold Shift up");
 f.up();
 connectReady=true;failEvent=true;f.service.idle();
 check(requestCount("event")==1,"first Shift RPC was not attempted");
 failEvent=false;f.service.idle();
 check(requestCount("event")==1,"possibly applied Shift RPC was retried");
}
static void demotedSink(){
 Fixture f;
 connectReady=true;f.service.idle();
 f.service.OnSetFocus(FALSE);
 check(requestCount("focus")==1,"demotion did not blur the agent session");
 requests.clear();
 f.service.idle();f.service.OnSetFocus(&f.manager.document,&f.manager.document);f.testDown('A');
 check(requests.empty(),"demoted keyboard sink reclaimed the session from the same process");
 f.service.OnSetFocus(TRUE);
 check(requestCount("open")==1,"keyboard focus gain did not reopen the session");
}
static void pendingContextOwnership(){
 Fixture f;
 f.testDown(VK_LSHIFT);
 check(f.testUp(),"TSF would skip cold Shift up");
 f.up();
 f.service.Deactivate();
 check(f.context.refs==1&&f.manager.refs==1,"deferred Shift left unbalanced COM references");
}
static void toastCaret(){
 Fixture f;
 connectReady=true;f.service.idle();
 f.tap();
 check(toastAnchors.size()==1&&EqualRect(&toastAnchors[0],&f.context.view.rect),"first toast omitted the current caret");
 f.context.view.rect.left=15;
 f.context.view.rect.right=15;
 check(f.tap()&&toastAnchors.size()==2&&EqualRect(&toastAnchors[1],&f.context.view.rect),"next toast reused an old caret");
}
static void unavailableToastCaret(bool emptyRect){
 Fixture f;
 connectReady=true;f.service.idle();
 f.service.apply({{"draftAvailable",true}}); // Seed the panel's caret the same way a draft does.
 f.manager.document.top=&f.other;
 f.service.OnSetFocus(&f.manager.document,nullptr);
 if(emptyRect)f.other.view.rect={};
 else f.other.view.available=false;
 BOOL eaten;
 f.service.OnTestKeyDown(&f.other,VK_LSHIFT,0,&eaten);
 f.service.OnTestKeyUp(&f.other,VK_LSHIFT,0,&eaten);
 check(eaten,"safe context with no caret did not accept language toggle");
 f.service.OnKeyUp(&f.other,VK_LSHIFT,0,&eaten);
 check(toastAnchors.empty(),"toast was drawn at the previous context's caret");
 check(eaten,"language toggle was lost when the caret was unavailable");
}
int main(){
 Json result={{"ok",true},{"checks",Json::array()}};
 auto run=[&](const std::string &name,auto test){
  try{test();result["checks"].push_back({{"name",name},{"passed",true}});}
  catch(const std::exception &error){result["ok"]=false;result["checks"].push_back({{"name",name},{"passed",false},{"error",error.what()}});}
 };
 for(bool denied:{false,true})run(denied?"clear-failed-still-revokes":"external-termination",[&]{runCase(denied);});
 run("cold-chinese-to-english-on-key",[]{coldTap(false,false);});
 run("cold-default-english-to-chinese-on-timer",[]{coldTap(true,true);});
 run("warm-shift-consumed",[]{warmTap(true);});
 run("warm-shift-unconsumed",[]{warmTap(false);});
 for(auto when:{"expiry","context","foreground","private","document","keyboard"})run(std::string("drop-on-")+when,[&]{droppedTap(when);});
 run("reject-invalid-shift-taps",invalidTap);
 run("recover-after-missed-shift-release",missedRelease);
 run("no-replay-after-event-rpc-failure",noReplay);
 run("demoted-keyboard-sink",demotedSink);
 run("deferred-context-ownership",pendingContextOwnership);
 run("toast-caret",toastCaret);
 run("unavailable-toast-caret",[]{unavailableToastCaret(false);});
 run("empty-toast-caret",[]{unavailableToastCaret(true);});
 std::ofstream(gw::modulePath().parent_path()/L"result.json")<<result.dump(2)<<"\n";
 return result.value("ok",false)?0:1;
}
