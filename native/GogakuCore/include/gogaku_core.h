#ifndef GOGAKU_CORE_H
#define GOGAKU_CORE_H
/*
 * Gogaku 共享核心 C ABI（版本 2）。
 *
 * 合同（见 docs/implementation-plan.md「统一接口与所有权」）：
 * - 显式整数与 UTF-8＋长度；字符串长度以字节计；所有字符串以 NUL 结尾便于跨语言拷贝。
 * - 库内部分配的内存由同一库释放；异常、STL 对象和 C++ 运行时对象不跨 ABI。
 * - 平台输入先转换为统一事件；本 ABI 不含 IMK／TSF 对象、窗口、系统键码或宿主插字。
 * - Unicode 标量计数用于 512 标量输入上限；小鹤原始偏移、Unicode 标量与 UTF-16
 *   范围分别定义，不得混用。
 * - 加载方必须先用 gc_abi_check 确认版本，再调用其他函数。
 * - 会话不是线程安全的：同一会话由一个平台串行队列拥有（输入法主队列）。
 * - 核心不建线程、不起定时器；持久化防抖由平台调用 gc_normal_flush 完成。
 *
 * 版本 2 新增：普通模式会话（组合状态机＋libime 绑定）、自定义词语存储与校验。
 * 版本 1 函数保持原样。
 *
 * 附加只读接口（不改动任何已有结构布局与函数签名，旧加载方不受影响）：
 * gc_normal_copy_raw —— 取当前组合的原始编码，供平台存草稿与恢复。
 */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  if defined(GOGAKU_CORE_BUILDING)
#    define GOGAKU_CORE_EXPORT __declspec(dllexport)
#  else
#    define GOGAKU_CORE_EXPORT __declspec(dllimport)
#  endif
#else
#  define GOGAKU_CORE_EXPORT __attribute__((visibility("default")))
#endif

#define GOGAKU_CORE_ABI_VERSION 2

/* 返回本库实现的 ABI 版本。 */
GOGAKU_CORE_EXPORT int32_t gc_abi_version(void);

/* expected 为加载方编译期假设的版本；0 表示兼容，1 表示版本不符。 */
GOGAKU_CORE_EXPORT int32_t gc_abi_check(int32_t expected);

/* 统计 UTF-8 缓冲中的 Unicode 标量个数（长度以字节计，不要求 NUL 结尾）。
 * text 为 NULL 且 length>0，或缓冲含非法 UTF-8 序列时返回 -1；
 * text 为 NULL 且 length==0 返回 0。 */
GOGAKU_CORE_EXPORT int64_t gc_utf8_scalar_count(const char *text, size_t length);

/* ---------- 普通模式会话 ---------- */

typedef enum GcScheme {
    GC_SCHEME_XIAOHE = 0,
    GC_SCHEME_FULLPINYIN = 1
} GcScheme;

/* 模糊音位标志，对应规格 9 对；默认全关（0）。 */
enum {
    GC_FUZZY_Z_ZH = 1u << 0,
    GC_FUZZY_C_CH = 1u << 1,
    GC_FUZZY_S_SH = 1u << 2,
    GC_FUZZY_N_L = 1u << 3,
    GC_FUZZY_F_H = 1u << 4,
    GC_FUZZY_L_R = 1u << 5,
    GC_FUZZY_AN_ANG = 1u << 6,
    GC_FUZZY_EN_ENG = 1u << 7,
    GC_FUZZY_IN_ING = 1u << 8
};

typedef enum GcEventKind {
    GC_EV_TEXT = 0,       /* text：单个或多个可打印标量（字母／数字／标点） */
    GC_EV_SPACE,
    GC_EV_ENTER,
    GC_EV_ESC,
    GC_EV_BACKSPACE,
    GC_EV_DELETE_WORD,    /* Control＋Backspace：删除个人学习词 */
    GC_EV_LEFT,
    GC_EV_RIGHT,
    GC_EV_UP,
    GC_EV_DOWN,
    GC_EV_HOME,
    GC_EV_END,
    GC_EV_PAGE_UP,
    GC_EV_PAGE_DOWN,
    GC_EV_CTRL_A,
    GC_EV_CTRL_B,
    GC_EV_CTRL_E,
    GC_EV_CTRL_F,
    GC_EV_CTRL_N,
    GC_EV_CTRL_P,
    GC_EV_SHIFT_CLICK,    /* 单击 Shift（按住期间无其他键且 <600ms 由平台判定）；arg：0 左 1 右 */
    GC_EV_QUICK_ADD,      /* 快速添加快捷键（默认 Control＋Shift＋A） */
    GC_EV_FOCUS_SYNC      /* 焦点／应用同步：app、field 为当前值 */
} GcEventKind;

