// Native Win32 settings. UI operations stay outside the TSF keystroke path.
// No webview, fabricated records, success-placeholder MessageBoxes, or host input.
#include "platform.h"
#include "update.h"
#include "appearance.h"
#include "../../shared/GogakuCore/include/gogaku_core.h"
#include <commctrl.h>
#include <commdlg.h>
#include <shellapi.h>
#include <shlobj.h>
#include <uxtheme.h>
#include <windowsx.h>
#include <algorithm>
#include <cmath>
#include <cwctype>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <thread>

namespace {
using gw::Json;
constexpr UINT Completed = WM_APP + 17, DialogCompleted = WM_APP + 18;
const wchar_t *PageNames[] = {L"学习翻译",L"普通输入",L"自定义词语",L"皮肤",L"快捷键",L"学习与隐私",L"学习片段"};
constexpr COLORREF TextColor=RGB(28,43,37),MutedColor=RGB(91,111,102),SideColor=RGB(237,243,239),LineColor=RGB(216,227,220);
HFONT uiFont(UINT dpi,int size,int weight=FW_NORMAL) {
    return CreateFontW(-MulDiv(size,int(dpi),96),0,0,0,weight,FALSE,FALSE,FALSE,DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Microsoft YaHei UI");
}
struct Placement { HWND window; int x,y,width,height; std::wstring kind; bool auxiliary=false; };
constexpr unsigned Shift = 1u<<17, Control = 1u<<18, Alt = 1u<<19, Windows = 1u<<20;
const char *Fuzzy[] = {"z-zh","c-ch","s-sh","n-l","f-h","l-r","an-ang","en-eng","in-ing"};
const char *ColorKeys[] = {"background","border","text","comment","index","highlight","highlightText","highlightComment","cursor","page"};
const wchar_t *ColorLabels[] = {L"背景",L"边框",L"候选文字",L"翻译文字",L"序号",L"高亮背景",L"高亮文字",L"选中翻译",L"输入与光标",L"页码"};
const char *VisualKeys[] = {"radius","padding","rowHeight","opacity","bgOpacity","imageOpacity"};
const wchar_t *VisualLabels[] = {L"圆角 (0–20)",L"内边距 (0–20)",L"行高 % (80–140)",L"整体不透明度 %",L"背景色不透明度 %",L"背景图不透明度 %"};
std::wstring content(HWND h) { int n=GetWindowTextLengthW(h); std::wstring s(size_t(n)+1,L'\0'); GetWindowTextW(h,s.data(),n+1); s.resize(n); return s; }
std::wstring lower(std::wstring s) { std::transform(s.begin(),s.end(),s.begin(),::towlower); return s; }
std::wstring trim(std::wstring s) { while(!s.empty() && iswspace(s.front()))s.erase(s.begin()); while(!s.empty() && iswspace(s.back()))s.pop_back(); return s; }
std::wstring message(const std::exception &e) { try { return gw::wide(e.what()); } catch(...) { return L"操作失败，请重试。"; } }
std::string uuid() { GUID id{}; if(FAILED(CoCreateGuid(&id)))throw std::runtime_error("无法生成主题 ID"); wchar_t s[40]{}; StringFromGUID2(id,s,40); return gw::utf8(std::wstring(s+1,36)); }
std::optional<gw::fs::path> pickFile(HWND owner,bool save,const wchar_t *filter,const wchar_t *extension) {
    std::wstring file(32768,L'\0'); OPENFILENAMEW request{}; request.lStructSize=sizeof(request); request.hwndOwner=owner;
    request.lpstrFilter=filter; request.lpstrFile=file.data(); request.nMaxFile=DWORD(file.size()); request.lpstrDefExt=extension;
    request.Flags=OFN_EXPLORER|OFN_NOCHANGEDIR|OFN_PATHMUSTEXIST|(save?OFN_OVERWRITEPROMPT:OFN_FILEMUSTEXIST);
    if (!(save?GetSaveFileNameW(&request):GetOpenFileNameW(&request))) {
        if(CommDlgExtendedError())throw std::runtime_error("无法打开文件选择器"); return std::nullopt;
    }
    return gw::fs::path(file.c_str());
}
struct Mutex {
    HANDLE h=nullptr;
    explicit Mutex(const wchar_t *purpose) {
        h=CreateMutexW(nullptr,FALSE,(L"Local\\Gogaku-"+gw::userSid()+L"-"+purpose).c_str());
        if(!h)throw std::runtime_error("无法创建保存锁");
        DWORD result=WaitForSingleObject(h,5000);
        if(result!=WAIT_OBJECT_0 && result!=WAIT_ABANDONED){CloseHandle(h);h=nullptr;throw std::runtime_error("数据正忙，请重试");}
    }
    ~Mutex(){if(h){ReleaseMutex(h);CloseHandle(h);}}
};
struct Word { int kind=0; bool enabled=true; std::string code,pinyin,text; };
struct Core {
    HMODULE library=nullptr;
#define API(name) decltype(&::name) name=nullptr;
    API(gc_abi_check) API(gc_custom_words_read) API(gc_custom_words_write) API(gc_custom_word_list_free)
    API(gc_custom_words_validate) API(gc_custom_pinyin_lookup)
#undef API
    ~Core(){if(library)FreeLibrary(library);}
    void load() {
        if(library)return;
        auto path=gw::installRoot()/L"bin/x64/libgogaku_core.dll";
        HMODULE candidate=LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32);
        if(!candidate)throw std::runtime_error("共享核心 DLL 不可用；自定义词语不能读取或保存。");
#define LOAD(name) name=reinterpret_cast<decltype(name)>(GetProcAddress(candidate,#name)); if(!name){FreeLibrary(candidate);throw std::runtime_error("共享核心缺少自定义词语接口");}
        LOAD(gc_abi_check) LOAD(gc_custom_words_read) LOAD(gc_custom_words_write) LOAD(gc_custom_word_list_free)
        LOAD(gc_custom_words_validate) LOAD(gc_custom_pinyin_lookup)
#undef LOAD
        if(gc_abi_check(GOGAKU_CORE_ABI_VERSION)){FreeLibrary(candidate);throw std::runtime_error("共享核心 ABI 不匹配");}
        library=candidate;
    }
    std::string path() { return gw::utf8((gw::userRoot()/L"custom-words.tsv").wstring()); }
    std::vector<Word> read(bool &corrupt) {
        load(); GcCustomWordList *list=nullptr; int result=gc_custom_words_read(path().c_str(),&list);
        std::unique_ptr<GcCustomWordList,std::function<void(GcCustomWordList *)>> holder(list,[this](auto p){gc_custom_word_list_free(p);});
        if(result || !list)throw std::runtime_error("词表读取失败；不能将读取失败当成空表保存。");
        corrupt=list->corrupt!=0; std::vector<Word> out;
        for(size_t i=0;i<list->count;++i){auto &w=list->words[i];out.push_back({w.kind,w.enabled!=0,w.code?w.code:"",w.pinyin?w.pinyin:"",w.content?w.content:""});}
        return out;
    }
    void validate(const Word &w) {
        load(); char error[512]{};
        if(gc_custom_words_validate(w.kind,w.code.c_str(),w.pinyin.c_str(),w.text.c_str(),error,sizeof(error)))throw std::runtime_error(error[0]?error:"词条无效");
    }
    void write(const std::vector<Word> &words) {
        load(); std::vector<GcCustomWord> values;
        for(const auto &w:words){validate(w); values.push_back({w.kind,w.enabled?1:0,const_cast<char *>(w.code.c_str()),const_cast<char *>(w.pinyin.c_str()),const_cast<char *>(w.text.c_str())});}
        GcCustomWordList list{values.data(),values.size(),0};
        if(gc_custom_words_write(path().c_str(),&list))throw std::runtime_error("词表原子保存失败；旧文件未替换，请重试。");
    }
    std::string lookup(const std::string &text) {
        load(); auto dictionary=gw::utf8((gw::installRoot()/L"data/sc.dict").wstring()); char *result=nullptr;
        int rc=gc_custom_pinyin_lookup(dictionary.c_str(),text.c_str(),&result);
        if(rc || !result)throw std::runtime_error("自动读音不可用：请检查随包词典，或手动填写每字一个全拼音节。");
        // Return allocations to the core's allocator, not the settings EXE CRT.
        // The C ABI exposes a list deleter but no standalone string deleter.
        GcCustomWordList *holder=nullptr; auto missing=gw::utf8((gw::userRoot()/gw::wide(".lookup-"+uuid()+".tsv")).wstring());
        int alloc=gc_custom_words_read(missing.c_str(),&holder);
        if(alloc || !holder || !holder->words){if(holder)gc_custom_word_list_free(holder);throw std::runtime_error("无法释放核心读音缓冲（核心分配接口失败）");}
        holder->count=1; holder->words[0].content=result;
        std::string value(result); gc_custom_word_list_free(holder); return value;
    }
};

// Small owned modal forms, built from real Win32 controls. Used for word edits
// and manually entered package identities. No changes are committed on Cancel.
struct Field { std::wstring label,value; bool multiline=false,password=false; };
struct Form {
    HINSTANCE instance; HWND owner,window=nullptr,error=nullptr; HFONT font;
    std::wstring title; std::vector<Field> fields; std::vector<HWND> inputs;
    std::function<void(std::vector<std::wstring> &)> validate;
    std::function<std::wstring(const std::vector<std::wstring> &)> extra;
    std::thread worker; std::vector<std::wstring> submitted;
    bool done=false,accepted=false,busy=false;
    UINT dpi=96; HFONT ownedFont=nullptr; std::vector<Placement> placements;
    ~Form(){if(ownedFont)DeleteObject(ownedFont);}
    int px(int value)const{return MulDiv(value,int(dpi),96);}
    void scale(UINT next) {
        dpi=next;auto previous=ownedFont;ownedFont=uiFont(dpi,15);font=ownedFont;
        for(const auto &p:placements){MoveWindow(p.window,px(p.x),px(p.y),px(p.width),px(p.height),TRUE);SendMessageW(p.window,WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE);}
        if(previous)DeleteObject(previous);
    }
    HWND add(const wchar_t *cls,const wchar_t *name,DWORD style,int x,int y,int w,int h,int id=0) {
        auto child=CreateWindowExW(cls==std::wstring(L"EDIT")?WS_EX_CLIENTEDGE:0,cls,name,WS_CHILD|WS_VISIBLE|style,px(x),px(y),px(w),px(h),window,reinterpret_cast<HMENU>(INT_PTR(id)),instance,nullptr);
        placements.push_back({child,x,y,w,h,cls});
        SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE); return child;
    }
    std::vector<std::wstring> values(){std::vector<std::wstring> out;for(auto h:inputs)out.push_back(content(h));return out;}
    static LRESULT CALLBACK proc(HWND h,UINT m,WPARAM w,LPARAM l) {
        if(m==WM_NCCREATE)SetWindowLongPtrW(h,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW *>(l)->lpCreateParams));
        auto self=reinterpret_cast<Form *>(GetWindowLongPtrW(h,GWLP_USERDATA));if(!self)return DefWindowProcW(h,m,w,l);
        try {
            if(m==WM_DPICHANGED){self->scale(HIWORD(w));auto r=reinterpret_cast<RECT *>(l);SetWindowPos(h,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER|SWP_NOACTIVATE);return 0;}
            if(m==WM_CTLCOLORSTATIC||m==WM_CTLCOLORBTN){auto dc=reinterpret_cast<HDC>(w);SetBkMode(dc,TRANSPARENT);SetBkColor(dc,RGB(255,255,255));SetTextColor(dc,TextColor);return reinterpret_cast<LRESULT>(GetStockObject(WHITE_BRUSH));}
            if(m==WM_COMMAND && LOWORD(w)==IDOK) {
                auto v=self->values();if(self->validate)self->validate(v);self->submitted=v;self->accepted=true;SendMessageW(h,WM_CLOSE,0,0);return 0;
            }
            if(m==WM_COMMAND && LOWORD(w)==IDCANCEL){SendMessageW(h,WM_CLOSE,0,0);return 0;}
            if(m==WM_COMMAND && LOWORD(w)==500 && !self->busy) {
                self->busy=true;self->submitted=self->values();SetWindowTextW(self->error,L"正在后台查询读音…");EnableWindow(GetDlgItem(h,500),FALSE);
                if(self->worker.joinable())self->worker.join();
                self->worker=std::thread([self,h,source=self->submitted](){std::wstring value;bool ok=true;try{value=self->extra(source);}catch(const std::exception &e){value=message(e);ok=false;}
                    PostMessageW(h,DialogCompleted,ok,reinterpret_cast<LPARAM>(new std::wstring(value)));});return 0;
            }
            if(m==DialogCompleted){std::unique_ptr<std::wstring> value(reinterpret_cast<std::wstring *>(l));self->busy=false;EnableWindow(GetDlgItem(h,500),TRUE);
                if(w && self->values()==self->submitted){SetWindowTextW(self->inputs[1],value->c_str());SetWindowTextW(self->error,L"读音已填写，可逐字修改后保存。");}
                else SetWindowTextW(self->error,w?L"内容已改变，未套用旧读音；请重新查询。":value->c_str());return 0;}
            if(m==WM_CLOSE){self->done=true;ShowWindow(h,SW_HIDE);return 0;}
        }catch(const std::exception &e){SetWindowTextW(self->error,message(e).c_str());return 0;}
        return DefWindowProcW(h,m,w,l);
    }
    bool run() {
        WNDCLASSW wc{};wc.lpfnWndProc=proc;wc.hInstance=instance;wc.lpszClassName=L"GogakuSettingsForm";wc.hbrBackground=GetSysColorBrush(COLOR_WINDOW);wc.hCursor=LoadCursorW(nullptr,IDC_ARROW);RegisterClassW(&wc);
        dpi=GetDpiForWindow(owner);if(!dpi)dpi=96;scale(dpi);
        int height=148;for(const auto &f:fields)height+=f.multiline?130:64;
        RECT parent{};GetWindowRect(owner,&parent);RECT bounds{0,0,px(620),px(height)};
        DWORD style=WS_CAPTION|WS_SYSMENU|WS_POPUP,extended=WS_EX_DLGMODALFRAME|WS_EX_CONTROLPARENT;
        AdjustWindowRectExForDpi(&bounds,style,FALSE,extended,dpi);
        window=CreateWindowExW(extended,wc.lpszClassName,title.c_str(),style,
            parent.left+px(60),parent.top+px(40),bounds.right-bounds.left,bounds.bottom-bounds.top,owner,nullptr,instance,this);
        if(!window)throw std::runtime_error("无法打开编辑表单");
        int y=16;
        for(size_t i=0;i<fields.size();++i){auto &f=fields[i];add(L"STATIC",f.label.c_str(),0,20,y,570,22);y+=24;
            DWORD style=WS_TABSTOP|ES_AUTOHSCROLL|(f.password?ES_PASSWORD:0)|(f.multiline?(ES_MULTILINE|ES_AUTOVSCROLL|ES_WANTRETURN|WS_VSCROLL):0);
            auto input=add(L"EDIT",f.value.c_str(),style,20,y,570,f.multiline?90:27,100+int(i));
            SendMessageW(input,EM_SETLIMITTEXT,f.multiline?4096:4096,0);inputs.push_back(input);y+=f.multiline?104:40;
        }
        error=add(L"STATIC",L"",0,20,y,570,42);y+=46;
        if(extra)add(L"BUTTON",L"自动读音",BS_PUSHBUTTON|WS_TABSTOP,20,y,110,28,500);
        add(L"BUTTON",L"保存",BS_DEFPUSHBUTTON|WS_TABSTOP,370,y,100,28,IDOK);add(L"BUTTON",L"取消",BS_PUSHBUTTON|WS_TABSTOP,480,y,100,28,IDCANCEL);
        EnableWindow(owner,FALSE);ShowWindow(window,SW_SHOWNORMAL);SetFocus(inputs.empty()?GetDlgItem(window,IDOK):inputs[0]);
        MSG msg{};while(!done && GetMessageW(&msg,nullptr,0,0)>0){if(!IsDialogMessageW(window,&msg)){TranslateMessage(&msg);DispatchMessageW(&msg);}}
        if(worker.joinable())worker.join();
        while(PeekMessageW(&msg,window,DialogCompleted,DialogCompleted,PM_REMOVE))delete reinterpret_cast<std::wstring *>(msg.lParam);
        EnableWindow(owner,TRUE);DestroyWindow(window);SetActiveWindow(owner);return accepted;
    }
};

