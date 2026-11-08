// 翻译加固层回归：重复分类、繁→简归一、时间一致性、脚本校验、长度比率、保护扫描。
// 用例全部来自已观察到的真实失败（small100 门槛语义审阅、quickmt 2026-11-02 烟测）
// 与评测集（validation/translation-short-expressions.json）的陷阱类别。
#include <cstring>
#include <iostream>
#include <string>

#include "gogaku_core.h"

namespace {

int failures = 0;
int checks = 0;

// 字面量的字节长度（UTF-8 源码直接编译，避免手数汉字字节）。
#define LEN(lit) (lit), (sizeof(lit) - 1)

void expect_eq(long long actual, long long expected, const char *what) {
    ++checks;
    if (actual != expected) {
        ++failures;
        std::cerr << "FAIL " << what << ": expected " << expected << ", got " << actual << "\n";
    }
}

void expect_str(const char *actual, const std::string &expected, const char *what) {
    ++checks;
    if (expected != actual) {
        ++failures;
        std::cerr << "FAIL " << what << ": expected [" << expected << "], got [" << actual
                  << "]\n";
    }
}

std::string t2s(const char *text) {
    const size_t needed = gc_translate_t2s(text, strlen(text), nullptr, 0);
    std::string out(needed, '\0');
    const size_t written = gc_translate_t2s(text, strlen(text), out.data(), out.size());
    if (written != needed) {
        ++failures;
        std::cerr << "FAIL t2s size contract\n";
    }
    out.resize(needed - 1);  // 去 NUL 便于比较
    return out;
}

}  // namespace

