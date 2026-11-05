/* TSF 文本服务：ITfTextInputProcessor＋按键／焦点／组合事件汇。
 * 按键流：TSF VK → 核心 GcKeyEvent（C ABI）→ 快照 → 组合文本／候选窗／提交。
 * 学习（调频）按版本 4 合同：宿主插入确认后发 GC_EV_COMMIT_CONFIRMED。 */
#pragma once

#include "stdafx.h"
#include "candidate_window.h"
#include "core_bridge.h"

class TextService
    : public ITfTextInputProcessor,
      public ITfKeyEventSink,
      public ITfFocusSink,
      public ITfCompositionSink {
public:
    TextService();
    virtual ~TextService();

    /* IUnknown */
    STDMETHODIMP QueryInterface(REFIID riid, void **ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    /* ITfTextInputProcessor */
    STDMETHODIMP Activate(ITfThreadMgr *ptim, TfClientId tid) override;
    STDMETHODIMP Deactivate() override;

    /* ITfKeyEventSink */
    STDMETHODIMP OnSetFocus(BOOL fForeground) override;
    STDMETHODIMP OnTestKeyDown(ITfContext *pic, WPARAM wParam, LPARAM lParam, BOOL *pfEaten) override;
    STDMETHODIMP OnKeyDown(ITfContext *pic, WPARAM wParam, LPARAM lParam, BOOL *pfEaten) override;
    STDMETHODIMP OnTestKeyUp(ITfContext *pic, WPARAM wParam, LPARAM lParam, BOOL *pfEaten) override;
    STDMETHODIMP OnKeyUp(ITfContext *pic, WPARAM wParam, LPARAM lParam, BOOL *pfEaten) override;
    STDMETHODIMP OnPreservedKey(ITfContext *pic, REFGUID rguid, BOOL *pfEaten) override;

    /* ITfFocusSink */
    STDMETHODIMP OnSetFocus(ITfDocumentMgr *pDocMgr) override;

    /* ITfCompositionSink */
    STDMETHODIMP OnCompositionTerminated(TfEditCookie ecWrite, ITfComposition *pComposition) override;

private:
    long m_ref = 1;
    ITfThreadMgr *m_tm = nullptr;
    TfClientId m_clientId = 0;
    DWORD m_keyCookie = TF_INVALID_COOKIE;
    DWORD m_focusCookie = TF_INVALID_COOKIE;
    GcNormalSession *m_normal = nullptr;
    CandidateWindow m_win;

    ITfComposition *m_comp = nullptr;
    bool m_composing = false;        /* 核心态：组合进行中 */
    RECT m_caretRect = {};           /* 最近一次组合文本的屏幕矩形 */
    bool m_hasCaretRect = false;

    /* Shift 单击切中英（与 Mac 同合同：<600ms 且按住期间无其他键） */
    bool m_shiftDown = false;
    bool m_shiftTapValid = false;
    ULONGLONG m_shiftDownTick = 0;

    bool initCore();
    void shutdownCore();

    bool claimKey(WPARAM vk) const;
    bool buildEvent(WPARAM vk, LPARAM lp, GcKeyEvent *ev, std::string *textStorage);
    void dispatchEvent(const GcKeyEvent &ev, BOOL *pfEaten);
    void applySnapshot(const GcSnapshot *snap);

    bool requestEdit(bool write, const std::function<void(TfEditCookie)> &fn);
    void ensureComposition(TfEditCookie ec, ITfContext *ctx);
    void setCompositionText(TfEditCookie ec, ITfContext *ctx, const std::string &marked);
    void commitText(TfEditCookie ec, ITfContext *ctx, const std::string &text);
    void abandonComposition(TfEditCookie ec, ITfContext *ctx);
    void updateCaretRect(TfEditCookie ec, ITfContext *ctx);

    std::string foregroundApp() const;
    static LRESULT CALLBACK flushTimerProc(HWND, UINT, WPARAM, LPARAM);
};