// SQLite is optional and is never searched on PATH or created for a placeholder.
// Only the explicit shipped DLL and the known events/tombstones schema are used.
struct Records {
    HMODULE library=nullptr; void *db=nullptr;
    int (*open)(const char *,void **,int,const char *)=nullptr;int (*close)(void *)=nullptr;
    int (*prepare)(void *,const char *,int,void **,const char **)=nullptr;int (*step)(void *)=nullptr;int (*finalize)(void *)=nullptr;
    const void *(*blob)(void *,int)=nullptr;int (*bytes)(void *,int)=nullptr;const unsigned char *(*text)(void *,int)=nullptr;
    int (*bindText)(void *,int,const char *,int,void(*)(void *))=nullptr;int (*bindBlob)(void *,int,const void *,int,void(*)(void *))=nullptr;
    int (*exec)(void *,const char *,void *,void *,char **)=nullptr;int (*timeout)(void *,int)=nullptr;
    ~Records(){if(db)close(db);if(library)FreeLibrary(library);}
    void load() {
        auto dll=gw::installRoot()/L"bin/x64/sqlite3.dll",path=gw::userRoot()/L"learning.sqlite";
        if(!gw::fs::exists(dll))throw std::runtime_error("此构建未随包提供 SQLite；学习片段查看不可用。真实采集仍关闭，不显示示例数据。");
        if(!gw::fs::exists(path))throw std::runtime_error("尚无真实学习片段数据库。真实采集仍关闭，不创建示例记录。");
        library=LoadLibraryExW(dll.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32);
        if(!library)throw std::runtime_error("随包 SQLite 无法加载；未打开或修改数据库。");
#define SQL(member,name) member=reinterpret_cast<decltype(member)>(GetProcAddress(library,"sqlite3_" name));if(!member)throw std::runtime_error("随包 SQLite 接口不完整");
        SQL(open,"open_v2") SQL(close,"close") SQL(prepare,"prepare_v2") SQL(step,"step") SQL(finalize,"finalize") SQL(blob,"column_blob") SQL(bytes,"column_bytes") SQL(text,"column_text") SQL(bindText,"bind_text") SQL(bindBlob,"bind_blob") SQL(exec,"exec") SQL(timeout,"busy_timeout")
#undef SQL
        if(open(gw::utf8(path.wstring()).c_str(),&db,2|0x10000,nullptr))throw std::runtime_error("无法打开已有学习数据库（未创建新文件）。");
        timeout(db,100);
        void *check=nullptr;
        if(prepare(db,"SELECT id,expires,app,payload FROM events LIMIT 0",-1,&check,nullptr)){if(check)finalize(check);throw std::runtime_error("学习数据库 schema 不兼容，未执行写入。");}finalize(check);
        if(prepare(db,"SELECT id FROM tombstones LIMIT 0",-1,&check,nullptr)){if(check)finalize(check);throw std::runtime_error("学习数据库缺少删除门禁表，未执行写入。");}finalize(check);
    }
    Json list() {
        load();void *s=nullptr;
        if(prepare(db,"SELECT payload FROM events WHERE expires > CAST(strftime('%s','now') AS REAL) ORDER BY rowid DESC LIMIT 1000",-1,&s,nullptr))throw std::runtime_error("学习片段查询失败");
        std::unique_ptr<void,std::function<void(void *)>> holder(s,[this](void *p){finalize(p);});Json rows=Json::array();int rc;
        while((rc=step(s))==100){int n=bytes(s,0);if(n<1||n>1024*1024)throw std::runtime_error("学习片段内容损坏");auto value=Json::parse(std::string(static_cast<const char *>(blob(s,0)),size_t(n)));if(!value.is_object()||!value.contains("id"))throw std::runtime_error("学习片段格式不兼容");rows.push_back(value);}
        if(rc!=101)throw std::runtime_error("学习片段读取失败");return rows;
    }
    void update(const std::string &id,bool dismiss) {
        load();if(exec(db,"BEGIN IMMEDIATE",nullptr,nullptr,nullptr))throw std::runtime_error("数据库正忙，请重试");
        try {
            auto run=[&](const char *sql,const std::string &value,bool isBlob){void *s=nullptr;if(prepare(db,sql,-1,&s,nullptr))throw std::runtime_error("学习片段写入准备失败");std::unique_ptr<void,std::function<void(void *)>> holder(s,[this](void *p){finalize(p);});
                auto transient=reinterpret_cast<void(*)(void *)>(INT_PTR(-1));
                if(isBlob){bindBlob(s,1,value.data(),int(value.size()),transient);bindText(s,2,id.c_str(),int(id.size()),transient);}else bindText(s,1,id.c_str(),int(id.size()),transient);
                if(step(s)!=101)throw std::runtime_error("学习片段写入失败");};
            if(dismiss){void *s=nullptr;if(prepare(db,"SELECT payload FROM events WHERE id=?",-1,&s,nullptr))throw std::runtime_error("片段读取失败");
                std::unique_ptr<void,std::function<void(void *)>> holder(s,[this](void *p){finalize(p);});bindText(s,1,id.c_str(),int(id.size()),reinterpret_cast<void(*)(void *)>(INT_PTR(-1)));
                if(step(s)!=100)throw std::runtime_error("片段已不存在");int n=bytes(s,0);if(n<1||n>1024*1024)throw std::runtime_error("片段格式无效");auto payload=Json::parse(std::string(static_cast<const char *>(blob(s,0)),size_t(n)));payload["issues"]=Json::array();
                holder.reset();run("UPDATE events SET payload=? WHERE id=?",payload.dump(),true);
            }else{run("INSERT OR IGNORE INTO tombstones(id) VALUES(?)",id,false);run("DELETE FROM events WHERE id=?",id,false);}
            if(exec(db,"COMMIT",nullptr,nullptr,nullptr))throw std::runtime_error("学习片段提交失败");
        }catch(...){exec(db,"ROLLBACK",nullptr,nullptr,nullptr);throw;}
    }
};