int main() {
    // ---- 重复分类 ----
    expect_eq(gc_translate_repeat_classify(LEN("参加会议 会议")), 1, "repeat suffix 参加会议 会议");
    expect_eq(gc_translate_repeat_classify(LEN("出席会议 会议")), 1, "repeat suffix 出席会议 会议");
    expect_eq(gc_translate_repeat_classify(LEN("早上好 好 好")), 2, "repeat run 好好好");
    expect_eq(gc_translate_repeat_classify(LEN("明天见,你明天见")), 1, "repeat phrase 明天见x2");
    expect_eq(gc_translate_repeat_classify(LEN("thank you thank you")), 2, "repeat bigram en");
    expect_eq(gc_translate_repeat_classify(LEN("爱丽丝将于周五在北京与鲍勃见面。")), 0,
              "normal sentence zh");
    expect_eq(gc_translate_repeat_classify(LEN("I have a meeting tomorrow.")), 0,
              "normal sentence en");
    expect_eq(gc_translate_repeat_classify(LEN("会议")), 0, "single token");
    // 合法叠词不得当成复读（2026-11-04 加固层第二片误报修复）。
    expect_eq(gc_translate_repeat_classify(LEN("哈哈")), 0, "repeat legal 哈哈");
    expect_eq(gc_translate_repeat_classify(LEN("看看")), 0, "repeat legal 看看");
    expect_eq(gc_translate_repeat_classify(LEN("多多少少")), 0, "repeat legal AABB");
    expect_eq(gc_translate_repeat_classify(LEN("一个一个")), 0, "repeat legal 一个一个");
    expect_eq(gc_translate_repeat_classify(LEN("一天一天")), 0, "repeat legal 一天一天");
    expect_eq(gc_translate_repeat_classify(LEN("会议会议")), 2, "repeat still 会议会议");
    // 181 个 Q（small100 乱码编造）
    const std::string many_q(181, 'Q');
    expect_eq(gc_translate_repeat_classify(many_q.data(), many_q.size()), 2, "repeat 181 Q");
    expect_eq(gc_translate_repeat_classify(nullptr, 0), 0, "repeat null");

    // ---- 繁→简归一 ----
    expect_str(t2s("參加會議").c_str(), "参加会议", "t2s 參加會議");
    expect_str(t2s("謝謝你!").c_str(), "谢谢你!", "t2s 謝謝你");
    expect_str(t2s("你怎麼會這樣?").c_str(), "你怎么会这样?", "t2s 你怎麼會這樣");
    expect_str(t2s("爱丽丝将于周五在北京与鲍勃见面。").c_str(), "爱丽丝将于周五在北京与鲍勃见面。",
               "t2s 简体透传");
    expect_eq(gc_translate_has_traditional(LEN("參加會議")), 1, "has_traditional yes");
    expect_eq(gc_translate_has_traditional(LEN("参加会议")), 0, "has_traditional no");
    expect_eq(gc_translate_has_traditional(LEN("Gogaku v3.2.1")), 0, "has_traditional latin");
    // 缓冲不足返回所需长度且不写（參加會議→参加会议 共 12 字节＋NUL）
    char small_buf[4] = {};
    const size_t needed = gc_translate_t2s("參加會議", strlen("參加會議"), small_buf, sizeof(small_buf));
    expect_eq(static_cast<long long>(needed), 13, "t2s needed bytes");
    expect_eq(static_cast<long long>(small_buf[0]), 0, "t2s no write when insufficient");

    // ---- 时间一致性 ----
    expect_eq(gc_translate_time_check(LEN("Good morning."), LEN("早上好。")), 0, "time greeting ok");
    expect_eq(gc_translate_time_check(
                  LEN("会议改到下周二上午十点半，请不要邀请爱丽丝。"),
                  LEN("The meeting is changed to 10:30 a.m. next Tuesday, please don't invite Alice.")),
              0, "time zh->en 10:30 ok");
    expect_eq(gc_translate_time_check(LEN("I cannot open the attachment, please send it again."),
                                      LEN("我无法打开附件,请再次发送。")),
              0, "time none ok");
    expect_eq(gc_translate_time_check(LEN("The meeting is at 10:30 a.m."), LEN("会议在上午10:30。")),
              0, "time en->zh 10:30 ok");
    expect_eq(gc_translate_time_check(LEN("9 a.m. to 4 p.m."), LEN("下午9点至下午4点")), 1,
              "time am->下午 flip");
    expect_eq(gc_translate_time_check(LEN("10:30 a.m."), LEN("下午10:30")), 1,
              "time am->下午 flip short");
    expect_eq(gc_translate_time_check(LEN("上午十点半"), LEN("10:30 p.m.")), 1, "time 上午->pm flip");
    // small100 zh-long：十点半→10 a.m.（丢半）
    expect_eq(gc_translate_time_check(
                  LEN("会议改到下周二上午十点半。"),
                  LEN("The meeting is changed to 10 a.m. next Tuesday.")),
              3, "time 十点半->10 a.m. lost half");
    expect_eq(gc_translate_time_check(LEN("at half past ten"), LEN("十点。")), 3,
              "time half past lost");
    // 第二片误报修复：英文动词 am、合法上下午区间、数值与顺序。
    expect_eq(gc_translate_time_check(LEN("I am free in the afternoon."), LEN("我下午有空。")), 0,
              "time verb am not meridiem");
    expect_eq(gc_translate_time_check(LEN("I am allergic to peanuts."), LEN("我对花生过敏。")), 0,
              "time verb am no time facts");
    expect_eq(gc_translate_time_check(LEN("The meeting runs from 9 a.m. to 4 p.m."),
                                     LEN("会议从上午9点开到下午4点。")),
              0, "time legal am-to-pm range");
    expect_eq(gc_translate_time_check(LEN("The meeting runs from 9 a.m. to 4 p.m."),
                                     LEN("会议从下午9点开到下午4点。")),
              1, "time range am->pm flip");
    expect_eq(gc_translate_time_check(LEN("会议室是302。"), LEN("The meeting room is 302.")), 0,
              "time number preserved ascii");
    expect_eq(gc_translate_time_check(LEN("会议室是302。"), LEN("The meeting room is three hundred.")),
              2, "time number lost");
    expect_eq(gc_translate_time_check(LEN("会议室是三百零二。"), LEN("The meeting room is 302.")), 0,
              "time chinese numeral preserved");
    expect_eq(gc_translate_time_check(LEN("从9点到10点"), LEN("from 10 to 9")), 2,
              "time points lost but numbers kept");
    expect_eq(gc_translate_time_check(LEN("从9点到10点"), LEN("从10点到9点")), 4,
              "time number order");

    // ---- 脚本校验 ----
    expect_eq(gc_translate_script_check(LEN("参加会议"), 'Z'), 0, "script zh ok");
    expect_eq(gc_translate_script_check(LEN("参加会议 会议"), 'Z'), 0, "script zh with dup ok");
    expect_eq(gc_translate_script_check(LEN("參加會議"), 'Z'), 1, "script zh rejects traditional");
    expect_eq(gc_translate_script_check(LEN("Thank you very much."), 'E'), 0, "script en ok");
    expect_eq(gc_translate_script_check(LEN("谢谢"), 'E'), 1, "script en rejects han");
    expect_eq(gc_translate_script_check(LEN("详情见 https://example.com/abcdefghijklmnop"), 'Z'), 0,
              "script ignores url latin");
    expect_eq(gc_translate_script_check(LEN("open https://example.com/abcdefghijklmnop"), 'E'), 0,
              "script en url ok");
    expect_eq(gc_translate_script_check(LEN("   "), 'Z'), 2, "script empty-ish");
    // quickmt 繁体漂移样本（thanks→謝謝你!）
    expect_eq(gc_translate_script_check(LEN("謝謝你!"), 'Z'), 1, "script zh flags 謝謝你");

    // ---- 长度比率 ----
    expect_eq(gc_translate_length_check(LEN("谢谢"), LEN("Thank you very much.")), 0, "len zh->en ok");
    expect_eq(gc_translate_length_check(LEN("attend a meeting"), LEN("参加会议")), 0, "len en->zh ok");
    expect_eq(gc_translate_length_check(LEN("Good morning."), LEN("早上好")), 0, "len greeting ok");
    expect_eq(gc_translate_length_check(LEN("谢谢"), LEN("T")), 1, "len truncated en");
    expect_eq(gc_translate_length_check(LEN("谢谢"), LEN("")), 1, "len empty out");
    expect_eq(gc_translate_length_check(LEN("Gogaku v3.2.1"), LEN("Gogaku v3.2.1")), 0,
              "len brand passthrough");
    expect_eq(gc_translate_length_check(LEN("attend a meeting"), LEN("参加会议会议会议会议会议会议会议会议会议会议")),
              2, "len bloated en->zh");
    expect_eq(gc_translate_length_check(LEN("打开 https://example.com/abcdefghijklmnopqrstuvwxyz"),
                                     LEN("open https://example.com/abcdefghijklmnopqrstuvwxyz")),
              0, "len ignores url");

    // ---- 保护扫描 ----
    GcTextRange ranges[16];
    const std::string src1 = "Please review Gogaku v2.1 before Friday.";
    size_t n = gc_translate_protection_scan(src1.data(), src1.size(), ranges, 16);
    expect_eq(static_cast<long long>(n), 2, "protect Gogaku+v2.1 count");
    if (n >= 2) {
        expect_str(src1.substr(ranges[0].begin, ranges[0].end - ranges[0].begin).c_str(), "Gogaku",
                   "protect Gogaku range");
        expect_str(src1.substr(ranges[1].begin, ranges[1].end - ranges[1].begin).c_str(), "v2.1",
                   "protect v2.1 range");
    }
    const std::string src2 = "Alice will meet Bob in Beijing";
    n = gc_translate_protection_scan(src2.data(), src2.size(), ranges, 16);
    // 句首 Alice 不作候选（v1 局限）；句中 Bob（人名）与 Beijing（地名实体）都在候选范围，
    // 处置方式（品牌原样保留 / 人名音译对齐）由翻译管线按类别决定。
    expect_eq(static_cast<long long>(n), 2, "protect Bob+Beijing count");
    if (n >= 2) {
        expect_str(src2.substr(ranges[0].begin, ranges[0].end - ranges[0].begin).c_str(), "Bob",
                   "protect Bob range");
        expect_str(src2.substr(ranges[1].begin, ranges[1].end - ranges[1].begin).c_str(), "Beijing",
                   "protect Beijing range");
    }
    const std::string src3 = "Open the file in VS Code";
    n = gc_translate_protection_scan(src3.data(), src3.size(), ranges, 16);
    expect_eq(static_cast<long long>(n), 2, "protect VS/Code count");
    const std::string src4 = "Open https://example.com/a?x=1.";
    n = gc_translate_protection_scan(src4.data(), src4.size(), ranges, 16);
    expect_eq(static_cast<long long>(n), 1, "protect URL count");
    if (n >= 1) {
        expect_str(src4.substr(ranges[0].begin, ranges[0].end - ranges[0].begin).c_str(),
                   "https://example.com/a?x=1", "protect URL range");
    }
    const std::string src5 = "I have a meeting tomorrow.";
    n = gc_translate_protection_scan(src5.data(), src5.size(), ranges, 16);
    expect_eq(static_cast<long long>(n), 0, "protect plain sentence none");
    // 句首已知品牌（Round2 已知错误：Gogaku 在句首未进保护词）
    const std::string src6 = "Gogaku is a keyboard for input.";
    n = gc_translate_protection_scan(src6.data(), src6.size(), ranges, 16);
    expect_eq(static_cast<long long>(n), 1, "protect sentence-initial brand");
    if (n >= 1) {
        expect_str(src6.substr(ranges[0].begin, ranges[0].end - ranges[0].begin).c_str(), "Gogaku",
                   "protect sentence-initial Gogaku range");
    }
    const std::string src7 = "push the change to GitHub today";
    n = gc_translate_protection_scan(src7.data(), src7.size(), ranges, 16);
    expect_eq(static_cast<long long>(n), 1, "protect mid-sentence brand");
    n = gc_translate_protection_scan(src1.data(), src1.size(), nullptr, 0);
    expect_eq(static_cast<long long>(n), 2, "protect null buffer count");

    // ---- 非法 UTF-8 不崩溃且透传 ----
    const char bad[] = "\xFF\xFE 參會";
    expect_eq(gc_translate_has_traditional(bad, strlen(bad)), 1, "invalid utf8 still finds trad");
    expect_str(t2s("\xFF\xFE 參會").c_str(), "\xFF\xFE 参会", "t2s passthrough invalid bytes");

    std::cout << "translate_safety: " << checks << " checks, " << failures << " failures\n";
    return failures == 0 ? 0 : 1;
}
