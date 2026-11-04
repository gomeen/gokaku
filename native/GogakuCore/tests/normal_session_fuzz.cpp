// 随机按键序列模糊测试：固定种子生成 ≥10 万个随机按键序列，检查一致性不变量。
// 与 ASan／UBSan 构建配合使用（cmake -DGOGAKU_SANITIZERS=on）：
//   无崩溃、无内存错误、无未定义行为；
//   快照合法（候选字段自洽）、上屏与预编辑文本是合法 UTF-8 且无控制字符；
//   组合结束后（Esc／焦点切换到新字段）状态完全清空。
// 覆盖事件：字母、大写、数字、标点（含引号交替）、Shift 单击、编辑键、翻页、
// 数字选择、焦点切换（换应用／换输入框）、无效 UTF-8、超长输入、emoji。
#include "gogaku_core.h"

#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

namespace {

int g_failures = 0;

// 合法 UTF-8 校验（严格：拒绝代理对、超编码、截断）。
bool valid_utf8(const char *data, size_t len) {
    size_t i = 0;
    while (i < len) {
        const unsigned char c = static_cast<unsigned char>(data[i]);
        size_t cont;
        if (c < 0x80) {
            cont = 0;
        } else if ((c & 0xE0) == 0xC0) {
            cont = 1;
            if (c < 0xC2) return false;  // 超编码
        } else if ((c & 0xF0) == 0xE0) {
            cont = 2;
        } else if ((c & 0xF8) == 0xF0) {
            cont = 3;
        } else {
            return false;
        }
        if (i + cont >= len) return false;  // 截断
        for (size_t k = 1; k <= cont; ++k) {
            if ((static_cast<unsigned char>(data[i + k]) & 0xC0) != 0x80) return false;
        }
        const unsigned char c1 = static_cast<unsigned char>(data[i + 1]);
        if (cont == 2 && c == 0xE0 && c1 < 0xA0) return false;      // 超编码
        if (cont == 2 && c == 0xED && c1 >= 0xA0) return false;     // 代理对
        if (cont == 3 && c == 0xF0 && c1 < 0x90) return false;      // 超编码
        if (cont == 3 && c == 0xF4 && c1 >= 0x90) return false;     // > U+10FFFF
        i += cont + 1;
    }
    return true;
}

bool no_control_chars(const char *s) {
    for (const unsigned char *p = reinterpret_cast<const unsigned char *>(s); *p != '\0'; ++p) {
        if (*p < 0x20 && *p != '\t') return false;
    }
    return true;
}

void check(bool ok, const std::string &what) {
    if (!ok) {
        ++g_failures;
        fprintf(stderr, "FAIL: %s\n", what.c_str());
    }
}

struct FuzzEnv {
    std::string dir;
    std::string dictPath;
    std::string modelPath;
    std::string wordsPath;
    bool ok = false;
};

bool make_env(FuzzEnv &env) {
    const char *dataDir = getenv("GOGAKU_CORE_TEST_DATA");
    std::string base = dataDir != nullptr && *dataDir != '\0' ? dataDir
        : std::string(getenv("HOME") == nullptr ? "" : getenv("HOME")) + "/Library/Caches/Gogaku/libime-1.1.17/data";
    env.modelPath = base + "/zh_CN.lm";
    // 与单测一致：用出厂模型＋最小出厂词典（无许可负担的自建词典会限制解码；
    // 模糊测试关心的是状态机与内存安全，用真实出厂词典更接近真实路径）。
    char dictOverride[4096];
    const char *dictEnv = getenv("GOGAKU_CORE_FUZZ_DICT");
    if (dictEnv != nullptr) {
        env.dictPath = dictEnv;
    } else {
        snprintf(dictOverride, sizeof(dictOverride), "%s/sc.dict", base.c_str());
        env.dictPath = dictOverride;
    }
    char tpl[] = "/tmp/gogaku-fuzz-XXXXXX";
    if (mkdtemp(tpl) == nullptr) return false;
    env.dir = tpl;
    env.wordsPath = env.dir + "/custom-words.tsv";
    FILE *probe = fopen(env.modelPath.c_str(), "rb");
    if (probe == nullptr) {
        // 复查 E1：缺数据必须显式区分于通过（ctest 将 SKIP 退出码 3 视为跳过）。
        fprintf(stderr, "SKIP: 未找到出厂模型 %s\n", env.modelPath.c_str());
        exit(3);
    }
    fclose(probe);
    env.ok = true;
    return true;
}

// 组合是否活跃（由调用方保存上一个快照得知；这里从核心快照字段推断）。
bool composing(const GcSnapshot *s) { return s != nullptr && s->composing != 0; }

}  // namespace