struct Result { std::string type; uint64_t generation=0; Json value; std::wstring error; };
struct App {
    HINSTANCE instance; HWND window=nullptr,nav=nullptr,pageWindow=nullptr,footer=nullptr,retry=nullptr,preview=nullptr;
    HWND heading=nullptr,brand=nullptr,versionLabel=nullptr;
    HFONT font=nullptr,titleFont=nullptr,helperFont=nullptr; HIMAGELIST icons=nullptr;
    HBRUSH sideBrush=CreateSolidBrush(SideColor);
    std::vector<Placement> placements;std::map<HWND,std::vector<int>> listColumns;
    Json settings=Json::object(),themeDraft=Json::object(),themeOriginal=Json::object(),themeList=Json::array(),records=Json::array();
    std::vector<HWND> controls;std::map<int,std::function<void(int)>> actions;
    std::vector<std::thread> jobs; std::atomic_bool cancel{false};
    std::function<void()> retryAction;
    Core core; std::vector<Word> words; std::vector<size_t> visibleWords; std::vector<Json> visibleApps;
    std::vector<int> visibleShortcuts;std::map<int,std::wstring> conflicts;std::map<int,Json> conflictDraft;
    std::unique_ptr<gw::CandidateRenderer> renderer;
    std::string wordBaseline; int currentPage=0,scroll=0,contentHeight=0,themeIndex=0,wordKind=0,recording=-1;
    bool building=false,themeEditing=false,themeTouched=false,themeBusy=false,previewDark=false,closed=false,wordReady=false;
    uint64_t generation=0;UINT dpi=96;std::wstring themeError; std::vector<std::wstring> fonts;
    explicit App(HINSTANCE h):instance(h){}
    ~App(){cancel=true;for(auto &job:jobs)if(job.joinable())job.join();if(icons)ImageList_Destroy(icons);if(font)DeleteObject(font);if(titleFont)DeleteObject(titleFont);if(helperFont)DeleteObject(helperFont);if(sideBrush)DeleteObject(sideBrush);}
    int px(int value)const{return MulDiv(value,int(dpi),96);}
    HWND get(int id)const{return GetDlgItem(pageWindow,id);}
    void status(const std::wstring &s,bool failed=false){SetWindowTextW(footer,s.c_str());SetWindowLongPtrW(footer,GWLP_USERDATA,failed?1:0);InvalidateRect(footer,nullptr,TRUE);ShowWindow(retry,failed && retryAction?SW_SHOW:SW_HIDE);}
    void fail(const std::exception &e){status(L"失败："+message(e),true);}
    HWND add(const wchar_t *cls,const std::wstring &name,DWORD style,int x,int y,int w,int h,int id=0,HWND parent=nullptr){
        HWND owner=parent?parent:pageWindow;DWORD ex=std::wstring(cls)==L"EDIT"?WS_EX_CLIENTEDGE:0;
        auto child=CreateWindowExW(ex,cls,name.c_str(),WS_CHILD|WS_VISIBLE|style,px(x),px(y),px(w),px(h),owner,reinterpret_cast<HMENU>(INT_PTR(id)),instance,nullptr);
        if(!child)throw std::runtime_error("无法创建原生设置控件");SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE);
        if(owner==pageWindow){controls.push_back(child);placements.push_back({child,x,y,w,h,cls});}return child;
    }
    HWND label(const std::wstring &s,int y,int h=24,int x=20,int w=790){
        if(y==18){SetWindowTextW(heading,s.c_str());return heading;}
        auto child=add(L"STATIC",s,0,x,y,w,h);placements.back().auxiliary=h>=40;
        if(h>=40)SendMessageW(child,WM_SETFONT,reinterpret_cast<WPARAM>(helperFont),TRUE);return child;
    }
    HWND button(const wchar_t *s,int id,int x,int y,int w=110){return add(L"BUTTON",s,WS_TABSTOP|BS_PUSHBUTTON,x,y,w,30,id);}
    HWND edit(const std::wstring &s,int id,int x,int y,int w,int h=28,DWORD more=0){auto hWnd=add(L"EDIT",s,WS_TABSTOP|ES_AUTOHSCROLL|more,x,y,w,h,id);SendMessageW(hWnd,EM_SETLIMITTEXT,16384,0);return hWnd;}
    HWND combo(int id,const std::vector<std::wstring> &values,int selected,int x,int y,int w=220,bool editable=false){auto h=add(L"COMBOBOX",L"",WS_TABSTOP|WS_VSCROLL|(editable?CBS_DROPDOWN:CBS_DROPDOWNLIST),x,y,w,280,id);
        for(const auto &v:values)SendMessageW(h,CB_ADDSTRING,0,reinterpret_cast<LPARAM>(v.c_str()));SendMessageW(h,CB_SETCURSEL,selected,0);return h;}
    bool checked(int id)const{return SendMessageW(get(id),BM_GETCHECK,0,0)==BST_CHECKED;}
    HWND check(const wchar_t *name,int id,int x,int y,bool value,int width=430){auto h=add(L"BUTTON",name,WS_TABSTOP|BS_AUTOCHECKBOX,x,y,width,26,id);SendMessageW(h,BM_SETCHECK,value?BST_CHECKED:BST_UNCHECKED,0);return h;}
    HWND list(int id,int y,int height,const std::vector<std::pair<std::wstring,int>> &columns,int width=840,bool checkboxes=false){
        HWND h=add(WC_LISTVIEWW,L"",WS_TABSTOP|WS_BORDER|LVS_REPORT|LVS_SINGLESEL|LVS_SHOWSELALWAYS,20,y,width,height,id);
        ListView_SetExtendedListViewStyle(h,LVS_EX_FULLROWSELECT|LVS_EX_DOUBLEBUFFER|(checkboxes?LVS_EX_CHECKBOXES:0));
        std::vector<int> widths;
        for(size_t i=0;i<columns.size();++i){LVCOLUMNW col{};col.mask=LVCF_TEXT|LVCF_WIDTH;col.pszText=const_cast<wchar_t *>(columns[i].first.c_str());col.cx=px(columns[i].second);ListView_InsertColumn(h,int(i),&col);widths.push_back(columns[i].second);}
        listColumns[h]=std::move(widths);SetWindowTheme(h,L"Explorer",nullptr);return h;
    }
    void row(HWND list,int index,const std::vector<std::wstring> &cells,int image=-1){if(cells.empty())return;LVITEMW item{};item.mask=LVIF_TEXT|(image>=0?LVIF_IMAGE:0);item.iItem=index;item.pszText=const_cast<wchar_t *>(cells[0].c_str());item.iImage=image;ListView_InsertItem(list,&item);
        for(size_t i=1;i<cells.size();++i)ListView_SetItemText(list,index,int(i),const_cast<wchar_t *>(cells[i].c_str()));}
    int selection(int id)const{return ListView_GetNextItem(get(id),-1,LVNI_SELECTED);}
    void job(const std::string &type,std::function<Json()> work,uint64_t gen=0){HWND target=window;jobs.emplace_back([target,type,work=std::move(work),gen](){auto result=std::make_unique<Result>();result->type=type;result->generation=gen;try{result->value=work();}catch(const std::exception &e){result->error=message(e);}catch(...){result->error=L"未知操作失败";}if(PostMessageW(target,Completed,0,reinterpret_cast<LPARAM>(result.get())))result.release();});}
    void notify(){uint64_t gen=generation;job("reload",[]{gw::RpcClient rpc;Json response;if(!rpc.connect()||!rpc.call({{"op","reload"}},response,2000)||!response.value("ok",false))throw std::runtime_error("设置已保存，但输入法重载未确认；可重试通知。");return response;},gen);}
    bool mutate(std::function<void(Json &)> operation){
        retryAction=[this,operation](){mutate(operation);};status(L"保存中…");
        try {
            // Same recursive named mutex as platform::saveSettings. Hold it over
            // read + field-only mutation + write, so async usage/mode updates and
            // unrelated pages are not replaced by a stale whole-settings copy.
            Mutex lock(L"settings");auto latest=gw::readSettings();operation(latest);gw::saveSettings(latest);settings=std::move(latest);++generation;
            retryAction=[this](){notify();};status(L"已保存");notify();return true;
        }catch(const std::exception &e){fail(e);return false;}
    }
    bool patch(Json changed){return mutate([changed](Json &latest){for(auto it=changed.begin();it!=changed.end();++it)latest[it.key()]=it.value();});}
    void bindBool(const wchar_t *labelText,int id,int y,const char *key){check(labelText,id,20,y,settings.value(key,false));actions[id]=[this,id,key](int n){if(n==BN_CLICKED)patch({{key,checked(id)}});};}
    void debounce(){SetTimer(window,2,300,nullptr);}
    void flushText();
    void buildPage();void layout();void reflowControls();void setDpi(UINT next);void setScroll(int position);void drawNavigation(const DRAWITEMSTRUCT &item);void learningPage();void normalPage();void wordPage();void skinPage();void shortcutPage();void privacyPage();void recordsPage();
    void fillApps();void addApp(bool browse);void removeApp();void toggleApp(size_t index);void fillWords();void editWord(bool fresh);void saveWords(std::vector<Word> value);void fillThemes();void openTheme(Json theme,bool fresh);void readThemeControls();void refreshPreview();bool leaveTheme();void saveTheme();void fillShortcuts();void recordKey(WPARAM key);void applyShortcut(int target,const Json &binding);void loadRecords();
    LRESULT command(int id,int notification);LRESULT result(Result &r);LRESULT notifyControl(NMHDR *header);
    static LRESULT CALLBACK proc(HWND,UINT,WPARAM,LPARAM);static LRESULT CALLBACK pageProc(HWND,UINT,WPARAM,LPARAM);static LRESULT CALLBACK previewProc(HWND,UINT,WPARAM,LPARAM);
    static LRESULT CALLBACK captureProc(HWND h,UINT m,WPARAM w,LPARAM l,UINT_PTR,DWORD_PTR p){auto self=reinterpret_cast<App *>(p);if((m==WM_KEYDOWN||m==WM_SYSKEYDOWN)&&self->recording>=0){self->recordKey(w);return 0;}if(m==WM_GETDLGCODE)return DLGC_WANTALLKEYS;if(m==WM_KILLFOCUS)self->recording=-1;return DefSubclassProc(h,m,w,l);}
    bool create(int show);
};

void App::learningPage(){
    label(L"学习翻译",18);bindBool(L"启用学习翻译（默认关闭）",100,56,"learningTranslationEnabled");
    actions[100]=[this](int n){if(n!=BN_CLICKED)return;bool enabled=checked(100);if(enabled && gw::readCredentials().value("accessKeyId",std::string()).empty()){SendMessageW(get(100),BM_SETCHECK,BST_UNCHECKED,0);throw std::runtime_error("请先保存完整的火山 NMT 凭据，再显式启用学习翻译。");}patch({{"learningTranslationEnabled",enabled}});};
    auto credentials=gw::readCredentials();bool configured=!credentials.value("accessKeyId",std::string()).empty()&&!credentials.value("secretAccessKey",std::string()).empty();
    label(L"Access Key ID",108);edit(gw::wide(credentials.value("accessKeyId",std::string())),101,20,134,600);
    label(L"Secret Access Key",176);edit(L"",102,20,202,600,28,ES_PASSWORD);
    label(configured?L"已配置；留空 SK 可保留原密钥。凭据只存本机独立受保护文件。":L"未配置；凭据不进入设置、主题包或日志。",244,42);
    button(L"保存凭据",103,20,298);button(L"移除凭据",104,144,298);button(L"连接测试",105,268,298);
    label(L"",340,46,20,800);auto statusLabel=controls.back();SetWindowLongPtrW(statusLabel,GWLP_ID,107);
    actions[103]=[this](int n){if(n!=BN_CLICKED)return;auto ak=gw::utf8(trim(content(get(101)))),sk=gw::utf8(content(get(102)));auto old=gw::readCredentials();
        if(sk.empty() && ak==old.value("accessKeyId",std::string()))sk=old.value("secretAccessKey",std::string());
        if(ak.empty()||sk.empty())throw std::runtime_error("请填写 AK 与 SK；更换 AK 时也必须填写对应 SK。");
        retryAction=[this](){actions[103](BN_CLICKED);};gw::saveCredentials({{"accessKeyId",ak},{"secretAccessKey",sk}});SetWindowTextW(get(102),L"");SetWindowTextW(get(107),L"凭据已保存");++generation;notify();status(L"凭据已保存");};
    actions[104]=[this](int n){if(n!=BN_CLICKED)return;retryAction=[this](){actions[104](BN_CLICKED);};gw::removeCredentials();patch({{"learningTranslationEnabled",false}});SendMessageW(get(100),BM_SETCHECK,BST_UNCHECKED,0);SetWindowTextW(get(101),L"");SetWindowTextW(get(102),L"");SetWindowTextW(get(107),L"凭据已移除；学习翻译已关闭。");};
    actions[105]=[this](int n){if(n!=BN_CLICKED)return;if(gw::readCredentials().value("accessKeyId",std::string()).empty())throw std::runtime_error("请先保存凭据。连接测试只使用已保存的凭据。");
        EnableWindow(get(105),FALSE);SetWindowTextW(get(107),L"正在后台测试（会发送一次短请求并计入本机统计）…");job("test",[this](){return gw::translate("Hello",1,&cancel);});};
    auto usage=gw::readUsage();label(L"本机本月成功请求字符："+gw::wide(usage.value("month",gw::currentMonth()))+L"  "+std::to_wstring(usage.value("characters",uint64_t(0))),410,30);
    SetWindowLongPtrW(controls.back(),GWLP_ID,106);label(L"仅为本机成功请求计量，不代表账户余额或官方免费额度。",450,40);
}
void App::normalPage(){
    label(L"普通输入",18);label(L"输入方案",60,24,20,100);combo(200,{L"小鹤双拼",L"全拼"},settings.value("inputScheme",std::string())=="fullPinyin",140,56);
    actions[200]=[this](int n){if(n==CBN_SELCHANGE)patch({{"inputScheme",SendMessageW(get(200),CB_GETCURSEL,0,0)==1?"fullPinyin":"xiaohe"}});};
    label(L"模糊音",100);auto fuzzy=settings.value("fuzzyPinyin",Json::array());
    for(int i=0;i<9;++i){check(gw::wide(Fuzzy[i]).c_str(),210+i,20+(i%3)*180,130+(i/3)*32,std::find(fuzzy.begin(),fuzzy.end(),Fuzzy[i])!=fuzzy.end(),170);
        actions[210+i]=[this](int n){if(n!=BN_CLICKED)return;Json values=Json::array();for(int k=0;k<9;++k)if(checked(210+k))values.push_back(Fuzzy[k]);patch({{"fuzzyPinyin",values}});};}
    label(L"候选字号（旧默认主题）",240,24,20,190);auto slider=add(TRACKBAR_CLASSW,L"",WS_TABSTOP|TBS_AUTOTICKS,220,232,250,45,220);SendMessageW(slider,TBM_SETRANGE,TRUE,MAKELONG(12,16));SendMessageW(slider,TBM_SETTICFREQ,1,0);SendMessageW(slider,TBM_SETPOS,TRUE,settings.value("candidateFontSize",14));
    label(std::to_wstring(settings.value("candidateFontSize",14)),242,26,480,50);SetWindowLongPtrW(controls.back(),GWLP_ID,228);
    bindBool(L"显示英文释义",221,294,"glossEnabled");bindBool(L"显示输入区字母（安全字段仍禁用）",222,326,"inputLettersEnabled");
    label(L"字母显示",368,24,20,110);combo(223,{L"展开全拼",L"原始编码"},settings.value("fullPinyinPreedit",true)?0:1,140,362);
    actions[223]=[this](int n){if(n==CBN_SELCHANGE)patch({{"fullPinyinPreedit",SendMessageW(get(223),CB_GETCURSEL,0,0)==0}});};
    bindBool(L"中文模式下提供英文候选",224,408,"englishCandidatesEnabled");bindBool(L"学习普通模式完整上屏的中文调频",225,440,"frequencyEnabled");button(L"清空调频…",227,480,438,140);
    actions[227]=[this](int n){if(n!=BN_CLICKED)return;if(MessageBoxW(window,L"仅清空个人调频，不删除出厂词和自定义词。继续？",L"清空调频",MB_YESNO|MB_ICONWARNING)!=IDYES)return;
        status(L"正在请求输入核心清空调频…");job("clear",[]{gw::RpcClient rpc;Json response;if(!rpc.connect()||!rpc.call({{"op","clear"}},response,4000)||!response.value("ok",false))throw std::runtime_error("输入法未确认清空；未删除任何词库文件，请重试。");return response;});};
    label(L"按应用默认英文",498);edit(L"",240,20,530,430);button(L"选择 .exe…",242,470,530,120);button(L"输入包身份…",243,604,530,140);
    list(241,572,240,{{L"应用",220},{L"路径／包身份",570}},840,true);button(L"移除",244,20,826);button(L"启用／停用",245,144,826,130);
    actions[240]=[this](int n){if(n==EN_CHANGE)fillApps();};actions[242]=[this](int n){if(n==BN_CLICKED)addApp(true);};actions[243]=[this](int n){if(n==BN_CLICKED)addApp(false);};actions[244]=[this](int n){if(n==BN_CLICKED)removeApp();};actions[245]=[this](int n){int i=selection(241);if(n==BN_CLICKED && i>=0)toggleApp(size_t(i));};fillApps();
}
void App::fillApps(){
    if(!get(241))return;bool previous=building;building=true;ListView_DeleteAllItems(get(241));visibleApps.clear();
    if(icons)ImageList_Destroy(icons);icons=ImageList_Create(px(16),px(16),ILC_COLOR32|ILC_MASK,16,8);ListView_SetImageList(get(241),icons,LVSIL_SMALL);
    bool excluded=currentPage==5;auto entries=settings.value(excluded?"excludedApplications":"appDefaultEnglish",Json::array());auto metadata=settings.value("windowsApplicationMetadata",Json::object());auto query=lower(content(get(240)));
    for(const auto &entry:entries){Json item=entry.is_string()?Json{{"id",entry},{"enabled",true}}:entry;if(!item.is_object())continue;auto id=item.value("id",std::string());if(id.empty())continue;
        Json meta=metadata.value(id,Json::object());std::wstring path=gw::wide(item.value("path",meta.value("path",std::string()))),name=gw::wide(item.value("name",meta.value("name",id)));
        if(!query.empty() && lower(name+L" "+path+L" "+gw::wide(id)).find(query)==std::wstring::npos)continue;
        SHFILEINFOW info{};DWORD flags=SHGFI_ICON|SHGFI_SMALLICON|SHGFI_DISPLAYNAME;
        if(path.empty()||!gw::fs::exists(path)){flags|=SHGFI_USEFILEATTRIBUTES;path=path.empty()?gw::wide(id):path;}
        SHGetFileInfoW(path.c_str(),FILE_ATTRIBUTE_NORMAL,&info,sizeof(info),flags);int image=-1;
        if(info.hIcon){image=ImageList_AddIcon(icons,info.hIcon);DestroyIcon(info.hIcon);}
        item["name"]=gw::utf8(name);item["path"]=gw::utf8(path);visibleApps.push_back(item);
        row(get(241),int(visibleApps.size()-1),{name,path},image);if(!excluded)ListView_SetCheckState(get(241),int(visibleApps.size()-1),item.value("enabled",true));
    }
    building=previous;
}
void App::addApp(bool browse){
    std::wstring id,path,name;
    if(browse){auto file=pickFile(window,false,L"应用程序 (*.exe)\0*.exe\0\0",L"exe");if(!file)return;if(lower(file->extension().wstring())!=L".exe")throw std::runtime_error("请选择 .exe 应用程序");path=file->wstring();id=lower(file->filename().wstring());
        SHFILEINFOW info{};SHGetFileInfoW(path.c_str(),0,&info,sizeof(info),SHGFI_DISPLAYNAME);name=info.szDisplayName[0]?info.szDisplayName:file->stem().wstring();
    }else{Form form{instance,window,nullptr,nullptr,font,L"添加包身份",{{L"包身份（PackageFamilyName!ApplicationId）",L""},{L"显示名称（可留空）",L""}}};
        form.validate=[](auto &v){v[0]=trim(v[0]);if(v[0].empty()||v[0].size()>512||v[0].find(L'!')==std::wstring::npos||v[0].find_first_of(L"\r\n\t\\/")!=std::wstring::npos)throw std::runtime_error("请输入完整 PackageFamilyName!ApplicationId；不接受路径或控制字符。");};
        if(!form.run())return;id=lower(form.submitted[0]);name=form.submitted[1].empty()?form.submitted[0]:form.submitted[1];path=form.submitted[0];}
    auto key=gw::utf8(id),display=gw::utf8(name),location=gw::utf8(path);bool excluded=currentPage==5;
    if(mutate([=](Json &latest){auto &entries=latest[excluded?"excludedApplications":"appDefaultEnglish"];if(!entries.is_array())entries=Json::array();bool found=false;
        for(auto &e:entries){auto existing=e.is_string()?e.get<std::string>():e.value("id",std::string());if(lower(gw::wide(existing))==lower(gw::wide(key))){found=true;if(!excluded)e={{"id",key},{"enabled",true}};}}
        if(!found)entries.push_back(excluded?Json(key):Json{{"id",key},{"enabled",true}});latest["windowsApplicationMetadata"][key]={{"name",display},{"path",location}};}))fillApps();
}
void App::removeApp(){int selected=selection(241);if(selected<0||size_t(selected)>=visibleApps.size())return;auto id=visibleApps[size_t(selected)].value("id",std::string());bool excluded=currentPage==5;
    if(mutate([=](Json &latest){auto &entries=latest[excluded?"excludedApplications":"appDefaultEnglish"];if(!entries.is_array())return;entries.erase(std::remove_if(entries.begin(),entries.end(),[&](const Json &e){return (e.is_string()?e.get<std::string>():e.value("id",std::string()))==id;}),entries.end());}))fillApps();}
