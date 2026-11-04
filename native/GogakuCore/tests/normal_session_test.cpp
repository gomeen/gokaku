// 普通模式事件轨迹测试：覆盖 docs/product.md「普通模式行为规格」与自定义词语规格。
// 事件序列 → 期望快照 的向量在这里固化；平台层不得偏离同一轨迹。
//
// 运行前提：libime 出厂数据（zh_CN.lm）。默认取
// ~/Library/Caches/Gogaku/libime-1.1.17/data，可用 GOGAKU_CORE_TEST_DATA 覆盖。
// 测试词典在临时目录由文本格式生成（只含测试自选词条，无许可负担）。
#include "gogaku_core.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

#include <libime/pinyin/pinyindictionary.h>

namespace {

int g_failures = 0;
int g_checks = 0;

void check(bool ok, const std::string &what) {
    ++g_checks;
    if (!ok) {
        ++g_failures;
        fprintf(stderr, "  FAIL: %s\n", what.c_str());
    }
}

void check_eq(const std::string &got, const std::string &want, const std::string &what) {
    ++g_checks;
    if (got != want) {
        ++g_failures;
        fprintf(stderr, "  FAIL: %s\n    got:  %s\n    want: %s\n", what.c_str(), got.c_str(), want.c_str());
    }
}

void check_eq(size_t got, size_t want, const std::string &what) {
    ++g_checks;
    if (got != want) {
        ++g_failures;
        fprintf(stderr, "  FAIL: %s (got %zu want %zu)\n", what.c_str(), got, want);
    }
}

struct Env {
    std::string dir;          // 临时测试目录
    std::string dictPath;     // 生成的二进制测试词典
    std::string modelPath;    // 出厂 zh_CN.lm
    std::string wordsPath;    // custom-words.tsv
    std::string englishPath;  // 英文词表
};

GcSnapshot *send(GcNormalSession *s, int32_t kind, const std::string &text = "", int64_t arg = 0,
                 int64_t time_ms = 0, const char *app = "test.app", const char *field = "f1") {
    GcKeyEvent ev{};
    ev.kind = kind;
    ev.arg = arg;
    ev.time_ms = time_ms;
    ev.text = text.c_str();
    ev.app = app;
    ev.field = field;
    GcSnapshot *snap = nullptr;
    int rc = gc_normal_handle(s, &ev, &snap);
    if (rc != 0 || snap == nullptr) {
        fprintf(stderr, "  FAIL: gc_normal_handle rc=%d kind=%d\n", rc, kind);
        ++g_failures;
        return nullptr;
    }
    return snap;
}

struct DelSnap {
    GcSnapshot *p;
    ~DelSnap() { if (p) gc_snapshot_free(p); }
};

std::string cand_text(const GcSnapshot *s, size_t i) {
    return s != nullptr && i < s->count && s->candidates != nullptr ? s->candidates[i].text : "<none>";
}

int32_t cand_kind(const GcSnapshot *s, size_t i) {
    return s != nullptr && i < s->count && s->candidates != nullptr ? s->candidates[i].kind : -1;
}

const char *kTestDictText = R"(你好 ni'hao
拟好 ni'hao
你 ni
好 hao
号 hao
毫 hao
耗 hao
豪 hao
嚎 hao
壕 hao
嗥 hao
浩 hao
昊 hao
皓 hao
淏 hao
今天 jin'tian
今 jin
我 wo
想 xiang
学 xue
英语 ying'yu
开会 kai'hui
会议 hui'yi
李好 li'hao
脏 zang
章 zhang
民 min
敏 min
泯 min
悯 min
C盘 C'pan
盘 pan
)";

const char *kTestEnglish = R"(
company 1000
compare 900
compact 800
meeting 700
min 500
)";

void write_file(const std::string &path, const std::string &content) {
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out << content;
}

void filesystem_create_dirs(const std::string &path) {
    std::filesystem::create_directories(path);
}

bool make_env(Env &env) {
    const char *dataDir = getenv("GOGAKU_CORE_TEST_DATA");
    std::string base = dataDir != nullptr && *dataDir != '\0' ? dataDir
        : std::string(getenv("HOME") == nullptr ? "" : getenv("HOME")) + "/Library/Caches/Gogaku/libime-1.1.17/data";
    env.modelPath = base + "/zh_CN.lm";
    std::ifstream probe(env.modelPath, std::ios::binary);
    if (!probe) {
        fprintf(stderr, "SKIP: 未找到 libime 出厂模型 %s（设置 GOGAKU_CORE_TEST_DATA）\n", env.modelPath.c_str());
        return false;
    }
    char tpl[] = "/tmp/gogaku-core-test-XXXXXX";
    if (mkdtemp(tpl) == nullptr) return false;
    env.dir = tpl;
    // 文本词典 → 二进制（与会话加载格式一致）。
    std::string textPath = env.dir + "/dict.text";
    write_file(textPath, kTestDictText);
    try {
        libime::PinyinDictionary d;
        d.load(0, textPath.c_str(), libime::PinyinDictFormat::Text);
        env.dictPath = env.dir + "/dict.bin";
        d.save(0, env.dictPath.c_str(), libime::PinyinDictFormat::Binary);
    } catch (const std::exception &e) {
        fprintf(stderr, "SKIP: 测试词典生成失败：%s\n", e.what());
        return false;
    }
    env.wordsPath = env.dir + "/custom-words.tsv";
    env.englishPath = env.dir + "/english.txt";
    write_file(env.englishPath, kTestEnglish);
    return true;
}

GcNormalSession *make_session(const Env &env, bool english = true, int32_t scheme = GC_SCHEME_XIAOHE,
                              uint32_t fuzzy = 0, int32_t fullPinyinPreedit = 1) {
    GcNormalConfig cfg{};
    cfg.dict_path = env.dictPath.c_str();
    cfg.model_path = env.modelPath.c_str();
    cfg.custom_words_path = env.wordsPath.c_str();
    cfg.english_words_path = english ? env.englishPath.c_str() : nullptr;
    cfg.scheme = scheme;
    cfg.fuzzy_mask = fuzzy;
    cfg.full_pinyin_preedit = fullPinyinPreedit;
    cfg.freq_enabled = 1;
    cfg.english_enabled = english ? 1 : 0;
    GcNormalSession *s = nullptr;
    char err[256] = {0};
    int rc = gc_normal_session_create(&cfg, &s, err, sizeof(err));
    if (rc != 0 || s == nullptr) {
        fprintf(stderr, "  FAIL: 会话创建 rc=%d err=%s\n", rc, err);
        ++g_failures;
        return nullptr;
    }
    return s;
}

// ---------- 各规格场景 ----------

void test_xiaohe_and_commit(const Env &env) {
    auto *s = make_session(env);
    { DelSnap d{send(s, GC_EV_TEXT, "n")}; }
    { DelSnap d{send(s, GC_EV_TEXT, "i")}; }
    DelSnap h{send(s, GC_EV_TEXT, "h")};
    check(h.p != nullptr && h.p->composing == 1, "小鹤组合中 composing");
    { DelSnap d{send(s, GC_EV_TEXT, "c")}; }
    DelSnap done{send(s, GC_EV_SPACE)};
    check_eq(done.p ? done.p->commit : "", "你好", "小鹤 nihc+空格 → 你好");
    check(done.p != nullptr && done.p->composing == 0, "上屏后退出组合");
    check(done.p != nullptr && *done.p->marked == '\0', "上屏后清除 marked text");
    gc_normal_session_destroy(s);
}

void test_enter_commits_raw(const Env &env) {
    auto *s = make_session(env);
    send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "c");
    DelSnap e{send(s, GC_EV_ENTER)};
    check_eq(e.p ? e.p->commit : "", "nihc", "Enter 上屏原编码");
    gc_normal_session_destroy(s);
}

void test_punctuation_table(const Env &env) {
    auto *s = make_session(env);
    const std::vector<std::pair<std::string, std::string>> cases = {
        {",", "，"}, {".", "。"}, {"?", "？"}, {"!", "！"}, {";", "；"}, {":", "："},
        {"(", "（"}, {")", "）"}, {"[", "【"}, {"]", "】"}, {"<", "《"}, {">", "》"},
        {"\\", "、"}, {"~", "～"}, {"@", "＠"}, {"#", "＃"}, {"%", "％"}, {"&", "＆"},
        {"*", "＊"}, {"+", "＋"}, {"=", "＝"}, {"^", "＾"}, {"$", "＄"}, {"_", "＿"}, {"|", "｜"},
    };
    for (const auto &c : cases) {
        DelSnap d{send(s, GC_EV_TEXT, c.first)};
        check_eq(d.p ? d.p->commit : "", c.second, "标点映射 " + c.first);
        check(d.p != nullptr && d.p->consumed == 1, "标点事件被消费 " + c.first);
    }
    // 引号交替
    DelSnap q1{send(s, GC_EV_TEXT, "\"")};
    DelSnap q2{send(s, GC_EV_TEXT, "\"")};
    DelSnap q3{send(s, GC_EV_TEXT, "'")};
    DelSnap q4{send(s, GC_EV_TEXT, "'")};
    check_eq(std::string(q1.p ? q1.p->commit : "") + (q2.p ? q2.p->commit : "") +
             (q3.p ? q3.p->commit : "") + (q4.p ? q4.p->commit : ""),
             "\u201c\u201d\u2018\u2019", "引号交替配对");
    // 数字后半角例外：数字后 . : 半角；非数字后恢复全角
    DelSnap d3{send(s, GC_EV_TEXT, "3")};
    check(d3.p != nullptr && d3.p->consumed == 0, "数字交还宿主");
    DelSnap dot{send(s, GC_EV_TEXT, ".")};
    check_eq(dot.p ? dot.p->commit : "", ".", "数字后 . 保持半角");
    DelSnap colon{send(s, GC_EV_TEXT, ":")};
    check_eq(colon.p ? colon.p->commit : "", "：", "非数字后 : 恢复全角");
    DelSnap d10{send(s, GC_EV_TEXT, "0")};
    DelSnap colon2{send(s, GC_EV_TEXT, ":")};
    check_eq(colon2.p ? colon2.p->commit : "", ":", "数字后 : 保持半角");
    DelSnap cn{send(s, GC_EV_TEXT, "。")};
    check_eq(cn.p ? cn.p->commit : "", "", "中文标点交还宿主（无映射）");
    gc_normal_session_destroy(s);
}

