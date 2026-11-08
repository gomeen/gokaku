// 学习模式事件轨迹测试（ABI v3）：学习组合状态机＋三状态按键语义＋翻译调度
// 合同。事件序列 → 期望快照 的向量在这里固化；平台层（Swift 薄封装／未来
// TSF）不得偏离同一轨迹。行为合同与 Swift CompositionSession 测试一致，
// 词典/模型与 Swift 侧同源（libime 出厂数据），向量可逐字对齐。
//
// 运行前提：libime 出厂数据（sc.dict ＋ zh_CN.lm）。默认取
// ~/Library/Caches/Gogaku/libime-1.1.17/data，可用 GOGAKU_CORE_TEST_DATA 覆盖。
#include "gogaku_core.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

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

void check_eq(long long got, long long want, const std::string &what) {
    ++g_checks;
    if (got != want) {
        ++g_failures;
        fprintf(stderr, "  FAIL: %s (got %lld want %lld)\n", what.c_str(), got, want);
    }
}

struct Env {
    std::string dictPath;
    std::string modelPath;
};

bool make_env(Env &env) {
    const char *dataDir = getenv("GOGAKU_CORE_TEST_DATA");
    std::string base = dataDir != nullptr && *dataDir != '\0' ? dataDir
        : std::string(getenv("HOME") == nullptr ? "" : getenv("HOME")) + "/Library/Caches/Gogaku/libime-1.1.17/data";
    env.dictPath = base + "/sc.dict";
    env.modelPath = base + "/zh_CN.lm";
    std::ifstream dict(env.dictPath, std::ios::binary);
    std::ifstream model(env.modelPath, std::ios::binary);
    if (!dict || !model) {
        fprintf(stderr, "SKIP: 未找到 libime 出厂数据 %s（设置 GOGAKU_CORE_TEST_DATA）\n", base.c_str());
        return false;
    }
    return true;
}

GcLearningSession *make_session(const Env &env) {
    GcLearningConfig cfg{};
    cfg.dict_path = env.dictPath.c_str();
    cfg.model_path = env.modelPath.c_str();
    GcLearningSession *s = nullptr;
    char err[256] = {0};
    int rc = gc_learning_session_create(&cfg, &s, err, sizeof(err));
    if (rc != 0 || s == nullptr) {
        fprintf(stderr, "  FAIL: 学习会话创建 rc=%d err=%s\n", rc, err);
        ++g_failures;
        return nullptr;
    }
    return s;
}

struct DelSnap {
    GcLearningSnapshot *p;
    ~DelSnap() { if (p) gc_learning_snapshot_free(p); }
};

DelSnap send(GcLearningSession *s, int32_t kind, int64_t arg0 = 0, const char *text = nullptr) {
    GcLearningEvent ev{};
    ev.kind = kind;
    ev.arg0 = arg0;
    ev.text = text;
    GcLearningSnapshot *snap = nullptr;
    int rc = gc_learning_handle(s, &ev, &snap);
    if (rc != 0) {
        fprintf(stderr, "  FAIL: gc_learning_handle rc=%d kind=%d\n", rc, kind);
        ++g_failures;
        return {nullptr};
    }
    return {snap};
}

DelSnap configure(GcLearningSession *s, uint64_t focus, int32_t mode, int32_t direction) {
    GcLearningEvent ev{};
    ev.kind = GC_LEV_CONFIGURE;
    ev.arg0 = static_cast<int64_t>(focus);
    ev.arg1 = mode;
    ev.arg2 = direction;
    GcLearningSnapshot *snap = nullptr;
    int rc = gc_learning_handle(s, &ev, &snap);
    if (rc != 0) {
        fprintf(stderr, "  FAIL: configure rc=%d\n", rc);
        ++g_failures;
        return {nullptr};
    }
    return {snap};
}

// 用当前快照身份回传一条翻译结果（approved=1）。
DelSnap receive(GcLearningSession *s, const GcLearningSnapshot *cur, const char *source_id,
                const char *source, const char *target, const char *resource) {
    GcLearningEvent ev{};
    ev.kind = GC_LEV_RECEIVE;
    ev.stamp_focus = cur->focus;
    ev.stamp_epoch = cur->epoch;
    ev.stamp_revision = cur->revision;
    ev.stamp_mode = cur->mode;
    ev.stamp_direction = cur->direction;
    ev.source_id = source_id;
    ev.source = source;
    ev.target = target;
    ev.resource = resource;
    ev.approved = 1;
    GcLearningSnapshot *snap = nullptr;
    int rc = gc_learning_handle(s, &ev, &snap);
    if (rc != 0) {
        fprintf(stderr, "  FAIL: receive rc=%d\n", rc);
        ++g_failures;
        return {nullptr};
    }
    return {snap};
}

// 用指定（可能过期）身份回传结果并返回新快照。
DelSnap receive_stamped(GcLearningSession *s, uint64_t focus, uint64_t epoch, uint64_t revision,
                        int32_t mode, int32_t direction, const char *source_id, const char *source,
                        const char *target, const char *resource, int approved) {
    GcLearningEvent ev{};
    ev.kind = GC_LEV_RECEIVE;
    ev.stamp_focus = focus;
    ev.stamp_epoch = epoch;
    ev.stamp_revision = revision;
    ev.stamp_mode = mode;
    ev.stamp_direction = direction;
    ev.source_id = source_id;
    ev.source = source;
    ev.target = target;
    ev.resource = resource;
    ev.approved = approved;
    GcLearningSnapshot *snap = nullptr;
    int rc = gc_learning_handle(s, &ev, &snap);
    if (rc != 0) {
        fprintf(stderr, "  FAIL: receive rc=%d\n", rc);
        ++g_failures;
        return {nullptr};
    }
    return {snap};
}