void App::toggleApp(size_t index){if(currentPage!=1||index>=visibleApps.size())return;auto id=visibleApps[index].value("id",std::string());bool enabled=!visibleApps[index].value("enabled",true);
    if(mutate([=](Json &latest){auto &entries=latest["appDefaultEnglish"];for(auto &e:entries)if((e.is_string()?e.get<std::string>():e.value("id",std::string()))==id)e={{"id",id},{"enabled",enabled}};}))fillApps();}

void App::wordPage(){
    label(L"自定义词语",18);combo(300,{L"短码短语",L"拼音词"},wordKind,20,56,180);edit(L"",301,220,56,420);button(L"重新读取",309,660,56,140);
    list(302,108,310,{{L"内容",430},{L"编码／读音",260},{L"状态",100}});
    button(L"新增",303,20,436,90);button(L"编辑",304,122,436,90);button(L"删除…",305,224,436,90);button(L"启用／停用",306,326,436,130);button(L"上移",307,470,436,90);button(L"下移",308,572,436,90);
    label(L"短码：1–32 个小写字母，内容最多 512 字符。拼音词：1–16 个汉字，每字一个规范全拼音节。",490,52);
    actions[300]=[this](int n){if(n==CBN_SELCHANGE){wordKind=int(SendMessageW(get(300),CB_GETCURSEL,0,0));fillWords();}};actions[301]=[this](int n){if(n==EN_CHANGE)fillWords();};
    actions[303]=[this](int n){if(n==BN_CLICKED)editWord(true);};actions[304]=[this](int n){if(n==BN_CLICKED)editWord(false);};
    actions[305]=[this](int n){int i=selection(302);if(n!=BN_CLICKED||i<0)return;if(MessageBoxW(window,L"删除选中的自定义词语？",L"删除词语",MB_YESNO|MB_ICONWARNING)!=IDYES)return;auto value=words;value.erase(value.begin()+ptrdiff_t(visibleWords[size_t(i)]));saveWords(value);};
    actions[306]=[this](int n){int i=selection(302);if(n!=BN_CLICKED||i<0)return;auto value=words;auto index=visibleWords[size_t(i)];value[index].enabled=!value[index].enabled;saveWords(value);};
    for(int id:{307,308})actions[id]=[this,id](int n){int i=selection(302);if(n!=BN_CLICKED||i<0||!content(get(301)).empty())return;int target=i+(id==307?-1:1);if(target<0||size_t(target)>=visibleWords.size())return;auto value=words;std::swap(value[visibleWords[size_t(i)]],value[visibleWords[size_t(target)]]);saveWords(value);ListView_SetItemState(get(302),target,LVIS_SELECTED|LVIS_FOCUSED,LVIS_SELECTED|LVIS_FOCUSED);};
    actions[309]=[this](int n){if(n!=BN_CLICKED)return;bool corrupt=false;auto value=core.read(corrupt);words=value;wordReady=true;auto path=gw::userRoot()/L"custom-words.tsv";wordBaseline=gw::fs::exists(path)?gw::readFile(path):"";fillWords();status(corrupt?L"词表损坏，核心已备份为 .corrupt 并以空表启动。":L"已读取真实词表");};
    try{actions[309](BN_CLICKED);}catch(const std::exception &e){wordReady=false;for(int id=303;id<=308;++id)EnableWindow(get(id),FALSE);retryAction=[this](){buildPage();};fail(e);}
}
void App::fillWords(){if(!get(302))return;ListView_DeleteAllItems(get(302));visibleWords.clear();auto query=lower(content(get(301)));
    for(size_t i=0;i<words.size();++i){const auto &w=words[i];if(w.kind!=wordKind)continue;auto value=gw::wide(w.text),code=gw::wide(w.kind?w.pinyin:w.code);if(!query.empty()&&lower(value+L" "+code).find(query)==std::wstring::npos)continue;
        visibleWords.push_back(i);for(auto &c:value)if(c==L'\r'||c==L'\n'||c==L'\t')c=L' ';row(get(302),int(visibleWords.size()-1),{value,code,w.enabled?L"启用":L"停用"});}
    EnableWindow(get(307),query.empty());EnableWindow(get(308),query.empty());
}
void App::editWord(bool fresh){if(!wordReady)return;int selected=selection(302);if(!fresh&&selected<0)return;size_t index=fresh?words.size():visibleWords[size_t(selected)];Word w=fresh?Word{}:words[index];w.kind=wordKind;
    Form form{instance,window,nullptr,nullptr,font,fresh?L"新增自定义词语":L"编辑自定义词语",{{L"内容",gw::wide(w.text),true},{wordKind?L"全拼读音（撇号分隔，可逐字修改）":L"短码（小写字母）",gw::wide(wordKind?w.pinyin:w.code)}}};
    form.validate=[this,w](auto &values){Word value=w;value.text=gw::utf8(values[0]);if(value.kind)value.pinyin=gw::utf8(trim(values[1]));else value.code=gw::utf8(trim(values[1]));core.validate(value);};
    if(wordKind)form.extra=[this](const auto &values){return gw::wide(core.lookup(gw::utf8(values[0])));};
    if(!form.run())return;w.text=gw::utf8(form.submitted[0]);if(wordKind)w.pinyin=gw::utf8(trim(form.submitted[1]));else w.code=gw::utf8(trim(form.submitted[1]));auto value=words;if(fresh)value.push_back(w);else value[index]=w;saveWords(value);
}
void App::saveWords(std::vector<Word> value){
    const auto baseline=wordBaseline;retryAction=[this,value](){saveWords(value);};
    try{Mutex lock(L"custom-words");auto path=gw::userRoot()/L"custom-words.tsv";auto latest=gw::fs::exists(path)?gw::readFile(path):"";
        if(latest!=baseline)throw std::runtime_error("词表已被其他程序修改。请重新读取后再编辑，未覆盖磁盘内容。");
        core.write(value);wordBaseline=gw::readFile(path);words=std::move(value);++generation;fillWords();status(L"词表已保存");notify();
    }catch(const std::exception &e){fail(e);}
}