void test_in_composition_punct(const Env &env) {
    { // 完整覆盖：暂存＋候选＋标点一次上屏
        auto *s = make_session(env);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "c");
        DelSnap q{send(s, GC_EV_TEXT, "?")};
        check_eq(q.p ? q.p->commit : "", "你好？", "组合中标点完整覆盖一次上屏");
        gc_normal_session_destroy(s);
    }
    { // 部分覆盖：暂存＋剩余原编码＋标点（高亮候选只覆盖部分编码）
        auto *s = make_session(env);
        DelSnap v{nullptr};
        for (char k : std::string("wojbtm")) { auto *snap = send(s, GC_EV_TEXT, std::string(1, k)); if (snap) { gc_snapshot_free(v.p); v.p = snap; } }
        // 选择分段“我”（不完整覆盖）
        long myIdx = -1;
        for (size_t i = 0; i < v.p->count; ++i) if (cand_text(v.p, i) == "我") { myIdx = static_cast<long>(i); break; }
        check(myIdx >= 0, "候选中存在分段 我");
        if (myIdx >= 0) {
            // 暂存后的快照即剩余编码 jbtm 的候选
            DelSnap v2{send(s, GC_EV_TEXT, std::to_string(myIdx + 1))};
            // 在剩余编码候选中选中不完整的“今”（显示含暂存前缀 我今）
            long jinIdx = -1;
            for (size_t i = 0; i < v2.p->count; ++i) if (cand_text(v2.p, i) == "我今") { jinIdx = static_cast<long>(i); break; }
            check(jinIdx >= 0, "剩余编码存在不完整候选 今");
            if (jinIdx >= 0) {
                send(s, GC_EV_TEXT, std::to_string(jinIdx + 1));
                DelSnap bang{send(s, GC_EV_TEXT, "!")};
                check_eq(bang.p ? bang.p->commit : "", "我今tm！", "部分覆盖：暂存文字＋剩余原编码＋标点");
                check(bang.p && bang.p->composing == 0, "部分覆盖标点提交后退出组合");
                check(bang.p && bang.p->count == 0, "部分覆盖标点提交后无候选");
                check_eq(bang.p ? bang.p->marked : "", "", "部分覆盖标点提交后无宿主字母");
                check(gc_normal_copy_raw(s, nullptr, 0) == 1, "部分覆盖标点提交后原编码为空");
            }
        }
        gc_normal_session_destroy(s);
    }
    { // 光标位于编码中间，高亮候选只能覆盖光标前的部分。
        auto *s = make_session(env);
        for (char k : std::string("nihc")) {
            DelSnap typed{send(s, GC_EV_TEXT, std::string(1, k))};
        }
        { DelSnap left{send(s, GC_EV_LEFT)}; }
        { DelSnap left{send(s, GC_EV_LEFT)}; }
        DelSnap bang{send(s, GC_EV_TEXT, "!")};
        check_eq(bang.p ? bang.p->commit : "", "nihc！", "中间光标标点保留全部原编码");
        check(bang.p && bang.p->composing == 0, "中间光标标点后组合结束");
        check(bang.p && bang.p->count == 0, "中间光标标点后无候选");
        check_eq(bang.p ? bang.p->marked : "", "", "中间光标标点后无宿主字母");
        check(gc_normal_copy_raw(s, nullptr, 0) == 1, "中间光标标点后无原编码");
        gc_normal_session_destroy(s);
    }
}

void test_digits(const Env &env) {
    { // 数字选择：找到首个完整覆盖候选（位置 >0），按其页内序号上屏
        auto *s = make_session(env);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
        DelSnap before{send(s, GC_EV_TEXT, "c")};
        long target = -1;
        std::string targetText;
        for (size_t i = 1; i < before.p->count; ++i) {
            if (before.p->candidates[i].completes == 1 && cand_text(before.p, i) != "你好") {
                target = static_cast<long>(i); targetText = cand_text(before.p, i); break;
            }
        }
        check(target > 0, "存在另一完整候选");
        if (target > 0) {
            DelSnap d{send(s, GC_EV_TEXT, std::to_string(target + 1))};
            check_eq(d.p ? d.p->commit : "", targetText, "数字按序号上屏候选");
        }
        gc_normal_session_destroy(s);
    }
    { // 数字选分段候选：暂存不提交，剩余编码继续
        auto *s = make_session(env);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
        DelSnap before{send(s, GC_EV_TEXT, "c")};
        long ni = -1;
        for (size_t i = 0; i < before.p->count; ++i) if (cand_text(before.p, i) == "你") { ni = static_cast<long>(i); break; }
        check(ni >= 0, "存在分段候选 你");
        if (ni >= 0) {
            DelSnap d{send(s, GC_EV_TEXT, std::to_string(ni + 1))};
            check(d.p != nullptr && d.p->commit[0] == '\0', "分段候选暂存不提交");
            check_eq(d.p ? d.p->preedit : "", "你hao", "暂存态预编辑（展开全拼）");
            DelSnap sp{send(s, GC_EV_SPACE)};
            check_eq(sp.p ? sp.p->commit : "", "你好", "暂存后剩余编码续选上屏");
        }
        gc_normal_session_destroy(s);
    }
    { // 数字 0：先上屏高亮候选再输出数字
        auto *s = make_session(env);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "c");
        DelSnap d0{send(s, GC_EV_TEXT, "0")};
        check_eq(d0.p ? d0.p->commit : "", "你好0", "数字 0 先上屏高亮再输出");
        gc_normal_session_destroy(s);
    }
    { // 超出页内数量：第 2 页只有 3 项，数字 5 → 高亮候选（完整）＋5
        auto *s = make_session(env, false, GC_SCHEME_FULLPINYIN);
        send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "a"); send(s, GC_EV_TEXT, "o");
        DelSnap onpage{send(s, GC_EV_PAGE_DOWN)};
        const std::string hi = cand_text(onpage.p, 0);
        DelSnap d5{send(s, GC_EV_TEXT, "5")};
        check_eq(d5.p ? d5.p->commit : "", hi + "5", "超出页内数量先上屏高亮再输出数字");
        gc_normal_session_destroy(s);
    }
}

void test_paging(const Env &env) {
    auto *s = make_session(env, false, GC_SCHEME_FULLPINYIN);
    send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "a");
    DelSnap p1{send(s, GC_EV_TEXT, "o")};
    check_eq(p1.p ? p1.p->total : 0, 12, "hao 候选总数 12");
    check_eq(p1.p ? p1.p->page_count : 0, 2, "两页");
    check_eq(p1.p ? p1.p->count : 0, 9, "每页 9 个");
    check_eq(p1.p ? p1.p->page : 0, 0, "页码 0");
    DelSnap pd{send(s, GC_EV_PAGE_DOWN)};
    check_eq(pd.p ? pd.p->page : 0, 1, "Page Down 进第 2 页");
    check_eq(pd.p ? pd.p->count : 0, 3, "第 2 页 3 个");
    // 页内数字选择：第 2 页数字 1 → 全局第 10 项
    std::string tenth;
    if (pd.p != nullptr && pd.p->count > 0) tenth = cand_text(pd.p, 0);
    DelSnap d1{send(s, GC_EV_TEXT, "1")};
    check_eq(d1.p ? d1.p->commit : "", tenth, "第 2 页数字 1 选中全局第 10 项");
    // `,`/`.` 翻页（有候选时占用）
    send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "a"); send(s, GC_EV_TEXT, "o");
    DelSnap dot{send(s, GC_EV_TEXT, ".")};
    check_eq(dot.p ? dot.p->page : 0, 1, ". 下一页");
    DelSnap comma{send(s, GC_EV_TEXT, ",")};
    check_eq(comma.p ? comma.p->page : 0, 0, ", 上一页");
    // ↑↓ 跨页移动高亮：9 次 ↓ 后跨到第 2 页，再 ↓ 停在末尾，↑ 回第 1 页
    for (int i = 0; i < 9; ++i) {
        DelSnap d{send(s, GC_EV_DOWN)};
        check_eq(d.p ? d.p->page : 0, i == 8 ? 1 : 0, "↓ 跨页");
    }
    DelSnap last{send(s, GC_EV_DOWN)};
    check_eq(last.p ? last.p->selected : 0, 10, "↓ 在末尾停住");
    DelSnap up1{send(s, GC_EV_UP)};
    check_eq(up1.p ? up1.p->page : 0, 1, "↑ 仍在第 2 页");
    DelSnap up2{send(s, GC_EV_UP)};
    check_eq(up2.p ? up2.p->page : 0, 0, "↑ 跨页回第 1 页");
    gc_normal_session_destroy(s);
}

