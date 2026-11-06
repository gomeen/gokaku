#include "platform.h"
#include "../GogakuCore/include/gogaku_core.h"
#include <sddl.h>
#include <shellapi.h>
#include <objbase.h>
#include <algorithm>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

namespace {
using gw::Json;
struct Core {
    HMODULE library = nullptr;
#define API(name) decltype(&::name) name = nullptr;
    API(gc_abi_check) API(gc_normal_session_create) API(gc_normal_session_destroy)
    API(gc_normal_handle) API(gc_normal_copy_raw) API(gc_normal_set_app_defaults)
    API(gc_normal_update) API(gc_normal_flush) API(gc_normal_reload_custom_words)
    API(gc_normal_clear_user_data) API(gc_snapshot_free)
    API(gc_learning_session_create) API(gc_learning_session_destroy)
    API(gc_learning_handle) API(gc_learning_snapshot_free)
#undef API
    GcNormalSession *normal = nullptr;
    Json settings;
    std::mutex mutex;
    uint64_t revision = 1, credentialsGeneration = 1;
    std::string active;
    bool preferencesDirty = false;
    bool load() {
        auto path = gw::installRoot()/L"bin"/L"x64"/L"libgogaku_core.dll";
        library = LoadLibraryExW(path.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!library) return false;
#define LOAD(name) name = reinterpret_cast<decltype(name)>(GetProcAddress(library,#name)); if (!name) return false;
        LOAD(gc_abi_check) LOAD(gc_normal_session_create) LOAD(gc_normal_session_destroy)
        LOAD(gc_normal_handle) LOAD(gc_normal_copy_raw) LOAD(gc_normal_set_app_defaults)
        LOAD(gc_normal_update) LOAD(gc_normal_flush) LOAD(gc_normal_reload_custom_words)
        LOAD(gc_normal_clear_user_data) LOAD(gc_snapshot_free)
        LOAD(gc_learning_session_create) LOAD(gc_learning_session_destroy)
        LOAD(gc_learning_handle) LOAD(gc_learning_snapshot_free)
#undef LOAD
        if (gc_abi_check(GOGAKU_CORE_ABI_VERSION)) return false;
        settings = gw::readSettings();
        std::string dict = gw::utf8((gw::installRoot()/L"data/sc.dict").wstring());
        std::string model = gw::utf8((gw::installRoot()/L"data/zh_CN.lm").wstring());
        std::string user = gw::utf8((gw::userRoot()/L"chinese").wstring());
        std::string custom = gw::utf8((gw::userRoot()/L"custom-words.tsv").wstring());
        std::string english = gw::utf8((gw::installRoot()/L"data/english-words.txt").wstring());
        std::string gloss = gw::utf8((gw::installRoot()/L"data/gloss.tsv").wstring());
        GcNormalConfig config{dict.c_str(),model.c_str(),user.c_str(),custom.c_str(),english.c_str(),gloss.c_str(),0,0,1,1,1};
        char error[256]{};
        if (gc_normal_session_create(&config,&normal,error,sizeof(error))) return false;
        applySettings(); return true;
    }
    uint32_t fuzzy() const {
        const char *names[] = {"z-zh","c-ch","s-sh","n-l","f-h","l-r","an-ang","en-eng","in-ing"};
        uint32_t mask=0;
        for (auto &name : settings.value("fuzzyPinyin",Json::array())) for (int i=0;i<9;++i) if (name == names[i]) mask |= 1u<<i;
        return mask;
    }
    void applySettings() {
        gc_normal_update(normal,settings.value("inputScheme",std::string())=="fullPinyin",fuzzy(),settings.value("fullPinyinPreedit",true),settings.value("frequencyEnabled",true),settings.value("englishCandidatesEnabled",true));
        std::vector<std::string> names;
        for (auto &entry:settings.value("appDefaultEnglish",Json::array())) {
            if (entry.is_string()) names.push_back(entry.get<std::string>());
            else if (entry.is_object() && entry.value("enabled",true)) names.push_back(entry.value("id",std::string()));
        }
        std::vector<const char *> pointers;
        for (auto &name:names) pointers.push_back(name.c_str());
        gc_normal_set_app_defaults(normal,pointers.data(),pointers.size());
    }
    std::string raw() {
        size_t size=gc_normal_copy_raw(normal,nullptr,0);
        if (!size || size>8192) return {};
        std::string text(size,'\0'); gc_normal_copy_raw(normal,text.data(),size); text.resize(size-1); return text;
    }
    Json normalEvent(int kind,const std::string &text={},const std::string &app={},const std::string &field={}) {
        GcKeyEvent event{}; event.kind=kind; event.text=text.c_str(); event.app=app.c_str(); event.field=field.c_str(); event.time_ms=(int64_t)GetTickCount64();
        GcSnapshot *s=nullptr;
        if (gc_normal_handle(normal,&event,&s) || !s) throw std::runtime_error("输入核心暂不可用");
        Json value={{"consumed",s->consumed==1},{"composing",s->composing==1},{"english",s->english},{"toast",s->toast},
           {"commit",s->commit?s->commit:""},{"marked",s->marked?s->marked:""},{"preedit",s->preedit?s->preedit:""},
           {"raw",raw()},{"selected",s->selected},{"page",s->page},{"pageCount",s->page_count},{"status",s->status?s->status:""},
           {"candidates",Json::array()},{"issues",Json::array()},{"learning",false},{"pending",false}};
        for (size_t i=0;i<s->count;++i) value["candidates"].push_back({{"text",s->candidates[i].text?s->candidates[i].text:""},{"gloss",s->candidates[i].gloss?s->candidates[i].gloss:""}});
        gc_snapshot_free(s); return value;
    }
};
Core core;
std::atomic<unsigned> clients{0}, workers{0};
std::atomic_bool stopping{false};
std::string str(const char *s) { return s?s:""; }
struct Task {
    Json request, result;
    std::atomic_bool cancel{false}, done{false};
};
struct Session {
    GcLearningSession *learning=nullptr;
    std::string id,app,field;
    std::map<std::string,std::string> drafts;
    Json currentPolicy=Json::object();
    uint64_t focus=0,commitId=0;
    Json view=Json::object(), stamp=Json::object(), sources=Json::array(), pending=Json::object();
    Json scheduled=Json::object();
    ULONGLONG scheduledAt=0;
    std::shared_ptr<Task> task;
    std::map<std::string,std::pair<ULONGLONG,Json>> cache;
    size_t cacheBytes=0;
    bool learningMode=false,englishDirect=false;
    int direction=0;
    ~Session() { if(task) task->cancel=true; if(learning) core.gc_learning_session_destroy(learning); }
    Json preference() const {
        return Json{{"mode",core.settings.value("preferredMode",std::string("normal"))},{"direction",core.settings.value("preferredDirection",std::string("zhToEn"))}};
    }
    std::string draftKey() const {return app+"\n"+field+"\n"+(learningMode?"learning":"normal")+"\n"+std::to_string(direction);}
    void stash(const std::string &raw) {if(!raw.empty()&&!field.empty()&&drafts.size()<64)drafts.emplace(draftKey(),raw);}
    Json policy() const {return Json{{"preference",preference()},{"enabled",core.settings.value("learningTranslationEnabled",false)},{"credentials",core.credentialsGeneration},{"ignored",core.settings.value("ignoredWords",Json::array())},{"excluded",core.settings.value("excludedApplications",Json::array())}};}
    void refreshPolicy() {if(!field.empty()&&policy()!=currentPolicy)focusTo({{"app",app},{"field",field}});}
    void resetLearning() {
        auto preferred=preference();
        learningMode=preferred.value("mode",std::string("normal"))=="learning" && core.settings.value("learningTranslationEnabled",false);
        direction=preferred.value("direction",std::string("zhToEn"))=="enToZh";
        auto excluded=core.settings.value("excludedApplications",Json::array());
        if(std::find(excluded.begin(),excluded.end(),Json(app))!=excluded.end())learningMode=false;
        currentPolicy=policy();
        ++focus;
        // A normal-input connection must not load a second dictionary/model.
        // Cold learning-session creation can exceed the bounded TSF RPC budget
        // and force every first-focus attempt to reconnect and start over.
        scheduled=Json::object();
        if(!learningMode)return;
        if (!learning) {
            auto dict=gw::utf8((gw::installRoot()/L"data/sc.dict").wstring()), model=gw::utf8((gw::installRoot()/L"data/zh_CN.lm").wstring());
            GcLearningConfig config{dict.c_str(),model.c_str()}; char error[256]{};
            if(core.gc_learning_session_create(&config,&learning,error,sizeof(error))) throw std::runtime_error("学习核心不可用");
        }
        GcLearningEvent ev{}; ev.kind=GC_LEV_CONFIGURE; ev.arg0=(int64_t)focus; ev.arg1=1; ev.arg2=direction;
        learn(ev);
    }
    Json learn(GcLearningEvent event) {
        GcLearningSnapshot *s=nullptr;
        if(core.gc_learning_handle(learning,&event,&s) || !s) throw std::runtime_error("学习核心暂不可用");
        stamp={{"focus",s->focus},{"epoch",s->epoch},{"revision",s->revision},{"mode",s->mode},{"direction",s->direction}};
        view={{"consumed",true},{"composing",!str(s->raw).empty()},{"english",englishDirect?1:0},{"toast",0},
          {"raw",str(s->raw)},{"preedit",str(s->preedit)},{"marked",""},{"status",str(s->status)},
          {"commit",str(s->commit_text)},{"selected",s->selected},{"page",s->page},{"pageCount",(s->total_candidates+8)/9},
          {"learning",true},{"pending",false},{"candidates",Json::array()},{"issues",Json::array()}};
        for(size_t i=0;i<s->candidate_count;++i) view["candidates"].push_back({{"text",str(s->candidates[i].target)},{"gloss",str(s->candidates[i].source)}});
        for(size_t i=0;i<s->issue_count;++i) view["issues"].push_back({{"location",s->issues[i].location},{"length",s->issues[i].length},{"explanation",str(s->issues[i].explanation)}});
        sources=Json::array();
        for(size_t i=0;i<s->source_count;++i) sources.push_back({{"sourceId",str(s->sources[i].id)},{"source",str(s->sources[i].text)}});
        if(s->translation_needed && s->translation_source_index>=0 && (size_t)s->translation_source_index<s->source_count) {
            scheduled=sources[(size_t)s->translation_source_index]; scheduled["stamp"]=stamp;
            scheduled["direction"]=direction; scheduled["raw"]=str(s->raw); scheduledAt=GetTickCount64()+180;
        }
        if(!str(s->commit_text).empty()) pending={{"raw",str(s->commit_recovery_raw)},{"learning",true}};
        core.gc_learning_snapshot_free(s);
        if(task && task->request.value("stamp",Json::object())!=stamp)task->cancel=true;
        return view;
    }
    void stampEvent(GcLearningEvent &ev,const Json &s) {
        ev.stamp_focus=s.value("focus",uint64_t(0)); ev.stamp_epoch=s.value("epoch",uint64_t(0)); ev.stamp_revision=s.value("revision",uint64_t(0));
        ev.stamp_mode=s.value("mode",1); ev.stamp_direction=s.value("direction",0);
    }
    void clearAsync() { if(task) task->cancel=true; scheduled=Json::object(); cache.clear(); cacheBytes=0; }
    void applyAsync() {
        if(task && task->done) {
            auto finished=task; task.reset();
            if(!finished->cancel && finished->request.value("stamp",Json::object())==stamp) {
                auto result=finished->result;
                GcLearningEvent ev{}; stampEvent(ev,finished->request["stamp"]);
                std::string sourceId=finished->request.value("sourceId",std::string()), source=finished->request.value("source",std::string());
                std::string target=result.value("target",std::string()), message="翻译失败，输入已保留；Ctrl+Enter 可原文上屏";
                ev.source_id=sourceId.c_str(); ev.source=source.c_str(); ev.resource="volcengine";
                if(result.value("ok",false)) { ev.kind=GC_LEV_RECEIVE; ev.target=target.c_str(); ev.approved=1; }
                else { ev.kind=GC_LEV_TRANSLATION_FAILED; ev.message=message.c_str(); }
                learn(ev);
                if(result.value("ok",false)) {
                    std::string key=std::to_string(direction)+":"+source;
                    if(cacheBytes+target.size()+source.size()>1024*1024) {cache.clear();cacheBytes=0;}
                    cache[key]={GetTickCount64(),result}; cacheBytes+=target.size()+source.size();
                }
                auto issues=result.value("spelling",Json::object()).value("issues",Json::array());
                std::vector<GcIssue> ranges; std::vector<std::string> explanations;
                for(auto &issue:issues) explanations.push_back(issue.value("explanation",std::string()));
                for(size_t i=0;i<issues.size();++i) ranges.push_back({issues[i].value("location",int64_t(0)),issues[i].value("length",int64_t(0)),explanations[i].data()});
                GcLearningEvent spelling{}; spelling.kind=GC_LEV_SET_ISSUES; stampEvent(spelling,stamp); spelling.issues=ranges.data(); spelling.issue_count=ranges.size();
                learn(spelling);
            }
        }
        if(!scheduled.empty() && scheduled["stamp"]!=stamp) scheduled=Json::object();
        if(!task && !scheduled.empty() && GetTickCount64()>=scheduledAt && workers.load()<8) {
            auto work=std::make_shared<Task>(); work->request=scheduled; scheduled=Json::object();
            auto key=std::to_string(direction)+":"+work->request.value("source",std::string());
            auto cached=cache.find(key);
            if(cached!=cache.end() && GetTickCount64()-cached->second.first<300000) { work->result=cached->second.second; work->done=true; task=work; return; }
            Json ignored=core.settings.value("ignoredWords",Json::array()); task=work; ++workers;
            std::thread([work,ignored]() {
                try {
                    if(!work->cancel) work->result=gw::translate(work->request.value("source",std::string()),work->request.value("direction",0),&work->cancel);
                    if(!work->cancel && work->request.value("direction",0)==1) work->result["spelling"]=gw::spell(work->request.value("raw",std::string()),ignored);
                } catch(...) { work->result={{"ok",false},{"error","backend"}}; }
                work->done=true; --workers;
            }).detach();
        }
        if(task || !scheduled.empty()) view["pending"]=true;
    }
    void focusTo(const Json &r) {
        stash(view.value("raw",std::string()));
        clearAsync(); pending=Json::object(); app=r.value("app",std::string()); field=r.value("field",std::string()); englishDirect=false;
        if(field.empty()) {
            // A delayed blur belongs to this connection only. Another host may
            // already own the shared normal session and be composing.
            if(core.active==id) {core.normalEvent(GC_EV_FOCUS_SYNC);core.active.clear();}
            ++focus; view=Json::object(); return;
        }
        core.active=id; view=core.normalEvent(GC_EV_FOCUS_SYNC,{},app,field);
        resetLearning();
        if(!learningMode) view=core.normalEvent(GC_EV_FOCUS_SYNC,{},app,field);
        else view["composing"]=false;
    }
    Json event(const Json &r) {
        applyAsync();
        int kind=r.value("kind",-1); std::string text=r.value("text",std::string()), command=r.value("command",std::string());
        if(command=="mode" || command=="direction") {
            if(!core.settings.value("learningTranslationEnabled",false) || gw::readCredentials().value("accessKeyId",std::string()).empty()) { view["status"]="请先在设置中配置并开启学习翻译"; view["consumed"]=true; return view; }
            auto preferred=preference();
            if(command=="mode") preferred["mode"]=learningMode?"normal":"learning";
            else preferred["direction"]=direction?"zhToEn":"enToZh";
            core.settings["preferredMode"]=preferred["mode"];core.settings["preferredDirection"]=preferred["direction"];
            core.preferencesDirty=true; ++core.revision; focusTo({{"app",app},{"field",field}}); view["consumed"]=true; return view;
        }
        if(command=="restore") {
            auto found=drafts.find(draftKey());if(found==drafts.end())return view;
            std::string restore=found->second;drafts.erase(found);
            if(learningMode) { GcLearningEvent ev{};ev.kind=GC_LEV_RESTORE;ev.text=restore.c_str();learn(ev); }
            else view=core.normalEvent(GC_EV_TEXT,restore);
            return view;
        }
        std::string recovery=view.value("raw",std::string());
        if(learningMode && !englishDirect) {
            GcLearningEvent ev{};
            if(command=="original" || (kind==GC_EV_SHIFT_CLICK && !recovery.empty())) ev.kind=GC_LEV_ORIGINAL;
            else if(command=="choose") { ev.kind=GC_LEV_CHOOSE; ev.arg0=r.value("index",0); }
            else switch(kind) {
            case GC_EV_TEXT: ev.kind=GC_LEV_TYPE;ev.text=text.c_str();break;
            case GC_EV_SPACE:
                if(direction) {ev.kind=GC_LEV_TYPE;ev.text=" ";} else {ev.kind=GC_LEV_CHOOSE;ev.arg0=view.value("selected",size_t(0))-view.value("page",size_t(0))*9;}
                break;
            case GC_EV_ENTER: ev.kind=GC_LEV_CHOOSE;ev.arg0=view.value("selected",size_t(0))-view.value("page",size_t(0))*9;break;
            case GC_EV_BACKSPACE:ev.kind=GC_LEV_BACKSPACE;break;
            case GC_EV_ESC:ev.kind=GC_LEV_CANCEL;clearAsync();break;
            case GC_EV_UP:case GC_EV_CTRL_P:ev.kind=GC_LEV_NAVIGATE;ev.arg0=-1;break;
            case GC_EV_DOWN:case GC_EV_CTRL_N:ev.kind=GC_LEV_NAVIGATE;ev.arg0=1;break;
            case GC_EV_PAGE_UP:ev.kind=GC_LEV_PAGE;ev.arg0=-1;break;
            case GC_EV_PAGE_DOWN:ev.kind=GC_LEV_PAGE;ev.arg0=1;break;
            case GC_EV_SHIFT_CLICK:englishDirect=true;view["english"]=1;view["toast"]=2;return view;
            default:view["consumed"]=false;return view;
            }
            learn(ev);
            if(kind==GC_EV_SHIFT_CLICK) { englishDirect=true;view["english"]=1;view["toast"]=2; }
        } else {
            if(learningMode && englishDirect) {
                if(kind==GC_EV_SHIFT_CLICK) {englishDirect=false;view["english"]=0;view["toast"]=1;view["consumed"]=true;}
                else view["consumed"]=false;
                return view;
            }
            if(command=="choose") {kind=GC_EV_TEXT;text=std::to_string(r.value("index",0)+1);}
            if(kind<GC_EV_TEXT || kind>GC_EV_COMMIT_CONFIRMED || kind==GC_EV_COMMIT_CONFIRMED || kind==GC_EV_FOCUS_SYNC) {view["consumed"]=false;return view;}
            view=core.normalEvent(kind,text);
            if(!view.value("commit",std::string()).empty()) pending={{"raw",recovery},{"learning",false}};
        }
        if(!view.value("commit",std::string()).empty()) { pending["token"]=std::to_string(++commitId);view["commitToken"]=pending["token"];clearAsync(); }
        return view;
    }
};
Json responseView(Session &s) { auto value=s.view;value["draftAvailable"]=s.drafts.count(s.draftKey())!=0;value["settingsRevision"]=core.revision;return value; }
void serve(HANDLE pipe) {
    ++clients;
    CoInitializeEx(nullptr,COINIT_MULTITHREADED);
    {
        Session session;
        session.id=std::to_string(GetTickCount64())+":"+std::to_string((uintptr_t)pipe);
        ULONG caller=0;GetNamedPipeClientProcessId(pipe,&caller);
        try {
            for(;;) {
                Json request;
                if(!gw::readMessage(pipe,request,120000)) break;
                Json response={{"v",gw::ProtocolVersion},{"id",request.value("id",uint64_t(0))},{"ok",true}};
                std::lock_guard<std::mutex> lock(core.mutex);
                try {
                    if(request.value("v",0u)!=gw::ProtocolVersion) throw std::runtime_error("管道协议不匹配");
                    std::string op=request.value("op",std::string());
                    if(op=="event" || ((op=="open"||op=="focus")&&!request.value("field",std::string()).empty())) {
                        DWORD foreground=0;GetWindowThreadProcessId(GetForegroundWindow(),&foreground);
                        if(!caller||foreground!=caller)throw std::runtime_error("目标不在前台");
                    }
                    if((op=="event"||op=="poll")&&core.active==session.id)session.refreshPolicy();
                    if(op=="hello") { if(request.value("abi",4)!=GOGAKU_CORE_ABI_VERSION) throw std::runtime_error("核心 ABI 不匹配"); }
                    else if(op=="open" || op=="focus") session.focusTo(request);
                    else if(op=="reload") {core.settings=gw::readSettings();core.applySettings();core.gc_normal_reload_custom_words(core.normal);++core.revision;}
                    else if(op=="clear") { if(core.gc_normal_clear_user_data(core.normal)) throw std::runtime_error("清空失败"); }
                    else if(op=="settings") response["settings"]=core.settings;
                    else if(op=="close") { if(core.active==session.id) {core.normalEvent(GC_EV_FOCUS_SYNC);core.active.clear();} break; }
                    else if(op=="event") {
                        if(core.active!=session.id) throw std::runtime_error("焦点已变化，请重新输入");
                        if(!session.pending.empty()) throw std::runtime_error("上次提交尚未确认");
                        session.event(request);
                    } else if(op=="poll") { if(core.active==session.id && session.learningMode) session.applyAsync(); }
                    else if(op=="confirm" || op=="reject") {
                        if(core.active!=session.id || session.pending.empty() || request.value("token",std::string())!=session.pending.value("token",std::string())) throw std::runtime_error("过期提交");
                        if(op=="confirm" && !session.pending.value("learning",false)) core.normalEvent(GC_EV_COMMIT_CONFIRMED);
                        if(op=="reject") session.stash(session.pending.value("raw",std::string()));
                        session.pending=Json::object();session.view["commit"]="";session.view["commitToken"]="";
                    } else throw std::runtime_error("未知命令");
                    response["view"]=responseView(session);
                } catch(const std::exception &e) {response["ok"]=false;response["error"]=e.what();}
                if(!gw::writeMessage(pipe,response,1000)) break;
            }
        } catch(...) {}
        std::lock_guard<std::mutex> lock(core.mutex);
        if(core.active==session.id) {try {core.normalEvent(GC_EV_FOCUS_SYNC);} catch(...) {} core.active.clear();}
    }
    DisconnectNamedPipe(pipe);CloseHandle(pipe);CoUninitialize();--clients;
}
LRESULT CALLBACK trayProcedure(HWND window,UINT message,WPARAM wParam,LPARAM lParam) {
    if(message!=WM_APP+40)return DefWindowProcW(window,message,wParam,lParam);
    if(lParam!=WM_RBUTTONUP&&lParam!=WM_LBUTTONDBLCLK)return 0;
    UINT selected=1;
    if(lParam==WM_RBUTTONUP){
        auto menu=CreatePopupMenu();
        AppendMenuW(menu,MF_STRING,1,L"Gogaku 设置…");
        AppendMenuW(menu,MF_STRING,2,L"切换普通／学习");
        AppendMenuW(menu,MF_STRING,3,L"切换学习方向");
        AppendMenuW(menu,MF_SEPARATOR,0,nullptr);
        AppendMenuW(menu,MF_STRING,4,L"退出输入代理");
        POINT point{};GetCursorPos(&point);SetForegroundWindow(window);
        selected=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_RIGHTBUTTON,point.x,point.y,0,window,nullptr);
        DestroyMenu(menu);PostMessageW(window,WM_NULL,0,0);
    }
    try {
        if(selected==1){
            auto path=gw::installRoot()/L"bin/x64/GogakuSettings.exe";
            std::wstring command=L"\""+path.wstring()+L"\"";
            STARTUPINFOW startup{sizeof(startup)};PROCESS_INFORMATION process{};
            if(CreateProcessW(path.c_str(),command.data(),nullptr,nullptr,FALSE,0,nullptr,path.parent_path().c_str(),&startup,&process)){CloseHandle(process.hThread);CloseHandle(process.hProcess);}
        }else if(selected==2||selected==3){
            bool configured=false;
            {
                std::lock_guard<std::mutex> lock(core.mutex);
                auto credentials=gw::readCredentials();
                configured=core.settings.value("learningTranslationEnabled",false)&&!credentials.value("accessKeyId",std::string()).empty()&&!credentials.value("secretAccessKey",std::string()).empty();
                if(configured){
                    auto value=Json{{"mode",core.settings.value("preferredMode",std::string("normal"))},{"direction",core.settings.value("preferredDirection",std::string("zhToEn"))}};
                    if(selected==2)value["mode"]=value.value("mode",std::string())=="learning"?"normal":"learning";
                    else value["direction"]=value.value("direction",std::string())=="enToZh"?"zhToEn":"enToZh";
                    core.settings["preferredMode"]=value["mode"];core.settings["preferredDirection"]=value["direction"];
                    core.preferencesDirty=true;++core.revision;
                }
            }
            if(!configured)MessageBoxW(window,L"请先在设置中保存火山凭据，并显式开启学习翻译。",L"Gogaku",MB_OK|MB_ICONINFORMATION);
        }else if(selected==4){
            Json settings;
            {std::lock_guard<std::mutex> lock(core.mutex);if(core.gc_normal_flush(core.normal))throw std::runtime_error("调频保存失败，请重试退出");settings=core.settings;}
            gw::saveSettings(settings);PostQuitMessage(0);
        }
    }catch(...){MessageBoxW(window,L"操作未完成，请检查设置或稍后重试。",L"Gogaku",MB_OK|MB_ICONWARNING);}
    return 0;
}
void runTray() {
    try {
        auto instance=GetModuleHandleW(nullptr);WNDCLASSW cls{};cls.hInstance=instance;cls.lpfnWndProc=trayProcedure;cls.lpszClassName=L"GogakuAgentTray";cls.hIcon=LoadIconW(instance,MAKEINTRESOURCEW(101));
        if(!RegisterClassW(&cls))return;
        auto window=CreateWindowExW(0,cls.lpszClassName,L"Gogaku",WS_POPUP,0,0,0,0,nullptr,nullptr,instance,nullptr);if(!window)return;
        NOTIFYICONDATAW icon{};icon.cbSize=sizeof(icon);icon.hWnd=window;icon.uID=1;icon.uFlags=NIF_ICON|NIF_MESSAGE|NIF_TIP;icon.uCallbackMessage=WM_APP+40;icon.hIcon=LoadIconW(instance,MAKEINTRESOURCEW(101));
        wcscpy_s(icon.szTip,gw::channel()=="dev"?L"Gogaku Dev 输入代理":L"Gogaku 输入代理");
        Shell_NotifyIconW(NIM_ADD,&icon);
        MSG message{};while(GetMessageW(&message,nullptr,0,0)>0){TranslateMessage(&message);DispatchMessageW(&message);}
        Shell_NotifyIconW(NIM_DELETE,&icon);DestroyWindow(window);ExitProcess(0);
    }catch(...){} // A tray failure does not interrupt active input.
}
int registration(const std::wstring &command) {
    auto path=gw::modulePath();
    std::wstring name=gw::channel()=="dev"?L"GogakuDevAgent":L"GogakuAgent";
    HKEY key=nullptr;
    if(command==L"--set-autostart on" || command==L"--set-autostart off" || command==L"--uninstall") {
        if(RegCreateKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",0,nullptr,0,KEY_SET_VALUE,nullptr,&key,nullptr)!=ERROR_SUCCESS) return 2;
        LONG status;
        if(command==L"--set-autostart on") {std::wstring value=L"\""+path.wstring()+L"\"";status=RegSetValueExW(key,name.c_str(),0,REG_SZ,(BYTE*)value.c_str(),(DWORD)((value.size()+1)*sizeof(wchar_t)));}
        else status=RegDeleteValueW(key,name.c_str());
        RegCloseKey(key);return status==ERROR_SUCCESS||status==ERROR_FILE_NOT_FOUND?0:2;
    }
    // --install 仅准备用户目录；不设置默认输入法，不擅自启用登录启动。
    if(command==L"--install") {gw::userRoot();return 0;}
    return -1;
}
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR args,int) {
    try {
        SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32|LOAD_LIBRARY_SEARCH_USER_DIRS);
        std::wstring command=args?args:L"";
        int registrationResult=registration(command);
        if(registrationResult>=0) return registrationResult;
        HANDLE mutex=CreateMutexW(nullptr,TRUE,(L"Local\\"+gw::pipeName().substr(9)+L"-mutex").c_str());
        if(!mutex || GetLastError()==ERROR_ALREADY_EXISTS) {if(mutex)CloseHandle(mutex);return 0;}
        if(!core.load()) {CloseHandle(mutex);return 2;}
        auto modified=[](const wchar_t *name){std::error_code error;auto value=gw::fs::last_write_time(gw::userRoot()/name,error);return error?gw::fs::file_time_type{}:value;};
        // The first watcher tick must not reapply the loaded Shuangpin profile
        // to an input that has already started.
        auto initialSettings=modified(L"settings.json"),initialCustom=modified(L"custom-words.tsv");
        std::thread(runTray).detach();
        std::thread([initialSettings,initialCustom] {
            ULONGLONG lastFlush=GetTickCount64();auto lastSettings=initialSettings,lastCustom=initialCustom;
            while(!stopping) {
                std::this_thread::sleep_for(std::chrono::milliseconds(500));
                try {
                    auto path=gw::userRoot()/L"settings.json",custom=gw::userRoot()/L"custom-words.tsv";
                    std::error_code ec;auto modified=gw::fs::last_write_time(path,ec);bool changed=!ec&&modified!=lastSettings;
                    std::error_code customEc;auto customTime=gw::fs::last_write_time(custom,customEc);bool customChanged=!customEc&&customTime!=lastCustom;
                    std::unique_lock<std::mutex> lock(core.mutex);
                    if(changed) {auto s=gw::readSettings();if(s!=core.settings){core.settings=s;core.applySettings();++core.revision;}lastSettings=modified;}
                    if(customChanged) {core.gc_normal_reload_custom_words(core.normal);lastCustom=customTime;++core.revision;}
                    if(GetTickCount64()-lastFlush>=30000) {core.gc_normal_flush(core.normal);lastFlush=GetTickCount64();}
                    if(core.preferencesDirty) {
                        auto mode=core.settings["preferredMode"],direction=core.settings["preferredDirection"];auto generation=core.revision;
                        lock.unlock();auto latest=gw::readSettings();latest["preferredMode"]=mode;latest["preferredDirection"]=direction;
                        gw::saveSettings(latest);lock.lock();if(core.revision==generation)core.preferencesDirty=false;
                    }
                } catch(...) {} // 不记录源文；写盘失败保持核心 dirty，下一轮 flush 可重试。
            }
        }).detach();
        std::wstring dacl=L"D:P(A;;GA;;;"+gw::userSid()+L")";
        PSECURITY_DESCRIPTOR descriptor=nullptr;
        if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(dacl.c_str(),SDDL_REVISION_1,&descriptor,nullptr)) return 3;
        SECURITY_ATTRIBUTES security{sizeof(security),descriptor,FALSE};
        bool first=true;
        for(;;) {
            HANDLE pipe=CreateNamedPipeW(gw::pipeName().c_str(),PIPE_ACCESS_DUPLEX|FILE_FLAG_OVERLAPPED|(first?FILE_FLAG_FIRST_PIPE_INSTANCE:0),PIPE_TYPE_BYTE|PIPE_READMODE_BYTE|PIPE_WAIT|PIPE_REJECT_REMOTE_CLIENTS,32,gw::MaxMessageBytes,gw::MaxMessageBytes,0,&security);
            if(pipe==INVALID_HANDLE_VALUE) break;
            first=false;OVERLAPPED operation{};operation.hEvent=CreateEventW(nullptr,TRUE,FALSE,nullptr);
            BOOL connected=ConnectNamedPipe(pipe,&operation);DWORD error=GetLastError();
            if(!connected && error==ERROR_IO_PENDING) {WaitForSingleObject(operation.hEvent,INFINITE);DWORD transferred=0;connected=GetOverlappedResult(pipe,&operation,&transferred,FALSE);}
            else if(!connected && error==ERROR_PIPE_CONNECTED) connected=TRUE;
            CloseHandle(operation.hEvent);
            if(!connected || clients.load()>=32) {CloseHandle(pipe);continue;}
            std::thread(serve,pipe).detach();
        }
        stopping=true;LocalFree(descriptor);CloseHandle(mutex);return 3;
    } catch(...) {return 1;}
}