void App::fillThemes(){themeList=gw::builtinThemes();std::set<std::string> ids={"rime-macos-like","gogaku","claude","grok","witch"};
    for(const auto &t:settings.value("userCandidateThemes",Json::array()))try{auto id=t.value("id",std::string());if(!ids.insert(id).second)continue;gw::validateTheme(t);themeList.push_back(t);}catch(...){}
}
void App::skinPage(){
    fillThemes();label(L"皮肤",18,24,20,430);
    if(!themeEditing){
        auto h=add(L"LISTBOX",L"",WS_TABSTOP|WS_BORDER|LBS_NOTIFY|WS_VSCROLL,20,58,420,252,400);
        for(const auto &t:themeList){std::wstring s=gw::wide(t.value("name",std::string()));if(t.value("id",std::string())==settings.value("candidateTheme",std::string()))s+=L"  · 已应用";SendMessageW(h,LB_ADDSTRING,0,reinterpret_cast<LPARAM>(s.c_str()));}
        themeIndex=std::clamp(themeIndex,0,int(themeList.size())-1);SendMessageW(h,LB_SETCURSEL,themeIndex,0);
        button(L"应用主题",401,20,330,130);button(L"新建",402,164,330,110);button(L"复制并编辑",403,288,330,152);
        button(L"编辑",404,20,374,130);button(L"删除…",405,164,374,110);button(L"导入主题…",406,288,374,152);
        button(L"导出主题…",407,20,418,150);
        label(L"选择只更新预览；保存与应用分别操作。",466,44,20,420);
        actions[400]=[this](int n){if(n==LBN_SELCHANGE){themeIndex=int(SendMessageW(get(400),LB_GETCURSEL,0,0));refreshPreview();}};
        actions[401]=[this](int n){if(n==BN_CLICKED && themeIndex>=0)patch({{"candidateTheme",themeList[size_t(themeIndex)]["id"]}});};
        actions[402]=[this](int n){if(n!=BN_CLICKED)return;auto t=gw::builtinThemes()[0];t.erase("dark");t["name"]="新主题";openTheme(t,true);};
        actions[403]=[this](int n){if(n!=BN_CLICKED)return;auto t=themeList[size_t(themeIndex)];t["name"]=t.value("name",std::string())+" 副本";openTheme(t,true);};
        actions[404]=[this](int n){if(n!=BN_CLICKED)return;if(themeIndex<4){status(L"内置主题不可修改，请使用“复制并编辑”。");return;}openTheme(themeList[size_t(themeIndex)],false);};
        actions[405]=[this](int n){if(n!=BN_CLICKED)return;if(themeIndex<4)throw std::runtime_error("内置主题不能删除");if(MessageBoxW(window,L"删除此用户主题？若正在应用，将回到旧默认外观。",L"删除主题",MB_YESNO|MB_ICONWARNING)!=IDYES)return;auto id=themeList[size_t(themeIndex)].value("id",std::string());
            if(mutate([id](Json &latest){auto &themes=latest["userCandidateThemes"];themes.erase(std::remove_if(themes.begin(),themes.end(),[&](const Json &t){return t.value("id",std::string())==id;}),themes.end());if(latest.value("candidateTheme",std::string())==id)latest["candidateTheme"]="rime-macos-like";})){themeIndex=0;buildPage();}};
        actions[406]=[this](int n){if(n!=BN_CLICKED||themeBusy)return;auto path=pickFile(window,false,L"Gogaku 主题 (*.gogakutheme)\0*.gogakutheme\0\0",L"gogakutheme");if(!path)return;themeBusy=true;status(L"正在后台校验并导入主题…");job("import",[path](){return gw::importTheme(*path);});};
        actions[407]=[this](int n){if(n!=BN_CLICKED||themeBusy)return;auto path=pickFile(window,true,L"Gogaku 主题 (*.gogakutheme)\0*.gogakutheme\0\0",L"gogakutheme");if(!path)return;auto t=themeList[size_t(themeIndex)];themeBusy=true;status(L"正在后台校验并导出主题…");job("export",[path,t](){gw::exportTheme(*path,t);return Json::object();});};
    }else{
        label(L"主题编辑（草稿）",54,24,20,420);button(L"返回",410,20,88,90);button(L"保存",411,124,88,90);button(L"导出草稿…",412,228,88,140);
        combo(413,{L"浅色／单色",L"深色"},previewDark?1:0,20,134,180);button(themeDraft.contains("dark")?L"改为单色":L"增加深色",414,220,134,140);
        label(L"主题与字体",190,24,20,420);
        label(L"名称",226,24,20,135);edit(gw::wide(themeDraft.value("name",std::string())),450,160,222,280);
        auto type=themeDraft.value("typography",Json::object());
        if(fonts.empty()){fonts.push_back(L"system-ui");LOGFONTW lf{};lf.lfCharSet=DEFAULT_CHARSET;HDC dc=GetDC(window);
            EnumFontFamiliesExW(dc,&lf,[](const LOGFONTW *lf,const TEXTMETRICW *,DWORD,LPARAM data)->int{auto v=reinterpret_cast<std::vector<std::wstring> *>(data);if(lf->lfFaceName[0]!=L'@'&&v->size()<1024)v->push_back(lf->lfFaceName);return 1;},reinterpret_cast<LPARAM>(&fonts),0);ReleaseDC(window,dc);std::sort(fonts.begin()+1,fonts.end());fonts.erase(std::unique(fonts.begin(),fonts.end()),fonts.end());}
        label(L"中文字体",266,24,20,135);auto cn=combo(451,fonts,0,160,262,280,true);SetWindowTextW(cn,gw::wide(type.value("fontCN",std::string("system-ui"))).c_str());
        label(L"英文字体",306,24,20,135);auto en=combo(452,fonts,0,160,302,280,true);SetWindowTextW(en,gw::wide(type.value("fontEN",std::string("system-ui"))).c_str());
        label(L"候选字号 (12–24)",346,24,20,140);edit(gw::wide(type.value("fontSize",Json(14)).dump()),453,160,342,100);
        label(L"序号字号 (8–20)",386,24,20,140);edit(gw::wide(type.value("indexSize",Json(11)).dump()),454,160,382,100);
        const auto &p=previewDark&&themeDraft.contains("dark")?themeDraft["dark"]:themeDraft["light"];auto v=p.value("visual",Json::object());
        label(L"形状、间距与透明度",434,24,20,420);
        const double defaults[]={8,8,100,100,100,25};
        for(int i=0;i<6;++i){int y=472+i*40;label(VisualLabels[i],y,24,20,195);edit(gw::wide(v.value(VisualKeys[i],Json(defaults[i])).dump()),460+i,220,y-4,120);}
        label(L"背景图片（规范化为 PNG）",726,24,20,420);button(L"选择图片…",420,20,758,130);button(L"移除图片",421,164,758,130);
        label(p.contains("imageData")?L"此配色已包含图片":L"此配色未设置图片",800,26,20,420);
        label(L"颜色（#RRGGBB）",846,24,20,420);
        for(int i=0;i<10;++i){int y=884+i*40;label(ColorLabels[i],y,24,20,135);wchar_t hex[10];swprintf(hex,10,L"#%06X",p.value(ColorKeys[i],0u));edit(hex,480+i,160,y-4,150);button(L"选色…",500+i,328,y-4,100);actions[500+i]=[this,i](int n){if(n!=BN_CLICKED)return;auto &p=themeDraft[previewDark?"dark":"light"];uint32_t rgb=p.value(ColorKeys[i],0u);static COLORREF custom[16]{};CHOOSECOLORW cc{};cc.lStructSize=sizeof(cc);cc.hwndOwner=window;cc.rgbResult=RGB(rgb>>16,(rgb>>8)&255,rgb&255);cc.lpCustColors=custom;cc.Flags=CC_FULLOPEN|CC_RGBINIT;
            if(ChooseColorW(&cc)){wchar_t s[10];swprintf(s,10,L"#%02X%02X%02X",GetRValue(cc.rgbResult),GetGValue(cc.rgbResult),GetBValue(cc.rgbResult));SetWindowTextW(get(480+i),s);readThemeControls();}};}
        label(L"",1300,88,20,420);SetWindowLongPtrW(controls.back(),GWLP_ID,430);
        actions[410]=[this](int n){if(n==BN_CLICKED&&leaveTheme()){themeEditing=false;buildPage();}};
        actions[411]=[this](int n){if(n==BN_CLICKED)saveTheme();};
        actions[412]=[this](int n){if(n!=BN_CLICKED||themeBusy)return;readThemeControls();if(!themeError.empty())throw std::runtime_error(gw::utf8(themeError));auto path=pickFile(window,true,L"Gogaku 主题 (*.gogakutheme)\0*.gogakutheme\0\0",L"gogakutheme");if(!path)return;auto t=themeDraft;themeBusy=true;status(L"正在后台导出当前草稿…");job("export",[path,t](){gw::exportTheme(*path,t);return Json::object();});};
        actions[413]=[this](int n){if(n!=CBN_SELCHANGE)return;readThemeControls();bool wanted=SendMessageW(get(413),CB_GETCURSEL,0,0)==1;if(wanted&&!themeDraft.contains("dark")){SendMessageW(get(413),CB_SETCURSEL,0,0);status(L"请先增加深色配色。");return;}if(!themeError.empty())throw std::runtime_error(gw::utf8(themeError));previewDark=wanted;buildPage();};
        actions[414]=[this](int n){if(n!=BN_CLICKED)return;readThemeControls();if(!themeError.empty())throw std::runtime_error(gw::utf8(themeError));if(themeDraft.contains("dark")){if(previewDark)themeDraft["light"]=themeDraft["dark"];themeDraft.erase("dark");previewDark=false;}else themeDraft["dark"]=themeDraft["light"];themeTouched=true;buildPage();};
        actions[420]=[this](int n){if(n!=BN_CLICKED||themeBusy)return;auto path=pickFile(window,false,L"图片 (*.png;*.jpg;*.jpeg;*.webp)\0*.png;*.jpg;*.jpeg;*.webp\0\0",L"png");if(!path)return;themeBusy=true;auto appearance=previewDark?"dark":"light";status(L"正在后台实际解码并规范化图片…");job("image",[path,appearance](){auto value=gw::normalizeImage(*path);value["appearance"]=appearance;return value;});};
        actions[421]=[this](int n){if(n!=BN_CLICKED)return;themeDraft[previewDark?"dark":"light"].erase("imageData");themeTouched=true;buildPage();};
        for(int id:{450,451,452,453,454,460,461,462,463,464,465,480,481,482,483,484,485,486,487,488,489})actions[id]=[this](int n){if(n==EN_CHANGE||n==CBN_EDITCHANGE||n==CBN_SELCHANGE){themeTouched=true;debounce();}};
    }
    ShowWindow(preview,SW_SHOW);refreshPreview();
}
void App::openTheme(Json theme,bool fresh){if(themeBusy)return;if(fresh)theme["id"]=uuid();themeDraft=theme;themeOriginal=fresh?Json::object():theme;themeEditing=true;themeTouched=fresh;previewDark=false;themeError.clear();buildPage();}
void App::readThemeControls(){if(!themeEditing||!get(450))return;
    try{auto next=themeDraft;next["name"]=gw::utf8(content(get(450)));auto &t=next["typography"];t["fontCN"]=gw::utf8(content(get(451)));t["fontEN"]=gw::utf8(content(get(452)));
        auto numeric=[&](int id){auto s=trim(content(get(id)));size_t read=0;double value=std::stod(s,&read);if(read!=s.size()||!std::isfinite(value))throw std::runtime_error("数值输入无效");return value;};
        t["fontSize"]=numeric(453);t["indexSize"]=numeric(454);auto &p=next[previewDark?"dark":"light"];for(int i=0;i<6;++i)p["visual"][VisualKeys[i]]=numeric(460+i);
        for(int i=0;i<10;++i){auto s=trim(content(get(480+i)));if(s.size()!=7||s[0]!=L'#'||!std::all_of(s.begin()+1,s.end(),[](wchar_t c){return iswxdigit(c)!=0;}))throw std::runtime_error("颜色必须为 #RRGGBB");p[ColorKeys[i]]=std::stoul(s.substr(1),nullptr,16);}
        // Images were actually decoded at import/selection. Avoid repeatedly
        // normalizing megabytes while typing a font or color value.
        auto withoutImages=next;for(const char *key:{"light","dark"})if(withoutImages.contains(key))withoutImages[key].erase("imageData");gw::validateTheme(withoutImages);
        themeDraft=next;themeError.clear();SetWindowTextW(get(430),L"");refreshPreview();
    }catch(const std::exception &e){themeError=message(e);SetWindowTextW(get(430),(L"草稿未保存："+themeError).c_str());}
}
void App::refreshPreview(){if(currentPage!=3)return;try{auto theme=themeEditing?themeDraft:themeList.at(size_t(themeIndex));if(!renderer)renderer=std::make_unique<gw::CandidateRenderer>();renderer->render(gw::candidatePreview(),theme,previewDark,settings.value("candidateFontSize",14),dpi);InvalidateRect(preview,nullptr,TRUE);
        const auto &p=previewDark&&theme.contains("dark")?theme["dark"]:theme["light"];auto luminance=[](uint32_t rgb){double sum=0;double weights[]={.2126,.7152,.0722};for(int i=0;i<3;++i){double c=double((rgb>>(16-i*8))&255)/255;sum+=weights[i]*(c<=.04045?c/12.92:std::pow((c+.055)/1.055,2.4));}return sum;};
        double a=luminance(p.value("background",0u)),b=luminance(p.value("text",0u));double contrast=(std::max(a,b)+.05)/(std::min(a,b)+.05);std::wstring warning=contrast<4.5?L"提示：候选文字与纯色背景对比度低于 4.5:1。":L"";
        auto visual=p.value("visual",Json::object());if(p.contains("imageData")||visual.value("opacity",100.0)<100||visual.value("bgOpacity",100.0)<100)warning+=L" 透明／图片背景请检查实际可读性。";
        if(themeEditing&&get(430)&&themeError.empty())SetWindowTextW(get(430),warning.c_str());
    }catch(const std::exception &e){themeError=message(e);status(L"预览失败："+themeError,true);}}
bool App::leaveTheme(){if(themeBusy){status(L"文件操作尚未完成，请稍后。",true);return false;}if(!themeEditing)return true;readThemeControls();if(!themeTouched&&themeDraft==themeOriginal)return true;
    int answer=MessageBoxW(window,L"主题草稿尚未保存。是：保存；否：丢弃；取消：继续编辑。",L"未保存的主题",MB_YESNOCANCEL|MB_ICONWARNING);
    if(answer==IDCANCEL)return false;if(answer==IDNO){themeTouched=false;return true;}saveTheme();return !themeEditing;
}
void App::saveTheme(){if(themeBusy)return;readThemeControls();if(!themeError.empty())throw std::runtime_error(gw::utf8(themeError));auto value=themeDraft,original=themeOriginal;
    gw::validateTheme(value);if(mutate([value,original](Json &latest){auto &all=latest["userCandidateThemes"];if(!all.is_array())all=Json::array();for(auto &t:all)if(t.value("id",std::string())==value.value("id",std::string())){if(!original.empty()&&t!=original)throw std::runtime_error("此主题已被其他设置窗口修改；未覆盖磁盘内容。");t=value;return;}if(!original.empty())throw std::runtime_error("此主题已被删除；请复制为新主题后保存。");all.push_back(value);})){
        themeOriginal=value;themeTouched=false;themeEditing=false;fillThemes();for(size_t i=0;i<themeList.size();++i)if(themeList[i]["id"]==value["id"])themeIndex=int(i);buildPage();status(L"主题已保存（未自动应用）");}
}