// 用当前快照身份回传结果并返回新快照（approved 可指定）。
DelSnap receive_approved(GcLearningSession *s, const GcLearningSnapshot *cur, const char *source_id,
                         const char *source, const char *target, const char *resource, int approved) {
    GcLearningEvent ev{};
    ev.kind = GC_LEV_RECEIVE;
    ev.stamp_focus = cur->focus;
    ev.stamp_epoch = cur->epoch;
    ev.stamp_revision = cur->revision;
    ev.stamp_mode = cur->mode;
    ev.stamp_direction = cur->direction;
    ev.source_id = source_id;
    ev.source = source;
    ev.target = target;
    ev.resource = resource;
    ev.approved = approved;
    GcLearningSnapshot *snap = nullptr;
    int rc = gc_learning_handle(s, &ev, &snap);
    if (rc != 0) {
        fprintf(stderr, "  FAIL: receive rc=%d\n", rc);
        ++g_failures;
        return {nullptr};
    }
    return {snap};
}

DelSnap failed(GcLearningSession *s, const GcLearningSnapshot *cur, const char *message) {
    GcLearningEvent ev{};
    ev.kind = GC_LEV_TRANSLATION_FAILED;
    ev.stamp_focus = cur->focus;
    ev.stamp_epoch = cur->epoch;
    ev.stamp_revision = cur->revision;
    ev.stamp_mode = cur->mode;
    ev.stamp_direction = cur->direction;
    ev.message = message;
    GcLearningSnapshot *snap = nullptr;
    int rc = gc_learning_handle(s, &ev, &snap);
    if (rc != 0) {
        fprintf(stderr, "  FAIL: translation_failed rc=%d\n", rc);
        ++g_failures;
        return {nullptr};
    }
    return {snap};
}

DelSnap set_issues(GcLearningSession *s, const GcLearningSnapshot *cur,
                   const GcIssue *issues, size_t count) {
    GcLearningEvent ev{};
    ev.kind = GC_LEV_SET_ISSUES;
    ev.stamp_focus = cur->focus;
    ev.stamp_epoch = cur->epoch;
    ev.stamp_revision = cur->revision;
    ev.stamp_mode = cur->mode;
    ev.stamp_direction = cur->direction;
    ev.issues = issues;
    ev.issue_count = count;
    GcLearningSnapshot *snap = nullptr;
    int rc = gc_learning_handle(s, &ev, &snap);
    if (rc != 0) {
        fprintf(stderr, "  FAIL: set_issues rc=%d\n", rc);
        ++g_failures;
        return {nullptr};
    }
    return {snap};
}

std::string source_text(const GcLearningSnapshot *s, size_t i) {
    return s != nullptr && i < s->source_count && s->sources != nullptr ? s->sources[i].text : "<none>";
}

std::string source_id(const GcLearningSnapshot *s, size_t i) {
    return s != nullptr && i < s->source_count && s->sources != nullptr ? s->sources[i].id : "<none>";
}

std::string cand_text(const GcLearningSnapshot *s, size_t field, bool target) {
    if (s == nullptr || field >= s->candidate_count || s->candidates == nullptr) return "<none>";
    return target ? s->candidates[field].target : s->candidates[field].source;
}

std::string commit_text(const GcLearningSnapshot *s) { return s != nullptr && s->commit_text ? s->commit_text : ""; }
std::string commit_recovery(const GcLearningSnapshot *s) { return s != nullptr && s->commit_recovery_raw ? s->commit_recovery_raw : ""; }

// ---------- 各规格场景 ----------