typedef struct GcKeyEvent {
    int32_t kind;
    int64_t arg;          /* 事件参数（如 SHIFT_CLICK 侧别） */
    int64_t time_ms;      /* 平台单调毫秒时钟，用于快速添加 60 秒窗口 */
    const char *text;     /* GC_EV_TEXT 的 UTF-8 内容 */
    const char *app;      /* 当前前台应用标识（bundle id 等），可为 NULL */
    const char *field;    /* 平台给出的不透明字段标识，可为 NULL */
} GcKeyEvent;

/* 候选来源类别。 */
enum {
    GC_CAND_CHINESE = 0,     /* libime 普通候选（含出厂与已学习） */
    GC_CAND_ENGLISH = 1,     /* 英文候选（整词或前缀补全） */
    GC_CAND_SHORTCODE = 2,   /* 自定义短码短语 */
    GC_CAND_PINYIN_WORD = 3, /* 自定义拼音词 */
    GC_CAND_LEARNED = 4      /* 本会话标记为可删除的个人学习词 */
};

typedef struct GcCandidate {
    char *text;           /* 选中后上屏的文本（含已暂存前缀） */
    char *gloss;          /* 释义注释；无数据时为空串 */
    int32_t kind;         /* GC_CAND_* */
    int32_t deletable;    /* 1 表示 Control＋Backspace 可从个人学习词删除 */
    int32_t completes;    /* 1 = 覆盖到当前输入末尾（数字选它会上屏） */
} GcCandidate;

typedef struct GcSnapshot {
    char *commit;          /* 本次事件要一次上屏的文本；空串表示无提交 */
    char *marked;          /* 宿主 marked text 显示内容；空串表示清除。
                             * 与 preedit 始终是同一字符串（平台可用同一 carets） */
    char *preedit;         /* 候选窗预编辑行（显示形态）；空串表示不显示 */
    int64_t preedit_caret; /* 预编辑中的光标字节偏移（UTF-8 字节，对 marked 同样适用）；
                             * -1 表示不显示 */
    int64_t typed_prefix_len; /* 预编辑开头已暂存（已转中文）前缀的标量个数；0 = 无 */
    int32_t consumed;      /* 1 = 核心已处理；0 = 平台应交给宿主 */
    int32_t composing;     /* 组合进行中（含已暂存分段） */
    int32_t english;       /* 0 中文，1 手动临时英文，2 按应用默认英文 */
    int32_t toast;         /* 0 无；1 「中」提示；2 「英」提示（Shift 单击 0.8 秒） */
    int32_t beep;          /* 1 = 平台应提示无效操作 */
    char *status;          /* 瞬态说明（删词结果、快速添加结果等）；空串 = 无 */
    GcCandidate *candidates;
    size_t count;          /* 本页候选数 */
    size_t selected;       /* 全局高亮下标 */
    size_t page;
    size_t page_count;
    size_t total;          /* 候选总数（合并后） */
} GcSnapshot;

GOGAKU_CORE_EXPORT void gc_snapshot_free(GcSnapshot *snapshot);

typedef struct GcNormalConfig {
    const char *dict_path;         /* libime 出厂词典（二进制）；必填 */
    const char *model_path;        /* libime 语言模型；必填 */
    const char *user_dir;          /* 调频与已学习词目录；NULL = 不持久化（测试用） */
    const char *custom_words_path; /* custom-words.tsv；NULL = 无自定义词 */
    const char *english_words_path;/* 英文词表（每行 word [count]，按频率降序）；NULL = 无英文候选 */
    const char *gloss_path;        /* 释义表（word\t注释 TSV）；NULL = 无注释 */
    int32_t scheme;                /* GcScheme */
    uint32_t fuzzy_mask;           /* GC_FUZZY_* 位或 */
    int32_t full_pinyin_preedit;   /* 1 = 展开全拼 ni'hao（默认），0 = 原码 */
    int32_t freq_enabled;          /* 中文调频开关 */
    int32_t english_enabled;       /* 中文模式下英文候选开关 */
} GcNormalConfig;