void test_shift(const Env &env) {
    { // 组合中 Shift：暂存＋剩余原编码一次上屏，同一事件进入临时英文。
        auto *s = make_session(env);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "c");
        DelSnap in{send(s, GC_EV_SHIFT_CLICK)};
        check_eq(in.p ? in.p->commit : "", "nihc", "组合中 Shift 上屏原编码");
        check(in.p != nullptr && in.p->english == 1, "组合中 Shift 进入临时英文");
        check(in.p != nullptr && in.p->toast == 2, "组合中 Shift 英文提示");
        check(in.p != nullptr && in.p->composing == 0, "组合中 Shift 后组合结束");
        check(in.p != nullptr && in.p->consumed == 1, "组合中 Shift 事件被消费");
        // 提交后的字母／标点按英文直输交还宿主（核心不产出，保持半角）。
        DelSnap letter{send(s, GC_EV_TEXT, "x")};
        check(letter.p != nullptr && letter.p->consumed == 0, "临时英文字母交还宿主");
        DelSnap dot{send(s, GC_EV_TEXT, ".")};
        check(dot.p != nullptr && dot.p->consumed == 0, "临时英文句号交还宿主");
        check_eq(dot.p ? dot.p->commit : "", "", "临时英文核心不产出标点");
        // 再按 Shift 切回中文（临时英文→中文），此后标点才映射全角。
        DelSnap back{send(s, GC_EV_SHIFT_CLICK)};
        check(back.p != nullptr && back.p->english == 0 && back.p->toast == 1, "再按 Shift 切回中文");
        DelSnap dot2{send(s, GC_EV_TEXT, ".")};
        check_eq(dot2.p ? dot2.p->commit : "", "。", "切回中文后句号映射全角");
        gc_normal_session_destroy(s);
    }
    { // lastChar 回归载体：数字直通 → 组合 Shift 提交 → 切回中文 → 句号应得全角。
        // 修复前 lastChar 仍停在数字 7，句号错误沿用数字后半角规则输出半角 "."。
        auto *s = make_session(env);
        DelSnap digit{send(s, GC_EV_TEXT, "7")};
        check(digit.p != nullptr && digit.p->consumed == 0, "无组合数字交还宿主");
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "c");
        DelSnap rawCommit{send(s, GC_EV_SHIFT_CLICK)};
        check_eq(rawCommit.p ? rawCommit.p->commit : "", "nihc", "数字直通后组合 Shift 上屏原编码");
        check(rawCommit.p != nullptr && rawCommit.p->english == 1, "数字直通后组合 Shift 进英文");
        DelSnap back{send(s, GC_EV_SHIFT_CLICK)};
        check(back.p != nullptr && back.p->english == 0, "切回中文");
        DelSnap dot{send(s, GC_EV_TEXT, ".")};
        check_eq(dot.p ? dot.p->commit : "", "。", "Shift 提交字母后句号恢复全角（lastChar 已更新）");
        gc_normal_session_destroy(s);
    }
    { // 分段（部分暂存）组合：Shift 上屏＝已暂存中文＋剩余原编码。
        auto *s = make_session(env);
        DelSnap v{nullptr};
        for (char k : std::string("wojbtm")) { auto *snap = send(s, GC_EV_TEXT, std::string(1, k)); if (snap) { gc_snapshot_free(v.p); v.p = snap; } }
        long wo = -1;
        for (size_t i = 0; i < v.p->count; ++i) if (cand_text(v.p, i) == "我") { wo = static_cast<long>(i); break; }
        check(wo >= 0, "候选中存在分段 我");
        if (wo >= 0) {
            send(s, GC_EV_TEXT, std::to_string(wo + 1));  // 暂存 我，剩余 jbtm 继续组合
            DelSnap partCommit{send(s, GC_EV_SHIFT_CLICK)};
            check_eq(partCommit.p ? partCommit.p->commit : "", "我jbtm", "分段组合 Shift＝暂存＋剩余原编码");
            check(partCommit.p != nullptr && partCommit.p->english == 1, "分段组合 Shift 进临时英文");
            check(partCommit.p != nullptr && partCommit.p->composing == 0, "分段组合 Shift 后组合结束");
        }
        gc_normal_session_destroy(s);
    }
    { // 大写字面段组合：Shift 上屏＝字面段＋剩余原编码。
        auto *s = make_session(env, false);
        send(s, GC_EV_TEXT, "C"); send(s, GC_EV_TEXT, "p"); send(s, GC_EV_TEXT, "j");
        DelSnap litCommit{send(s, GC_EV_SHIFT_CLICK)};
        check_eq(litCommit.p ? litCommit.p->commit : "", "Cpj", "大写字面段组合 Shift 一次上屏");
        check(litCommit.p != nullptr && litCommit.p->english == 1, "大写字面段组合 Shift 进临时英文");
        gc_normal_session_destroy(s);
    }
    { // 左右 Shift 等价：组合中提交进英文，无组合切换，再按回中文。
        auto *s = make_session(env);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i");
        DelSnap right{send(s, GC_EV_SHIFT_CLICK, "", 1)};
        check_eq(right.p ? right.p->commit : "", "ni", "右 Shift 组合中上屏原编码");
        check(right.p != nullptr && right.p->english == 1 && right.p->toast == 2, "右 Shift 进临时英文");
        DelSnap back{send(s, GC_EV_SHIFT_CLICK, "", 1)};
        check(back.p != nullptr && back.p->english == 0 && back.p->toast == 1, "右 Shift 切回中文");
        DelSnap idle{send(s, GC_EV_SHIFT_CLICK, "", 1)};
        check(idle.p != nullptr && idle.p->english == 1 && idle.p->toast == 2, "右 Shift 未组合切临时英文");
        gc_normal_session_destroy(s);
    }
    { // 两次连续 Shift 往返：提交并进英文 → 再按回中文 → 中文组合恢复。
        auto *s = make_session(env);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "c");
        DelSnap first{send(s, GC_EV_SHIFT_CLICK)};
        check(first.p != nullptr && first.p->english == 1, "第一次 Shift 提交并进英文");
        DelSnap second{send(s, GC_EV_SHIFT_CLICK)};
        check(second.p != nullptr && second.p->english == 0 && second.p->toast == 1, "第二次 Shift 回中文");
        DelSnap letter{send(s, GC_EV_TEXT, "n")};
        check(letter.p != nullptr && letter.p->composing == 1, "回中文后字母重新进入组合");
        gc_normal_session_destroy(s);
    }
    { // 对照：真数字后半角例外不因 Shift 规则扩大范围。
        auto *s = make_session(env);
        DelSnap digit3{send(s, GC_EV_TEXT, "3")};
        check(digit3.p != nullptr && digit3.p->consumed == 0, "真数字交还宿主");
        DelSnap dot{send(s, GC_EV_TEXT, ".")};
        check_eq(dot.p ? dot.p->commit : "", ".", "真数字后句号仍保持半角");
        gc_normal_session_destroy(s);
    }
    { // 对照：Enter 仍只上屏原编码并保持中文。
        auto *s = make_session(env);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "c");
        DelSnap enterCommit{send(s, GC_EV_ENTER)};
        check_eq(enterCommit.p ? enterCommit.p->commit : "", "nihc", "Enter 上屏原编码");
        check(enterCommit.p != nullptr && enterCommit.p->english == 0, "Enter 不切英文（保持中文）");
        DelSnap dot{send(s, GC_EV_TEXT, ".")};
        check_eq(dot.p ? dot.p->commit : "", "。", "Enter 提交后句号全角");
        gc_normal_session_destroy(s);
    }
}

void test_per_app_english(const Env &env) {
    auto *s = make_session(env);
    gc_normal_set_app_defaults(s, std::vector<const char *>{"com.raycast"}.data(), 1);
    DelSnap sync{send(s, GC_EV_FOCUS_SYNC, "", 0, 0, "com.raycast", "f1")};
    check(sync.p != nullptr && sync.p->english == 2, "按应用默认英文切入");
    DelSnap letter{send(s, GC_EV_TEXT, "a", 0, 0, "com.raycast", "f1")};
    check(letter.p != nullptr && letter.p->consumed == 0, "默认英文应用字母直通");
    DelSnap shift{send(s, GC_EV_SHIFT_CLICK, "", 0, 0, "com.raycast", "f1")};
    check(shift.p != nullptr && shift.p->english == 0 && shift.p->toast == 1, "Shift 覆盖默认英文");
    // 中文输入正常
    send(s, GC_EV_TEXT, "n", 0, 0, "com.raycast", "f1");
    send(s, GC_EV_TEXT, "i", 0, 0, "com.raycast", "f1");
    send(s, GC_EV_TEXT, "h", 0, 0, "com.raycast", "f1");
    send(s, GC_EV_TEXT, "c", 0, 0, "com.raycast", "f1");
    DelSnap sp{send(s, GC_EV_SPACE, "", 0, 0, "com.raycast", "f1")};
    check_eq(sp.p ? sp.p->commit : "", "你好", "覆盖后中文正常输入");
    DelSnap esc{send(s, GC_EV_ESC, "", 0, 0, "com.raycast", "f1")};
    check(esc.p != nullptr && esc.p->english == 2, "无组合 Esc 回到应用默认");
    DelSnap esc2{send(s, GC_EV_ESC, "", 0, 0, "com.raycast", "f1")};
    check(esc2.p != nullptr && esc2.p->consumed == 0, "已是默认时 Esc 交还宿主");
    // 新规格完整链：覆盖默认英文为中文 → 组合 Shift 提交进临时英文 →
    // 再 Shift 回中文（不回按应用默认）→ Esc 恢复应用默认。
    DelSnap cn{send(s, GC_EV_SHIFT_CLICK, "", 0, 0, "com.raycast", "f1")};
    check(cn.p != nullptr && cn.p->english == 0, "再次 Shift 覆盖默认英文为中文");
    send(s, GC_EV_TEXT, "n", 0, 0, "com.raycast", "f1");
    send(s, GC_EV_TEXT, "i", 0, 0, "com.raycast", "f1");
    send(s, GC_EV_TEXT, "h", 0, 0, "com.raycast", "f1");
    send(s, GC_EV_TEXT, "c", 0, 0, "com.raycast", "f1");
    DelSnap commitShift{send(s, GC_EV_SHIFT_CLICK, "", 0, 0, "com.raycast", "f1")};
    check_eq(commitShift.p ? commitShift.p->commit : "", "nihc", "默认英文应用内组合 Shift 上屏原编码");
    check(commitShift.p != nullptr && commitShift.p->english == 1 && commitShift.p->toast == 2,
          "组合 Shift 提交后进临时英文");
    DelSnap letter2{send(s, GC_EV_TEXT, "x", 0, 0, "com.raycast", "f1")};
    check(letter2.p != nullptr && letter2.p->consumed == 0, "临时英文字母直通");
    DelSnap back{send(s, GC_EV_SHIFT_CLICK, "", 0, 0, "com.raycast", "f1")};
    check(back.p != nullptr && back.p->english == 0 && back.p->toast == 1,
          "临时英文 Shift 回中文（不回按应用默认）");
    DelSnap esc3{send(s, GC_EV_ESC, "", 0, 0, "com.raycast", "f1")};
    check(esc3.p != nullptr && esc3.p->english == 2, "Esc 恢复应用默认不变");
    gc_normal_session_destroy(s);
}

