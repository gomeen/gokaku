// Exercises the production TSF termination callback with synthetic COM ranges.
// No host input, real user data, agent process or translations are accessed.
#include "../windows/GogakuTsf/src/stdafx.h"
#include "../windows/GogakuTsf/src/core_bridge.h"
#include "../windows/GogakuTsf/src/candidate_window.h"
#include <map>
#define private public
#include "../windows/GogakuTsf/src/text_service.h"
#undef private
#include <fstream>
#include <stdexcept>

HINSTANCE g_hInst=nullptr;
LONG g_objects=0;
using gw::Json;
static std::vector<Json> requests;
bool CoreBridge::connect(){return false;}
bool CoreBridge::warmUp(){return false;}
bool CoreBridge::request(const Json &request,Json &view){requests.push_back(request);view=Json::object();return true;}
std::string Utf16ToUtf8(const std::wstring &v){return gw::utf8(v);}
std::wstring Utf8ToUtf16(const std::string &v){return gw::wide(v);}
#define OBJECT \
 ULONG refs=1; \
 STDMETHODIMP QueryInterface(REFIID iid,void **out) override{if(!out)return E_POINTER;*out=nullptr;if(iid!=IID_IUnknown)return E_NOINTERFACE;*out=static_cast<IUnknown*>(this);AddRef();return S_OK;} \
 STDMETHODIMP_(ULONG) AddRef() override{return ++refs;} \
 STDMETHODIMP_(ULONG) Release() override{return --refs;}
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
struct Context:ITfContext {
 OBJECT
 UNUSED(RequestEditSession,(TfClientId,ITfEditSession*,DWORD,HRESULT*))
 UNUSED(InWriteSession,(TfClientId,BOOL*))
 UNUSED(GetSelection,(TfEditCookie,ULONG,ULONG,TF_SELECTION*,ULONG*))
 UNUSED(SetSelection,(TfEditCookie,ULONG,const TF_SELECTION*))
 UNUSED(GetStart,(TfEditCookie,ITfRange**))
 UNUSED(GetEnd,(TfEditCookie,ITfRange**))
 UNUSED(GetActiveView,(ITfContextView**))
 UNUSED(EnumViews,(IEnumTfContextViews**))
 UNUSED(GetStatus,(TF_STATUS*))
 UNUSED(GetProperty,(REFGUID,ITfProperty**))
 UNUSED(GetAppProperty,(REFGUID,ITfReadOnlyProperty**))
 UNUSED(TrackProperties,(const GUID**,ULONG,const GUID**,ULONG,ITfReadOnlyProperty**))
 UNUSED(EnumProperties,(IEnumTfProperties**))
 UNUSED(GetDocumentMgr,(ITfDocumentMgr**))
 UNUSED(CreateRangeBackup,(TfEditCookie,ITfRange*,ITfRangeBackup**))
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
#undef UNUSED
static void check(bool value,const char *message){if(!value)throw std::runtime_error(message);}
static void runCase(bool denied,Json &checks){
 Context context;Range range;Composition composition(range),unrelated(range);
 {
  TextService service;
  context.AddRef();service.context_=&context;
  composition.AddRef();service.composition_=&composition;
  range.AddRef();service.anchor_=&range;
  context.AddRef();service.fields_.emplace(static_cast<IUnknown*>(&context),1);service.nextField_=1;
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
  check(service.fields_.at(static_cast<IUnknown*>(&context))!=1,"reused context can expose old field draft");
  check(denied?range.text==L"ni":range.text.empty(),"old range clear result mismatch");
  service.OnCompositionTerminated(42,&composition);
  check(requests.size()==1,"duplicate termination resent blur");
 }
 check(context.refs==1&&range.refs==1&&composition.refs==1,"COM ownership leak");
 checks.push_back({{"name",denied?"clear-failed-still-revokes":"external-termination"},{"passed",true}});
}
int main(){
 Json result={{"ok",false},{"checks",Json::array()}};
 try{runCase(false,result["checks"]);runCase(true,result["checks"]);result["ok"]=true;}
 catch(const std::exception &error){result["error"]=error.what();}
 std::ofstream(gw::modulePath().parent_path()/L"result.json")<<result.dump(2)<<"\n";
 return result.value("ok",false)?0:1;
}