typedef struct GcNormalSession GcNormalSession;

/* 创建会话。err/err_len 可为 NULL；非 NULL 时写入可读问题
 * （资源缺失、custom-words.tsv 损坏已备份等）。返回 0 成功，1 参数错误，2 资源错误。 */
GOGAKU_CORE_EXPORT int gc_normal_session_create(const GcNormalConfig *config,
                                                GcNormalSession **out,
                                                char *err, size_t err_len);
GOGAKU_CORE_EXPORT void gc_normal_session_destroy(GcNormalSession *session);

/* 处理一个输入事件；*out 必须用 gc_snapshot_free 释放。返回 0 成功，1 参数错误。 */
GOGAKU_CORE_EXPORT int gc_normal_handle(GcNormalSession *session,
                                        const GcKeyEvent *event,
                                        GcSnapshot **out);

/* 设置按应用默认英文列表（bundle id 数组）。返回 0 成功。 */
GOGAKU_CORE_EXPORT int gc_normal_set_app_defaults(GcNormalSession *session,
                                                  const char *const *apps,
                                                  size_t count);
/* 设置快速添加排除应用列表。返回 0 成功。 */
GOGAKU_CORE_EXPORT int gc_normal_set_excluded_apps(GcNormalSession *session,
                                                   const char *const *apps,
                                                   size_t count);
/* 运行时更新配置（设置变更；输入法收到通知后调用）。返回 0 成功。 */
GOGAKU_CORE_EXPORT int gc_normal_update(GcNormalSession *session, int32_t scheme,
                                        uint32_t fuzzy_mask,
                                        int32_t full_pinyin_preedit,
                                        int32_t freq_enabled);
/* custom-words.tsv 变更后重载。返回 0 成功，2 文件损坏（已按空表启动）。 */
GOGAKU_CORE_EXPORT int gc_normal_reload_custom_words(GcNormalSession *session);

/* 立即持久化调频与已学习词（若脏）。平台 30 秒防抖调用。返回 0 成功。 */
GOGAKU_CORE_EXPORT int gc_normal_flush(GcNormalSession *session);

/* 最近一次可快速添加的完整上屏是否存在（供菜单态显示）。 */
GOGAKU_CORE_EXPORT int32_t gc_normal_quick_add_available(GcNormalSession *session);

/* 复制当前组合的原始编码（context 的 userInput，例如小鹤 "nihc"）。
 *
 * 用途：预编辑可能显示为展开全拼（"ni'hao"），草稿若按显示文本重输会损坏；
 * 平台在每次 handle 之后读一次本值，存为草稿的 rawInput。
 *
 * 协议：返回值 = 所需字节数（含结尾 NUL）。
 *   - session 为 NULL 或出错时返回 0（错误）。
 *   - buffer 为 NULL 或 capacity 不足时只返回所需字节数，不复制。
 *   - 容量足够时复制并以 NUL 结尾，仍返回所需字节数。
 *   - 组合结束（提交／Esc／焦点切换清空）后内容为空串，返回 1。
 * 返回的原始编码包含已暂存（已转中文）部分对应的原键，重输可复现同一组合。
 *
 * 本函数为纯新增，不改动 GcSnapshot／GcKeyEvent 等任何结构布局。 */
GOGAKU_CORE_EXPORT size_t gc_normal_copy_raw(GcNormalSession *session, char *buffer, size_t capacity);

/* ---------- 自定义词语存储（设置进程使用） ---------- */

enum { GC_WORD_SHORTCODE = 0, GC_WORD_PINYIN = 1 };

typedef struct GcCustomWord {
    int32_t kind;      /* GC_WORD_* */
    int32_t enabled;   /* 1 启用 */
    char *code;        /* 短码编码；拼音词为空串 */
    char *pinyin;      /* 拼音词读音（ni'hao 形式）；短码为空串 */
    char *content;     /* 上屏内容 */
} GcCustomWord;

typedef struct GcCustomWordList {
    GcCustomWord *words;
    size_t count;
    int32_t corrupt;   /* 读取时文件损坏：已备份为 <path>.corrupt 并从空表启动 */
} GcCustomWordList;

