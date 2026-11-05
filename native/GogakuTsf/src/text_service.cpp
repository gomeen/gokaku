#include "text_service.h"

#include <shellscalingapi.h>
#pragma comment(lib, "shcore.lib")

/* ---------- COM 基建 ---------- */

TextService::TextService() = default;

TextService::~TextService() { Deactivate(); }

STDMETHODIMP TextService::QueryInterface(REFIID riid, void **ppv) {
    if (!ppv) return E_INVALIDARG;
    *ppv = nullptr;
    if (riid == IID_IUnknown || riid == IID_ITfTextInputProcessor) {
        *ppv = (ITfTextInputProcessor *)this;
    } else if (riid == IID_ITfKeyEventSink) {
        *ppv = (ITfKeyEventSink *)this;
    } else if (riid == IID_ITfThreadMgrEventSink) {
        *ppv = (ITfThreadMgrEventSink *)this;
    } else if (riid == IID_ITfCompositionSink) {
        *ppv = (ITfCompositionSink *)this;
    }
    if (*ppv) {
        AddRef();
        return S_OK;
    }
    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) TextService::AddRef() { return InterlockedIncrement(&m_ref); }

STDMETHODIMP_(ULONG) TextService::Release() {
    long r = InterlockedDecrement(&m_ref);
    if (r == 0) delete this;
    return r;
}

/* ---------- 激活 ---------- */