void test_english_candidates(const Env &env) {
    { // compa：中文无法完整覆盖 → 英文排第一，前缀补全最多 3
        auto *s = make_session(env);
        send(s, GC_EV_TEXT, "c"); send(s, GC_EV_TEXT, "o"); send(s, GC_EV_TEXT, "m");
        send(s, GC_EV_TEXT, "p");
        DelSnap v{send(s, GC_EV_TEXT, "a")};
        check_eq(cand_text(v.p, 0), "company", "英文候选排第一");
        check_eq(cand_kind(v.p, 0), GC_CAND_ENGLISH, "英文候选类别");
        check_eq(cand_text(v.p, 1), "compare", "前缀补全 1");
        check_eq(cand_text(v.p, 2), "compact", "前缀补全 2");
        DelSnap sp{send(s, GC_EV_SPACE)};
        check_eq(sp.p ? sp.p->commit : "", "company", "英文候选上屏");
        gc_normal_session_destroy(s);
    }
    { // min：中文完整覆盖 → 英文排第二位
        auto *s = make_session(env);
        send(s, GC_EV_TEXT, "m"); send(s, GC_EV_TEXT, "i");
        DelSnap v{send(s, GC_EV_TEXT, "n")};
        check(cand_kind(v.p, 0) != GC_CAND_ENGLISH, "中文完整覆盖时英文不在首位");
        check_eq(cand_text(v.p, 1), "min", "英文排第二位");
        gc_normal_session_destroy(s);
    }
    { // 英文候选关闭时不出现
        auto *s = make_session(env, false);
        send(s, GC_EV_TEXT, "c"); send(s, GC_EV_TEXT, "o"); send(s, GC_EV_TEXT, "m");
        send(s, GC_EV_TEXT, "p");
        DelSnap v{send(s, GC_EV_TEXT, "a")};
        bool hasEnglish = false;
        for (size_t i = 0; i < v.p->count; ++i) if (cand_kind(v.p, i) == GC_CAND_ENGLISH) hasEnglish = true;
        check(!hasEnglish, "关闭英文候选后不出现");
        gc_normal_session_destroy(s);
    }
}

void test_uppercase(const Env &env) {
    auto *s = make_session(env, false);
    DelSnap c{send(s, GC_EV_TEXT, "C")};
    check(c.p != nullptr && c.p->composing == 1, "大写字母进入组合");
    send(s, GC_EV_TEXT, "p");
    DelSnap v{send(s, GC_EV_TEXT, "j")};
    check_eq(cand_text(v.p, 0), "C盘", "Cpj → C盘");
    DelSnap sp{send(s, GC_EV_SPACE)};
    check_eq(sp.p ? sp.p->commit : "", "C盘", "上屏 C盘");
    // 单独大写字母加空格原样上屏
    DelSnap h{send(s, GC_EV_TEXT, "H")};
    check(h.p != nullptr && h.p->composing == 1, "单独大写进入组合");
    DelSnap sp2{send(s, GC_EV_SPACE)};
    check_eq(sp2.p ? sp2.p->commit : "", "H", "单独大写字母空格原样上屏");
    gc_normal_session_destroy(s);
}

void test_segments_and_backspace(const Env &env) {
    auto *s = make_session(env, false);
    DelSnap before{nullptr};
    for (char k : std::string("wojbtm")) { auto *snap = send(s, GC_EV_TEXT, std::string(1, k)); if (snap) { gc_snapshot_free(before.p); before.p = snap; } }
    long myIdx = -1;
    for (size_t i = 0; i < before.p->count; ++i) if (cand_text(before.p, i) == "我") { myIdx = static_cast<long>(i); break; }
    check(myIdx >= 0, "候选中存在分段 我");
    check(myIdx != 0 || cand_text(before.p, 0) == "我", "分段位置记录");
    if (myIdx >= 0) {
        DelSnap sel{send(s, GC_EV_TEXT, std::to_string(myIdx + 1))};
        check(sel.p != nullptr && sel.p->commit[0] == '\0', "分段暂存不提交");
        check_eq(sel.p ? sel.p->preedit : "", "我jin'tian", "暂存态展开预编辑");
        check_eq(sel.p ? std::to_string(sel.p->typed_prefix_len) : "", "1", "暂存中文前缀标量数");
        DelSnap second{send(s, GC_EV_CTRL_P)};
        check_eq(cand_text(second.p, 0), "我今天", "剩余编码继续出候选（显示含暂存前缀）");
        DelSnap undo{send(s, GC_EV_BACKSPACE)};
        check_eq(undo.p ? undo.p->preedit : "", "wo'jin'tian", "退格撤回最后一次选择");
        // 重新暂存并整段上屏
        send(s, GC_EV_TEXT, std::to_string(myIdx + 1));
        DelSnap fin{send(s, GC_EV_SPACE)};
        check_eq(fin.p ? fin.p->commit : "", "我今天", "整段选完上屏");
    }
    gc_normal_session_destroy(s);
}

void test_editor_keys(const Env &env) {
    // 小鹤＋展开全拼（full_pinyin_preedit=1）：caret 为展开串的字节偏移。
    auto *s = make_session(env, false);
    send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "c");
    DelSnap home{send(s, GC_EV_HOME)};
    check_eq(home.p ? std::to_string(home.p->preedit_caret) : "", "0", "Home 行首");
    DelSnap end{send(s, GC_EV_END)};
    check_eq(end.p ? std::to_string(end.p->preedit_caret) : "", "6", "End 行尾（ni'hao 6 字节）");
    DelSnap left{send(s, GC_EV_LEFT)};
    check_eq(left.p ? std::to_string(left.p->preedit_caret) : "", "4", "← 光标后退（初始后）");
    DelSnap cb{send(s, GC_EV_CTRL_B)};
    check_eq(cb.p ? std::to_string(cb.p->preedit_caret) : "", "2", "Ctrl+b 后退");
    DelSnap cf{send(s, GC_EV_CTRL_F)};
    check_eq(cf.p ? std::to_string(cf.p->preedit_caret) : "", "4", "Ctrl+f 前进");
    DelSnap ca{send(s, GC_EV_CTRL_A)};
    check_eq(ca.p ? std::to_string(ca.p->preedit_caret) : "", "0", "Ctrl+a 行首");
    DelSnap ce{send(s, GC_EV_CTRL_E)};
    check_eq(ce.p ? std::to_string(ce.p->preedit_caret) : "", "6", "Ctrl+e 行尾");
    check_eq(home.p ? home.p->preedit : "", "ni'hao", "小鹤展开预编辑 ni'hao");
    gc_normal_session_destroy(s);
    // 小鹤＋原码（full_pinyin_preedit=0）：caret 为原码字节偏移。
    auto *raw = make_session(env, false, GC_SCHEME_XIAOHE, 0, 0);
    send(raw, GC_EV_TEXT, "n"); send(raw, GC_EV_TEXT, "i"); send(raw, GC_EV_TEXT, "h"); send(raw, GC_EV_TEXT, "c");
    DelSnap rawEnd{send(raw, GC_EV_END)};
    check_eq(rawEnd.p ? rawEnd.p->preedit : "", "nihc", "小鹤原码预编辑 nihc");
    check_eq(rawEnd.p ? std::to_string(rawEnd.p->preedit_caret) : "", "4", "原码 caret 为字节偏移");
    gc_normal_session_destroy(raw);
    // 全拼展开预编辑
    auto *s2 = make_session(env, false, GC_SCHEME_FULLPINYIN);
    send(s2, GC_EV_TEXT, "n"); send(s2, GC_EV_TEXT, "i"); send(s2, GC_EV_TEXT, "h");
    send(s2, GC_EV_TEXT, "a"); send(s2, GC_EV_TEXT, "o");
    DelSnap fp{send(s2, GC_EV_CTRL_A)};
    check_eq(fp.p ? fp.p->preedit : "", "ni'hao", "全拼展开预编辑 ni'hao");
    gc_normal_session_destroy(s2);
}