std::wstring shortcutText(const Json &binding){if(binding.value("disabled",false))return L"已禁用";auto key=gw::wide(binding.value("key",std::string()));if(key.empty())return L"未设置";auto modifiers=binding.value("modifiers",0u);std::wstring value;
    if(modifiers&Control)value+=L"Ctrl+";if(modifiers&Alt)value+=L"Alt+";if(modifiers&Shift)value+=L"Shift+";if(modifiers&Windows)value+=L"Win+";
    std::transform(key.begin(),key.end(),key.begin(),::towupper);return value+key;
}
const char *ShortcutKeys[]={"modeShortcut","directionShortcut"};
const wchar_t *ShortcutNames[]={L"普通／学习",L"学习方向"};
void App::shortcutPage(){label(L"快捷键",18);edit(L"",601,20,58,320);combo(602,{L"全部",L"我修改的",L"冲突"},0,360,58,160);edit(L"",603,540,58,260);
    label(L"搜索命令",92,22,20,300);label(L"按键文字过滤",92,22,540,260);
    list(600,126,180,{{L"命令",210},{L"按键",350},{L"状态",250}});button(L"录制",604,20,326);button(L"禁用",605,144,326);button(L"恢复默认",606,268,326,130);
    auto capture=edit(L"选择命令后点击“录制”；Esc 取消，Delete 禁用",607,20,372,800,32,ES_READONLY);SetWindowSubclass(capture,captureProc,1,reinterpret_cast<DWORD_PTR>(this));
    label(L"固定操作（仅检查 Gogaku 内部冲突，不检测系统或其他应用）",430,28);
    list(608,468,280,{{L"操作",300},{L"按键",260},{L"适用状态",250}});
    const std::vector<std::vector<std::wstring>> fixed={{L"取消组合",L"Esc",L"普通＋学习"},{L"原文上屏",L"Ctrl+Enter",L"学习"},{L"行首／行尾",L"Ctrl+A / Ctrl+E",L"普通"},{L"光标后退／前进",L"Ctrl+B / Ctrl+F",L"普通"},{L"下一／上一候选",L"Ctrl+N / Ctrl+P",L"普通"},{L"删除个人学习词",L"Ctrl+Backspace",L"普通"},{L"上一／下一页",L"Page Up / Page Down / , / .",L"有候选时"},{L"选择编号",L"1–9；Alt+1–9（学习）",L"按模式"},{L"临时中英文",L"单击 Shift",L"普通＋学习"}};
    for(size_t i=0;i<fixed.size();++i)row(get(608),int(i),fixed[i]);
    actions[601]=actions[603]=[this](int n){if(n==EN_CHANGE)fillShortcuts();};actions[602]=[this](int n){if(n==CBN_SELCHANGE)fillShortcuts();};
    actions[604]=[this](int n){int i=selection(600);if(n!=BN_CLICKED||i<0)return;recording=visibleShortcuts[size_t(i)];conflicts.erase(recording);conflictDraft.erase(recording);SetWindowTextW(get(607),L"请按快捷键（Ctrl / Alt / Shift / Win + 键）；Esc 取消，Delete 禁用");SetFocus(get(607));};
    actions[605]=[this](int n){int i=selection(600);if(n==BN_CLICKED&&i>=0)applyShortcut(visibleShortcuts[size_t(i)],{{"key",""},{"modifiers",0},{"disabled",true}});};
    actions[606]=[this](int n){int i=selection(600);if(n==BN_CLICKED&&i>=0){int target=visibleShortcuts[size_t(i)];applyShortcut(target,{{"key",target?"j":"k"},{"modifiers",Control|Shift}});}};fillShortcuts();
}
void App::fillShortcuts(){if(!get(600))return;ListView_DeleteAllItems(get(600));visibleShortcuts.clear();auto query=lower(content(get(601))),keys=lower(content(get(603)));int filter=int(SendMessageW(get(602),CB_GETCURSEL,0,0));
    for(int i=0;i<2;++i){auto binding=settings.value(ShortcutKeys[i],Json::object());auto display=shortcutText(conflictDraft.count(i)?conflictDraft[i]:binding);auto state=conflicts.count(i)?L"冲突，未写入："+conflicts[i]:L"";Json defaults={{"key",i?"j":"k"},{"modifiers",Control|Shift}};
        if(!query.empty()&&lower(ShortcutNames[i]).find(query)==std::wstring::npos)continue;if(!keys.empty()&&lower(display).find(keys)==std::wstring::npos)continue;if(filter==1&&binding==defaults)continue;if(filter==2&&!conflicts.count(i))continue;
        visibleShortcuts.push_back(i);row(get(600),int(visibleShortcuts.size()-1),{ShortcutNames[i],display,state});}
}
void App::applyShortcut(int target,const Json &binding){
    auto key=binding.value("key",std::string());auto modifiers=binding.value("modifiers",0u);std::wstring conflict;
    if(!binding.value("disabled",false)){
        auto other=settings.value(ShortcutKeys[1-target],Json::object());if(!other.value("disabled",false)&&other.value("key",std::string())==key&&other.value("modifiers",0u)==modifiers)conflict=ShortcutNames[1-target];
        const std::set<std::string> controlKeys={"a","b","e","f","n","p","backspace","return"};
        if(modifiers==Control&&controlKeys.count(key))conflict=L"固定输入操作";
        if(modifiers==Alt&&key.size()==1&&key[0]>='1'&&key[0]<='9')conflict=L"学习候选选择";
        if(modifiers==Shift&&key.size()==1&&key[0]>='A'&&key[0]<='Z')conflict=L"大写字母输入";
        if(!modifiers)conflict=L"必须包含修饰键（当前输入匹配合同）";
    }
    if(!conflict.empty()){conflicts[target]=conflict;conflictDraft[target]=binding;status(L"快捷键冲突，保留最后有效绑定。",true);fillShortcuts();return;}
    if(patch({{ShortcutKeys[target],binding}})){conflicts.erase(target);conflictDraft.erase(target);recording=-1;SetWindowTextW(get(607),L"快捷键已保存");fillShortcuts();}
}
void App::recordKey(WPARAM vk){if(recording<0)return;unsigned modifiers=0;if(GetKeyState(VK_SHIFT)&0x8000)modifiers|=Shift;if(GetKeyState(VK_CONTROL)&0x8000)modifiers|=Control;if(GetKeyState(VK_MENU)&0x8000)modifiers|=Alt;if((GetKeyState(VK_LWIN)|GetKeyState(VK_RWIN))&0x8000)modifiers|=Windows;
    if(vk==VK_SHIFT||vk==VK_CONTROL||vk==VK_MENU||vk==VK_LWIN||vk==VK_RWIN)return;
    if(vk==VK_ESCAPE&&!modifiers){recording=-1;SetWindowTextW(get(607),L"已取消录制");return;}
    if((vk==VK_DELETE||vk==VK_BACK)&&!modifiers){int target=recording;recording=-1;applyShortcut(target,{{"key",""},{"modifiers",0},{"disabled",true}});return;}
    std::string key;if(vk>='A'&&vk<='Z')key=char('a'+vk-'A');else if(vk>='0'&&vk<='9')key=char(vk);else if(vk>=VK_F1&&vk<=VK_F19)key="f"+std::to_string(vk-VK_F1+1);
    else {const std::map<WPARAM,std::string> special={{VK_RETURN,"return"},{VK_SPACE,"space"},{VK_TAB,"tab"},{VK_BACK,"backspace"},{VK_DELETE,"forwarddelete"},{VK_HOME,"home"},{VK_END,"end"},{VK_PRIOR,"pageup"},{VK_NEXT,"pagedown"},{VK_LEFT,"left"},{VK_RIGHT,"right"},{VK_UP,"up"},{VK_DOWN,"down"},{VK_ESCAPE,"esc"}};auto it=special.find(vk);if(it!=special.end())key=it->second;
        else if(vk>=VK_OEM_1&&vk<=VK_OEM_8){BYTE state[256]{};wchar_t chars[4]{};if(ToUnicodeEx(UINT(vk),MapVirtualKeyW(UINT(vk),MAPVK_VK_TO_VSC),state,chars,4,4,GetKeyboardLayout(0))==1)key=gw::utf8(std::wstring(chars,1));}}
    if(key.empty()){SetWindowTextW(get(607),L"不支持此键，请重试。");return;}int target=recording;recording=-1;applyShortcut(target,{{"key",key},{"modifiers",modifiers}});
}