static void actLog(const char *msg) {
    HANDLE f = CreateFileW(L"C:\\gogaku-test\\activate-log.txt",
                           FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (!f) return;
    DWORD w = 0;
    WriteFile(f, msg, (DWORD)strlen(msg), &w, nullptr);
    CloseHandle(f);
}

STDMETHODIMP TextService::Activate(ITfThreadMgr *ptim, TfClientId tid) {
    actLog("activate: enter\r\n");
    if (!ptim) { actLog("activate: no threadmgr\r\n"); return E_INVALIDARG; }
    m_tm = ptim;
    m_tm->AddRef();
    m_clientId = tid;

    if (!initCore()) {
        actLog("activate: initCore FAILED\r\n");
        Deactivate();
        return E_FAIL; /* 核心缺失/ABI 不匹配：诚实地拒绝激活 */
    }
    actLog("activate: core ok\r\n");

    /* 按键汇：本 TIP 激活期间接收全部按键 */
    ITfKeystrokeMgr *ks = nullptr;
    if (SUCCEEDED(m_tm->QueryInterface(IID_PPV_ARGS(&ks)))) {
        ks->AdviseKeyEventSink(m_clientId, (ITfKeyEventSink *)this, TRUE);
        ks->Release();
    }
    /* 焦点汇 */
    ITfSource *src = nullptr;
    if (SUCCEEDED(m_tm->QueryInterface(IID_PPV_ARGS(&src)))) {
        src->AdviseSink(IID_ITfThreadMgrEventSink, (ITfThreadMgrEventSink *)this, &m_focusCookie);
        src->Release();
    }
    m_win.create(g_hInst);

    /* 首次焦点同步（app 标识 = 前台进程名，供按应用默认英文） */
    GcKeyEvent ev{};
    ev.kind = GC_EV_FOCUS_SYNC;
    std::string app = foregroundApp();
    ev.app = app.c_str();
    dispatchEvent(ev, nullptr);
    return S_OK;
}

STDMETHODIMP TextService::Deactivate() {
    if (m_normal) {
        CoreBridge::instance().normalFlush(m_normal);
        CoreBridge::instance().normalDestroy(m_normal);
        m_normal = nullptr;
    }
    m_composing = false;
    m_comp = nullptr; /* 组合由会话拥有；焦点丢失时已结束 */
    m_win.destroy();
    if (m_tm) {
        ITfKeystrokeMgr *ks = nullptr;
        if (SUCCEEDED(m_tm->QueryInterface(IID_PPV_ARGS(&ks)))) {
            ks->UnadviseKeyEventSink(m_clientId);
            ks->Release();
        }
        ITfSource *src = nullptr;
        if (SUCCEEDED(m_tm->QueryInterface(IID_PPV_ARGS(&src)))) {
            if (m_focusCookie != TF_INVALID_COOKIE)
                src->UnadviseSink(m_focusCookie);
            src->Release();
        }
        m_tm->Release();
        m_tm = nullptr;
    }
    m_focusCookie = TF_INVALID_COOKIE;
    m_keyCookie = TF_INVALID_COOKIE;
    return S_OK;
}

bool TextService::initCore() {
    if (!CoreBridge::instance().ensureLoaded()) return false;
    char err[256] = {};
    int rc = CoreBridge::instance().normalCreate(&m_normal, err, sizeof(err));
    if (rc != 0) return false;
    return true;
}

void TextService::shutdownCore() {
    if (m_normal) {
        CoreBridge::instance().normalFlush(m_normal);
        CoreBridge::instance().normalDestroy(m_normal);
        m_normal = nullptr;
    }
}

/* ---------- 焦点 ---------- */

STDMETHODIMP TextService::OnInitDocumentMgr(ITfDocumentMgr *) { return S_OK; }
STDMETHODIMP TextService::OnUninitDocumentMgr(ITfDocumentMgr *) { return S_OK; }
STDMETHODIMP TextService::OnPushContext(ITfContext *) { return S_OK; }
STDMETHODIMP TextService::OnPopContext(ITfContext *) { return S_OK; }

STDMETHODIMP TextService::OnSetFocus(ITfDocumentMgr *pDocMgr, ITfDocumentMgr * /*pdimPrevFocus*/) {
    /* 丢弃旧文档上的组合：清空文本＋核心 Esc（对齐 Mac 焦点丢失语义） */
    if (m_comp) {
        ITfContext *ctx = nullptr;
        if (pDocMgr && pDocMgr->GetTop(&ctx) == S_OK && ctx) {
            requestEdit(true, [&](TfEditCookie ec) { abandonComposition(ec, ctx); });
            ctx->Release();
        } else {
            /* 旧文档不可达：仅释放 */
            m_comp->Release();
            m_comp = nullptr;
        }
    }
    m_win.hide();
    m_composing = false;

    GcKeyEvent ev{};
    ev.kind = GC_EV_FOCUS_SYNC;
    std::string app = foregroundApp();
    ev.app = app.c_str();
    dispatchEvent(ev, nullptr);
    return S_OK;
}

/* ---------- 按键 ---------- */

bool TextService::claimKey(WPARAM vk) const {
    if ((vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9')) return true;
    if (m_composing) {
        switch (vk) {
        case VK_SPACE:
        case VK_RETURN:
        case VK_BACK:
        case VK_ESCAPE:
        case VK_LEFT:
        case VK_RIGHT:
        case VK_UP:
        case VK_DOWN:
        case VK_HOME:
        case VK_END:
        case VK_PRIOR:
        case VK_NEXT:
        case VK_DELETE:
            return true;
        }
    } else if (vk == VK_BACK || vk == VK_SPACE) {
        /* 未组合时空格交给宿主；Backspace 无需截获 */
        return vk == VK_BACK ? false : false;
    }
    /* 标点：一律先接住，核心未消费则放行（中英文标点表在核心） */
    if ((vk >= VK_OEM_1 && vk <= VK_OEM_8) || vk == VK_SPACE) return true;
    return false;
}

bool TextService::buildEvent(WPARAM vk, LPARAM lp, GcKeyEvent *ev, std::string *textStorage) {
    static const BYTE scanCode = (BYTE)((lp >> 16) & 0xFF);
    BYTE state[256] = {};
    GetKeyboardState(state);
    wchar_t chars[8] = {};
    /* Win10+ SDK 与 mingw 均为 7 参（末位 HKL）。 */
    int produced = ToUnicodeEx((UINT)vk, scanCode, state, chars, 8, 0, GetKeyboardLayout(0));

    bool ctrl = (state[VK_CONTROL] & 0x80) != 0;
    *ev = GcKeyEvent{};
    ev->time_ms = (int64_t)GetTickCount64();

    switch (vk) {
    case VK_BACK:
        if (ctrl) { ev->kind = GC_EV_DELETE_WORD; return true; }
        ev->kind = GC_EV_BACKSPACE;
        return m_composing ? true : false; /* 未组合退格交宿主 */
    case VK_ESCAPE:
        ev->kind = GC_EV_ESC;
        return true;
    case VK_RETURN:
        ev->kind = GC_EV_ENTER;
        return true; /* 核心未组合时返回未消费 */
    case VK_SPACE:
        ev->kind = GC_EV_SPACE;
        return true;
    case VK_LEFT: ev->kind = GC_EV_LEFT; return m_composing;
    case VK_RIGHT: ev->kind = GC_EV_RIGHT; return m_composing;
    case VK_UP: ev->kind = GC_EV_UP; return m_composing;
    case VK_DOWN: ev->kind = GC_EV_DOWN; return m_composing;
    case VK_HOME: ev->kind = GC_EV_HOME; return m_composing;
    case VK_END: ev->kind = GC_EV_END; return m_composing;
    case VK_PRIOR: ev->kind = GC_EV_PAGE_UP; return m_composing;
    case VK_NEXT: ev->kind = GC_EV_PAGE_DOWN; return m_composing;
    default: break;
    }
    if (ctrl && produced <= 0) {
        switch (vk) {
        case 'A': ev->kind = GC_EV_CTRL_A; return m_composing;
        case 'B': ev->kind = GC_EV_CTRL_B; return m_composing;
        case 'E': ev->kind = GC_EV_CTRL_E; return m_composing;
        case 'F': ev->kind = GC_EV_CTRL_F; return m_composing;
        case 'N': ev->kind = GC_EV_CTRL_N; return m_composing;
        case 'P': ev->kind = GC_EV_CTRL_P; return m_composing;
        default: return false;
        }
    }
    /* 字符键（字母/数字/标点）：取键盘布局产出的字符 */
    if (produced >= 1 && chars[0] >= 0x20) {
        std::wstring w(chars, produced);
        *textStorage = Utf16ToUtf8(w);
        if (textStorage->empty()) return false;
        ev->kind = GC_EV_TEXT;
        ev->text = textStorage->c_str();
        return true;
    }
    return false;
}

void TextService::dispatchEvent(const GcKeyEvent &ev, BOOL *pfEaten) {
    if (!m_normal) { actLog("dispatch: no session\r\n"); return; }
    GcSnapshot *snap = nullptr;
    int rc = CoreBridge::instance().normalHandle(m_normal, &ev, &snap);
    if (rc != 0) {
        char buf[64]; snprintf(buf, 64, "dispatch: core rc=%d\r\n", rc);
        actLog(buf);
        if (pfEaten) *pfEaten = FALSE;
        return;
    }
    char buf[96];
    snprintf(buf, 96, "dispatch: consumed=%d composing=%d commit_empty=%d marked_empty=%d\r\n",
             (int)snap->consumed, (int)snap->composing,
             (int)(!snap->commit || !*snap->commit), (int)(!snap->marked || !*snap->marked));
    actLog(buf);
    applySnapshot(snap);
    if (pfEaten) *pfEaten = snap->consumed == 1 ? TRUE : FALSE;
    CoreBridge::instance().snapshotFree(snap);
}

void TextService::applySnapshot(const GcSnapshot *snap) {
    bool nowComposing = snap->composing == 1;
    std::string commit = snap->commit ? snap->commit : "";
    std::string marked = snap->marked ? snap->marked : "";

    if (!commit.empty()) {
        /* 提交：替换组合文本并结束组合；成功后发确认事件（版本 4 学习合同） */
        ITfContext *ctx = nullptr;
        ITfDocumentMgr *doc = nullptr;
        if (m_tm && SUCCEEDED(m_tm->GetFocus(&doc)) && doc) {
            doc->GetTop(&ctx);
            doc->Release();
        }
        if (ctx) {
            std::string text = commit;
            requestEdit(true, [&](TfEditCookie ec) { commitText(ec, ctx, text); });
            ctx->Release();
        }
        m_composing = false;
        m_win.hide();
        GcKeyEvent ev{};
        ev.kind = GC_EV_COMMIT_CONFIRMED;
        dispatchEvent(ev, nullptr); /* 学习/调频；快照应无后续提交 */
        return;
    }

    m_composing = nowComposing;
    if (m_composing && !marked.empty()) {
        ITfContext *ctx = nullptr;
        ITfDocumentMgr *doc = nullptr;
        if (m_tm && SUCCEEDED(m_tm->GetFocus(&doc)) && doc) {
            doc->GetTop(&ctx);
            doc->Release();
        }
        if (ctx) {
            std::string text = marked;
            requestEdit(true, [&](TfEditCookie ec) {
                setCompositionText(ec, ctx, text);
                updateCaretRect(ec, ctx);
            });
            ctx->Release();
        }
        /* 快照候选：候选窗展示当前页（selected 为全局下标，面板取本页相对高亮） */
        RECT caret = m_caretRect;
        /* 快照副本线程内即取即用 */
        m_win.showCandidates(*snap, caret);
    } else {
        m_win.hide();
    }
    if (snap->toast == 1) m_win.showToast(L"中");
    else if (snap->toast == 2) m_win.showToast(L"英");
}

STDMETHODIMP TextService::OnTestKeyDown(ITfContext *pic, WPARAM wParam, LPARAM, BOOL *pfEaten) {
    *pfEaten = claimKey(wParam) ? TRUE : FALSE;
    return S_OK;
}

STDMETHODIMP TextService::OnKeyDown(ITfContext *pic, WPARAM wParam, LPARAM lParam, BOOL *pfEaten) {
    /* Shift 单击检测（与 Mac 合同 <600ms 无其他键）：按下补记时刻 */
    if (wParam == VK_SHIFT || wParam == VK_LSHIFT || wParam == VK_RSHIFT) {
        if (!m_shiftDown) {
            m_shiftDown = true;
            m_shiftTapValid = true;
            m_shiftDownTick = GetTickCount64();
        }
        *pfEaten = FALSE;
        return S_OK;
    }
    /* 非 Shift 按键使当前 Shift 按住失效 */
    m_shiftTapValid = false;

    GcKeyEvent ev;
    std::string text;
    if (!buildEvent(wParam, lParam, &ev, &text)) {
        *pfEaten = FALSE;
        return S_OK;
    }
    ev.app = nullptr; /* app 只在焦点同步给出 */
    actLog("keydown: dispatch\r\n");
    dispatchEvent(ev, pfEaten);
    return S_OK;
}

STDMETHODIMP TextService::OnTestKeyUp(ITfContext *, WPARAM, LPARAM, BOOL *pfEaten) {
    *pfEaten = FALSE;
    return S_OK;
}

STDMETHODIMP TextService::OnKeyUp(ITfContext *pic, WPARAM wParam, LPARAM lParam, BOOL *pfEaten) {
    *pfEaten = FALSE;
    if (wParam == VK_SHIFT || wParam == VK_LSHIFT || wParam == VK_RSHIFT) {
        if (m_shiftDown && m_shiftTapValid) {
            ULONGLONG now = GetTickCount64();
            if (now - m_shiftDownTick < 600) {
                GcKeyEvent ev{};
                ev.kind = GC_EV_SHIFT_CLICK;
                ev.arg = wParam == VK_RSHIFT ? 1 : 0;
                ev.time_ms = (int64_t)now;
                dispatchEvent(ev, nullptr);
            }
        }
        m_shiftDown = false;
    }
    return S_OK;
}

/* Shift 按下时间戳（配合 OnKeyUp 判定单击） */
STDMETHODIMP TextService::OnSetFocus(BOOL fForeground) {
    if (fForeground) {
        BYTE state[256];
        GetKeyboardState(state);
        if (state[VK_SHIFT] & 0x80) {
            m_shiftDown = true;
            m_shiftTapValid = true;
            m_shiftDownTick = GetTickCount64();
        }
    }
    return S_OK;
}

STDMETHODIMP TextService::OnPreservedKey(ITfContext *, REFGUID, BOOL *pfEaten) {
    *pfEaten = FALSE;
    return S_OK;
}

/* Shift 按下时刻：在 KeyDown 补记（OnKeyDown VK_SHIFT 时） */
/* 注：buildEvent 不产 Shift 事件；此处重载了 OnSetFocus(BOOL)，Shift 按下
 * 时间戳改由 OnKeyDown 记录。 */

/* ---------- 组合 ---------- */

class EditSession final : public ITfEditSession {
public:
    EditSession(std::function<void(TfEditCookie)> fn) : m_fn(std::move(fn)) {}
    STDMETHODIMP QueryInterface(REFIID riid, void **ppv) override {
        if (!ppv) return E_INVALIDARG;
        if (riid == IID_IUnknown || riid == IID_ITfEditSession) {
            *ppv = (ITfEditSession *)this;
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&m_ref); }
    STDMETHODIMP_(ULONG) Release() override {
        long r = InterlockedDecrement(&m_ref);
        if (r == 0) delete this;
        return r;
    }
    STDMETHODIMP DoEditSession(TfEditCookie ec) override {
        m_fn(ec);
        return S_OK;
    }

private:
    long m_ref = 1;
    std::function<void(TfEditCookie)> m_fn;
};

bool TextService::requestEdit(bool write, const std::function<void(TfEditCookie)> &fn) {
    if (!m_tm) { actLog("reqedit: no tm\r\n"); return false; }
    ITfDocumentMgr *doc = nullptr;
    if (FAILED(m_tm->GetFocus(&doc)) || !doc) { actLog("reqedit: no focus doc\r\n"); return false; }
    ITfContext *ctx = nullptr;
    HRESULT hr = doc->GetTop(&ctx);
    doc->Release();
    if (FAILED(hr) || !ctx) return false;
    EditSession *ses = new EditSession(fn);
    HRESULT hrSession = E_FAIL;
    hr = ctx->RequestEditSession(m_clientId, ses,
                                 TF_ES_SYNC | (write ? TF_ES_READWRITE : TF_ES_READ),
                                 &hrSession);
    char buf[64]; snprintf(buf, 64, "reqedit: hr=0x%08X ses=0x%08X\r\n", (unsigned)hr, (unsigned)hrSession);
    actLog(buf);
    ses->Release();
    ctx->Release();
    return SUCCEEDED(hr) && SUCCEEDED(hrSession);
}

void TextService::ensureComposition(TfEditCookie ec, ITfContext *ctx) {
    if (m_comp) return;
    ITfContextComposition *cc = nullptr;
    if (FAILED(ctx->QueryInterface(IID_PPV_ARGS(&cc)))) return;
    TF_SELECTION sel{};
    ULONG fetched = 0;
    if (ctx->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &fetched) == S_OK && fetched == 1) {
        cc->StartComposition(ec, sel.range, (ITfCompositionSink *)this, &m_comp);
        sel.range->Release();
    }
    cc->Release();
}

void TextService::setCompositionText(TfEditCookie ec, ITfContext *ctx, const std::string &marked) {
    ensureComposition(ec, ctx);
    if (!m_comp) return;
    ITfRange *range = nullptr;
    if (SUCCEEDED(m_comp->GetRange(&range))) {
        std::wstring w = Utf8ToUtf16(marked);
        range->SetText(ec, 0, w.c_str(), (LONG)w.size());
        range->Release();
    }
}

void TextService::commitText(TfEditCookie ec, ITfContext *ctx, const std::string &text) {
    if (m_comp) {
        ITfRange *range = nullptr;
        if (SUCCEEDED(m_comp->GetRange(&range))) {
            std::wstring w = Utf8ToUtf16(text);
            range->SetText(ec, 0, w.c_str(), (LONG)w.size());
            range->Release();
        }
        m_comp->EndComposition(ec);
        m_comp->Release();
        m_comp = nullptr;
    } else {
        /* 无组合（延迟到达的提交）：插入到当前选区 */
        std::wstring w = Utf8ToUtf16(text);
        TF_SELECTION sel{};
        ULONG fetched = 0;
        if (ctx->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &fetched) == S_OK && fetched == 1) {
            sel.range->SetText(ec, 0, w.c_str(), (LONG)w.size());
            sel.range->Collapse(ec, TF_ANCHOR_END);
            ctx->SetSelection(ec, 1, &sel); /* 原 selection（含原 style）回落到文本尾 */
            sel.range->Release();
        }
    }
    m_hasCaretRect = false;
}

void TextService::abandonComposition(TfEditCookie ec, ITfContext *ctx) {
    if (!m_comp) return;
    ITfRange *range = nullptr;
    if (SUCCEEDED(m_comp->GetRange(&range))) {
        range->SetText(ec, 0, L"", 0); /* 清掉已插入的标记文本 */
        range->Release();
    }
    m_comp->EndComposition(ec);
    m_comp->Release();
    m_comp = nullptr;
    /* 核心侧清组合 */
    GcKeyEvent ev{};
    ev.kind = GC_EV_ESC;
    dispatchEvent(ev, nullptr);
}

void TextService::updateCaretRect(TfEditCookie ec, ITfContext *ctx) {
    if (!m_comp) return;
    ITfRange *range = nullptr;
    if (FAILED(m_comp->GetRange(&range))) return;
    ITfContextView *view = nullptr;
    if (SUCCEEDED(ctx->QueryInterface(IID_PPV_ARGS(&view)))) {
        BOOL clipped = FALSE;
        RECT rect{};
        if (view->GetTextExt(ec, range, &rect, &clipped) == S_OK) {
            POINT topLeft = {rect.left, rect.top};
            POINT bottomRight = {rect.right, rect.bottom};
            HWND hwndFocus = GetFocus();
            if (hwndFocus) {
                ScreenToClient(hwndFocus, &topLeft);
                ScreenToClient(hwndFocus, &bottomRight);
            }
            m_caretRect = rect;
            m_hasCaretRect = true;
        }
        view->Release();
    }
    range->Release();
}

STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie ecWrite, ITfComposition *pComposition) {
    /* 宿主终止组合（例如应用取消）：清空残留文本＋核心复位 */
    if (pComposition == m_comp) {
        ITfRange *range = nullptr;
        if (SUCCEEDED(pComposition->GetRange(&range))) {
            range->SetText(ecWrite, 0, L"", 0);
            range->Release();
        }
        pComposition->Release();
        m_comp = nullptr;
    }
    m_win.hide();
    m_composing = false;
    GcKeyEvent ev{};
    ev.kind = GC_EV_ESC;
    dispatchEvent(ev, nullptr);
    return S_OK;
}

/* ---------- 辅助 ---------- */

std::string TextService::foregroundApp() const {
    HWND fg = GetForegroundWindow();
    if (!fg) return {};
    DWORD pid = 0;
    GetWindowThreadProcessId(fg, &pid);
    if (!pid) return {};
    std::string name;
    HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (proc) {
        wchar_t buf[MAX_PATH];
        DWORD len = MAX_PATH;
        if (QueryFullProcessImageNameW(proc, 0, buf, &len)) {
            std::wstring w(buf, len);
            size_t slash = w.find_last_of(L'\\');
            if (slash != std::wstring::npos) w = w.substr(slash + 1);
            for (auto &c : w) c = (wchar_t)towlower(c);
            name = Utf16ToUtf8(w);
        }
        CloseHandle(proc);
    }
    return name;
}