// 预编辑显示：两种方案都尊重 full_pinyinPreedit；分段后为「已选中文＋剩余展开拼音」，
// caret 是预编辑串的字节偏移（不超 UTF-8 字节长度）。
void test_preedit_display(const Env &env) {
    {   // 小鹤：full_pinyin_preedit=1 → ni'hao
        auto *s = make_session(env, false);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
        DelSnap v{send(s, GC_EV_TEXT, "c")};
        check_eq(v.p ? v.p->preedit : "", "ni'hao", "小鹤展开预编辑");
        check_eq(v.p ? v.p->marked : "", "ni'hao", "宿主 marked text 同为展开拼音");
        check_eq(v.p ? std::to_string(v.p->preedit_caret) : "", "6", "caret ＝字节长度");
        gc_normal_session_destroy(s);
    }
    {   // 小鹤：full_pinyin_preedit=0 → nihc
        auto *s = make_session(env, false, GC_SCHEME_XIAOHE, 0, 0);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
        DelSnap v{send(s, GC_EV_TEXT, "c")};
        check_eq(v.p ? v.p->preedit : "", "nihc", "小鹤原码预编辑");
        gc_normal_session_destroy(s);
    }
    {   // 分段：已选中文＋剩余展开拼音；caret 为字节偏移
        auto *s = make_session(env, false);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
        DelSnap v{send(s, GC_EV_TEXT, "c")};
        long ni = -1;
        for (size_t i = 0; i < v.p->count; ++i) if (cand_text(v.p, i) == "你") { ni = static_cast<long>(i); break; }
        check(ni >= 0, "存在分段候选 你");
        if (ni >= 0) {
            DelSnap sel{send(s, GC_EV_TEXT, std::to_string(ni + 1))};
            check_eq(sel.p ? sel.p->preedit : "", "你hao", "分段预编辑＝已选中文＋剩余展开拼音");
            check_eq(sel.p ? std::to_string(sel.p->preedit_caret) : "", "6", "分段 caret ＝字节长度");
            check_eq(sel.p ? std::to_string(sel.p->typed_prefix_len) : "", "1", "暂存前缀标量数");
            DelSnap home{send(s, GC_EV_HOME)};
            check_eq(home.p ? std::to_string(home.p->preedit_caret) : "", "3", "分段 Home caret ＝已选中文字节数");
            DelSnap left{send(s, GC_EV_LEFT)};
            check_eq(left.p ? std::to_string(left.p->preedit_caret) : "", "3",
                     "分段 Home 后光标已在暂存边界，← 不再回退到暂存之前");
        }
        gc_normal_session_destroy(s);
    }
    {   // 全拼：分段后同样是「已选中文＋剩余展开拼音」
        auto *s = make_session(env, false, GC_SCHEME_FULLPINYIN);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
        send(s, GC_EV_TEXT, "a"); send(s, GC_EV_TEXT, "o");
        DelSnap v{send(s, GC_EV_CTRL_A)};
        long ni = -1;
        for (size_t i = 0; i < v.p->count; ++i) if (cand_text(v.p, i) == "你") { ni = static_cast<long>(i); break; }
        check(ni >= 0, "全拼存在分段候选 你");
        if (ni >= 0) {
            DelSnap sel{send(s, GC_EV_TEXT, std::to_string(ni + 1))};
            check_eq(sel.p ? sel.p->preedit : "", "你hao", "全拼分段预编辑");
            check_eq(sel.p ? std::to_string(sel.p->preedit_caret) : "", "3",
                     "全拼分段 caret（Home 后光标在暂存边界）");
            check_eq(sel.p ? std::to_string(sel.p->typed_prefix_len) : "", "1", "全拼暂存前缀标量数");
            DelSnap end{send(s, GC_EV_END)};
            check_eq(end.p ? std::to_string(end.p->preedit_caret) : "", "6", "全拼分段 End caret ＝字节长度");
        }
        gc_normal_session_destroy(s);
    }
}

// 原始编码读取接口：草稿必须用原码而不是展开后的预编辑。
void test_copy_raw(const Env &env) {
    auto *s = make_session(env, false);
    check(gc_normal_copy_raw(s, nullptr, 0) == 1, "无组合时所需字节数为 1（空串＋NUL）");
    send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
    DelSnap last{send(s, GC_EV_TEXT, "c")};
    const size_t needed = gc_normal_copy_raw(s, nullptr, 0);
    check(needed == 5, "原码所需字节数 5（nihc＋NUL）");
    std::vector<char> small(2, '\0');
    check(gc_normal_copy_raw(s, small.data(), small.size()) == 5, "容量不足只返回所需字节数");
    check(std::string(small.data()) != "nihc", "容量不足不复制");
    std::vector<char> buffer(needed, '\0');
    check(gc_normal_copy_raw(s, buffer.data(), buffer.size()) == 5, "容量足够返回所需字节数");
    check_eq(std::string(buffer.data()), "nihc", "原码内容正确");
    check(gc_normal_copy_raw(nullptr, buffer.data(), buffer.size()) == 0, "空会话返回 0（错误）");
    // 分段（不完整覆盖）后原码仍含已暂存部分对应的键
    long ni = -1;
    for (size_t i = 0; i < last.p->count; ++i) if (cand_text(last.p, i) == "你") { ni = static_cast<long>(i); break; }
    check(ni >= 0, "存在分段候选 你");
    if (ni >= 0) {
        DelSnap sel{send(s, GC_EV_TEXT, std::to_string(ni + 1))};
        (void)sel;
        const size_t needed2 = gc_normal_copy_raw(s, nullptr, 0);
        std::vector<char> buffer2(needed2, '\0');
        gc_normal_copy_raw(s, buffer2.data(), buffer2.size());
        check_eq(std::string(buffer2.data()), "nihc", "分段后原码不变");
    }
    // 提交后清空
    send(s, GC_EV_SPACE);
    check(gc_normal_copy_raw(s, nullptr, 0) == 1, "提交后原码为空");
    gc_normal_session_destroy(s);
}

void test_full_pinyin_scheme(const Env &env) {
    auto *s = make_session(env, false, GC_SCHEME_FULLPINYIN);
    send(s, GC_EV_TEXT, "j"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "n");
    send(s, GC_EV_TEXT, "t"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "a");
    DelSnap v{send(s, GC_EV_TEXT, "n")};
    check_eq(cand_text(v.p, 0), "今天", "全拼 jintian → 今天");
    DelSnap sp{send(s, GC_EV_SPACE)};
    check_eq(sp.p ? sp.p->commit : "", "今天", "全拼上屏");
    gc_normal_session_destroy(s);
}

void test_fuzzy(const Env &env) {
    { // 不开模糊：zhang 只有 章
        auto *s = make_session(env, false, GC_SCHEME_FULLPINYIN, 0);
        send(s, GC_EV_TEXT, "z"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "a"); send(s, GC_EV_TEXT, "n");
        DelSnap v{send(s, GC_EV_TEXT, "g")};
        bool hasZang = false;
        for (size_t i = 0; i < v.p->count; ++i) if (cand_text(v.p, i) == "脏") hasZang = true;
        check(!hasZang, "未开模糊音 zhang 不含 脏");
        gc_normal_session_destroy(s);
    }
    { // 开 z/zh：zhang 同时命中 章 与 脏
        auto *s = make_session(env, false, GC_SCHEME_FULLPINYIN, GC_FUZZY_Z_ZH);
        send(s, GC_EV_TEXT, "z"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "a"); send(s, GC_EV_TEXT, "n");
        DelSnap v{send(s, GC_EV_TEXT, "g")};
        bool hasZang = false, hasZhang = false;
        for (size_t i = 0; i < v.p->count; ++i) {
            if (cand_text(v.p, i) == "脏") hasZang = true;
            if (cand_text(v.p, i) == "章") hasZhang = true;
        }
        check(hasZang && hasZhang, "开 z/zh 后 zhang 命中 章／脏");
        gc_normal_session_destroy(s);
    }
    { // 开 n/l：nihao 命中 李好
        auto *s = make_session(env, false, GC_SCHEME_FULLPINYIN, GC_FUZZY_N_L);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "a");
        DelSnap v{send(s, GC_EV_TEXT, "o")};
        bool hasLi = false;
        for (size_t i = 0; i < v.p->count; ++i) if (cand_text(v.p, i) == "李好") hasLi = true;
        check(hasLi, "开 n/l 后 nihao 命中 李好");
        gc_normal_session_destroy(s);
    }
}