// 英→中英文缓冲：源表达式＝原文本身；结果按 stamp/源/approved 语义进入候选。
void test_en_to_zh_buffer_and_dispatch(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_EN_TO_ZH)};
    check(c.p != nullptr && c.p->translation_needed == 0, "空组合不请求翻译");
    check_eq(c.p ? c.p->revision : -1, 0, "新组合 revision 归零");
    DelSnap t{send(s, GC_LEV_TYPE, 0, "metting")};
    check_eq(t.p ? t.p->raw : "", "metting", "英文缓冲保留原样");
    check_eq(t.p ? t.p->preedit : "", "metting", "英→中预编辑行＝原文");
    check_eq(t.p ? t.p->translation_needed : 0, 1, "发布后请求翻译");
    check_eq(t.p ? t.p->translation_source_index : -1, 0, "请求指向首个源");
    check_eq(source_id(t.p, 0), "english:full", "英→中源 id");
    check_eq(source_text(t.p, 0), "metting", "英→中源文＝原文");
    check_eq(t.p ? static_cast<long long>(t.p->source_count) : -1, 1, "英→中单源");
    check_eq(t.p ? t.p->revision : -1, 1, "键入推进 revision");
    check_eq(t.p ? t.p->epoch : -1, 1, "configure 开启首个组合身份");
    check(t.p != nullptr && t.p->focus == 1 && t.p->mode == GC_LEARN_MODE_LEARNING &&
          t.p->direction == GC_LEARN_DIR_EN_TO_ZH, "身份字段随 configure");

    // 非 approved 成功结果不进入候选（豁免由平台按资源标记判定后传 approved）。
    DelSnap r0{receive_approved(s, t.p, "english:full", "metting", "会议", "review-list", 0)};
    check_eq(r0.p ? static_cast<long long>(r0.p->candidate_count) : -1, 0, "非 approved 结果不进候选");
    // 开发版资源按豁免进入候选。
    DelSnap r1{receive(s, t.p, "english:full", "metting", "会议", "quickmt-ct2-dev")};
    check_eq(r1.p ? static_cast<long long>(r1.p->candidate_count) : -1, 1, "approved 结果进入候选");
    check_eq(cand_text(r1.p, 0, true), "会议", "候选目标文本");
    check_eq(cand_text(r1.p, 0, false), "metting", "候选源文");
    check(r1.p != nullptr && r1.p->candidates != nullptr && r1.p->candidates[0].start == 0 &&
          r1.p->candidates[0].length == 7, "候选消费范围＝全源");
    check_eq(r1.p ? r1.p->status : "<none>", "", "候选到达后清除状态行");
    // 同源重复结果不重复进入候选；已显示候选不被替换。
    DelSnap r2{receive(s, r1.p, "english:full", "metting", "会议二", "quickmt-ct2-dev")};
    check_eq(r2.p ? static_cast<long long>(r2.p->candidate_count) : -1, 1, "同源重复结果被拒");
    check_eq(cand_text(r2.p, 0, true), "会议", "已显示候选不被迟到结果替换");

    // 回格：候选清空并重新发布（新 revision 使旧结果失效）。
    DelSnap b{send(s, GC_LEV_BACKSPACE)};
    check_eq(b.p ? b.p->raw : "", "mettin", "回格删除末字符");
    check_eq(b.p ? static_cast<long long>(b.p->candidate_count) : -1, 0, "组合变更清空候选");
    check_eq(b.p ? b.p->translation_needed : 0, 1, "回格后重新请求");
    check_eq(b.p ? b.p->revision : -1, r1.p->revision + 1, "回格推进 revision");
    // 旧 stamp 的结果迟到：拒绝（事件合法但无候选）。
    {
        DelSnap stale{receive_stamped(s, t.p->focus, t.p->epoch, r1.p->revision, t.p->mode,
                                      t.p->direction, "english:full", "mettin", "旧结果",
                                      "quickmt-ct2-dev", 1)};
        check_eq(stale.p ? static_cast<long long>(stale.p->candidate_count) : -1, 0,
                 "迟到结果不进候选");
    }
    // 新组合的结果重新进入。
    DelSnap r3{receive(s, b.p, "english:full", "mettin", "会面", "quickmt-ct2-dev")};
    check_eq(cand_text(r3.p, 0, true), "会面", "新组合结果进入候选");
    // id 匹配但源文不匹配的结果被拒。
    DelSnap r4{receive(s, r3.p, "english:full", "mettins", "错位", "quickmt-ct2-dev")};
    check_eq(r4.p ? static_cast<long long>(r4.p->candidate_count) : -1, 1, "源文不匹配的结果被拒");
    gc_learning_session_destroy(s);
}

// 失败路径：保留输入；候选存在或冻结时不覆盖状态。
void test_failure_keeps_input(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_EN_TO_ZH)};
    DelSnap t{send(s, GC_LEV_TYPE, 0, "metting")};
    DelSnap f{failed(s, t.p, "quickmt 模型未就绪；输入已保留")};
    check_eq(f.p ? f.p->status : "", "quickmt 模型未就绪；输入已保留", "失败状态行提示");
    check_eq(f.p ? f.p->raw : "", "metting", "失败保留输入");
    check_eq(f.p ? static_cast<long long>(f.p->candidate_count) : -1, 0, "失败不创建候选");
    check_eq(f.p ? f.p->translation_needed : 0, 0, "失败不触发新请求");
    // 组合变更后旧失败不再覆盖状态。
    DelSnap t2{send(s, GC_LEV_TYPE, 0, "x")};
    {
        GcLearningEvent ev{};
        ev.kind = GC_LEV_TRANSLATION_FAILED;
        ev.stamp_focus = t.p->focus;
        ev.stamp_epoch = t.p->epoch;
        ev.stamp_revision = t.p->revision;
        ev.stamp_mode = t.p->mode;
        ev.stamp_direction = t.p->direction;
        ev.message = "过期提示";
        GcLearningSnapshot *snap = nullptr;
        check(gc_learning_handle(s, &ev, &snap) == 0, "过期失败事件合法");
        check(snap != nullptr && std::string(snap->status) != "过期提示", "过期失败不覆盖状态");
        if (snap) gc_learning_snapshot_free(snap);
    }
    // 同 stamp 的后续失败可更新提示。
    DelSnap f2{failed(s, t2.p, "quickmt 翻译超时；输入已保留")};
    check_eq(f2.p ? f2.p->status : "", "quickmt 翻译超时；输入已保留", "同 stamp 失败可更新");
    // 候选存在时失败不覆盖状态（译文已在）。
    DelSnap r{receive(s, f2.p, "english:full", "mettingx", "会议", "quickmt-ct2-dev")};
    check_eq(r.p ? static_cast<long long>(r.p->candidate_count) : -1, 1, "结果先到");
    DelSnap f3{failed(s, r.p, "不应覆盖")};
    check(f3.p != nullptr && std::string(f3.p->status) != "不应覆盖", "候选存在时失败不覆盖状态");
    // 冻结（导航）后失败同样不覆盖。
    DelSnap n{send(s, GC_LEV_NAVIGATE, 1)};
    check(n.p != nullptr && n.p->frozen == 1, "导航冻结");
    DelSnap f4{failed(s, n.p, "冻结提示")};
    check(f4.p != nullptr && std::string(f4.p->status) != "冻结提示", "冻结后失败不覆盖状态");
    gc_learning_session_destroy(s);
}

