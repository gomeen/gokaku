#pragma once
#include "stdafx.h"
#include "core_bridge.h"
#include "candidate_window.h"
#include <map>

class TextService : public ITfTextInputProcessor, public ITfKeyEventSink,
                    public ITfThreadMgrEventSink, public ITfCompositionSink {
public:
    TextService();
    ~TextService();
    STDMETHODIMP QueryInterface(REFIID,void **) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;
    STDMETHODIMP Activate(ITfThreadMgr *,TfClientId) override;
    STDMETHODIMP Deactivate() override;
    STDMETHODIMP OnSetFocus(BOOL) override;
    STDMETHODIMP OnTestKeyDown(ITfContext *,WPARAM,LPARAM,BOOL *) override;
    STDMETHODIMP OnKeyDown(ITfContext *,WPARAM,LPARAM,BOOL *) override;
    STDMETHODIMP OnTestKeyUp(ITfContext *,WPARAM,LPARAM,BOOL *) override;
    STDMETHODIMP OnKeyUp(ITfContext *,WPARAM,LPARAM,BOOL *) override;
    STDMETHODIMP OnPreservedKey(ITfContext *,REFGUID,BOOL *) override;
    STDMETHODIMP OnInitDocumentMgr(ITfDocumentMgr *) override;
    STDMETHODIMP OnUninitDocumentMgr(ITfDocumentMgr *) override;
    STDMETHODIMP OnSetFocus(ITfDocumentMgr *,ITfDocumentMgr *) override;
    STDMETHODIMP OnPushContext(ITfContext *) override;
    STDMETHODIMP OnPopContext(ITfContext *) override;
    STDMETHODIMP OnCompositionTerminated(TfEditCookie,ITfComposition *) override;
private:
    LONG refs_=1;
    ITfThreadMgr *manager_=nullptr;
    TfClientId client_=0;
    DWORD focusCookie_=TF_INVALID_COOKIE;
    ITfContext *context_=nullptr;
    ITfComposition *composition_=nullptr;
    ITfRange *anchor_=nullptr;
    std::map<IUnknown *,uint64_t> fields_;
    struct ScopeResolution { bool valid=false,allowed=false; };
    std::map<IUnknown *,ScopeResolution> scopeCache_;
    CoreBridge bridge_;
    CandidateWindow window_;
    gw::Json view_=gw::Json::object(),settings_=gw::Json::object();
    HWND timer_=nullptr;
    RECT caret_{};
    bool hasCaret_=false,editing_=false,opened_=false;
    bool shiftDown_=false,shiftValid_=false,shiftTapPending_=false;
    ULONGLONG shiftTime_=0;
    uint64_t settingsRevision_=0,nextField_=0;
    std::string field_,app_,lastCommit_;
    bool safe(ITfContext *,TfEditCookie = TF_INVALID_COOKIE);
    bool syncContext(ITfContext *);
    bool buildEvent(WPARAM,LPARAM,gw::Json &);
    bool shortcut(WPARAM,gw::Json &);
    bool shouldClaim(ITfContext *,WPARAM,LPARAM);
    bool dispatch(const gw::Json &);
    void apply(const gw::Json &);
    bool edit(ITfContext *,bool,const std::function<HRESULT(TfEditCookie)> &);
    HRESULT setPreedit(TfEditCookie,const std::string &);
    HRESULT commit(TfEditCookie,const std::string &);
    HRESULT clearComposition(TfEditCookie);
    bool selectionMatches(TfEditCookie) const;
    void caret(TfEditCookie);
    void loseFocus();
    void idle();
    static LRESULT CALLBACK timerProc(HWND,UINT,WPARAM,LPARAM);
};