void test_custom_words(const Env &env) {
    write_file(env.wordsPath,
               "#gogaku-custom-words\tv1\n"
               "0\t1\tzj\t\t早安！新的一天。\n"
               "1\t1\thuiyi\thui'yi\t会议纪要\n"
               "0\t0\tzz\t\t停用短语\n");
    { // 短码精确匹配置顶；前缀不出现；停用不出现
        auto *s = make_session(env);
        DelSnap prefix{send(s, GC_EV_TEXT, "z")};
        check_eq(cand_kind(prefix.p, 0), GC_CAND_CHINESE, "短码前缀不出现");
        DelSnap v{send(s, GC_EV_TEXT, "j")};
        check_eq(cand_kind(v.p, 0), GC_CAND_SHORTCODE, "短码精确匹配置顶");
        check_eq(cand_text(v.p, 0), "早安！新的一天。", "短码内容");
        DelSnap sp{send(s, GC_EV_SPACE)};
        check_eq(sp.p ? sp.p->commit : "", "早安！新的一天。", "短码原样上屏");
        gc_normal_session_destroy(s);
    }
    { // 拼音词完整匹配置顶（全拼方案）
        auto *s = make_session(env, false, GC_SCHEME_FULLPINYIN);
        send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "u"); send(s, GC_EV_TEXT, "i");
        send(s, GC_EV_TEXT, "y"); send(s, GC_EV_TEXT, "i");
        DelSnap v{send(s, GC_EV_CTRL_A)};
        check_eq(cand_kind(v.p, 0), GC_CAND_PINYIN_WORD, "拼音词完整匹配置顶");
        check_eq(cand_text(v.p, 0), "会议纪要", "拼音词内容");
        DelSnap sp{send(s, GC_EV_SPACE)};
        check_eq(sp.p ? sp.p->commit : "", "会议纪要", "拼音词上屏");
        gc_normal_session_destroy(s);
    }
    { // 有暂存分段时短码不出现
        auto *s = make_session(env);
        DelSnap v0{nullptr};
        for (char k : std::string("wojbtm")) { auto *snap = send(s, GC_EV_TEXT, std::string(1, k)); if (snap) { gc_snapshot_free(v0.p); v0.p = snap; } }
        long myIdx = -1;
        for (size_t i = 0; i < v0.p->count; ++i) if (cand_text(v0.p, i) == "我") { myIdx = static_cast<long>(i); break; }
        check(myIdx >= 0, "候选中存在分段 我");
        DelSnap sel{send(s, GC_EV_TEXT, std::to_string(myIdx + 1))};
        check(sel.p != nullptr && sel.p->commit[0] == '\0', "暂存 我");
        send(s, GC_EV_TEXT, "z");
        DelSnap v{send(s, GC_EV_TEXT, "j")};
        bool hasShortcode = false;
        for (size_t i = 0; i < v.p->count; ++i) if (cand_kind(v.p, i) == GC_CAND_SHORTCODE) hasShortcode = true;
        check(!hasShortcode, "暂存分段时短码不出现");
        gc_normal_session_destroy(s);
    }
    { // 重载生效
        auto *s = make_session(env);
        write_file(env.wordsPath,
                   "#gogaku-custom-words\tv1\n0\t1\tzz\t\t新增短语\n");
        gc_normal_reload_custom_words(s);
        send(s, GC_EV_TEXT, "z");
        DelSnap v{send(s, GC_EV_TEXT, "z")};
        check_eq(cand_text(v.p, 0), "新增短语", "重载后新短码生效");
        gc_normal_session_destroy(s);
    }
}

// 使用真实出厂词典：小型测试词典无法暴露生僻自定义词在解码时被剪枝的问题。
void test_factory_custom_pinyin(const Env &env) {
    Env factory = env;
    factory.dictPath = (std::filesystem::path(env.modelPath).parent_path() / "sc.dict").string();
    const std::string header = "#gogaku-custom-words\tv1\n";
    const std::string word = "1\t1\t\tji'shi'jiao\t极视角\n";
    struct Case { int32_t scheme; const char *keys; const char *sentence; };
    const Case cases[] = {
        {GC_SCHEME_XIAOHE, "jiuijn", "woxlkjjiuijn"},
        {GC_SCHEME_FULLPINYIN, "jishijiao", "woxiangkanjishijiao"},
    };
    for (const auto &c : cases) {
        for (bool reload : {false, true}) {
            write_file(factory.wordsPath, reload ? header : header + word);
            auto *s = make_session(factory, false, c.scheme);
            if (s == nullptr) continue;
            if (reload) {
                write_file(factory.wordsPath, header + word);
                check(gc_normal_reload_custom_words(s) == 0, "新增拼音词后重载成功");
            }
            for (char k : std::string(c.keys)) {
                DelSnap d{send(s, GC_EV_TEXT, std::string(1, k))};
            }
            DelSnap v{send(s, GC_EV_END)};
            check_eq(cand_text(v.p, 0), "极视角", "出厂词典中自定义拼音词置顶（双拼／全拼，初载／重载）");
            check_eq(cand_kind(v.p, 0), GC_CAND_PINYIN_WORD, "生僻自定义词保留自定义类别");
            DelSnap sp{send(s, GC_EV_SPACE)};
            check_eq(sp.p ? sp.p->commit : "", "极视角", "生僻自定义词一次上屏");
            for (char k : std::string(c.sentence)) {
                DelSnap d{send(s, GC_EV_TEXT, std::string(1, k))};
            }
            DelSnap sentence{send(s, GC_EV_SPACE)};
            check_eq(sentence.p ? sentence.p->commit : "", "我想看极视角", "生僻自定义拼音词参与长句组句");
            gc_normal_session_destroy(s);
        }
    }
}

void test_factory_auto_pinyin(const Env &env) {
    const std::string dict = (std::filesystem::path(env.modelPath).parent_path() / "sc.dict").string();
    const std::vector<std::pair<std::string, std::string>> cases = {
        {"极视角", "ji'shi'jiao"}, {"极", "ji"}, {"视", "shi"},
        {"角", "jiao"}, {"会议", "hui'yi"},
    };
    for (const auto &[word, expected] : cases) {
        char *out = nullptr;
        check(gc_custom_pinyin_lookup(dict.c_str(), word.c_str(), &out) == 0,
              "真实出厂词典自动读音成功：" + word);
        check_eq(out ? out : "", expected, "真实出厂词典优先常用读音：" + word);
        free(out);
    }
    char *missing = nullptr;
    check(gc_custom_pinyin_lookup((env.dir + "/missing.dict").c_str(), "极", &missing) == 2,
          "自动读音缺词典时明确失败");
    check(missing == nullptr, "自动读音失败不返回部分结果");
    check(gc_custom_pinyin_lookup(env.dictPath.c_str(), "极", &missing) == 2,
          "自动读音确实缺字时明确失败");
    check(missing == nullptr, "缺字不返回部分读音");
}

void test_delete_word(const Env &env) {
    write_file(env.wordsPath, "#gogaku-custom-words\tv1\n");
    auto *s = make_session(env);
    send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "c");
    send(s, GC_EV_SPACE);  // 学习 你好
    send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
    DelSnap v{send(s, GC_EV_TEXT, "c")};
    check_eq(cand_kind(v.p, 0), GC_CAND_LEARNED, "已学习词标记 deletable");
    check(v.p != nullptr && v.p->candidates[0].deletable == 1, "deletable 置位");
    DelSnap del{send(s, GC_EV_DELETE_WORD)};
    check_eq(del.p ? del.p->status : "", "已删除学习词「你好」", "删词提示");
    // 出厂词不能删除
    send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "a");
    DelSnap v2{send(s, GC_EV_TEXT, "o")};
    check_eq(cand_kind(v2.p, 0), GC_CAND_CHINESE, "出厂词不可删标记");
    DelSnap del2{send(s, GC_EV_DELETE_WORD)};
    check_eq(del2.p ? del2.p->status : "", "出厂词不能删除", "出厂词拒删提示");
    gc_normal_session_destroy(s);
}

void test_delete_prefixed_learned_word(const Env &env) {
    const std::string userDir = env.dir + "/prefix-delete";
    GcNormalConfig cfg{};
    cfg.dict_path = env.dictPath.c_str();
    cfg.model_path = env.modelPath.c_str();
    cfg.user_dir = userDir.c_str();
    cfg.freq_enabled = 1;
    GcNormalSession *s = nullptr;
    check(gc_normal_session_create(&cfg, &s, nullptr, 0) == 0, "暂存删词会话创建");
    if (!s) return;
    for (char k : std::string("nihc")) { DelSnap typed{send(s, GC_EV_TEXT, std::string(1, k))}; }
    { DelSnap committed{send(s, GC_EV_SPACE)}; }
    for (char k : std::string("wonih")) { DelSnap typed{send(s, GC_EV_TEXT, std::string(1, k))}; }
    DelSnap before{send(s, GC_EV_TEXT, "c")};
    long prefixIndex = -1;
    for (size_t i = 0; before.p && i < before.p->count; ++i) {
        if (cand_text(before.p, i) == "我") { prefixIndex = static_cast<long>(i); break; }
    }
    check(prefixIndex >= 0, "暂存删词：存在分段 我");
    if (prefixIndex >= 0) {
        DelSnap staged{send(s, GC_EV_TEXT, std::to_string(prefixIndex + 1))};
        check_eq(cand_text(staged.p, 0), "我你好", "学习候选展示含暂存前缀");
        check(cand_kind(staged.p, 0) == GC_CAND_LEARNED, "带前缀候选仍标记学习词");
        DelSnap deleted{send(s, GC_EV_DELETE_WORD)};
        check_eq(deleted.p ? deleted.p->status : "", "已删除学习词「你好」", "删除用裸词并提示裸词");
        bool learned = false;
        for (size_t i = 0; deleted.p && i < deleted.p->count; ++i) {
            if (cand_text(deleted.p, i) == "我你好" && cand_kind(deleted.p, i) == GC_CAND_LEARNED) learned = true;
        }
        check(!learned, "删除后当前快照不再标记该学习词");
    }
    check(gc_normal_flush(s) == 0, "带前缀删词落盘");
    gc_normal_session_destroy(s);
    s = nullptr;
    check(gc_normal_session_create(&cfg, &s, nullptr, 0) == 0, "带前缀删词后重载");
    if (!s) return;
    for (char k : std::string("nih")) { DelSnap typed{send(s, GC_EV_TEXT, std::string(1, k))}; }
    DelSnap reloaded{send(s, GC_EV_TEXT, "c")};
    bool resurrected = false;
    for (size_t i = 0; reloaded.p && i < reloaded.p->count; ++i) {
        if (cand_text(reloaded.p, i) == "你好" && cand_kind(reloaded.p, i) == GC_CAND_LEARNED) resurrected = true;
    }
    check(!resurrected, "带前缀删除的学习词重载不复活");
    gc_normal_session_destroy(s);
}