// 学习候选选择：意图携带目标与恢复内容；全部消费后组合结束并开启新身份。
void test_choose_commit(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_EN_TO_ZH)};
    DelSnap t{send(s, GC_LEV_TYPE, 0, "hello")};
    DelSnap r{receive(s, t.p, "english:full", "hello", "你好", "quickmt-ct2-dev")};
    check_eq(r.p ? static_cast<long long>(r.p->candidate_count) : -1, 1, "候选就绪");
    // 越界选择：无效（平台按当前快照候选下标传递）。
    {
        GcLearningEvent ev{};
        ev.kind = GC_LEV_CHOOSE;
        ev.arg0 = 99;
        GcLearningSnapshot *snap = nullptr;
        check(gc_learning_handle(s, &ev, &snap) == 1, "越界候选选择拒绝（rc=1）");
        check(snap == nullptr, "无效选择无快照");
    }
    DelSnap ch{send(s, GC_LEV_CHOOSE, 0)};
    check_eq(commit_text(ch.p), "你好", "选择意图目标＝译文");
    check_eq(commit_recovery(ch.p), "hello", "意图恢复内容＝原输入");
    check(ch.p != nullptr && ch.p->commit_original == 0, "学习候选为翻译提交");
    check(ch.p != nullptr && ch.p->commit_epoch == r.p->epoch && ch.p->commit_revision == r.p->revision,
          "意图归属事件前状态");
    check_eq(ch.p ? ch.p->raw : "", "", "消费全部源后组合清空");
    check_eq(ch.p ? ch.p->epoch : -1, r.p->epoch, "全部消费不开启新组合（无 cancel）");
    check_eq(ch.p ? ch.p->revision : -1, r.p->revision + 1, "消费推进 revision");
    check_eq(ch.p ? ch.p->translation_needed : 1, 0, "空组合不再请求");
    gc_learning_session_destroy(s);
}

// ⌘Return 原文上屏：全文作为 original 意图；组合结束；仅一次。
void test_original_commit_once(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_EN_TO_ZH)};
    DelSnap t{send(s, GC_LEV_TYPE, 0, "hello")};
    DelSnap o{send(s, GC_LEV_ORIGINAL)};
    check_eq(commit_text(o.p), "hello", "原文上屏意图＝全文");
    check(o.p != nullptr && o.p->commit_original == 1, "original 标记");
    check(o.p != nullptr && o.p->commit_resource != nullptr &&
          std::string(o.p->commit_resource) == "original", "original 资源标记");
    check_eq(commit_recovery(o.p), "hello", "原文意图恢复内容＝全文");
    check(o.p != nullptr && o.p->commit_epoch == t.p->epoch && o.p->commit_revision == t.p->revision,
          "意图归属事件前状态");
    check_eq(o.p ? o.p->raw : "", "", "原文上屏后组合结束");
    check_eq(o.p ? o.p->epoch : -1, t.p->epoch + 1, "原文上屏开启新组合");
    // 空组合再取原文：无效。
    {
        GcLearningEvent ev{};
        ev.kind = GC_LEV_ORIGINAL;
        GcLearningSnapshot *snap = nullptr;
        check(gc_learning_handle(s, &ev, &snap) == 1, "空组合原文上屏无效（rc=1）");
        check(snap == nullptr, "无效事件无快照");
    }
    gc_learning_session_destroy(s);
}