void App::privacyPage(){label(L"学习与隐私",18);bindBool(L"保存学习记录偏好",700,58,"recording");label(L"真实学习记录采集仍关闭：保存此偏好不会解除宿主安全验收门禁。普通输入不采集。",100,56);
    label(L"忽略词（空白或换行分隔）",174);std::wstring ignored;for(const auto &s:settings.value("ignoredWords",Json::array()))if(s.is_string()){if(!ignored.empty())ignored+=L"\r\n";ignored+=gw::wide(s.get<std::string>());}edit(ignored,701,20,204,800,130,ES_MULTILINE|ES_AUTOVSCROLL|ES_WANTRETURN|WS_VSCROLL);
    actions[701]=[this](int n){if(n==EN_CHANGE)debounce();else if(n==EN_KILLFOCUS)flushText();};
    label(L"排除应用",378);edit(L"",240,20,410,430);button(L"选择 .exe…",242,470,410,120);button(L"输入包身份…",243,604,410,140);
    list(241,454,260,{{L"应用",220},{L"路径／包身份",570}});button(L"移除排除",244,20,730,140);
    actions[240]=[this](int n){if(n==EN_CHANGE)fillApps();};actions[242]=[this](int n){if(n==BN_CLICKED)addApp(true);};actions[243]=[this](int n){if(n==BN_CLICKED)addApp(false);};actions[244]=[this](int n){if(n==BN_CLICKED)removeApp();};fillApps();
}
void App::recordsPage(){label(L"学习片段",18);label(L"真实采集仍关闭；只读取已有、未过期的真实记录，不生成示例数据。",58,50);
    button(L"刷新",801,20,120);button(L"查看全文",802,144,120,130);button(L"删除片段…",803,288,120,140);button(L"排除误报",804,442,120,130);
    list(800,170,350,{{L"源表达",300},{L"目标表达",300},{L"方向／来源",210}});label(L"",540,90);SetWindowLongPtrW(controls.back(),GWLP_ID,805);
    actions[801]=[this](int n){if(n==BN_CLICKED)loadRecords();};
    actions[802]=[this](int n){int i=selection(800);if(n!=BN_CLICKED||i<0||size_t(i)>=records.size())return;const auto &r=records[size_t(i)];Form form{instance,window,nullptr,nullptr,font,L"学习片段（现有记录）",{{L"源表达",gw::wide(r.value("source",std::string())),true},{L"目标表达",gw::wide(r.value("target",std::string())),true}}};form.validate=[](auto &){};form.run();};
    for(int id:{803,804})actions[id]=[this,id](int n){int i=selection(800);if(n!=BN_CLICKED||i<0||size_t(i)>=records.size())return;if(id==803&&MessageBoxW(window,L"删除此真实片段并写入删除门禁？",L"删除片段",MB_YESNO|MB_ICONWARNING)!=IDYES)return;auto key=records[size_t(i)].value("id",std::string());job("records-update",[key,id](){Records store;store.update(key,id==804);return Json::object();});};loadRecords();
}
void App::loadRecords(){if(get(801))EnableWindow(get(801),FALSE);if(get(805))SetWindowTextW(get(805),L"正在后台读取真实存储…");job("records",[]{Records store;return store.list();});}
void App::flushText(){KillTimer(window,2);if(currentPage==3&&themeEditing){readThemeControls();return;}if(currentPage==5&&get(701)){std::wistringstream input(content(get(701)));std::wstring token;std::set<std::string> words;while(input>>token){if(token.size()>128)throw std::runtime_error("忽略词不能超过 128 字符");words.insert(gw::utf8(lower(token)));}Json list=Json::array();for(const auto &s:words)list.push_back(s);if(list!=settings.value("ignoredWords",Json::array()))patch({{"ignoredWords",list}});}}
void App::buildPage(){
    building=true;recording=-1;KillTimer(window,2);for(auto h:controls)DestroyWindow(h);controls.clear();placements.clear();listColumns.clear();actions.clear();contentHeight=0;scroll=0;ShowWindow(preview,SW_HIDE);
    try{switch(currentPage){case 0:learningPage();break;case 1:normalPage();break;case 2:wordPage();break;case 3:skinPage();break;case 4:shortcutPage();break;case 5:privacyPage();break;case 6:recordsPage();break;}}catch(const std::exception &e){fail(e);}
    building=false;layout();InvalidateRect(pageWindow,nullptr,TRUE);
}
// Keep geometry separate from page data/actions. Reflow never rebuilds controls,
// so resizing and monitor changes retain text, selections and pending drafts.
void App::reflowControls(){
    RECT client{};GetClientRect(pageWindow,&client);
    int available=std::max(1,MulDiv(client.right,96,int(dpi))-40);
    auto sorted=placements;std::stable_sort(sorted.begin(),sorted.end(),[](const Placement &a,const Placement &b){return a.y==b.y?a.x<b.x:a.y<b.y;});
    HDC dc=GetDC(pageWindow);int extraHeight=0;contentHeight=0;
    auto visibleHeight=[](const Placement &p){return p.kind==L"COMBOBOX"?28:p.height;};
    auto textWidth=[&](const Placement &p){auto old=SelectObject(dc,p.auxiliary?helperFont:font);SIZE size{};auto text=content(p.window);GetTextExtentPoint32W(dc,text.c_str(),int(text.size()),&size);SelectObject(dc,old);return (size.cx*96+int(dpi)-1)/int(dpi);};
    for(size_t start=0;start<sorted.size();){
        int top=sorted[start].y,bottom=top+visibleHeight(sorted[start]);size_t end=start+1;
        while(end<sorted.size()&&sorted[end].y<bottom){bottom=std::max(bottom,sorted[end].y+visibleHeight(sorted[end]));++end;}
        std::vector<Placement> row(sorted.begin()+ptrdiff_t(start),sorted.begin()+ptrdiff_t(end));
        std::stable_sort(row.begin(),row.end(),[](const auto &a,const auto &b){return a.x<b.x;});
        std::vector<int> widths,minimum;int preferred=0,capacity=0;
        for(const auto &p:row){
            int low=p.width;
            if(p.kind==L"EDIT"||p.kind==L"COMBOBOX")low=std::min(p.width,p.kind==L"EDIT"?120:160);
            else if(p.kind==TRACKBAR_CLASSW)low=160;
            else if(p.kind==WC_LISTVIEWW||p.kind==L"LISTBOX")low=120;
            else if(p.kind==L"STATIC")low=p.width>=260?120:textWidth(p);
            else if(p.kind==L"BUTTON")low=textWidth(p)+((GetWindowLongPtrW(p.window,GWL_STYLE)&BS_TYPEMASK)==BS_AUTOCHECKBOX?32:28);
            low=std::clamp(low,1,available);int ideal=std::min(available,std::max(low,p.width));
            minimum.push_back(low);widths.push_back(ideal);preferred+=ideal;capacity+=ideal-low;
        }
        int gaps=int(row.size()-1)*12;
        int shrink=std::min(capacity,std::max(0,preferred+gaps-available));
        for(size_t i=0;i<row.size();++i){int room=widths[i]-minimum[i];int take=capacity?int((int64_t(shrink)*room+capacity-1)/capacity):0;take=std::min(take,room);widths[i]-=take;shrink-=take;capacity-=room;}
        if(row.size()==1&&(row[0].width>=260||row[0].kind==WC_LISTVIEWW||row[0].kind==L"LISTBOX"))widths[0]=available;
        int x=20,y=top-40+extraHeight,lineHeight=0,rowBottom=y;
        for(size_t i=0;i<row.size();++i){const auto &p=row[i];int width=widths[i],height=visibleHeight(p);
            if(x>20&&x+width>available+20){y+=lineHeight+12;x=20;lineHeight=0;}
            if(p.kind==L"STATIC"){
                auto old=SelectObject(dc,p.auxiliary?helperFont:font);RECT textRect{0,0,px(width),0};auto text=content(p.window);
                DrawTextW(dc,text.c_str(),int(text.size()),&textRect,DT_CALCRECT|DT_WORDBREAK|DT_NOPREFIX);SelectObject(dc,old);
                height=std::max(height,(int(textRect.bottom)*96+int(dpi)-1)/int(dpi)+2);
            }
            int offset=p.y-top;int actualHeight=p.kind==L"COMBOBOX"?p.height:height;
            MoveWindow(p.window,px(x),px(y+offset)-scroll,px(width),px(actualHeight),TRUE);
            if(auto columns=listColumns.find(p.window);columns!=listColumns.end()){
                RECT bounds{};GetClientRect(p.window,&bounds);int total=0;for(int value:columns->second)total+=value;
                // Reserve a scrollbar even when the current list has few rows.
                int usable=std::max(1,int(bounds.right)-GetSystemMetricsForDpi(SM_CXVSCROLL,dpi)-px(4)),used=0;
                for(size_t c=0;c<columns->second.size();++c){int size=c+1==columns->second.size()?usable-used:MulDiv(usable,columns->second[c],total);ListView_SetColumnWidth(p.window,int(c),size);used+=size;}
            }
            lineHeight=std::max(lineHeight,offset+height);rowBottom=std::max(rowBottom,y+offset+height);x+=width+12;
        }
        extraHeight+=rowBottom-(top-40+extraHeight)-(bottom-top);
        contentHeight=std::max(contentHeight,rowBottom+24);start=end;
    }
    ReleaseDC(pageWindow,dc);
}
void App::setScroll(int position){
    SCROLLINFO info{};info.cbSize=sizeof(info);info.fMask=SIF_RANGE|SIF_PAGE;GetScrollInfo(pageWindow,SB_VERT,&info);
    position=std::clamp(position,0,std::max(0,info.nMax-int(info.nPage)+1));int delta=scroll-position;scroll=position;
    if(delta)ScrollWindowEx(pageWindow,0,delta,nullptr,nullptr,nullptr,nullptr,SW_SCROLLCHILDREN|SW_INVALIDATE|SW_ERASE);
    SetScrollPos(pageWindow,SB_VERT,position,TRUE);
}
void App::setDpi(UINT next){
    if(!next)next=96;UINT previousDpi=dpi;dpi=next;scroll=MulDiv(scroll,int(dpi),int(previousDpi));
    auto oldFont=font,oldTitle=titleFont,oldHelper=helperFont;font=uiFont(dpi,15);titleFont=uiFont(dpi,22,FW_SEMIBOLD);helperFont=uiFont(dpi,13);
    for(const auto &p:placements)SendMessageW(p.window,WM_SETFONT,reinterpret_cast<WPARAM>(p.auxiliary?helperFont:font),TRUE);
    for(auto h:{nav,retry,GetDlgItem(window,12)})if(h)SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(font),TRUE);
    for(auto h:{heading,brand})if(h)SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(titleFont),TRUE);
    for(auto h:{footer,versionLabel})if(h)SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(helperFont),TRUE);
    if(nav)SendMessageW(nav,LB_SETITEMHEIGHT,0,px(44));
    if(oldFont)DeleteObject(oldFont);if(oldTitle)DeleteObject(oldTitle);if(oldHelper)DeleteObject(oldHelper);
    if(window){
        auto small=reinterpret_cast<HICON>(LoadImageW(instance,MAKEINTRESOURCEW(101),IMAGE_ICON,GetSystemMetricsForDpi(SM_CXSMICON,dpi),GetSystemMetricsForDpi(SM_CYSMICON,dpi),LR_SHARED));
        auto large=reinterpret_cast<HICON>(LoadImageW(instance,MAKEINTRESOURCEW(101),IMAGE_ICON,GetSystemMetricsForDpi(SM_CXICON,dpi),GetSystemMetricsForDpi(SM_CYICON,dpi),LR_SHARED));
        SendMessageW(window,WM_SETICON,ICON_SMALL,reinterpret_cast<LPARAM>(small));SendMessageW(window,WM_SETICON,ICON_BIG,reinterpret_cast<LPARAM>(large));
    }
    if(currentPage==1||currentPage==5){int selected=selection(241);fillApps();if(selected>=0)ListView_SetItemState(get(241),selected,LVIS_SELECTED|LVIS_FOCUSED,LVIS_SELECTED|LVIS_FOCUSED);}
    if(currentPage==3&&preview)refreshPreview();
}
void App::drawNavigation(const DRAWITEMSTRUCT &item){
    if(item.itemID==UINT(-1))return;auto dc=item.hDC;FillRect(dc,&item.rcItem,sideBrush);
    RECT row=item.rcItem;InflateRect(&row,-px(2),-px(3));bool selected=(item.itemState&ODS_SELECTED)!=0;
    if(selected){auto brush=CreateSolidBrush(RGB(214,237,225));auto oldBrush=SelectObject(dc,brush);auto oldPen=SelectObject(dc,GetStockObject(NULL_PEN));RoundRect(dc,row.left,row.top,row.right,row.bottom,px(12),px(12));SelectObject(dc,oldPen);SelectObject(dc,oldBrush);DeleteObject(brush);}
    SetBkMode(dc,TRANSPARENT);SetTextColor(dc,selected?RGB(13,122,83):TextColor);auto old=SelectObject(dc,font);row.left+=px(14);
    DrawTextW(dc,PageNames[item.itemID],-1,&row,DT_SINGLELINE|DT_VCENTER|DT_NOPREFIX);SelectObject(dc,old);
    if((item.itemState&ODS_FOCUS)&&!(item.itemState&ODS_NOFOCUSRECT)){RECT focus=item.rcItem;InflateRect(&focus,-px(4),-px(5));DrawFocusRect(dc,&focus);}
}
void App::layout(){
    RECT client{};GetClientRect(window,&client);int width=client.right,height=client.bottom,sidebar=px(200),bottom=px(52),header=px(76);
    MoveWindow(brand,px(24),px(25),sidebar-px(40),px(34),TRUE);
    MoveWindow(nav,px(10),px(87),sidebar-px(20),std::max(px(7*44),height-px(205)),TRUE);
    MoveWindow(versionLabel,px(24),height-px(83),sidebar-px(40),px(22),TRUE);
    MoveWindow(GetDlgItem(window,12),px(20),height-px(52),sidebar-px(40),px(30),TRUE);
    MoveWindow(heading,sidebar+px(24),px(23),std::max(1,width-sidebar-px(48)),px(34),TRUE);
    MoveWindow(footer,sidebar+px(24),height-bottom+px(13),std::max(1,width-sidebar-px(152)),px(32),TRUE);
    MoveWindow(retry,width-px(112),height-bottom+px(10),px(88),px(30),TRUE);
    int bodyWidth=width-sidebar,pageWidth=bodyWidth;
    if(currentPage==3){int previewWidth=std::clamp(bodyWidth*46/100,px(280),px(460));pageWidth=std::max(px(240),bodyWidth-previewWidth-px(16));
        MoveWindow(preview,sidebar+pageWidth+px(16),header, std::max(1,bodyWidth-pageWidth-px(32)),std::max(1,height-header-bottom-px(16)),TRUE);}
    MoveWindow(pageWindow,sidebar,header,std::max(1,pageWidth),std::max(1,height-header-bottom),TRUE);
    reflowControls();RECT page{};GetClientRect(pageWindow,&page);SCROLLINFO si{};si.cbSize=sizeof(si);si.fMask=SIF_RANGE|SIF_PAGE|SIF_DISABLENOSCROLL;si.nMin=0;si.nMax=std::max(0,px(contentHeight)-1);si.nPage=UINT(page.bottom);SetScrollInfo(pageWindow,SB_VERT,&si,TRUE);setScroll(scroll);
    InvalidateRect(window,nullptr,TRUE);
}
LRESULT App::command(int id,int notification){if(building)return 0;
    try{if(id==10&&notification==LBN_SELCHANGE){int requested=int(SendMessageW(nav,LB_GETCURSEL,0,0));flushText();if(requested!=currentPage&&!leaveTheme()){SendMessageW(nav,LB_SETCURSEL,currentPage,0);return 0;}if(requested!=currentPage){themeEditing=false;currentPage=requested;buildPage();}return 0;}
        if(id==11){if(retryAction)retryAction();return 0;}if(id==12){gw::showUpdateWindow(window,instance);return 0;}
        auto it=actions.find(id);if(it!=actions.end())it->second(notification);
    }catch(const std::exception &e){fail(e);}return 0;
}
LRESULT App::notifyControl(NMHDR *header){if(building)return 0;try{
    if(header->idFrom==241&&header->code==LVN_ITEMCHANGED&&currentPage==1){auto change=reinterpret_cast<NMLISTVIEW *>(header);if((change->uChanged&LVIF_STATE)&&((change->uNewState^change->uOldState)&LVIS_STATEIMAGEMASK)&&change->iItem>=0)toggleApp(size_t(change->iItem));}
    if(header->idFrom==302&&header->code==NM_DBLCLK)editWord(false);
    if(header->idFrom==241&&header->code==NM_DBLCLK&&currentPage==1){int selected=selection(241);if(selected>=0)toggleApp(size_t(selected));}
    }catch(const std::exception &e){fail(e);}return 0;
}
LRESULT App::result(Result &r){
    if(r.type=="reload"){if(r.generation!=generation)return 0;if(!r.error.empty()){retryAction=[this](){notify();};status(r.error,true);}return 0;}
    if(r.type=="test"){if(currentPage==0){EnableWindow(get(105),TRUE);std::wstring result;
            if(!r.error.empty())result=L"连接测试失败："+r.error;else if(r.value.value("ok",false))result=L"连接成功 · "+std::to_wstring(int(r.value.value("milliseconds",0.0)))+L" ms";
            else {auto error=r.value.contains("error")&&r.value["error"].is_string()?gw::wide(r.value["error"].get<std::string>()):L"backend_error";result=L"最近测试失败："+error;}
            SetWindowTextW(get(107),result.c_str());auto usage=gw::readUsage();SetWindowTextW(get(106),(L"本机本月成功请求字符："+gw::wide(usage.value("month",gw::currentMonth()))+L"  "+std::to_wstring(usage.value("characters",uint64_t(0)))).c_str());}return 0;}
    if(r.type=="import"||r.type=="export"||r.type=="image")themeBusy=false;
    if(r.type=="records"){if(currentPage!=6)return 0;EnableWindow(get(801),TRUE);ListView_DeleteAllItems(get(800));records=Json::array();if(!r.error.empty()){SetWindowTextW(get(805),r.error.c_str());return 0;}records=r.value;
        for(size_t i=0;i<records.size();++i){const auto &v=records[i];row(get(800),int(i),{gw::wide(v.value("source",std::string())),gw::wide(v.value("target",std::string())),gw::wide(v.value("direction",std::string())+" / "+v.value("category",std::string()))});}
        SetWindowTextW(get(805),records.empty()?L"没有未过期的真实学习片段。":L"只显示现有未过期记录（最多 1000 条）；真实采集仍关闭。");return 0;}
    if(!r.error.empty()){status(L"失败："+r.error,true);return 0;}
    if(r.type=="import"){openTheme(r.value,true);status(L"已校验导入为新主题草稿；尚未保存或应用。");}
    else if(r.type=="export")status(L"主题包已导出");
    else if(r.type=="image"){auto appearance=r.value.value("appearance",std::string("light"));themeDraft[appearance]["imageData"]=r.value["imageData"];themeTouched=true;buildPage();status(L"图片已实际解码并规范化为 PNG；主题草稿尚未保存。");}
    else if(r.type=="clear")status(L"输入核心已确认清空调频");
    else if(r.type=="records-update"){status(L"真实片段已更新");if(currentPage==6)loadRecords();}
    return 0;
}
LRESULT CALLBACK App::pageProc(HWND h,UINT m,WPARAM w,LPARAM l){
    if(m==WM_NCCREATE)SetWindowLongPtrW(h,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW *>(l)->lpCreateParams));auto self=reinterpret_cast<App *>(GetWindowLongPtrW(h,GWLP_USERDATA));
    if(!self)return DefWindowProcW(h,m,w,l);
    if(m==WM_COMMAND||m==WM_NOTIFY||m==WM_HSCROLL||m==WM_CTLCOLORSTATIC||m==WM_CTLCOLORBTN||m==WM_CTLCOLORLISTBOX)return SendMessageW(self->window,m,w,l);
    if(m==WM_VSCROLL||m==WM_MOUSEWHEEL){SCROLLINFO info{};info.cbSize=sizeof(info);info.fMask=SIF_ALL;GetScrollInfo(h,SB_VERT,&info);int position=self->scroll;
        if(m==WM_MOUSEWHEEL)position-=GET_WHEEL_DELTA_WPARAM(w)*self->px(48)/WHEEL_DELTA;
        else switch(LOWORD(w)){case SB_LINEUP:position-=self->px(28);break;case SB_LINEDOWN:position+=self->px(28);break;case SB_PAGEUP:position-=int(info.nPage);break;case SB_PAGEDOWN:position+=int(info.nPage);break;case SB_THUMBTRACK:position=info.nTrackPos;break;default:return 0;}
        self->setScroll(position);return 0;}
    return DefWindowProcW(h,m,w,l);
}
LRESULT CALLBACK App::previewProc(HWND h,UINT m,WPARAM w,LPARAM l){if(m==WM_NCCREATE)SetWindowLongPtrW(h,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW *>(l)->lpCreateParams));auto self=reinterpret_cast<App *>(GetWindowLongPtrW(h,GWLP_USERDATA));
    if(m==WM_PAINT){PAINTSTRUCT paint{};auto dc=BeginPaint(h,&paint);RECT r{};GetClientRect(h,&r);FillRect(dc,&r,GetSysColorBrush(COLOR_WINDOW));if(self&&self->renderer){auto size=self->renderer->size();int margin=self->px(8),availableWidth=std::max(1,int(r.right)-2*margin),availableHeight=std::max(1,int(r.bottom)-2*margin);
            // Preserve the candidate's aspect ratio. Large theme typography can
            // exceed the reserved column; fit the complete nine-row preview.
            double scale=std::min({1.0,double(availableWidth)/std::max(1L,size.cx),double(availableHeight)/std::max(1L,size.cy)});
            int width=std::max(1,int(size.cx*scale)),height=std::max(1,int(size.cy*scale));
            if(scale==1.0)self->renderer->paint(dc,(r.right-width)/2,margin);
            else{BLENDFUNCTION blend{AC_SRC_OVER,0,self->renderer->opacity(),AC_SRC_ALPHA};AlphaBlend(dc,(r.right-width)/2,margin,width,height,self->renderer->dc(),0,0,size.cx,size.cy,blend);}}
        EndPaint(h,&paint);return 0;}return DefWindowProcW(h,m,w,l);}