/* 读取；文件不存在视为空表（corrupt=0）。返回 0 成功，1 参数错误。 */
GOGAKU_CORE_EXPORT int gc_custom_words_read(const char *path, GcCustomWordList **out);
/* 原子写入（临时文件＋rename，权限 0600，带版本行）。返回 0 成功。 */
GOGAKU_CORE_EXPORT int gc_custom_words_write(const char *path,
                                             const GcCustomWordList *list);
GOGAKU_CORE_EXPORT void gc_custom_word_list_free(GcCustomWordList *list);

/* 校验单条词条；err/err_len 可为 NULL，写入具体原因。返回 0 合法，1 非法。 */
GOGAKU_CORE_EXPORT int gc_custom_words_validate(int32_t kind, const char *code,
                                                const char *pinyin,
                                                const char *content,
                                                char *err, size_t err_len);

/* 用 libime 出厂词典给出每个汉字的常用读音，结果为撇号分隔全拼（如 hui'yi）。
 * 首次调用会导出词典文本并缓存单字读音（仅设置进程使用，输入法进程不调用）。
 * 返回 0 成功（*out 需 free），1 参数错误，2 词典不可用或存在无读音字符。 */
GOGAKU_CORE_EXPORT int gc_custom_pinyin_lookup(const char *dict_path,
                                               const char *hanzi, char **out);

/* ---------- 翻译加固层（2026-11-02 模型路线裁决的处置手段；附加接口） ----------
 *
 * 处置口径：修正或安全拦截均算已处置——回退为显示原文不译、错误译文不进入
 * 默认候选即达标（docs/implementation-plan.md §四；手段证据见
 * docs/research-translation-model-unblock.md §四/§七）。
 * 纯文本规则，无 libime 依赖；UTF-8＋字节长度；非法 UTF-8 原样透传不崩溃；
 * 无全局状态；v1 局限（单字级 t2s、句首大写词不作候选等）见调研文档。
 */

/* 输出重复分类：0=正常，1=可疑（后缀复制/短语复现），
 * 2=严重（同词元连续≥3 次/二元组连续重复，如 181 个 Q）。 */
GOGAKU_CORE_EXPORT int32_t gc_translate_repeat_classify(const char *text, size_t length);

/* 繁→简归一（单字级，OpenCC TSCharacters 生成表）。返回所需字节数（含 NUL）；
 * buffer 非 NULL 且容量足够时写出，不足时不写。text 为 NULL 或 length=0 时
 * 仅返回 1。 */
GOGAKU_CORE_EXPORT size_t gc_translate_t2s(const char *text, size_t length,
                                           char *buffer, size_t buffer_capacity);

/* 是否含繁体专用字：0=无，1=有（需归一）。 */
GOGAKU_CORE_EXPORT int32_t gc_translate_has_traditional(const char *text, size_t length);

/* 时间一致性：0=一致或不涉及，1=时段矛盾（9 a.m.→下午9点），
 * 2=显式数字时间丢失，3=半点丢失（十点半→10 点整）。 */
GOGAKU_CORE_EXPORT int32_t gc_translate_time_check(const char *source, size_t source_length,
                                                   const char *output, size_t output_length);

/* 脚本校验：expected 'Z'=简体中文（汉字主导且无繁体专用字），
 * 'E'=英语（拉丁字母主导）。0=通过，1=不符，2=空/无文字。 */
GOGAKU_CORE_EXPORT int32_t gc_translate_script_check(const char *text, size_t length,
                                                     char expected);

/* 长度比率（粗网）：0=合理，1=疑似截断，2=疑似膨胀，2 同用于参数错误。 */
GOGAKU_CORE_EXPORT int32_t gc_translate_length_check(const char *source, size_t source_length,
                                                     const char *output, size_t output_length);

typedef struct GcTextRange {
    size_t begin;  /* UTF-8 字节偏移（含） */
    size_t end;    /* UTF-8 字节偏移（不含） */
} GcTextRange;

/* 保护候选扫描：URL／版本号（v3.2.1）／驼峰或异形大写（VSCode、iPhone）／
 * 全大写（VS）／句中大写词（Bob、Gogaku；停用词表排除可译普通词）。
 * 句首大写词不作候选（v1 局限，品牌靠调用方词表）。返回完整候选个数；
 * 超出 capacity 的不写 out_ranges（可为 NULL）。 */
GOGAKU_CORE_EXPORT size_t gc_translate_protection_scan(const char *text, size_t length,
                                                       GcTextRange *out_ranges,
                                                       size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