void test_flush_and_persistence(const Env &env) {
    write_file(env.wordsPath, "#gogaku-custom-words\tv1\n");
    std::string userDir = env.dir + "/user";
    {
        GcNormalConfig cfg{};
        cfg.dict_path = env.dictPath.c_str();
        cfg.model_path = env.modelPath.c_str();
        cfg.user_dir = userDir.c_str();
        cfg.freq_enabled = 1;
        GcNormalSession *s = nullptr;
        check(gc_normal_session_create(&cfg, &s, nullptr, 0) == 0, "带 user_dir 创建");
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "c");
        send(s, GC_EV_SPACE);
        check(gc_normal_flush(s) == 0, "flush 成功");
        gc_normal_session_destroy(s);
    }
    {
        std::ifstream f(userDir + "/model.userlm", std::ios::binary);
        check(f.good(), "model.userlm 已写入");
        std::ifstream g(userDir + "/learned.txt", std::ios::binary);
        check(g.good(), "learned.txt 已写入");
    }
    { // 重载后 30 秒防抖之外的数据仍在（立即重载验证持久化）
        GcNormalConfig cfg{};
        cfg.dict_path = env.dictPath.c_str();
        cfg.model_path = env.modelPath.c_str();
        cfg.user_dir = userDir.c_str();
        cfg.freq_enabled = 1;
        GcNormalSession *s = nullptr;
        gc_normal_session_create(&cfg, &s, nullptr, 0);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
        DelSnap v{send(s, GC_EV_TEXT, "c")};
        check_eq(cand_kind(v.p, 0), GC_CAND_LEARNED, "重载后学习词仍在");
        gc_normal_session_destroy(s);
    }
}

void test_custom_words_store(const Env &env) {
    // 校验规则
    char err[128] = {0};
    check(gc_custom_words_validate(GC_WORD_SHORTCODE, "ZJ", "", "内容", err, sizeof(err)) == 1, "大写编码非法");
    check(gc_custom_words_validate(GC_WORD_SHORTCODE, "zj1", "", "内容", err, sizeof(err)) == 1, "含数字编码非法");
    check(gc_custom_words_validate(GC_WORD_SHORTCODE, std::string(33, 'a').c_str(), "", "内容", err, sizeof(err)) == 1, "超长编码非法");
    check(gc_custom_words_validate(GC_WORD_SHORTCODE, "zj", "", std::string(513 * 3, '\xc3').c_str(), err, sizeof(err)) == 1, "超长内容非法");
    check(gc_custom_words_validate(GC_WORD_PINYIN, "", "hui'yi'", "会议纪要", err, sizeof(err)) == 1, "空音节非法");
    check(gc_custom_words_validate(GC_WORD_PINYIN, "", "hui'yi", "会议纪要", err, sizeof(err)) == 1, "音节数与字数不符非法");
    check(gc_custom_words_validate(GC_WORD_PINYIN, "", "hui'yi'ji'yao", "会议纪要ab", err, sizeof(err)) == 1, "非汉字内容非法");
    check(gc_custom_words_validate(GC_WORD_PINYIN, "", "hui'yi'ji'yao", "会议纪要", err, sizeof(err)) == 0, "合法拼音词");
    check(gc_custom_words_validate(GC_WORD_SHORTCODE, "zj", "", "你好 世界\n第二行\t含制表", err, sizeof(err)) == 0, "合法短码含转义字符");
    // 读写往返与转义
    std::string path = env.dir + "/store.tsv";
    {
        GcCustomWord w1{};
        w1.kind = GC_WORD_SHORTCODE; w1.enabled = 1;
        w1.code = const_cast<char *>("zj");
        w1.pinyin = const_cast<char *>("");
        w1.content = const_cast<char *>("行一\n行二\t含制表\\斜杠");
        GcCustomWord w2{};
        w2.kind = GC_WORD_PINYIN; w2.enabled = 0;
        w2.code = const_cast<char *>(""); w2.pinyin = const_cast<char *>("hui'yi");
        w2.content = const_cast<char *>("会议纪要");
        GcCustomWordList list{};
        GcCustomWord words[2] = {w1, w2};
        list.words = words; list.count = 2;
        check(gc_custom_words_write(path.c_str(), &list) == 0, "原子写入成功");
    }
    {
        GcCustomWordList *list = nullptr;
        check(gc_custom_words_read(path.c_str(), &list) == 0, "读回成功");
        check(list != nullptr && list->corrupt == 0, "无损坏标记");
        check_eq(list ? std::to_string(list->count) : "", "2", "两条词条");
        check_eq(list && list->count == 2 && list->words[0].content ? list->words[0].content : "",
                 "行一\n行二\t含制表\\斜杠", "转义往返一致");
        check(list != nullptr && list->count == 2 && list->words[1].enabled == 0, "停用位往返一致");
        gc_custom_word_list_free(list);
    }
    { // 损坏文件：备份并以空表启动
        std::string bad = env.dir + "/bad.tsv";
        write_file(bad, "#gogaku-custom-words\tv1\nbroken line without tabs\n");
        GcCustomWordList *list = nullptr;
        check(gc_custom_words_read(bad.c_str(), &list) == 0, "损坏文件读取返回成功");
        check(list != nullptr && list->corrupt == 1, "标记损坏");
        check_eq(list ? std::to_string(list->count) : "", "0", "空表启动");
        std::ifstream backup(bad + ".corrupt");
        check(backup.good(), "已备份为 .corrupt");
        gc_custom_word_list_free(list);
    }
    { // 会话创建时报告损坏
        std::string bad = env.dir + "/bad2.tsv";
        write_file(bad, "not the version line\n");
        GcNormalConfig cfg{};
        cfg.dict_path = env.dictPath.c_str();
        cfg.model_path = env.modelPath.c_str();
        cfg.custom_words_path = bad.c_str();
        GcNormalSession *s = nullptr;
        char err2[256] = {0};
        check(gc_normal_session_create(&cfg, &s, err2, sizeof(err2)) == 0, "损坏文件仍可创建会话");
        check(std::string(err2).find("损坏") != std::string::npos, "创建时报告损坏");
        gc_normal_session_destroy(s);
    }
}

void test_corrupt_userlm_recovery(const Env &env) {
    write_file(env.wordsPath, "#gogaku-custom-words\tv1\n");
    std::string userDir = env.dir + "-corrupt-user";
    filesystem_create_dirs(userDir);
    write_file(userDir + "/model.userlm", "\x00\xff 破损数据 not-a-model\n");
    {
        GcNormalConfig cfg{};
        cfg.dict_path = env.dictPath.c_str();
        cfg.model_path = env.modelPath.c_str();
        cfg.user_dir = userDir.c_str();
        cfg.freq_enabled = 1;
        GcNormalSession *s = nullptr;
        char err[256] = {0};
        const int rc = gc_normal_session_create(&cfg, &s, err, sizeof(err));
        check(rc == 0, "调频历史损坏时仍可创建会话");
        if (rc == 0) {
            check(std::string(err).find("model.userlm") != std::string::npos,
                  "错误信息提及 model.userlm");
            // 能正常学习与输入（降级为空调频历史）。
            send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
            DelSnap v{send(s, GC_EV_TEXT, "c")};
            check_eq(v.p ? v.p->commit : "", "", "降级会话不误上屏");
            send(s, GC_EV_SPACE);
            check(gc_normal_flush(s) == 0, "降级会话可 flush");
            gc_normal_session_destroy(s);
        }
    }
    {   // 损坏文件已备份，重建后可用新历史。
        std::ifstream backup(userDir + "/model.userlm.corrupt", std::ios::binary);
        check(backup.good(), "损坏 model.userlm 已备份为 .corrupt");
        std::ifstream fresh(userDir + "/model.userlm", std::ios::binary);
        check(fresh.good(), "flush 已重建 model.userlm");
    }
}