// 512 标量上限：超限保留全部现有输入；emoji 按 1 标量计（UTF-16 不适用）。
void test_scalar_limit_and_unicode(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_EN_TO_ZH)};
    const std::string emoji = "\xF0\x9F\x98\x80"; // 😀＝1 标量（UTF-16 为 2，不适用）
    std::string many;
    for (int i = 0; i < 512; ++i) many += emoji;
    DelSnap t{send(s, GC_LEV_TYPE, 0, many.c_str())};
    check_eq(t.p ? static_cast<long long>(t.p->source_count) : -1, 1, "512 标量接受");
    check_eq(t.p ? static_cast<long long>(gc_utf8_scalar_count(t.p->raw, strlen(t.p->raw))) : -1,
             512, "raw 恰为 512 标量");
    DelSnap over{send(s, GC_LEV_TYPE, 0, "x")};
    check_eq(over.p ? static_cast<long long>(gc_utf8_scalar_count(over.p->raw, strlen(over.p->raw))) : -1,
             512, "超限保留全部现有输入");
    check(over.p != nullptr && std::string(over.p->status).find("512") != std::string::npos,
          "超限状态行提示");
    // 原文上屏带走 512 标量全文。
    DelSnap o{send(s, GC_LEV_ORIGINAL)};
    check_eq(o.p ? static_cast<long long>(gc_utf8_scalar_count(commit_text(o.p).data(),
                 commit_text(o.p).size())) : -1, 512, "原文意图含全文");
    // 组合字符（e＋组合锐音符＝2 标量）与数字标点混排。
    DelSnap c2{configure(s, 2, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_EN_TO_ZH)};
    DelSnap t2{send(s, GC_LEV_TYPE, 0, "e\xCC\x81 12!")};
    check_eq(source_text(t2.p, 0), "e\xCC\x81 12!", "组合字符与标点原样保留");
    // 回格删除一个字素簇（与历史 Swift String.removeLast 同语义）。
    DelSnap c3{configure(s, 3, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_EN_TO_ZH)};
    DelSnap t3{send(s, GC_LEV_TYPE, 0, "e\xCC\x81")}; // é＝2 标量 1 字素
    DelSnap b3{send(s, GC_LEV_BACKSPACE)};
    check_eq(b3.p ? b3.p->raw : "", "", "回格删除整个字素簇");
    // ZWJ 粘接表情（👩🏽‍💻＝7 标量 1 字素）整簇回退。
    DelSnap t4{send(s, GC_LEV_TYPE, 0,
                    "a\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x8F\xBD\xE2\x80\x8D\xF0\x9F\x92\xBB")};
    DelSnap b4{send(s, GC_LEV_BACKSPACE)};
    check_eq(b4.p ? b4.p->raw : "", "a", "ZWJ 粘接表情整簇回退");
    // 区域指示符对（旗标）整簇回退（前置字母 a 保留）。
    DelSnap t5{send(s, GC_LEV_TYPE, 0, "\xF0\x9F\x87\xAF\xF0\x9F\x87\xB5")}; // 🇯🇵
    DelSnap b5{send(s, GC_LEV_BACKSPACE)};
    check_eq(b5.p ? b5.p->raw : "", "a", "区域指示符对整簇回退");
    // 键帽序列（#＋VS16＋20E3）整簇回退。
    DelSnap t6{send(s, GC_LEV_TYPE, 0, "#\xEF\xB8\x8F\xE2\x83\xA3")};
    DelSnap b6{send(s, GC_LEV_BACKSPACE)};
    check_eq(b6.p ? b6.p->raw : "", "a", "键帽序列整簇回退");
    gc_learning_session_destroy(s);
}

// 中→英源文推导：字面/编码片段分别解码；备选源；部分消费。
void test_zh_to_en_source_derivation(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_ZH_TO_EN)};
    DelSnap t{send(s, GC_LEV_TYPE, 0, "nihc,12!kdhv")};
    check_eq(source_text(t.p, 0), "你好,12!开会", "片段解码合成全文");
    check_eq(source_id(t.p, 0), "chinese:full", "全文源 id");
    check_eq(t.p ? t.p->preedit : "", "你好,12!开会", "预编辑行＝解码中文");
    check_eq(t.p ? t.p->translation_needed : 0, 1, "发布后请求翻译");
    // 首段备选源（你；范围＝首段原码）。
    size_t partial_index = t.p ? t.p->source_count : 0;
    if (t.p != nullptr) {
        for (size_t i = 1; i < t.p->source_count; ++i) {
            if (source_text(t.p, i) == "你") {
                partial_index = i;
                check_eq(static_cast<long long>(t.p->sources[i].length), 2, "备选源范围＝首段原码长度");
                check(t.p->sources[i].start == 0, "备选源从组合起点消费");
                check(source_id(t.p, i).rfind("chinese:0:", 0) == 0, "备选源 id 前缀");
            }
        }
    }
    check(partial_index < (t.p ? t.p->source_count : 0), "存在首段备选源");
    // 备选源结果进入候选后选择：只消费覆盖范围，剩余输入继续发布。
    DelSnap r{receive(s, t.p, source_id(t.p, partial_index).c_str(), "你", "you", "quickmt-ct2-dev")};
    check_eq(r.p ? static_cast<long long>(r.p->candidate_count) : -1, 1, "备选源候选进入");
    check(r.p != nullptr && r.p->candidates != nullptr && r.p->candidates[0].length == 2,
          "候选只消费首段");
    DelSnap ch{send(s, GC_LEV_CHOOSE, 0)};
    check_eq(commit_text(ch.p), "you", "部分消费意图目标");
    check_eq(commit_recovery(ch.p), "nihc,12!kdhv", "恢复内容＝完整原输入");
    check_eq(ch.p ? ch.p->raw : "", "hc,12!kdhv", "剩余原码保留");
    check_eq(ch.p ? ch.p->translation_needed : 0, 1, "剩余输入继续请求");
    check_eq(source_id(ch.p, 0), "chinese:full", "剩余输入重新推导为全文源");
    gc_learning_session_destroy(s);
}