int main(int argc, char **argv) {
    FuzzEnv env;
    if (!make_env(env)) return env.ok ? 1 : 0;

    const uint64_t seed = argc > 1 ? strtoull(argv[1], nullptr, 10) : 20261031;
    const uint64_t sequences = argc > 2 ? strtoull(argv[2], nullptr, 10) : 100000;
    std::mt19937_64 rng(seed);

    GcNormalConfig cfg{};
    cfg.dict_path = env.dictPath.c_str();
    cfg.model_path = env.modelPath.c_str();
    cfg.user_dir = env.dir.c_str();
    cfg.custom_words_path = env.wordsPath.c_str();
    cfg.scheme = GC_SCHEME_XIAOHE;
    cfg.freq_enabled = 1;
    cfg.english_enabled = 1;
    GcNormalSession *s = nullptr;
    char err[256] = {0};
    if (gc_normal_session_create(&cfg, &s, err, sizeof(err)) != 0) {
        fprintf(stderr, "session create failed: %s\n", err);
        return 1;
    }

    const char *apps[] = {"app.one", "app.two", "com.raycast.raycast", "com.apple.Spotlight"};
    const char *fields[] = {"f1", "f2", "editor-3"};
    // 无效 UTF-8 样本：截断多字节、孤立续字节、超编码。
    const char *badTexts[] = {"\xff", "\xE4\xBD", "\xC0\x80", "\xE0\x80\x80", "a\xF0\x9F", "\x80\x80"};
    const char *emoji = "\xF0\x9F\x98\x80\xF0\x9F\x8E\x89";  // 😀🎉
    const char *puncts[] = {",", ".", "?", "!", ";", ":", "'", "\"", "/", "\\"};

    long long events = 0;
    // 与引擎语义一致：当前 app/field 跨序列持久（只有 FOCUS_SYNC 更新）。
    std::string lastApp, lastField;
    for (uint64_t seq = 0; seq < sequences; ++seq) {
        if (seq % 512 == 0) {
            // 周期性重建会话：覆盖销毁路径与重新加载（含 flush 落盘内容）。
            gc_normal_flush(s);
            gc_normal_session_destroy(s);
            if (gc_normal_session_create(&cfg, &s, err, sizeof(err)) != 0) {
                fprintf(stderr, "FAIL: recreate failed at seq %llu: %s\n",
                        static_cast<unsigned long long>(seq), err);
                ++g_failures;
                return 1;
            }
        }
        const char *app = apps[rng() % 4];
        const char *field = fields[rng() % 3];
        const int len = 1 + static_cast<int>(rng() % 24);
        bool wasComposing = false;
        for (int k = 0; k < len; ++k) {
            GcKeyEvent ev{};
            ev.app = app;
            ev.field = field;
            ev.time_ms = ++events;
            const uint32_t pick = static_cast<uint32_t>(rng() % 100);
            std::string text;
            if (pick < 40) {                                   // 小鹤字母
                text = std::string(1, static_cast<char>('a' + rng() % 26));
                ev.kind = GC_EV_TEXT;
            } else if (pick < 44) {                            // 大写
                text = std::string(1, static_cast<char>('A' + rng() % 26));
                ev.kind = GC_EV_TEXT;
            } else if (pick < 50) {                            // 数字
                text = std::string(1, static_cast<char>('0' + rng() % 10));
                ev.kind = GC_EV_TEXT;
            } else if (pick < 58) {                            // 标点
                text = puncts[rng() % 10];
                ev.kind = GC_EV_TEXT;
            } else if (pick < 60) {                            // emoji
                text = emoji;
                ev.kind = GC_EV_TEXT;
            } else if (pick < 62) {                            // 无效 UTF-8
                text = badTexts[rng() % 6];
                ev.kind = GC_EV_TEXT;
            } else if (pick < 66) {
                ev.kind = GC_EV_SPACE;
            } else if (pick < 70) {
                ev.kind = GC_EV_ENTER;
            } else if (pick < 74) {
                ev.kind = GC_EV_BACKSPACE;
            } else if (pick < 76) {
                ev.kind = GC_EV_DELETE_WORD;
            } else if (pick < 78) {
                ev.kind = GC_EV_ESC;
            } else if (pick < 82) {
                ev.kind = GC_EV_SHIFT_CLICK;
                ev.arg = static_cast<int64_t>(rng() % 2);
            } else if (pick < 86) {
                ev.kind = GC_EV_FOCUS_SYNC;                    // 换应用／换框
                app = apps[rng() % 4];
                field = fields[rng() % 3];
                ev.app = app;
                ev.field = field;
            } else if (pick < 93) {
                static const int32_t nav[] = {GC_EV_LEFT, GC_EV_RIGHT, GC_EV_UP, GC_EV_DOWN,
                                              GC_EV_HOME, GC_EV_END, GC_EV_PAGE_UP, GC_EV_PAGE_DOWN,
                                              GC_EV_CTRL_A, GC_EV_CTRL_B, GC_EV_CTRL_E,
                                              GC_EV_CTRL_F, GC_EV_CTRL_N, GC_EV_CTRL_P};
                ev.kind = nav[rng() % 14];
            } else {                                           // 数字选择
                text = std::string(1, static_cast<char>('1' + rng() % 9));
                ev.kind = GC_EV_TEXT;
            }
            ev.text = text.empty() ? nullptr : text.c_str();

            GcSnapshot *snap = nullptr;
            const int rc = gc_normal_handle(s, &ev, &snap);
            if (rc != 0 || snap == nullptr) {
                fprintf(stderr, "FAIL: handle rc=%d at seq=%llu event=%lld kind=%d text=%s\n",
                        rc, static_cast<unsigned long long>(seq), events, ev.kind,
                        ev.text != nullptr ? ev.text : "(null)");
                ++g_failures;
                continue;
            }
            // 不变量检查。
            check(valid_utf8(snap->commit, strlen(snap->commit)), "commit 是合法 UTF-8");
            check(valid_utf8(snap->preedit, strlen(snap->preedit)), "preedit 是合法 UTF-8");
            check(valid_utf8(snap->marked, strlen(snap->marked)), "marked 是合法 UTF-8");
            check(valid_utf8(snap->status, strlen(snap->status)), "status 是合法 UTF-8");
            check(no_control_chars(snap->commit), "commit 无控制字符");
            check(no_control_chars(snap->preedit), "preedit 无控制字符");
            check(no_control_chars(snap->marked), "marked 无控制字符");
            if (snap->composing && snap->total > 0) {
                check(snap->selected < snap->total, "selected 在候选范围内");
                check(snap->page < snap->page_count, "组合中有候选时页数有效");
                check(snap->count > 0 && snap->count <= snap->total, "本页候选数在总数范围内");
            } else if (!snap->composing) {
                check(snap->count == 0, "非组合状态无候选");
                check(snap->total == 0, "非组合状态候选总数为 0");
            }
            // 预编辑光标不变量：组合中 caret 是预编辑串的 UTF-8 字节偏移，
            // 不得超出字节长度（非组合时为 -1 表示不显示）。
            if (snap->composing) {
                const size_t preeditBytes = strlen(snap->preedit);
                check(snap->preedit_caret >= 0, "组合中 preedit_caret ≥ 0");
                check(static_cast<size_t>(snap->preedit_caret) <= preeditBytes,
                      "preedit_caret 不超 UTF-8 字节长度");
            } else {
                check(snap->preedit_caret == -1, "非组合状态 preedit_caret 为 -1");
            }
            // 平台契约：宿主 marked text 与候选窗预编辑是同一字符串，
            // preedit_caret 对两者同时适用。
            check(strcmp(snap->marked, snap->preedit) == 0, "marked 与 preedit 同一字符串");
            if (snap->preedit_caret >= 0) {
                check(static_cast<size_t>(snap->preedit_caret) <= strlen(snap->marked),
                      "preedit_caret 不超 marked 字节长度");
            }
            if (snap->commit[0] != '\0') {
                check(!composing(snap), "产生提交后组合结束");
                check(snap->count == 0 && snap->total == 0, "产生提交后无候选");
                check(snap->marked[0] == '\0' && snap->preedit[0] == '\0', "产生提交后字母清空");
                check(gc_normal_copy_raw(s, nullptr, 0) == 1, "产生提交后原编码清空");
            }
            // 组合结束后不得再携带候选页（复查 E3）。
            if (ev.kind == GC_EV_ESC || ev.kind == GC_EV_ENTER) {
                check(snap->count == 0 && snap->total == 0,
                      "组合结束事件后不携带候选");
            }
            // Esc 必须完全清空组合；焦点切换到新字段也必须清空（复查 E2：
            // 记录上一事件的 app/field，字段变化且此前在组合时断言清空）。
            if (ev.kind == GC_EV_ESC) {
                check(!composing(snap), "Esc 后组合清空");
                check(snap->count == 0 && snap->marked[0] == '\0' && snap->preedit[0] == '\0',
                      "Esc 后候选／字母／预编辑全部清空");
            }
            if (ev.kind == GC_EV_FOCUS_SYNC && wasComposing &&
                (std::string(app) != lastApp || std::string(field) != lastField)) {
                check(!composing(snap), "焦点切换到不同字段后组合清空");
                check(snap->count == 0 && snap->marked[0] == '\0', "切换后字母与候选清空");
            }
            if (ev.kind == GC_EV_FOCUS_SYNC) {
                // 与引擎语义一致：只有 FOCUS_SYNC 更新引擎的当前 app/field。
                lastApp = app;
                lastField = field;
            }
            wasComposing = composing(snap);
            gc_snapshot_free(snap);
        }
        if (g_failures > 20) { fprintf(stderr, "失败过多，提前结束\n"); break; }
    }

    gc_normal_flush(s);
    gc_normal_session_destroy(s);
    fprintf(stderr, "fuzz: %llu 序列 / %lld 事件，失败 %d — %s\n",
            static_cast<unsigned long long>(sequences), events, g_failures,
            g_failures == 0 ? "PASS" : "FAIL");
    return g_failures == 0 ? 0 : 2;
}