void test_delete_not_resurrected(const Env &env) {
    write_file(env.wordsPath, "#gogaku-custom-words\tv1\n");
    std::string userDir = env.dir + "-delete-user";
    filesystem_create_dirs(userDir);
    GcNormalConfig cfg{};
    cfg.dict_path = env.dictPath.c_str();
    cfg.model_path = env.modelPath.c_str();
    cfg.user_dir = userDir.c_str();
    cfg.freq_enabled = 1;
    {
        // 学习→落盘→删除→落盘。
        GcNormalSession *s = nullptr;
        gc_normal_session_create(&cfg, &s, nullptr, 0);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
        send(s, GC_EV_TEXT, "c");
        send(s, GC_EV_SPACE);                       // 学习 你好
        check(gc_normal_flush(s) == 0, "学习落盘");
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
        DelSnap v{send(s, GC_EV_TEXT, "c")};
        check(v.p != nullptr && v.p->count > 0 && v.p->candidates[0].deletable == 1, "删除前可删");
        DelSnap del{send(s, GC_EV_DELETE_WORD)};
        check_eq(del.p ? del.p->status : "", "已删除学习词「你好」", "删词成功");
        check(gc_normal_flush(s) == 0, "删除落盘");
        gc_normal_session_destroy(s);
    }
    {
        // 新会话：删除不可被迟到的写入恢复。
        GcNormalSession *s = nullptr;
        gc_normal_session_create(&cfg, &s, nullptr, 0);
        send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h");
        DelSnap v{send(s, GC_EV_TEXT, "c")};
        bool resurrected = false;
        for (size_t i = 0; v.p != nullptr && i < v.p->count; ++i) {
            if (v.p->candidates[i].kind == GC_CAND_LEARNED) resurrected = true;
        }
        check(!resurrected, "删除后新会话不再出现学习词标记");
        // 再 flush（无脏数据）也不得让旧状态复活。
        check(gc_normal_flush(s) == 0, "无脏 flush 安全");
        DelSnap v2{send(s, GC_EV_TEXT, "x")};
        (void)v2;
        gc_normal_session_destroy(s);
        GcNormalSession *s2 = nullptr;
        gc_normal_session_create(&cfg, &s2, nullptr, 0);
        send(s2, GC_EV_TEXT, "n"); send(s2, GC_EV_TEXT, "i"); send(s2, GC_EV_TEXT, "h");
        DelSnap v3{send(s2, GC_EV_TEXT, "c")};
        bool again = false;
        for (size_t i = 0; v3.p != nullptr && i < v3.p->count; ++i) {
            if (v3.p->candidates[i].kind == GC_CAND_LEARNED) again = true;
        }
        check(!again, "再次 flush 后也不复活");
        gc_normal_session_destroy(s2);
    }
}

void test_esc_and_misc(const Env &env) {
    auto *s = make_session(env);
    send(s, GC_EV_TEXT, "n");
    DelSnap esc{send(s, GC_EV_ESC)};
    check(esc.p != nullptr && esc.p->composing == 0, "Esc 取消组合");
    DelSnap esc2{send(s, GC_EV_ESC)};
    check(esc2.p != nullptr && esc2.p->consumed == 0, "无组合 Esc 交还宿主");
    // 空组合退格交还宿主
    DelSnap bs{send(s, GC_EV_BACKSPACE)};
    check(bs.p != nullptr && bs.p->consumed == 0, "空组合退格交还宿主");
    // 无效 UTF-8 / 长文本
    DelSnap big{send(s, GC_EV_TEXT, std::string(5, 'a'))};
    check(big.p != nullptr && big.p->consumed == 0, "超长 text 交还宿主");
    gc_normal_session_destroy(s);
}

// 平台契约：宿主 marked text 与候选窗预编辑是同一字符串，
// preedit_caret（UTF-8 字节偏移）对两者同时适用。
void test_marked_matches_preedit(const Env &env) {
    auto *s = make_session(env, false);
    const int32_t kinds[] = {GC_EV_TEXT, GC_EV_SPACE, GC_EV_ENTER, GC_EV_ESC, GC_EV_BACKSPACE,
                             GC_EV_LEFT, GC_EV_RIGHT, GC_EV_HOME, GC_EV_END, GC_EV_UP, GC_EV_DOWN,
                             GC_EV_PAGE_UP, GC_EV_PAGE_DOWN, GC_EV_CTRL_A, GC_EV_CTRL_B,
                             GC_EV_CTRL_E, GC_EV_CTRL_F, GC_EV_DELETE_WORD, GC_EV_SHIFT_CLICK};
    int mismatches = 0;
    int caretOverflow = 0;
    for (char k : std::string("nihc")) {
        DelSnap d{send(s, GC_EV_TEXT, std::string(1, k))};
        if (d.p == nullptr) continue;
        if (strcmp(d.p->marked, d.p->preedit) != 0) ++mismatches;
        if (d.p->preedit_caret > static_cast<int64_t>(strlen(d.p->preedit))) ++caretOverflow;
    }
    for (int32_t kind : kinds) {
        DelSnap d{send(s, kind, "")};
        if (d.p == nullptr) continue;
        if (strcmp(d.p->marked, d.p->preedit) != 0) ++mismatches;
        if (d.p->preedit_caret > static_cast<int64_t>(strlen(d.p->preedit))) ++caretOverflow;
        if (d.p->preedit_caret < -1) ++caretOverflow;
    }
    check_eq(mismatches, 0, "marked 与 preedit 始终同一字符串");
    check_eq(caretOverflow, 0, "preedit_caret 在预编辑字节长度内");
    gc_normal_session_destroy(s);
}

// 写失败注入（目录只读）：flush 保留 dirty、会话仍可用；权限恢复后重试
// 可持久化（提交已发生但持久化失败不得错误回退；2026-11-02 补）。
// 设置进程侧「写入失败不能显示保存成功」由 SettingsStoreTests 覆盖。
void test_write_failure_paths(const Env &env) {
    namespace fs = std::filesystem;
    write_file(env.wordsPath, "#gogaku-custom-words\tv1\n");
    const std::string roDir = env.dir + "/readonly";
    fs::create_directories(roDir);
    fs::permissions(roDir, fs::perms::owner_read | fs::perms::owner_exec);
    GcNormalConfig cfg{};
    cfg.dict_path = env.dictPath.c_str();
    cfg.model_path = env.modelPath.c_str();
    cfg.user_dir = roDir.c_str();
    const std::string customPath = roDir + "/custom.tsv";  // 生存期覆盖 session_create（悬垂指针 ASan 会拦截）
    cfg.custom_words_path = customPath.c_str();
    cfg.freq_enabled = 1;
    GcNormalSession *s = nullptr;
    check(gc_normal_session_create(&cfg, &s, nullptr, 0) == 0, "只读目录下会话可创建");
    send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i"); send(s, GC_EV_TEXT, "h"); send(s, GC_EV_TEXT, "c");
    DelSnap commit{send(s, GC_EV_SPACE)};
    check_eq(commit.p ? commit.p->commit : "", "你好", "只读目录下上屏不受影响");
    check(gc_normal_flush(s) == 0, "flush 写失败不报错（dirty 保留，下次重写）");
    // 会话仍可用：写失败后继续输入不卡死。
    send(s, GC_EV_TEXT, "n"); send(s, GC_EV_TEXT, "i");
    DelSnap alive{send(s, GC_EV_TEXT, "h")};
    check(alive.p != nullptr && alive.p->composing == 1, "写失败后组合仍可继续");
    gc_normal_session_destroy(s);
    // 权限恢复后同会话重试 flush：提交已发生的数据持久化补上（平台层 30 秒
    // 防抖重试语义）。
    fs::permissions(roDir, fs::perms::owner_read | fs::perms::owner_write | fs::perms::owner_exec);
    GcNormalSession *s2 = nullptr;
    check(gc_normal_session_create(&cfg, &s2, nullptr, 0) == 0, "权限恢复后重建会话");
    send(s2, GC_EV_TEXT, "n"); send(s2, GC_EV_TEXT, "i"); send(s2, GC_EV_TEXT, "h"); send(s2, GC_EV_TEXT, "c");
    send(s2, GC_EV_SPACE);
    check(gc_normal_flush(s2) == 0, "恢复后 flush 成功");
    gc_normal_session_destroy(s2);
    GcNormalSession *s3 = nullptr;
    check(gc_normal_session_create(&cfg, &s3, nullptr, 0) == 0, "重载会话");
    send(s3, GC_EV_TEXT, "n"); send(s3, GC_EV_TEXT, "i"); send(s3, GC_EV_TEXT, "h");
    DelSnap reload{send(s3, GC_EV_TEXT, "c")};
    check_eq(cand_kind(reload.p, 0), GC_CAND_LEARNED, "恢复后学习词已持久化");
    gc_normal_session_destroy(s3);
    fs::permissions(roDir, fs::perms::owner_read | fs::perms::owner_write | fs::perms::owner_exec);
}

struct NamedTest {
    const char *name;
    std::function<void(const Env &)> fn;
};

}  // namespace

int main() {
    Env env;
    if (!make_env(env)) {
        return g_failures == 0 ? 0 : 1;
    }
    const NamedTest tests[] = {
        {"xiaohe_commit", test_xiaohe_and_commit},
        {"enter_raw", test_enter_commits_raw},
        {"punct_table", test_punctuation_table},
        {"in_composition_punct", test_in_composition_punct},
        {"digits", test_digits},
        {"paging", test_paging},
        {"shift", test_shift},
        {"per_app_english", test_per_app_english},
        {"english_candidates", test_english_candidates},
        {"uppercase", test_uppercase},
        {"segments", test_segments_and_backspace},
        {"editor_keys", test_editor_keys},
        {"preedit_display", test_preedit_display},
        {"copy_raw", test_copy_raw},
        {"marked_matches_preedit", test_marked_matches_preedit},
        {"full_pinyin", test_full_pinyin_scheme},
        {"fuzzy", test_fuzzy},
        {"custom_words", test_custom_words},
        {"factory_custom_pinyin", test_factory_custom_pinyin},
        {"factory_auto_pinyin", test_factory_auto_pinyin},
        {"delete_word", test_delete_word},
        {"delete_prefixed_learned_word", test_delete_prefixed_learned_word},
        {"flush_persistence", test_flush_and_persistence},
        {"corrupt_userlm", test_corrupt_userlm_recovery},
        {"delete_not_resurrected", test_delete_not_resurrected},
        {"custom_store", test_custom_words_store},
        {"write_failure", test_write_failure_paths},
        {"esc_misc", test_esc_and_misc},
    };
    for (const auto &t : tests) {
        int before = g_failures;
        fprintf(stderr, "TEST %s\n", t.name);
        t.fn(env);
        fprintf(stderr, "  %s\n", g_failures == before ? "ok" : "FAILED");
    }
    fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
