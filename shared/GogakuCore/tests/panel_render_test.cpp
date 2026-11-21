// 两端共跑的渲染行为向量：像素、布局、命中、UTF-16 与失败所有权。
#include "../include/gogaku_core.h"
#include "../../third_party/json.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <thread>
#include <string>
#include <vector>
using Json = nlohmann::json;
using Result = std::unique_ptr<GcPanelResult, decltype(&gc_panel_result_free)>;
namespace {
int failures = 0;
void expect(bool condition,const char *message){if(!condition){++failures;std::fprintf(stderr,"FAIL: %s\n",message);}}
Json theme(){return Json::parse(R"({"id":"gogaku","light":{"background":16777215,"border":14147545,"text":2107685,"comment":8214528,"index":7897981,"highlight":1218922,"highlightText":16777215,"highlightComment":16711680,"cursor":5465434,"page":8095872,"visual":{"radius":8,"padding":8,"rowHeight":100,"opacity":100,"bgOpacity":100}},"dark":{"background":2107683,"text":15922931,"visual":{"radius":8,"padding":8,"rowHeight":100,"opacity":100,"bgOpacity":100}},"typography":{"fontSize":14,"indexSize":11}})");}
Json frame(const std::string &font,int index){return {{"fonts",Json::array({{{"path",font},{"index",index}}})},{"preedit","ni'hao"},{"preeditCaretUTF16",6},{"layout","vertical"},{"pageSize",9},{"selected",0},{"page",0},{"pageCount",4},{"candidates",Json::array({{{"text","你好"},{"gloss","int. hello"}},{{"text","您号"}},{{"text","泥壕"}},{{"text","拟好"}}})}};}
Result call(const Json &f,const Json &t,double scale=2,int dark=0,bool pixels=true,int expected=0){
    auto a=f.dump(),b=t.dump();GcPanelResult *out=reinterpret_cast<GcPanelResult *>(uintptr_t(1));
    int rc=(pixels?gc_panel_render:gc_panel_layout)(a.data(),a.size(),b.data(),b.size(),scale,dark,&out);
    if(rc!=expected){std::fprintf(stderr,"FAIL: render rc=%d expected=%d\n",rc,expected);++failures;}
    if(rc)expect(out==nullptr,"失败清空输出，调用方不会拿到旧位图");
    return Result(rc?nullptr:out,gc_panel_result_free);
}
std::vector<GcPanelHitRegion> choices(const GcPanelResult *r){std::vector<GcPanelHitRegion> out;if(r)for(size_t i=0;i<r->hit_count;++i)if(r->hits[i].action==GC_PANEL_HIT_CHOOSE)out.push_back(r->hits[i]);return out;}
bool action(const GcPanelResult *r,int a,int arg=0){if(r)for(size_t i=0;i<r->hit_count;++i)if(r->hits[i].action==a&&r->hits[i].arg==arg)return true;return false;}
bool samePixels(const GcPanelResult *a,const GcPanelResult *b){return a&&b&&a->width==b->width&&a->height==b->height&&!std::memcmp(a->pixels,b->pixels,size_t(a->width)*a->height*4);}
void bounds(const GcPanelResult *r){if(!r)return;for(size_t i=0;i<r->hit_count;++i){auto h=r->hits[i];expect(h.x>=0&&h.y>=0&&h.w>0&&h.h>0&&h.x+h.w<=r->width&&h.y+h.h<=r->height,"命中区域不出画布");}}
struct Ink { size_t color=0, gray=0; int left=0, right=-1; };
Ink ink(const GcPanelResult *r){
    Ink out;if(!r||!r->pixels)return out;out.left=r->width;
    for(int y=0;y<r->height;++y)for(int x=0;x<r->width;++x){
        const auto *p=r->pixels+(size_t(y)*r->width+x)*4;
        int spread=int(std::max({p[0],p[1],p[2]}))-int(std::min({p[0],p[1],p[2]}));
        if(spread>40){++out.color;out.left=std::min(out.left,x);out.right=std::max(out.right,x);}
        else if(spread<=1&&p[3]>10&&int(p[0])+p[1]+p[2]<740)++out.gray;
    }
    return out;
}
void themeCacheRegression(const Json &f,const Json &base) {
    auto a=base,b=base;
    a["light"]["background"]=0x112233;b["light"]["background"]=0x332211;
    auto source=a.dump(),other=b.dump(),frameText=f.dump();
    expect(source.size()==other.size(),"同长度不同内容的主题测试前提");
    auto expectedA=call(f,a),expectedB=call(f,b);
    expect(!samePixels(expectedA.get(),expectedB.get()),"A/B主题确实改变像素");
    // 复用同一输入地址；按指针或长度缓存会错误命中。
    for(int i=0;i<6;++i) {
        std::memcpy(source.data(),(i%2?other:a.dump()).data(),source.size());
        GcPanelResult *raw=nullptr;
        expect(gc_panel_render(frameText.data(),frameText.size(),source.data(),source.size(),2,0,&raw)==0,"旧ABI重复渲染成功");
        Result r(raw,gc_panel_result_free);
        expect(samePixels(r.get(),i%2?expectedB.get():expectedA.get()),"旧ABI同址同长度A/B/A不得沿用旧主题");
    }
    using Theme=std::unique_ptr<GcPanelTheme,decltype(&gc_panel_theme_free)>;
    auto prepare=[&](const Json &j) {
        auto bytes=j.dump();GcPanelTheme *raw=nullptr;
        expect(gc_panel_theme_create(bytes.data(),bytes.size(),&raw)==0&&raw,"主题准备成功，生命周期独立于输入字符串");
        return Theme(raw,gc_panel_theme_free);
    };
    auto pa=prepare(a),pb=prepare(b);
    auto prepared=[&](GcPanelTheme *t,int dark=0,bool pixels=true) {
        GcPanelResult *raw=nullptr;
        expect((pixels?gc_panel_render_prepared:gc_panel_layout_prepared)(frameText.data(),frameText.size(),t,2,dark,&raw)==0,"准备后渲染成功");
        return Result(raw,gc_panel_result_free);
    };
    for(int i=0;i<4;++i){auto r=prepared(i%2?pb.get():pa.get());expect(samePixels(r.get(),i%2?expectedB.get():expectedA.get()),"独立句柄交错不串主题");}
    auto l=prepared(pa.get(),0,false);
    expect(l&&expectedA&&l->pixels==nullptr&&l->width==expectedA->width&&l->height==expectedA->height,"新旧布局ABI兼容");
    GcPanelTheme *bad=reinterpret_cast<GcPanelTheme *>(uintptr_t(1));
    expect(gc_panel_theme_create("[]",2,&bad)==2&&bad==nullptr,"创建失败清空句柄");
    GcPanelResult *out=reinterpret_cast<GcPanelResult *>(uintptr_t(1));
    expect(gc_panel_render_prepared(frameText.data(),frameText.size(),nullptr,2,0,&out)==1&&out==nullptr,"空句柄失败清空输出");
    gc_panel_theme_free(nullptr);
    auto im=base;
    im["light"]["imageData"]="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC";
    im["light"]["visual"]["imageOpacity"]=100;
    im["dark"]["imageData"]="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNg+M8AAAICAQB7CYF4AAAAAElFTkSuQmCC";
    im["dark"]["visual"]["imageOpacity"]=60;
    auto pi=prepare(im);auto light=call(f,im),dark=call(f,im,2,1);
    auto single=im;single["dark"]=nullptr;auto ps=prepare(single);
    auto fallback=prepared(ps.get(),1),fallbackReference=call(f,single,2,1);
    expect(samePixels(fallback.get(),fallbackReference.get()),"深色槽null复用浅色图像且保留深色文字gamma");
    auto changedImage=im;changedImage["light"]["imageData"]=im["dark"]["imageData"];
    auto imageA=im.dump(),imageB=changedImage.dump();
    expect(imageA.size()==imageB.size(),"同长度不同PNG测试前提");
    auto changedReference=call(f,changedImage);
    auto imageRepeat=call(f,im);expect(samePixels(imageRepeat.get(),light.get()),"旧ABI图片A/B/A正确失效");
    expect(!samePixels(changedReference.get(),light.get()),"相同长度不同PNG改变背景像素");
    // 同一句柄并发首次解码、深浅色切换；字体仍为线程私有。
    std::vector<Result> results;for(int i=0;i<8;++i)results.emplace_back(nullptr,gc_panel_result_free);
    std::vector<std::thread> threads;
    for(int i=0;i<8;++i)threads.emplace_back([&,i]{GcPanelResult *raw=nullptr;
        gc_panel_render_prepared(frameText.data(),frameText.size(),pi.get(),2,i%2,&raw);results[i].reset(raw);});
    for(auto &thread:threads)thread.join();
    for(int i=0;i<8;++i)expect(samePixels(results[i].get(),i%2?dark.get():light.get()),"同一主题句柄跨线程及明暗切换不串图像");
    pi.reset();
    expect(samePixels(results[0].get(),light.get()),"句柄释放不影响已返回像素");
    auto noImage=prepared(pa.get());expect(samePixels(noImage.get(),expectedA.get()),"切回无图主题不残留旧图像");
    im["light"]["imageData"]="bm90LWEtcG5n";auto invalid=prepare(im);
    out=reinterpret_cast<GcPanelResult *>(uintptr_t(1));
    expect(gc_panel_render_prepared(frameText.data(),frameText.size(),invalid.get(),2,0,&out)==1&&out==nullptr,"无效图片不能复用旧缓存，失败清空输出");
}
void typedPrefixRegression(const Json &fonts) {
    Json f={{"fonts",fonts},{"preedit","A🙂B"}},t={{"id","rime-macos-like"}};
    f["typedPrefixUTF16"]=4;auto end=call(f,t);
    for(double length:{5.0,16384.0,1000000.0,1e20}) {
        f["typedPrefixUTF16"]=length;auto overlong=call(f,t);
        expect(samePixels(end.get(),overlong.get()),"超长前缀夹紧到当前UTF16总长，转换整数前限界");
    }
    f["typedPrefixUTF16"]=0;auto none=call(f,t);
    f["typedPrefixUTF16"]=1;auto before=call(f,t);
    f["typedPrefixUTF16"]=3;auto after=call(f,t);
    f["typedPrefixUTF16"]=2;auto inside=call(f,t);
    expect(!samePixels(none.get(),before.get())&&samePixels(inside.get(),after.get())&&!samePixels(after.get(),end.get()),"非BMP占两个UTF16单位，后续B不能提前标为typed；簇不被拆开");
    f["learning"]=true;f["direction"]="enToZh";f["typedPrefixUTF16"]=0;
    auto learning=call(f,t);expect(samePixels(learning.get(),end.get()),"学习英到中维持整段typed语义");
}
void emojiRegression(const Json &baseFonts){
    const char *configured=std::getenv("GOGAKU_PANEL_EMOJI_FONT");
    std::string path=configured?configured:"";
#ifdef __APPLE__
    if(path.empty())path="/System/Library/Fonts/Apple Color Emoji.ttc";
#endif
    std::error_code error;
    if(path.empty()||!std::filesystem::is_regular_file(std::filesystem::u8path(path),error)){
        std::printf("UNTESTED: emoji度量/栅格与VS15/VS16（无可用字体文件；GOGAKU_PANEL_EMOJI_FONT=%s）\n",path.c_str());return;
    }
    int before=failures;
    auto fonts=baseFonts;fonts.push_back({{"path",path},{"emoji",true}});
    Json f={{"fonts",fonts},{"layout","horizontal"},{"selected",9},{"candidates",Json::array({{{"text","🙂"}}})}};
    // 全灰配色且隐藏序号；非灰像素只能来自真实彩色字形，不能用缺字方框冒充通过。
    Json t={{"light",{{"background",0xffffff},{"border",0xffffff},{"text",0},{"index",0xffffff},
                      {"visual",{{"radius",0}}}}},{"typography",{{"fontSize",12},{"indexSize",11}}}};
    for(double scale:{1.0,2.0}){
        int advances[2]={0,0};int n=0;
        for(int pt:{12,24}){
            t["typography"]["fontSize"]=pt;f["candidates"][0]["text"]="🙂";
            auto one=call(f,t,scale);f["candidates"][0]["text"]="🙂🙂";auto two=call(f,t,scale);
            auto h1=choices(one.get()),h2=choices(two.get());auto i1=ink(one.get()),i2=ink(two.get());
            expect(i1.color>0&&i2.color>i1.color,"emoji度量回归必须实际绘出两个彩色字形");
            expect(h1.size()==1&&h2.size()==1,"emoji候选存在独立命中区域");
            if(h1.size()==1&&h2.size()==1){
                // 差值扣掉序号与padding，只度量增加一个emoji所需的空间。
                advances[n]=h2[0].w-h1[0].w;
                expect(advances[n]>0,"第二个emoji增加布局宽度");
                expect(i1.color>0&&i1.right-i1.left+1<=advances[n]+1,"emoji字形宽度不超过advance，避免相邻图形重叠");
                expect(std::abs((i2.right-i1.right)-advances[n])<=1,"第二个emoji的像素位置与命中宽度增量一致");
            }
            bounds(one.get());bounds(two.get());++n;
        }
        expect(advances[0]>0&&std::abs(advances[1]-2*advances[0])<=2,"12到24pt的emoji advance同比放大，不能固定为strike宽度");
        std::printf("emoji advance scale=%.0f: 12pt=%dpx 24pt=%dpx\n",scale,advances[0],advances[1]);
    }
    t["typography"]["fontSize"]=24;
    f["candidates"][0]["text"]="\u00a9\ufe0e";auto text=call(f,t,1);
    auto onlyText=f;onlyText["fonts"]=baseFonts;auto reference=call(onlyText,t,1);
    f["candidates"][0]["text"]="\u00a9\ufe0f";auto emoji=call(f,t,1);
    expect(ink(text.get()).color==0&&ink(text.get()).gray>0,"VS15绘出单色文本字形，不选彩色emoji");
    expect(samePixels(text.get(),reference.get()),"VS15与不提供emoji字体时的文本字形一致");
    // Apple Color Emoji 的版权符号本身为黑白；VS16 要核对字体切换，不能要求有色彩。
    auto emojiInk=ink(emoji.get());
    expect(emojiInk.color+emojiInk.gray>0&&!samePixels(text.get(),emoji.get()),"VS16实际绘出与文本字体不同的emoji字形");
    if(failures==before)std::printf("PASS: 本机emoji度量/栅格与VS15/VS16，字体=%s（不代表其他平台已测）\n",path.c_str());
}
}
int main(){
    const char *font=std::getenv("GOGAKU_PANEL_FONT");
    if(!font||!*font){std::fprintf(stderr,"SKIP: 未设置 GOGAKU_PANEL_FONT\n");return 3;}
    int index=0;if(const char *i=std::getenv("GOGAKU_PANEL_FONT_INDEX"))index=std::atoi(i);
    auto f=frame(font,index),t=theme();
    {GcPanelResult *r=nullptr;expect(gc_panel_render("[]",2,"{}",2,1,0,&r)==2,"拒绝非对象");expect(gc_panel_render("broken",6,"{}",2,1,0,&r)==2,"拒绝非法JSON");}
    call(Json{{"fonts",f["fonts"]}},t,1,0,true,1);
    auto nofont=f;nofont["fonts"]=Json::array();call(nofont,t,1,0,true,3);
    auto bad=f;bad["pageSize"]=0;call(bad,t,1,0,true,1);
    bad=f;bad["fonts"]=Json::object();call(bad,t,1,0,true,1);
    auto invalidTheme=t;invalidTheme["light"]["visual"]["fontSize"]=-1;
    invalidTheme["light"]["visual"]["radius"]=-1;call(f,invalidTheme,1,0,true,1);
    for(double s:{0.0,-1.0,1e30,std::numeric_limits<double>::infinity(),std::numeric_limits<double>::quiet_NaN()})call(f,t,s,0,true,1);
    auto a=call(f,t),l=call(f,t,2,0,false),repeat=call(f,t);
    if(a&&l){
        expect(a->width==l->width&&a->height==l->height&&a->hit_count==l->hit_count,"布局与位图使用同一路径");
        expect(l->pixels==nullptr,"layout不分配像素");
        expect(!std::memcmp(a->hits,l->hits,a->hit_count*sizeof(GcPanelHitRegion)),"布局命中表一致");
        expect(samePixels(a.get(),repeat.get()),"缓存热冷不改变位图");
        auto hits=choices(a.get());expect(hits.size()==4,"竖排保留四候选");
        if(hits.size()==4){expect(hits[1].y>hits[0].y&&hits[1].x==hits[0].x,"竖排同列递增");expect(hits.back().arg==3,"CHOOSE全局索引");}
        // 页码自 2026-11-20 起不绘制：多页与单页高度、命中表均一致。
        expect(!action(a.get(),GC_PANEL_HIT_PAGE_NEXT),"不再产生翻页命中区");bounds(a.get());
        for(size_t i=0;i<size_t(a->width)*a->height;++i){const auto *p=a->pixels+4*i;expect(p[0]<=p[3]&&p[1]<=p[3]&&p[2]<=p[3],"RGBA必须预乘");}
    }
    {auto no=f;for(auto &c:no["candidates"])c["gloss"]="";auto b=call(no,t);expect(!samePixels(a.get(),b.get()),"竖排释义实际绘出");}
    {auto one=f;one["pageCount"]=1;auto b=call(one,t);if(a&&b){expect(a->height==b->height,"单页与多页等高（页码不占行）");expect(!action(b.get(),GC_PANEL_HIT_PAGE_NEXT),"单页无翻页命中");}}
    {auto dark=call(f,t,2,1);expect(!samePixels(a.get(),dark.get()),"深色配色生效");}
    {auto caret=f;caret["preeditCaretUTF16"]=-1;auto b=call(caret,t);expect(!samePixels(a.get(),b.get()),"预编辑光标可见");}
    {auto small=f;small["preedit"]="";small["pageCount"]=1;auto x=call(small,t,1),y=call(small,t,2);
        if(x&&y){expect(std::abs(y->width-2*x->width)<=1&&std::abs(y->height-2*x->height)<=1,"DPI几何同比缩放");
            auto ink=[](GcPanelResult *r){size_t n=0;for(int row=2;row<r->height-2;++row)for(int col=2;col<r->width-2;++col){auto p=r->pixels+(size_t(row)*r->width+col)*4;if(p[0]<80&&p[1]<100&&p[2]<80&&p[3]>200)++n;}return n;};
            auto ix=ink(x.get()),iy=ink(y.get());expect(ix>0&&iy>ix*2,"2x字形本身放大，不只是advance放大");}}
    // 极长横排：即便每页9个仍完整保留命中，缩短文本而不偷偷改变分页。
    for(int size=4;size<=9;++size){auto h=f;h["layout"]="horizontal";h["pageSize"]=size;h["page"]=1;h["selected"]=size+size-1;h["candidates"]=Json::array();
        for(int i=0;i<size;++i)h["candidates"].push_back({{"text",std::string(180,'W')},{"gloss","n. long explanation"}});
        auto r=call(h,t);if(r){auto hits=choices(r.get());expect(hits.size()==size_t(size),"横排长文本不能丢候选");expect(r->width<=1720&&r->width>=640,"横排宽度夹紧");
            for(size_t i=0;i<hits.size();++i){expect(hits[i].arg==size+int(i),"横排命中全局页起点");if(i)expect(hits[i].x>=hits[i-1].x+hits[i-1].w,"横排命中不重叠");}bounds(r.get());}
        h["glossRow"]=false;auto plain=call(h,t);if(r&&plain)expect(r->height>plain->height,"横排无释义时收起释义行");}
    {auto h=f;h["layout"]="horizontal";h["glossRow"]=true;h["selected"]=1;auto empty=call(h,t);h["glossRow"]=false;auto off=call(h,t);expect(samePixels(empty.get(),off.get()),"高亮无释义不占行");}
    {auto learning=f;learning["learning"]=true;learning["direction"]="zhToEn";learning["hasOriginal"]=true;learning["hasRestore"]=true;learning["preedit"]="🙂 metting";
        learning["issues"]=Json::array({{{"location",3},{"length",7},{"explanation","疑似拼写"}}});
        auto r=call(learning,t);expect(action(r.get(),GC_PANEL_HIT_ORIGINAL)&&action(r.get(),GC_PANEL_HIT_RESTORE)&&action(r.get(),GC_PANEL_HIT_EXPLAIN),"学习动作与UTF16拼写命中");bounds(r.get());
        learning["issues"][0]["location"]=99;auto invalid=call(learning,t);expect(!action(invalid.get(),GC_PANEL_HIT_EXPLAIN),"过期拼写范围不生成命中");
        learning["candidates"][0]["gloss"]=std::string(300,'W');auto tall=call(learning,t);if(tall&&r)expect(tall->height>r->height,"学习高亮长释义可换行");}
    // 超过四行后只省略头部：隐藏字符不能借省略号产生EXPLAIN，保留尾部必须连续。
    for(double scale:{1.0,2.0}){
        Json longText={{"fonts",f["fonts"]},{"preedit",std::string(200,'W')},{"learning",true},
                       {"issues",Json::array({{{"location",0},{"length",1}}})}};
        auto hidden=call(longText,t,scale);
        expect(!action(hidden.get(),GC_PANEL_HIT_EXPLAIN),"已隐藏的第0字符不能在省略号上产生EXPLAIN");
        longText["issues"]=Json::array();auto plain=call(longText,t,scale);
        expect(samePixels(hidden.get(),plain.get()),"已隐藏issue不能给省略号画波浪线");
        for(int i=0;i<200;++i)longText["issues"].push_back({{"location",i},{"length",1}});
        auto marked=call(longText,t,scale);std::vector<int> visible,rows;
        if(marked)for(size_t i=0;i<marked->hit_count;++i){const auto &h=marked->hits[i];if(h.action!=GC_PANEL_HIT_EXPLAIN)continue;
            visible.push_back(h.arg);if(rows.empty()||rows.back()!=h.y)rows.push_back(h.y);
        }
        expect(rows.size()==4,"长预编辑用例确实触发四行保留上限");
        expect(!visible.empty()&&visible.front()>0&&visible.back()==199,"保留真实尾部且不把省略号映射为第0字符");
        for(size_t i=1;i<visible.size();++i)expect(visible[i]==visible[i-1]+1,"长预编辑保留字符连续，不在换行处丢失中间字符");
        bounds(marked.get());
    }
    themeCacheRegression(f,t);
    typedPrefixRegression(f["fonts"]);
    emojiRegression(f["fonts"]);
    {auto toast=Json{{"fonts",f["fonts"]},{"toast","中文"}};auto r=call(toast,t);if(r)expect(r->width<360&&r->height<160&&r->hit_count==0,"toast使用紧凑无候选画布");}
    {auto semi=t;semi["light"]["visual"]["opacity"]=50;auto r=call(f,semi);if(a&&r&&a->width==r->width&&a->height==r->height){bool checked=false;
        for(size_t i=0;i<size_t(r->width)*r->height;++i)if(a->pixels[i*4+3]==255){expect(r->pixels[i*4+3]>=127&&r->pixels[i*4+3]<=128,"整体透明度作用于背景、高亮、文字");checked=true;}
        expect(checked,"存在可验证整体透明度的像素");}}
    // 1x1 红色 PNG。alpha=0背景仍可显示图像，整体透明度最后统一处理。
    {auto image=t;image["light"]["imageData"]="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC";image["light"]["visual"]["imageOpacity"]=100;
        auto r=call(f,image);expect(!samePixels(a.get(),r.get()),"PNG背景进入共享位图");}
    {auto badImage=t;badImage["light"]["imageData"]="bm90LWEtcG5n";call(f,badImage,1,0,true,1);}
    // 稳态测量只打印证据，不把CI机器负载变成脆弱功能断言。
    std::vector<double> times;
    for(int i=0;i<100;++i){auto start=std::chrono::steady_clock::now();auto r=call(f,t);times.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count());}
    std::sort(times.begin(),times.end());std::printf("panel_render steady 2x (4 rows): median=%.3fms p95=%.3fms\n",times[50],times[95]);
    if(failures){std::fprintf(stderr,"panel_render: %d 项失败\n",failures);return 1;}
    std::puts("panel_render: 已执行断言全部通过；未测子项见上方UNTESTED（如有）");return 0;
}