LRESULT CALLBACK App::proc(HWND h,UINT m,WPARAM w,LPARAM l){if(m==WM_NCCREATE)SetWindowLongPtrW(h,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(reinterpret_cast<CREATESTRUCTW *>(l)->lpCreateParams));auto self=reinterpret_cast<App *>(GetWindowLongPtrW(h,GWLP_USERDATA));if(!self)return DefWindowProcW(h,m,w,l);
    try{switch(m){case WM_COMMAND:return self->command(LOWORD(w),HIWORD(w));case WM_NOTIFY:return self->notifyControl(reinterpret_cast<NMHDR *>(l));
        case gw::UpdateAvailableMessage:SetWindowTextW(GetDlgItem(h,12),w?L"检查更新 · 新版":L"检查更新");return 0;
        case WM_HSCROLL:if(reinterpret_cast<HWND>(l)==self->get(220)){int size=int(SendMessageW(self->get(220),TBM_GETPOS,0,0));SetWindowTextW(self->get(228),std::to_wstring(size).c_str());self->patch({{"candidateFontSize",size}});}return 0;
        case WM_TIMER:if(w==2)self->flushText();return 0;
        case WM_SIZE:if(self->nav)self->layout();return 0;
        case WM_DPICHANGED:{self->setDpi(HIWORD(w));auto r=reinterpret_cast<RECT *>(l);SetWindowPos(h,nullptr,r->left,r->top,r->right-r->left,r->bottom-r->top,SWP_NOZORDER|SWP_NOACTIVATE);self->layout();return 0;}
        case WM_GETMINMAXINFO:{auto info=reinterpret_cast<MINMAXINFO *>(l);info->ptMinTrackSize={self->px(820),self->px(560)};return 0;}
        case WM_MEASUREITEM:if(w==10){reinterpret_cast<MEASUREITEMSTRUCT *>(l)->itemHeight=self->px(44);return TRUE;}break;
        case WM_DRAWITEM:if(w==10){self->drawNavigation(*reinterpret_cast<DRAWITEMSTRUCT *>(l));return TRUE;}break;
        case WM_ERASEBKGND:{auto dc=reinterpret_cast<HDC>(w);RECT client{};GetClientRect(h,&client);FillRect(dc,&client,GetSysColorBrush(COLOR_WINDOW));RECT side=client;side.right=self->px(200);FillRect(dc,&side,self->sideBrush);
            auto pen=CreatePen(PS_SOLID,1,LineColor);auto old=SelectObject(dc,pen);MoveToEx(dc,side.right,0,nullptr);LineTo(dc,side.right,client.bottom);
            for(int y:{self->px(76),int(client.bottom)-self->px(52)}){MoveToEx(dc,side.right,y,nullptr);LineTo(dc,client.right,y);}
            SelectObject(dc,old);DeleteObject(pen);return TRUE;}
        case WM_CTLCOLORSTATIC:case WM_CTLCOLORBTN:case WM_CTLCOLORLISTBOX:{auto child=reinterpret_cast<HWND>(l);auto dc=reinterpret_cast<HDC>(w);bool side=child==self->brand||child==self->versionLabel||child==self->nav;
            SetBkMode(dc,TRANSPARENT);SetBkColor(dc,side?SideColor:GetSysColor(COLOR_WINDOW));SetTextColor(dc,TextColor);
            if(child==self->footer)SetTextColor(dc,GetWindowLongPtrW(child,GWLP_USERDATA)?RGB(184,48,48):MutedColor);
            else if(child==self->versionLabel)SetTextColor(dc,MutedColor);
            else for(const auto &p:self->placements)if(p.window==child&&p.auxiliary){SetTextColor(dc,MutedColor);break;}
            return reinterpret_cast<LRESULT>(side?self->sideBrush:GetSysColorBrush(COLOR_WINDOW));}
        case Completed:{std::unique_ptr<Result> result(reinterpret_cast<Result *>(l));return self->result(*result);}
        case WM_CLOSE:{self->flushText();if(!self->leaveTheme())return 0;self->closed=true;self->cancel=true;EnableWindow(h,FALSE);for(auto &job:self->jobs)if(job.joinable())job.join();MSG pending{};while(PeekMessageW(&pending,h,Completed,Completed,PM_REMOVE))delete reinterpret_cast<Result *>(pending.lParam);DestroyWindow(h);return 0;}
        case WM_DESTROY:PostQuitMessage(0);return 0;
    }}catch(const std::exception &e){self->fail(e);return 0;}return DefWindowProcW(h,m,w,l);
}
bool App::create(int show){
    dpi=GetDpiForSystem();if(!dpi)dpi=96;
    WNDCLASSW root{};root.lpfnWndProc=proc;root.hInstance=instance;root.hCursor=LoadCursorW(nullptr,IDC_ARROW);root.hIcon=LoadIconW(instance,MAKEINTRESOURCEW(101));root.hbrBackground=GetSysColorBrush(COLOR_WINDOW);root.lpszClassName=L"GogakuNativeSettings";RegisterClassW(&root);
    root.lpszClassName=L"GogakuSettingsPage";root.lpfnWndProc=pageProc;RegisterClassW(&root);root.lpszClassName=L"GogakuSettingsPreview";root.lpfnWndProc=previewProc;RegisterClassW(&root);
    window=CreateWindowExW(WS_EX_CONTROLPARENT,L"GogakuNativeSettings",L"Gogaku 设置",WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN,CW_USEDEFAULT,CW_USEDEFAULT,px(1000),px(700),nullptr,nullptr,instance,this);if(!window)return false;
    dpi=GetDpiForWindow(window);if(!dpi)dpi=96;setDpi(dpi);
    nav=add(L"LISTBOX",L"",LBS_NOTIFY|LBS_OWNERDRAWFIXED|LBS_HASSTRINGS|LBS_NOINTEGRALHEIGHT|WS_TABSTOP,10,87,180,400,10,window);
    for(const auto *s:PageNames)SendMessageW(nav,LB_ADDSTRING,0,reinterpret_cast<LPARAM>(s));SendMessageW(nav,LB_SETITEMHEIGHT,0,px(44));SendMessageW(nav,LB_SETCURSEL,0,0);
    brand=add(L"STATIC",L"Gogaku",0,24,25,160,34,14,window);
    heading=add(L"STATIC",PageNames[0],0,224,23,700,34,15,window);
    pageWindow=CreateWindowExW(WS_EX_CONTROLPARENT,L"GogakuSettingsPage",L"",WS_CHILD|WS_VISIBLE|WS_VSCROLL|WS_CLIPCHILDREN,0,0,1,1,window,nullptr,instance,this);
    preview=CreateWindowExW(0,L"GogakuSettingsPreview",L"九条候选布局预览",WS_CHILD,0,0,1,1,window,nullptr,instance,this);
    footer=add(L"STATIC",L"",0,224,650,600,32,13,window);retry=add(L"BUTTON",L"重试",BS_PUSHBUTTON|WS_TABSTOP,880,650,88,30,11,window);ShowWindow(retry,SW_HIDE);
    std::wstring version=L"版本未知";try{auto info=Json::parse(gw::readFile(gw::installRoot()/L"build-identity.json",1024*1024));version=gw::wide(info.value("fullVersion",std::string("?")))+L" b"+std::to_wstring(info.value("buildNumber",0));}catch(...){}
    versionLabel=add(L"STATIC",version,0,24,600,160,22,16,window);
    add(L"BUTTON",L"检查更新",BS_PUSHBUTTON|WS_TABSTOP,20,640,160,30,12,window);
    for(auto h:{brand,heading})SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(titleFont),TRUE);
    for(auto h:{footer,versionLabel})SendMessageW(h,WM_SETFONT,reinterpret_cast<WPARAM>(helperFont),TRUE);
    try{settings=gw::readSettings();buildPage();status(L"设置已载入");}catch(const std::exception &e){retryAction=[this](){settings=gw::readSettings();buildPage();status(L"设置已载入");};fail(e);}
    layout();gw::startUpdateController(window,instance);ShowWindow(window,show);UpdateWindow(window);return true;
}
} // namespace

int WINAPI wWinMain(HINSTANCE instance,HINSTANCE,PWSTR,int show){
    SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32|LOAD_LIBRARY_SEARCH_USER_DIRS);
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HRESULT apartment=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    INITCOMMONCONTROLSEX common{sizeof(common),ICC_STANDARD_CLASSES|ICC_WIN95_CLASSES|ICC_BAR_CLASSES};InitCommonControlsEx(&common);
    int code=0;{
        App app(instance);try{if(!app.create(show))code=2;else{MSG message{};while(GetMessageW(&message,nullptr,0,0)>0){if(!IsDialogMessageW(app.window,&message)){TranslateMessage(&message);DispatchMessageW(&message);}}}}catch(...){code=2;}
    }
    if(SUCCEEDED(apartment))CoUninitialize();return code;
}