// 内核拒绝的片段（撇号开头）：与历史 decode 抛异常同源——以引擎错误返回
//（rc=2），平台侧走 viewError；「无完整候选」状态路径工厂词典不可达，
// 由 Swift 行为合同保留。
void test_zh_to_en_segment_engine_error(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_ZH_TO_EN)};
    {
        GcLearningEvent ev{};
        ev.kind = GC_LEV_TYPE;
        ev.text = "'";
        GcLearningSnapshot *snap = nullptr;
        check(gc_learning_handle(s, &ev, &snap) == 2, "撇号片段内核拒绝（rc=2）");
        check(snap == nullptr, "引擎错误无快照");
    }
    DelSnap ve{send(s, GC_LEV_VIEW_ERROR)};
    check_eq(ve.p ? ve.p->status : "", "引擎操作失败；输入已保留，请取消或保存草稿",
             "引擎失败状态行（平台 viewError 同款）");
    check_eq(ve.p ? ve.p->raw : "", "'", "输入保留");
    gc_learning_session_destroy(s);
}

// 导航/翻页：多候选移动高亮并冻结迟到结果；学习翻页不推进 revision。
void test_navigation_freeze_and_paging(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_ZH_TO_EN)};
    DelSnap t{send(s, GC_LEV_TYPE, 0, "nihc")};
    // 全文源＋首段备选源各取一条候选。
    DelSnap r1{receive(s, t.p, "chinese:full", "你好", "hello", "quickmt-ct2-dev")};
    check_eq(r1.p ? static_cast<long long>(r1.p->candidate_count) : -1, 1, "全文候选进入");
    size_t partial_index = r1.p ? r1.p->source_count : 0;
    if (r1.p != nullptr) {
        for (size_t i = 1; i < r1.p->source_count; ++i) {
            if (source_text(r1.p, i) == "你") { partial_index = i; break; }
        }
    }
    check(partial_index < (r1.p ? r1.p->source_count : 0), "存在备选源");
    DelSnap r2{receive(s, r1.p, source_id(r1.p, partial_index).c_str(), "你", "you", "quickmt-ct2-dev")};
    check_eq(r2.p ? static_cast<long long>(r2.p->candidate_count) : -1, 2, "备选候选进入");
    const uint64_t rev_before_nav = r2.p->revision;
    DelSnap n{send(s, GC_LEV_NAVIGATE, 1)};
    check_eq(n.p ? static_cast<long long>(n.p->selected) : -1, 1, "导航移动高亮");
    check_eq(n.p ? static_cast<long long>(n.p->revision) : -1, static_cast<long long>(rev_before_nav),
             "导航不推进 revision");
    // 冻结后同 stamp 结果被拒。
    DelSnap r3{receive(s, n.p, "chinese:full", "你好", "第三条", "quickmt-ct2-dev")};
    check_eq(r3.p ? static_cast<long long>(r3.p->candidate_count) : -1, 2, "冻结后新结果被拒");
    DelSnap pg{send(s, GC_LEV_PAGE, 1)};
    check_eq(pg.p ? static_cast<long long>(pg.p->page) : -1, 0, "无更多页钳制在 0");
    check_eq(pg.p ? static_cast<long long>(pg.p->selected) : -1, 0, "翻页重置页首高亮");
    check(pg.p != nullptr && pg.p->frozen == 1, "翻页冻结");
    gc_learning_session_destroy(s);
}

// configure/cancel 使旧身份失效；restore 取消后重放。
void test_identity_invalidation_and_restore(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_EN_TO_ZH)};
    DelSnap t{send(s, GC_LEV_TYPE, 0, "hello")};
    const uint64_t old_epoch = t.p->epoch;
    DelSnap c2{configure(s, 2, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_ZH_TO_EN)};
    check_eq(c2.p ? c2.p->epoch : -1, static_cast<long long>(old_epoch) + 1, "configure 开启新组合身份");
    check_eq(c2.p ? c2.p->raw : "", "", "configure 清空组合");
    check_eq(c2.p ? static_cast<long long>(c2.p->candidate_count) : -1, 0, "configure 清空候选");
    check_eq(c2.p ? c2.p->revision : -1, 0, "新组合 revision 归零");
    // restore：取消后按原始编码重放。
    DelSnap r{send(s, GC_LEV_RESTORE, 0, "nihc")};
    check_eq(source_text(r.p, 0), "你好", "恢复后重新推导源文");
    check_eq(r.p ? r.p->translation_needed : 0, 1, "恢复后请求翻译");
    check_eq(r.p ? r.p->raw : "", "nihc", "恢复原码");
    // cancel 清空并开启新身份。
    DelSnap x{send(s, GC_LEV_CANCEL)};
    check_eq(x.p ? x.p->raw : "", "", "cancel 清空");
    check_eq(x.p ? x.p->epoch : -1, r.p->epoch + 1, "cancel 开启新身份");
    gc_learning_session_destroy(s);
}

