#include "text_service.h"
#include "native_edit_safety.h"
#include <textstor.h>
#ifdef __MINGW32__
// MinGW's uuid import library omits the inputscope GUIDs; instantiate the
// official SDK definitions in this translation unit.
#include <initguid.h>
#endif
#include <inputscope.h>
#include <shellapi.h>
#include <appmodel.h>
#include <algorithm>
#include <cwctype>

extern LONG g_objects;
namespace {
using gw::Json;
bool sameObject(IUnknown *a,IUnknown *b) {
    if(!a||!b) return a==b;
    IUnknown *x=nullptr,*y=nullptr;
    a->QueryInterface(IID_IUnknown,(void **)&x);b->QueryInterface(IID_IUnknown,(void **)&y);
    bool same=x&&x==y;if(x)x->Release();if(y)y->Release();return same;
}
std::string appIdentity() {
    HWND foreground=GetForegroundWindow();DWORD pid=0;GetWindowThreadProcessId(foreground,&pid);
    HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
    if(!process) return {};
    // Settings stores package AUMIDs, or executable basenames for desktop apps.
    UINT32 appLength=0;
    if(GetApplicationUserModelId(process,&appLength,nullptr)==ERROR_INSUFFICIENT_BUFFER&&appLength>1&&appLength<=32768){
        std::wstring identity(appLength,L'\0');
        if(GetApplicationUserModelId(process,&appLength,identity.data())==ERROR_SUCCESS){
            CloseHandle(process);identity.resize(wcslen(identity.c_str()));for(auto &c:identity)c=(wchar_t)towlower(c);return gw::utf8(identity);
        }
    }
    std::wstring path(32768,L'\0');DWORD size=(DWORD)path.size();
    bool ok=QueryFullProcessImageNameW(process,0,path.data(),&size);CloseHandle(process);
    if(!ok)return {};path.resize(size);for(auto &c:path)c=(wchar_t)towlower(c);
    return gw::utf8(gw::fs::path(path).filename().wstring());
}
class EditSession final:public ITfEditSession {
    LONG refs_=1;std::function<HRESULT(TfEditCookie)> fn_;
public:
    explicit EditSession(std::function<HRESULT(TfEditCookie)> fn):fn_(std::move(fn)){}
    STDMETHODIMP QueryInterface(REFIID id,void **out) override {
        if(!out)return E_POINTER;*out=nullptr;
        if(id==IID_IUnknown||id==IID_ITfEditSession){*out=(ITfEditSession*)this;AddRef();return S_OK;}return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override{return InterlockedIncrement(&refs_);}
    STDMETHODIMP_(ULONG) Release() override{ULONG n=InterlockedDecrement(&refs_);if(!n)delete this;return n;}
    STDMETHODIMP DoEditSession(TfEditCookie cookie) override{try{return fn_(cookie);}catch(...){return E_FAIL;}}
};
}
TextService::TextService(){InterlockedIncrement(&g_objects);}
TextService::~TextService(){Deactivate();InterlockedDecrement(&g_objects);}
STDMETHODIMP TextService::QueryInterface(REFIID id,void **out){
    if(!out)return E_POINTER;*out=nullptr;
    if(id==IID_IUnknown||id==IID_ITfTextInputProcessor)*out=(ITfTextInputProcessor*)this;
    else if(id==IID_ITfKeyEventSink)*out=(ITfKeyEventSink*)this;
    else if(id==IID_ITfThreadMgrEventSink)*out=(ITfThreadMgrEventSink*)this;
    else if(id==IID_ITfCompositionSink)*out=(ITfCompositionSink*)this;
    if(*out){AddRef();return S_OK;}return E_NOINTERFACE;
}
STDMETHODIMP_(ULONG) TextService::AddRef(){return InterlockedIncrement(&refs_);}
STDMETHODIMP_(ULONG) TextService::Release(){ULONG n=InterlockedDecrement(&refs_);if(!n)delete this;return n;}
STDMETHODIMP TextService::Activate(ITfThreadMgr *manager,TfClientId client){
    if(!manager)return E_INVALIDARG;
    try {
        Deactivate();manager_=manager;manager_->AddRef();client_=client;
        ITfKeystrokeMgr *keys=nullptr;HRESULT hr=manager_->QueryInterface(IID_PPV_ARGS(&keys));
        if(SUCCEEDED(hr)){hr=keys->AdviseKeyEventSink(client_,this,TRUE);keys->Release();}
        if(FAILED(hr)){Deactivate();return hr;}
        ITfSource *source=nullptr;hr=manager_->QueryInterface(IID_PPV_ARGS(&source));
        if(SUCCEEDED(hr)){hr=source->AdviseSink(IID_ITfThreadMgrEventSink,(ITfThreadMgrEventSink*)this,&focusCookie_);source->Release();}
        if(FAILED(hr)||!window_.create(g_hInst)){Deactivate();return E_FAIL;}
        settings_=gw::readSettings();
        window_.onChoose=[this](size_t index){dispatch({{"op","event"},{"command","choose"},{"index",index}});};
        window_.onOriginal=[this]{dispatch({{"op","event"},{"command","original"}});};
        window_.onRestore=[this]{dispatch({{"op","event"},{"command","restore"}});};
        WNDCLASSW wc{};wc.hInstance=g_hInst;wc.lpfnWndProc=timerProc;wc.lpszClassName=L"GogakuTsfDispatch";
        if(!RegisterClassW(&wc)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS){Deactivate();return E_FAIL;}
        timer_=CreateWindowExW(0,wc.lpszClassName,L"",0,0,0,0,0,HWND_MESSAGE,nullptr,g_hInst,this);
        if(!timer_){Deactivate();return E_FAIL;}SetTimer(timer_,1,100,nullptr);
        // 代理尚未启动时保持服务激活，但在握手完成前不消费输入。
        idle();return S_OK;
    } catch(...){Deactivate();return E_FAIL;}
}
STDMETHODIMP TextService::Deactivate(){
    if(timer_){KillTimer(timer_,1);DestroyWindow(timer_);timer_=nullptr;}
    loseFocus();window_.destroy();bridge_.close();opened_=false;
    if(manager_){
        ITfKeystrokeMgr *keys=nullptr;if(SUCCEEDED(manager_->QueryInterface(IID_PPV_ARGS(&keys)))){keys->UnadviseKeyEventSink(client_);keys->Release();}
        ITfSource *source=nullptr;if(focusCookie_!=TF_INVALID_COOKIE&&SUCCEEDED(manager_->QueryInterface(IID_PPV_ARGS(&source)))){source->UnadviseSink(focusCookie_);source->Release();}
        manager_->Release();manager_=nullptr;
    }
    for(auto &item:fields_)item.first->Release();fields_.clear();focusCookie_=TF_INVALID_COOKIE;return S_OK;
}
bool TextService::safe(ITfContext *context,TfEditCookie cookie) const {
    if(!context||!manager_)return false;
    DWORD pid=0;GetWindowThreadProcessId(GetForegroundWindow(),&pid);
    if(pid!=GetCurrentProcessId())return false;
    ITfDocumentMgr *document=nullptr;ITfContext *focused=nullptr;
    HRESULT focusedResult=manager_->GetFocus(&document);
    if(SUCCEEDED(focusedResult)&&document){focusedResult=document->GetTop(&focused);document->Release();}
    bool current=SUCCEEDED(focusedResult)&&focused&&sameObject(context,focused);
    if(focused)focused->Release();if(!current)return false;
    TS_STATUS status{};
    if(FAILED(context->GetStatus(&status))||(status.dwDynamicFlags&TS_SD_READONLY))return false;
    ITfCompartmentMgr *compartments=nullptr;
    if(FAILED(context->QueryInterface(IID_PPV_ARGS(&compartments))))return false;
    const GUID ids[]={GUID_COMPARTMENT_KEYBOARD_DISABLED,GUID_COMPARTMENT_EMPTYCONTEXT};
    bool allowed=true;
    for(auto &id:ids){
        ITfCompartment *item=nullptr;VARIANT value;VariantInit(&value);
        if(SUCCEEDED(compartments->GetCompartment(id,&item))&&item){
            HRESULT hr=item->GetValue(&value);item->Release();
            if(FAILED(hr)||(value.vt==VT_I4&&value.lVal))allowed=false;
        }else allowed=false;
        VariantClear(&value);
    }
    compartments->Release();if(!allowed)return false;
    auto checkScope=[&](TfEditCookie ec)->HRESULT {
        ITfReadOnlyProperty *property=nullptr;TF_SELECTION selection{};ULONG fetched=0;
        HRESULT hr=context->GetAppProperty(GUID_PROP_INPUTSCOPE,&property);
        bool known=false,privateScope=false;
        if(hr==S_OK&&property&&SUCCEEDED(context->GetSelection(ec,TF_DEFAULT_SELECTION,1,&selection,&fetched))&&fetched==1){
            VARIANT value;VariantInit(&value);hr=property->GetValue(ec,selection.range,&value);
            if(hr==S_OK&&value.vt==VT_UNKNOWN&&value.punkVal){
                ITfInputScope *scope=nullptr;
                if(SUCCEEDED(value.punkVal->QueryInterface(IID_ITfInputScope,(void**)&scope))){
                    InputScope *scopes=nullptr;UINT count=0;
                    if(SUCCEEDED(scope->GetInputScopes(&scopes,&count))&&count){
                        known=true;for(UINT i=0;i<count;++i)if(scopes[i]==IS_PASSWORD||scopes[i]==IS_PRIVATE||scopes[i]==IS_NUMERIC_PASSWORD||scopes[i]==IS_NUMERIC_PIN||scopes[i]==IS_ALPHANUMERIC_PIN||scopes[i]==IS_ALPHANUMERIC_PIN_SET)privateScope=true;
                    }
                    CoTaskMemFree(scopes);scope->Release();
                }
            }
            VariantClear(&value);selection.range->Release();
        }
        if(property)property->Release();
        // 缺 scope 时只接受已知的原生 Edit／RichEdit，并确认焦点归属此文档。
        // 显式的密码／private scope 不走兜底，未知控件继续拒绝。
        if(!known){
            GUITHREADINFO info{sizeof(info)};ITfContextView *view=nullptr;HWND documentWindow=nullptr;
            if(SUCCEEDED(context->GetActiveView(&view))&&view){view->GetWnd(&documentWindow);view->Release();}
            if(GetGUIThreadInfo(GetCurrentThreadId(),&info))known=nativeEditFallbackSafe(info.hwndFocus,documentWindow);
        }
        return known&&!privateScope?S_OK:E_ACCESSDENIED;
    };
    if(cookie!=TF_INVALID_COOKIE)return checkScope(cookie)==S_OK;
    auto read=new EditSession(checkScope);HRESULT result=E_FAIL;
    HRESULT request=context->RequestEditSession(client_,read,TF_ES_SYNC|TF_ES_READ,&result);read->Release();
    return SUCCEEDED(request)&&result==S_OK;
}
bool TextService::syncContext(ITfContext *context){
    if(!safe(context)) {loseFocus();return false;}
    if(!sameObject(context_,context)){
        loseFocus();context_=context;context_->AddRef();
        IUnknown *identity=nullptr;context_->QueryInterface(IID_IUnknown,(void **)&identity);
        auto it=fields_.find(identity);
        if(it==fields_.end()){
            if(fields_.size()>=64){identity->Release();loseFocus();return false;}
            it=fields_.emplace(identity,fields_.size()+1).first;
        }else identity->Release();
        field_=std::to_string(GetCurrentProcessId())+":"+std::to_string(it->second);
        app_=appIdentity();opened_=false;hasCaret_=false;
    }
    if(!bridge_.connect())return false;
    if(!opened_){
        Json view;if(!bridge_.request({{"op","open"},{"app",app_},{"field",field_}},view))return false;
        opened_=true;apply(view);
    }
    return true;
}
bool TextService::shortcut(WPARAM vk,Json &event){
    uint32_t modifiers=0;
    if(GetKeyState(VK_SHIFT)&0x8000)modifiers|=1u<<17;
    if(GetKeyState(VK_CONTROL)&0x8000)modifiers|=1u<<18;
    if(GetKeyState(VK_MENU)&0x8000)modifiers|=1u<<19;
    if((GetKeyState(VK_LWIN)|GetKeyState(VK_RWIN))&0x8000)modifiers|=1u<<20;
    std::string key;
    if(vk>='A'&&vk<='Z')key=char('a'+vk-'A');
    else if(vk>='0'&&vk<='9')key=char(vk);
    else if(vk>=VK_F1&&vk<=VK_F24)key="f"+std::to_string(vk-VK_F1+1);
    else if(vk==VK_RETURN)key="return";
    else if(vk==VK_SPACE)key="space";
    else if(vk>=VK_OEM_1&&vk<=VK_OEM_8){
        BYTE state[256]{};wchar_t characters[4]{};
        if(ToUnicodeEx((UINT)vk,MapVirtualKeyW((UINT)vk,MAPVK_VK_TO_VSC),state,characters,4,4,GetKeyboardLayout(0))==1)key=gw::utf8(std::wstring(characters,1));
    }
    for(const char *name:{"modeShortcut","directionShortcut"}){
        Json binding=settings_.value(name,Json::object());
        if(!binding.value("disabled",false)&&modifiers&&binding.value("modifiers",0u)==modifiers&&binding.value("key",std::string())==key){event={{"op","event"},{"command",name==std::string("modeShortcut")?"mode":"direction"}};return true;}
    }
    return false;
}
bool TextService::buildEvent(WPARAM vk,LPARAM lp,Json &event){
    event={{"op","event"}};bool composing=view_.value("composing",false);
    bool ctrl=GetKeyState(VK_CONTROL)&0x8000,alt=GetKeyState(VK_MENU)&0x8000,win=(GetKeyState(VK_LWIN)|GetKeyState(VK_RWIN))&0x8000;
    if(shortcut(vk,event))return true;
    if(ctrl&&vk==VK_RETURN&&composing&&view_.value("learning",false)){event["command"]="original";return true;}
    if(alt&&!ctrl&&!win&&composing&&view_.value("learning",false)&&vk>='1'&&vk<='9'){event["command"]="choose";event["index"]=vk-'1';return true;}
    if(alt||win)return false;
    int kind=-1;
    if(ctrl){
        if(!composing)return false;
        switch(vk){case VK_BACK:kind=GC_EV_DELETE_WORD;break;case 'A':kind=GC_EV_CTRL_A;break;case 'B':kind=GC_EV_CTRL_B;break;case 'E':kind=GC_EV_CTRL_E;break;case 'F':kind=GC_EV_CTRL_F;break;case 'N':kind=GC_EV_CTRL_N;break;case 'P':kind=GC_EV_CTRL_P;break;default:return false;}
    }else switch(vk){
      case VK_BACK:if(composing)kind=GC_EV_BACKSPACE;break;case VK_ESCAPE:kind=GC_EV_ESC;break;
      case VK_RETURN:if(composing)kind=GC_EV_ENTER;break;case VK_SPACE:if(composing)kind=GC_EV_SPACE;break;
      case VK_LEFT:if(composing)kind=GC_EV_LEFT;break;case VK_RIGHT:if(composing)kind=GC_EV_RIGHT;break;
      case VK_UP:if(composing)kind=GC_EV_UP;break;case VK_DOWN:if(composing)kind=GC_EV_DOWN;break;
      case VK_HOME:if(composing)kind=GC_EV_HOME;break;case VK_END:if(composing)kind=GC_EV_END;break;
      case VK_PRIOR:if(composing)kind=GC_EV_PAGE_UP;break;case VK_NEXT:if(composing)kind=GC_EV_PAGE_DOWN;break;
      default:break;
    }
    if(kind>=0){event["kind"]=kind;return true;}
    if(ctrl||view_.value("english",0)!=0)return false;
    BYTE state[256]{};GetKeyboardState(state);wchar_t characters[8]{};
    UINT scan=(UINT)((lp>>16)&0xff);
    int count=ToUnicodeEx((UINT)vk,scan,state,characters,8,4,GetKeyboardLayout(0));
    if(count<=0||characters[0]<0x20)return false;
    event["kind"]=GC_EV_TEXT;event["text"]=gw::utf8(std::wstring(characters,count));return true;
}
bool TextService::shouldClaim(ITfContext *context,WPARAM vk,LPARAM lp){
    if(!bridge_.connected()||!opened_||!sameObject(context_,context)||!safe(context))return false;
    Json event;if(!buildEvent(vk,lp,event))return false;
    if(event.contains("command"))return true;
    int kind=event.value("kind",-1);
    if(kind==GC_EV_ESC)return view_.value("composing",false)||view_.value("english",0)==1;
    if(kind==GC_EV_TEXT){
        auto text=event.value("text",std::string());
        if(!view_.value("composing",false)&&!view_.value("learning",false)&&!text.empty()&&text[0]>='0'&&text[0]<='9')return false;
    }
    return true;
}
STDMETHODIMP TextService::OnTestKeyDown(ITfContext *context,WPARAM vk,LPARAM lp,BOOL *eaten){
    if(!eaten)return E_POINTER;*eaten=FALSE;
    try {
        if(vk==VK_SHIFT||vk==VK_LSHIFT||vk==VK_RSHIFT){
            if(!shiftDown_){shiftDown_=true;shiftValid_=!(GetKeyState(VK_CONTROL)&0x8000)&&!(GetKeyState(VK_MENU)&0x8000)&&!((GetKeyState(VK_LWIN)|GetKeyState(VK_RWIN))&0x8000);shiftTime_=GetTickCount64();}
            return S_OK;
        }
        shiftValid_=false;
        if(syncContext(context))*eaten=shouldClaim(context,vk,lp);return S_OK;
    }catch(...){return S_OK;}
}
STDMETHODIMP TextService::OnKeyDown(ITfContext *context,WPARAM vk,LPARAM lp,BOOL *eaten){
    if(!eaten)return E_POINTER;*eaten=FALSE;
    try{if(!safe(context)||!syncContext(context))return S_OK;Json event;if(buildEvent(vk,lp,event))*eaten=dispatch(event);}catch(...){bridge_.close();opened_=false;}
    return S_OK;
}
STDMETHODIMP TextService::OnTestKeyUp(ITfContext *context,WPARAM vk,LPARAM,BOOL *eaten){
    if(!eaten)return E_POINTER;*eaten=FALSE;
    if(vk==VK_SHIFT||vk==VK_LSHIFT||vk==VK_RSHIFT){
        *eaten=shiftDown_&&shiftValid_&&GetTickCount64()-shiftTime_<600&&safe(context)&&bridge_.connected();
        if(!*eaten){shiftDown_=false;shiftValid_=false;}
    }
    return S_OK;
}
STDMETHODIMP TextService::OnKeyUp(ITfContext *context,WPARAM vk,LPARAM,BOOL *eaten){
    if(!eaten)return E_POINTER;*eaten=FALSE;
    try{if(vk==VK_SHIFT||vk==VK_LSHIFT||vk==VK_RSHIFT){bool tap=shiftDown_&&shiftValid_&&GetTickCount64()-shiftTime_<600;shiftDown_=false;shiftValid_=false;if(tap&&syncContext(context))dispatch({{"op","event"},{"kind",GC_EV_SHIFT_CLICK}});}}catch(...){}
    return S_OK;
}
bool TextService::dispatch(const Json &event){
    if(!context_||!safe(context_)||!opened_)return false;
    Json view;
    if(!bridge_.request(event,view)){opened_=false;bridge_.close();loseFocus();return false;}
    bool consumed=view.value("consumed",false);apply(view);return consumed;
}
bool TextService::edit(ITfContext *context,bool write,const std::function<HRESULT(TfEditCookie)> &fn){
    if(!context)return false;
    auto session=new EditSession(fn);HRESULT result=E_FAIL;
    HRESULT hr=context->RequestEditSession(client_,session,TF_ES_SYNC|(write?TF_ES_READWRITE:TF_ES_READ),&result);
    session->Release();return SUCCEEDED(hr)&&SUCCEEDED(result);
}
bool TextService::selectionMatches(TfEditCookie cookie) const{
    if(!anchor_)return true;
    TF_SELECTION selection{};ULONG fetched=0;
    if(FAILED(context_->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selection,&fetched))||fetched!=1)return false;
    LONG start=1,end=1;
    HRESULT a=selection.range->CompareStart(cookie,anchor_,TF_ANCHOR_START,&start),b=selection.range->CompareEnd(cookie,anchor_,TF_ANCHOR_END,&end);
    selection.range->Release();return SUCCEEDED(a)&&SUCCEEDED(b)&&start==0&&end==0;
}
HRESULT TextService::setPreedit(TfEditCookie cookie,const std::string &text){
    if(!safe(context_,cookie)||!selectionMatches(cookie))return E_ABORT;
    if(!composition_){
        ITfContextComposition *compositions=nullptr;HRESULT hr=context_->QueryInterface(IID_PPV_ARGS(&compositions));if(FAILED(hr))return hr;
        TF_SELECTION selection{};ULONG fetched=0;hr=context_->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selection,&fetched);
        if(SUCCEEDED(hr)&&fetched==1){hr=compositions->StartComposition(cookie,selection.range,this,&composition_);selection.range->Release();}else hr=E_FAIL;
        compositions->Release();if(FAILED(hr)||!composition_)return E_FAIL;
    }
    ITfRange *range=nullptr;HRESULT hr=composition_->GetRange(&range);if(FAILED(hr))return hr;
    auto value=gw::wide(settings_.value("inputLettersEnabled",true)?text:std::string());
    hr=range->SetText(cookie,0,value.c_str(),(LONG)value.size());
    if(SUCCEEDED(hr)){
        range->Collapse(cookie,TF_ANCHOR_END);TF_SELECTION selection{range,{TF_AE_END,FALSE}};hr=context_->SetSelection(cookie,1,&selection);
        if(anchor_){anchor_->Release();anchor_=nullptr;}range->Clone(&anchor_);
    }
    range->Release();return hr;
}
HRESULT TextService::commit(TfEditCookie cookie,const std::string &text){
    if(!safe(context_,cookie)||!selectionMatches(cookie))return E_ABORT;
    auto value=gw::wide(text);ITfRange *range=nullptr;HRESULT hr=E_FAIL;
    if(composition_)hr=composition_->GetRange(&range);
    else {TF_SELECTION selection{};ULONG fetched=0;hr=context_->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selection,&fetched);if(SUCCEEDED(hr)&&fetched==1)range=selection.range;else hr=E_FAIL;}
    if(!range||FAILED(hr))return E_FAIL;
    hr=range->SetText(cookie,0,value.c_str(),(LONG)value.size());
    if(SUCCEEDED(hr)){
        range->Collapse(cookie,TF_ANCHOR_END);TF_SELECTION selection{range,{TF_AE_END,FALSE}};
        HRESULT positioned=context_->SetSelection(cookie,1,&selection);if(FAILED(positioned))hr=positioned;
        if(composition_){auto old=composition_;composition_=nullptr;HRESULT ended=old->EndComposition(cookie);old->Release();if(FAILED(ended))hr=ended;}
    }
    range->Release();if(anchor_){anchor_->Release();anchor_=nullptr;}return hr;
}
HRESULT TextService::clearComposition(TfEditCookie cookie){
    HRESULT hr=S_OK;
    if(composition_){auto old=composition_;composition_=nullptr;ITfRange *range=nullptr;
        if(SUCCEEDED(old->GetRange(&range))){hr=range->SetText(cookie,0,L"",0);range->Release();}
        HRESULT ended=old->EndComposition(cookie);old->Release();if(FAILED(ended))hr=ended;
    }
    if(anchor_){anchor_->Release();anchor_=nullptr;}return hr;
}
void TextService::caret(TfEditCookie cookie){
    ITfContextView *view=nullptr;ITfRange *range=nullptr;
    TF_SELECTION selection{};ULONG fetched=0;
    if(SUCCEEDED(context_->GetSelection(cookie,TF_DEFAULT_SELECTION,1,&selection,&fetched))&&fetched==1)range=selection.range;
    if(range&&SUCCEEDED(context_->GetActiveView(&view))){BOOL clipped=FALSE;RECT rect{};
        if(SUCCEEDED(view->GetTextExt(cookie,range,&rect,&clipped))){caret_=rect;hasCaret_=true;}view->Release();
    }
    if(range)range->Release();
}
void TextService::apply(const Json &view){
    view_=view;
    auto revision=view.value("settingsRevision",uint64_t(0));
    if(revision!=settingsRevision_){settings_=gw::readSettings();settingsRevision_=revision;}
    std::string text=view.value("commit",std::string()),token=view.value("commitToken",std::string());
    if(!text.empty()){
        if(token.empty()||token==lastCommit_)return;
        lastCommit_=token;editing_=true;
        bool success=edit(context_,true,[&](TfEditCookie cookie){return commit(cookie,text);});editing_=false;
        Json reply;
        if(!bridge_.request({{"op",success?"confirm":"reject"},{"token",token}},reply)){bridge_.close();opened_=false;}
        else view_=reply;
        window_.hide();return;
    }
    if(!context_)return;
    editing_=true;
    if(view.value("composing",false)){
        // 学习文字只在自己的非激活候选窗，宿主中的预编辑仅用于普通输入。
        bool learning=view.value("learning",false);
        bool good=edit(context_,true,[&](TfEditCookie cookie){HRESULT hr=setPreedit(cookie,learning?std::string():view.value("marked",std::string()));if(SUCCEEDED(hr))caret(cookie);return hr;});
        if(!good){editing_=false;loseFocus();return;}
        if(hasCaret_)window_.showView(view,caret_,settings_);else window_.hide();
    }else{
        if(composition_)edit(context_,true,[&](TfEditCookie cookie){return clearComposition(cookie);});
        edit(context_,false,[&](TfEditCookie cookie){caret(cookie);return S_OK;});
        if(view.value("draftAvailable",false)&&hasCaret_)window_.showView(view,caret_,settings_);else window_.hide();
    }
    editing_=false;
    if(view.value("toast",0)==1)window_.showToast(L"中");else if(view.value("toast",0)==2)window_.showToast(L"英");
}
void TextService::loseFocus(){
    window_.hide();shiftValid_=false;shiftDown_=false;
    if(context_){
        editing_=true;if(composition_)edit(context_,true,[&](TfEditCookie cookie){return clearComposition(cookie);});editing_=false;
        if(composition_){composition_->Release();composition_=nullptr;}if(anchor_){anchor_->Release();anchor_=nullptr;}
        context_->Release();context_=nullptr;
    }
    if(opened_){Json ignored;bridge_.request({{"op","focus"},{"app",""},{"field",""}},ignored);}
    opened_=false;view_=Json::object();hasCaret_=false;
}
void TextService::idle(){
    try{
        if(!manager_)return;ITfDocumentMgr *document=nullptr;ITfContext *context=nullptr;
        if(SUCCEEDED(manager_->GetFocus(&document))&&document){document->GetTop(&context);document->Release();}
        if(!context){loseFocus();return;}
        bool ready=syncContext(context);context->Release();
        if(ready){
            Json view;
            if(bridge_.request({{"op","poll"}},view)){
                if(view_.value("learning",false)||view.value("settingsRevision",uint64_t(0))!=settingsRevision_)apply(view);
            }else{bridge_.close();loseFocus();}
        }
    }catch(...){bridge_.close();opened_=false;window_.hide();}
}
LRESULT CALLBACK TextService::timerProc(HWND hwnd,UINT msg,WPARAM wp,LPARAM lp){
    if(msg==WM_NCCREATE){auto create=(CREATESTRUCTW*)lp;SetWindowLongPtrW(hwnd,GWLP_USERDATA,(LONG_PTR)create->lpCreateParams);}
    auto self=(TextService*)GetWindowLongPtrW(hwnd,GWLP_USERDATA);
    if(msg==WM_TIMER&&self){self->idle();return 0;}return DefWindowProcW(hwnd,msg,wp,lp);
}
STDMETHODIMP TextService::OnSetFocus(BOOL foreground){if(!foreground)loseFocus();else idle();return S_OK;}
STDMETHODIMP TextService::OnSetFocus(ITfDocumentMgr *,ITfDocumentMgr *){loseFocus();idle();return S_OK;}
STDMETHODIMP TextService::OnInitDocumentMgr(ITfDocumentMgr *){return S_OK;}
STDMETHODIMP TextService::OnUninitDocumentMgr(ITfDocumentMgr *){return S_OK;}
STDMETHODIMP TextService::OnPushContext(ITfContext *){loseFocus();idle();return S_OK;}
STDMETHODIMP TextService::OnPopContext(ITfContext *){loseFocus();return S_OK;}
STDMETHODIMP TextService::OnPreservedKey(ITfContext *,REFGUID,BOOL *eaten){if(eaten)*eaten=FALSE;return S_OK;}
STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie,ITfComposition *composition){
    if(editing_)return S_OK;
    if(composition_&&sameObject(composition_,composition)){composition_->Release();composition_=nullptr;if(anchor_){anchor_->Release();anchor_=nullptr;}window_.hide();opened_=false;}
    return S_OK;
}