// 拼写问题结构：仅英→中学习态接受；原样往返不解释口径。
void test_issues_guard_and_roundtrip(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_EN_TO_ZH)};
    DelSnap t{send(s, GC_LEV_TYPE, 0, "metting")};
    GcIssue in[1];
    in[0].location = 0;
    in[0].length = 7;
    in[0].explanation = const_cast<char *>("疑似拼写问题；词典未识别此表达，不代表一定错误。");
    DelSnap i1{set_issues(s, t.p, in, 1)};
    check_eq(i1.p ? static_cast<long long>(i1.p->issue_count) : -1, 1, "英→中接受拼写问题");
    check(i1.p != nullptr && i1.p->issues != nullptr && i1.p->issues[0].location == 0 &&
          i1.p->issues[0].length == 7, "问题偏移原样往返");
    check(i1.p != nullptr && i1.p->issues != nullptr && i1.p->issues[0].explanation != nullptr &&
          std::string(i1.p->issues[0].explanation) == in[0].explanation, "说明文本往返");
    // 中→英方向不接受。
    DelSnap c2{configure(s, 2, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_ZH_TO_EN)};
    DelSnap t2{send(s, GC_LEV_TYPE, 0, "nihc")};
    DelSnap i2{set_issues(s, t2.p, in, 1)};
    check_eq(i2.p ? static_cast<long long>(i2.p->issue_count) : -1, 0, "中→英不接受拼写问题");
    // 普通（引擎态）不接受。
    DelSnap c3{configure(s, 3, GC_LEARN_MODE_NORMAL, GC_LEARN_DIR_ZH_TO_EN)};
    DelSnap i3{set_issues(s, c3.p, in, 1)};
    check_eq(i3.p ? static_cast<long long>(i3.p->issue_count) : -1, 0, "普通态不接受拼写问题");
    gc_learning_session_destroy(s);
}

// 普通态（引擎态）：与历史 ge_* 桥同语义——解码、完整选择提交、部分选择。
void test_normal_mode_engine_semantics(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_NORMAL, GC_LEARN_DIR_ZH_TO_EN)};
    DelSnap t{send(s, GC_LEV_TYPE, 0, "nihc")};
    check_eq(t.p ? t.p->preedit : "", "ni hao", "普通态预编辑＝展开全拼（ge 桥同语义）");
    check(t.p != nullptr && t.p->candidate_count >= 1 && t.p->candidates != nullptr, "候选非空");
    check_eq(t.p && t.p->candidates ? std::string(t.p->candidates[0].source_id) : "", "libime:0",
             "普通候选 id 带解码下标");
    check(t.p != nullptr && t.p->candidates != nullptr && t.p->candidates[0].completes == 1,
          "首选覆盖到末尾");
    check_eq(t.p && t.p->candidates ? std::string(t.p->candidates[0].target) : "", "你好",
             "工厂词典 nihc 首选＝你好");
    check_eq(t.p && t.p->candidates ? std::string(t.p->candidates[0].source) : "", "你好",
             "普通候选源文＝候选文本（无已暂存前缀）");
    check_eq(t.p ? t.p->translation_needed : 1, 0, "普通态不触发翻译");
    // 完整选择：提交意图＋组合结束。
    DelSnap ch{send(s, GC_LEV_CHOOSE, 0)};
    check_eq(commit_text(ch.p), "你好", "普通态完整选择提交");
    check_eq(commit_recovery(ch.p), "nihc", "普通态恢复内容＝原码");
    check_eq(ch.p ? ch.p->raw : "", "", "提交后组合结束");
    check(ch.p != nullptr && ch.p->commit_epoch == t.p->epoch, "意图归属提交前状态");
    // 部分选择：不提交，已暂存前缀进预编辑，后续候选范围接续。
    DelSnap t2{send(s, GC_LEV_TYPE, 0, "nihc")};
    int ni_index = -1;
    if (t2.p != nullptr && t2.p->candidates != nullptr) {
        for (size_t i = 0; i < t2.p->candidate_count; ++i) {
            if (std::string(t2.p->candidates[i].target) == "你" && t2.p->candidates[i].completes == 0) {
                ni_index = static_cast<int>(i);
                check_eq(static_cast<long long>(t2.p->candidates[i].start), 0, "部分候选从起点起");
                check_eq(static_cast<long long>(t2.p->candidates[i].length), 2, "部分候选覆盖首音节");
            }
        }
    }
    check(ni_index >= 0, "存在部分候选（你）");
    DelSnap ch2{send(s, GC_LEV_CHOOSE, ni_index)};
    check_eq(commit_text(ch2.p), "", "部分选择不提交");
    check(ch2.p != nullptr && std::string(ch2.p->typed_prefix) == "你", "已暂存前缀进入预编辑");
    check_eq(ch2.p ? static_cast<long long>(ch2.p->revision) : -1,
             static_cast<long long>(t2.p->revision) + 1, "部分选择推进 revision");
    // 续选剩余音节：完整提交。
    int hao_index = -1;
    if (ch2.p != nullptr && ch2.p->candidates != nullptr) {
        for (size_t i = 0; i < ch2.p->candidate_count; ++i) {
            if (std::string(ch2.p->candidates[i].target) == "好" && ch2.p->candidates[i].completes == 1) {
                hao_index = static_cast<int>(i);
            }
        }
    }
    check(hao_index >= 0, "剩余音节候选存在（好）");
    DelSnap ch3{send(s, GC_LEV_CHOOSE, hao_index)};
    check_eq(commit_text(ch3.p), "你好", "分段选择后完整提交");
    gc_learning_session_destroy(s);
}

// 引擎拒绝路径：普通态非法字符／非法 UTF-8／越界操作返回错误；状态行事件。
void test_invalid_requests_and_view_error(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_NORMAL, GC_LEARN_DIR_ZH_TO_EN)};
    {
        GcLearningEvent ev{};
        ev.kind = GC_LEV_TYPE;
        ev.text = "1"; // 普通态只收小写字母
        GcLearningSnapshot *snap = nullptr;
        check(gc_learning_handle(s, &ev, &snap) == 2, "普通态数字键入被内核拒绝（rc=2）");
        if (snap) gc_learning_snapshot_free(snap);
    }
    {
        GcLearningEvent ev{};
        ev.kind = GC_LEV_TYPE;
        ev.text = "\xF0\x9F"; // 非法 UTF-8（截断）
        GcLearningSnapshot *snap = nullptr;
        check(gc_learning_handle(s, &ev, &snap) == 1, "非法 UTF-8 拒绝（rc=1）");
        check(snap == nullptr, "参数错误无快照");
    }
    {
        GcLearningEvent ev{};
        ev.kind = GC_LEV_CHOOSE;
        ev.arg0 = 99;
        GcLearningSnapshot *snap = nullptr;
        check(gc_learning_handle(s, &ev, &snap) == 1, "越界候选选择拒绝（rc=1）");
        if (snap) gc_learning_snapshot_free(snap);
    }
    {
        GcLearningEvent ev{};
        ev.kind = GC_LEV_PAGE;
        ev.arg0 = 5;
        GcLearningSnapshot *snap = nullptr;
        check(gc_learning_handle(s, &ev, &snap) == 1, "普通态翻页非法增量拒绝（rc=1）");
        if (snap) gc_learning_snapshot_free(snap);
    }
    {
        GcLearningEvent ev{};
        ev.kind = GC_LEV_CONFIGURE;
        ev.arg1 = 7; // 非法模式
        GcLearningSnapshot *snap = nullptr;
        check(gc_learning_handle(s, &ev, &snap) == 1, "非法模式拒绝（rc=1）");
        if (snap) gc_learning_snapshot_free(snap);
    }
    DelSnap ve{send(s, GC_LEV_VIEW_ERROR)};
    check_eq(ve.p ? ve.p->status : "", "引擎操作失败；输入已保留，请取消或保存草稿",
             "引擎失败状态行");
    gc_learning_session_destroy(s);
}

// request_source：按下标重发请求；越界拒绝。
void test_request_source(const Env &env) {
    auto *s = make_session(env);
    DelSnap c{configure(s, 1, GC_LEARN_MODE_LEARNING, GC_LEARN_DIR_EN_TO_ZH)};
    DelSnap t{send(s, GC_LEV_TYPE, 0, "hello")};
    DelSnap r{send(s, GC_LEV_REQUEST_SOURCE, 0)};
    check_eq(r.p ? r.p->translation_needed : 0, 1, "按需重发请求");
    check_eq(r.p ? r.p->translation_source_index : -1, 0, "重发指向指定源");
    {
        GcLearningEvent ev{};
        ev.kind = GC_LEV_REQUEST_SOURCE;
        ev.arg0 = 5;
        GcLearningSnapshot *snap = nullptr;
        check(gc_learning_handle(s, &ev, &snap) == 1, "越界源请求拒绝（rc=1）");
        if (snap) gc_learning_snapshot_free(snap);
    }
    gc_learning_session_destroy(s);
}

// 创建参数与缺资源路径。
void test_create_validation(const Env &env) {
    {
        GcLearningSession *s = nullptr;
        check(gc_learning_session_create(nullptr, &s, nullptr, 0) == 1, "缺配置拒绝（rc=1）");
    }
    {
        GcLearningConfig cfg{};
        cfg.dict_path = "/nonexistent/sc.dict";
        cfg.model_path = env.modelPath.c_str();
        GcLearningSession *s = nullptr;
        char err[256] = {0};
        check(gc_learning_session_create(&cfg, &s, err, sizeof(err)) == 2, "词典缺失拒绝（rc=2）");
        check(err[0] != '\0', "资源错误带说明");
    }
    {
        GcLearningEvent ev{};
        ev.kind = GC_LEV_TYPE;
        GcLearningSnapshot *snap = nullptr;
        check(gc_learning_handle(nullptr, &ev, &snap) == 1, "空会话拒绝（rc=1）");
        check(snap == nullptr, "空会话无快照");
    }
}

} // namespace

int main() {
    Env env;
    if (!make_env(env)) {
        printf("gogaku learning test: SKIP\n");
        return 0;
    }
    test_en_to_zh_buffer_and_dispatch(env);
    test_failure_keeps_input(env);
    test_choose_commit(env);
    test_original_commit_once(env);
    test_scalar_limit_and_unicode(env);
    test_zh_to_en_source_derivation(env);
    test_zh_to_en_segment_engine_error(env);
    test_navigation_freeze_and_paging(env);
    test_identity_invalidation_and_restore(env);
    test_issues_guard_and_roundtrip(env);
    test_normal_mode_engine_semantics(env);
    test_invalid_requests_and_view_error(env);
    test_request_source(env);
    test_create_validation(env);
    if (g_failures == 0) {
        printf("gogaku learning test: all passed (%d checks)\n", g_checks);
        return 0;
    }
    printf("gogaku learning test: %d failures / %d checks\n", g_failures, g_checks);
    return 1;
}
