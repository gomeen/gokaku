// 由 scripts/generate-core-cases.py 从 probes/input-engine-cases.json
// ＋ probes/input-engine-holdout.json 生成；不要手改。
#ifndef GOGAKU_QUALITY_CASES_INC
#define GOGAKU_QUALITY_CASES_INC

struct QualityCase {
    const char *id;
    const char *keys;        // 小鹤按键序列（ASCII）
    const char *const *targets;
    size_t target_count;
    int syllables;
};

static const char *const kTargets0[] = {"你好"};
static const char *const kTargets1[] = {"谢谢"};
static const char *const kTargets2[] = {"再见"};
static const char *const kTargets3[] = {"早上好"};
static const char *const kTargets4[] = {"没关系"};
static const char *const kTargets5[] = {"我知道"};
static const char *const kTargets6[] = {"想一想"};
static const char *const kTargets7[] = {"今天晚上有空"};
static const char *const kTargets8[] = {"你吃饭了吗"};
static const char *const kTargets9[] = {"学习英语"};
static const char *const kTargets10[] = {"我想学英语"};
static const char *const kTargets11[] = {"我没有听懂"};
static const char *const kTargets12[] = {"请再说一遍"};
static const char *const kTargets13[] = {"开会"};
static const char *const kTargets14[] = {"明天下午开会"};
static const char *const kTargets15[] = {"请把文件发给我"};
static const char *const kTargets16[] = {"我们下周再讨论"};
static const char *const kTargets17[] = {"这个方案可以"};
static const char *const kTargets18[] = {"发送邮件"};
static const char *const kTargets19[] = {"不要发送邮件"};
static const char *const kTargets20[] = {"请把明天下午开会的时间发给我"};
static const char *const kTargets21[] = {"我想每天花一点时间学习英语"};
static const char *const kTargets22[] = {"数据库"};
static const char *const kTargets23[] = {"人工智能"};
static const char *const kTargets24[] = {"量子计算"};
static const char *const kTargets25[] = {"小鹤双拼"};
static const char *const kTargets26[] = {"英伟达"};
static const char *const kTargets27[] = {"台积电"};
static const char *const kTargets28[] = {"飞书"};
static const char *const kTargets29[] = {"深度求索"};
static const char *const kTargets30[] = {"美团"};
static const char *const kTargets31[] = {"会议", "回忆"};
static const char *const kTargets32[] = {"银行"};
static const char *const kTargets33[] = {"行走"};
static const char *const kTargets34[] = {"重庆"};
static const char *const kTargets35[] = {"音乐"};
static const char *const kTargets36[] = {"安全"};
static const char *const kTargets37[] = {"偶尔"};
static const char *const kTargets38[] = {"方案"};
static const char *const kTargets39[] = {"爱好"};
static const char *const kTargets40[] = {"好久不见"};
static const char *const kTargets41[] = {"太感谢了"};
static const char *const kTargets42[] = {"明天见"};
static const char *const kTargets43[] = {"你最近怎么样"};
static const char *const kTargets44[] = {"我有点累"};
static const char *const kTargets45[] = {"保重"};
static const char *const kTargets46[] = {"恭喜你"};
static const char *const kTargets47[] = {"抱歉来晚了"};
static const char *const kTargets48[] = {"要不要一起吃个饭"};
static const char *const kTargets49[] = {"今天天气真不错"};
static const char *const kTargets50[] = {"改到下周一可以吗"};
static const char *const kTargets51[] = {"周报我写好了"};
static const char *const kTargets52[] = {"我需要这份数据"};
static const char *const kTargets53[] = {"这周加班有点多"};
static const char *const kTargets54[] = {"麻烦你帮我看一下"};
static const char *const kTargets55[] = {"这个方案通过了"};
static const char *const kTargets56[] = {"我请三天假"};
static const char *const kTargets57[] = {"客户下午来电"};
static const char *const kTargets58[] = {"交付时间往后延一周"};
static const char *const kTargets59[] = {"报销单我已经提交了"};
static const char *const kTargets60[] = {"容器编排"};
static const char *const kTargets61[] = {"前端框架"};
static const char *const kTargets62[] = {"微服务架构"};
static const char *const kTargets63[] = {"分词器"};
static const char *const kTargets64[] = {"向量数据库"};
static const char *const kTargets65[] = {"推理加速"};
static const char *const kTargets66[] = {"微调模型"};
static const char *const kTargets67[] = {"灰度发布"};
static const char *const kTargets68[] = {"负载均衡"};
static const char *const kTargets69[] = {"容器镜像"};
static const char *const kTargets70[] = {"华为"};
static const char *const kTargets71[] = {"腾讯"};
static const char *const kTargets72[] = {"小米"};
static const char *const kTargets73[] = {"百度"};
static const char *const kTargets74[] = {"京东"};
static const char *const kTargets75[] = {"微信"};
static const char *const kTargets76[] = {"上海"};
static const char *const kTargets77[] = {"知乎"};
static const char *const kTargets78[] = {"图形处理器"};
static const char *const kTargets79[] = {"指令集架构"};
static const char *const kTargets80[] = {"会议结束后请把纪要发到项目群里"};
static const char *const kTargets81[] = {"航班延误了两个小时我们才能登机"};
static const char *const kTargets82[] = {"快递显示已经签收麻烦你确认一下"};
static const char *const kTargets83[] = {"明天上午的面试需要准备两个项目案例"};
static const char *const kTargets84[] = {"外面下着大雨我开车可能晚一点到"};
static const char *const kTargets85[] = {"这个项目我们要按时交付"};
static const char *const kTargets86[] = {"麻烦帮我订一间明天下午的会议室", "麻烦帮我定一间明天下午的会议室"};
static const char *const kTargets87[] = {"我看了一下比赛记录", "我看了一下比赛纪录"};
static const char *const kTargets88[] = {"他做了份详细的报告", "他作了份详细的报告"};
static const char *const kTargets89[] = {"他看起来比我们想象的要忙", "他看起来比我们想像的要忙"};
static const char *const kTargets90[] = {"事情", "实情"};
static const char *const kTargets91[] = {"心里", "心理"};
static const char *const kTargets92[] = {"主意", "注意"};
static const char *const kTargets93[] = {"世纪", "实际"};
static const char *const kTargets94[] = {"使用", "试用"};
static const char *const kTargets95[] = {"知道", "指导"};
static const char *const kTargets96[] = {"经历", "精力"};
static const char *const kTargets97[] = {"机器", "及其"};
static const char *const kTargets98[] = {"委屈", "委曲"};
static const char *const kTargets99[] = {"考察", "考查"};
static const char *const kTargets100[] = {"丈夫"};
static const char *const kTargets101[] = {"传记"};
static const char *const kTargets102[] = {"会计"};
static const char *const kTargets103[] = {"打折"};
static const char *const kTargets104[] = {"便宜"};
static const char *const kTargets105[] = {"的确"};
static const char *const kTargets106[] = {"长度"};
static const char *const kTargets107[] = {"重量"};
static const char *const kTargets108[] = {"差不多"};
static const char *const kTargets109[] = {"少年"};
static const char *const kTargets110[] = {"熬夜"};
static const char *const kTargets111[] = {"欧洲"};
static const char *const kTargets112[] = {"按时"};
static const char *const kTargets113[] = {"爱惜"};
static const char *const kTargets114[] = {"饿了"};
static const char *const kTargets115[] = {"昂贵"};
static const char *const kTargets116[] = {"儿童"};
static const char *const kTargets117[] = {"恶心"};
static const char *const kTargets118[] = {"金额"};
static const char *const kTargets119[] = {"而且"};

static const QualityCase kQualityCases[] = {
    {"hello", "nihc", kTargets0, 1, 2},
    {"thanks", "xpxp", kTargets1, 1, 2},
    {"goodbye", "zdjm", kTargets2, 1, 2},
    {"morning", "zcuhhc", kTargets3, 1, 3},
    {"no-problem", "mwgrxi", kTargets4, 1, 3},
    {"i-know", "wovidc", kTargets5, 1, 3},
    {"think", "xlyixl", kTargets6, 1, 3},
    {"available", "jbtmwjuhyzks", kTargets7, 1, 6},
    {"eat", "niiifjlema", kTargets8, 1, 5},
    {"learn", "xtxiykyu", kTargets9, 1, 4},
    {"want-learn", "woxlxtykyu", kTargets10, 1, 5},
    {"no-understanding", "womwyztkds", kTargets11, 1, 5},
    {"repeat", "qkzduoyibm", kTargets12, 1, 5},
    {"meeting", "kdhv", kTargets13, 1, 2},
    {"tomorrow-meeting", "mktmxxwukdhv", kTargets14, 1, 6},
    {"send-file", "qkbawfjmfagwwo", kTargets15, 1, 7},
    {"next-week", "womfxxvzzdtcly", kTargets16, 1, 7},
    {"plan", "vegefhankeyi", kTargets17, 1, 6},
    {"send-email", "fassyzjm", kTargets18, 1, 4},
    {"negation", "buycfassyzjm", kTargets19, 1, 6},
    {"long-work", "qkbamktmxxwukdhvdeuijmfagwwo", kTargets20, 1, 14},
    {"long-learning", "woxlmwtmhxyidmuijmxtxiykyu", kTargets21, 1, 13},
    {"database", "uujuku", kTargets22, 1, 3},
    {"ai", "rfgsving", kTargets23, 1, 4},
    {"quantum", "llzijisr", kTargets24, 1, 4},
    {"xiaohe", "xnheulpb", kTargets25, 1, 4},
    {"nvidia", "ykwwda", kTargets26, 1, 3},
    {"tsmc", "tdjidm", kTargets27, 1, 3},
    {"lark", "fwuu", kTargets28, 1, 2},
    {"deepseek", "ufduqqso", kTargets29, 1, 4},
    {"meituan", "mwtr", kTargets30, 1, 2},
    {"unconstrained-huiyi", "hvyi", kTargets31, 2, 2},
    {"bank", "ybhh", kTargets32, 1, 2},
    {"walk", "xkzz", kTargets33, 1, 2},
    {"chongqing", "isqk", kTargets34, 1, 2},
    {"music", "ybyt", kTargets35, 1, 2},
    {"safety", "anqr", kTargets36, 1, 2},
    {"occasionally", "ouer", kTargets37, 1, 2},
    {"scheme", "fhan", kTargets38, 1, 2},
    {"love", "aihc", kTargets39, 1, 2},
    {"daily-long-time-no-see", "hcjqbujm", kTargets40, 1, 4},
    {"daily-many-thanks", "tdgjxple", kTargets41, 1, 4},
    {"daily-see-you-tomorrow", "mktmjm", kTargets42, 1, 3},
    {"daily-how-are-you-recently", "nizvjbzfmeyh", kTargets43, 1, 6},
    {"daily-i-am-a-bit-tired", "woyzdmlw", kTargets44, 1, 4},
    {"daily-take-care-of-yourself", "bcvs", kTargets45, 1, 2},
    {"daily-congratulations", "gsxini", kTargets46, 1, 3},
    {"daily-sorry-im-late", "bcqmldwjle", kTargets47, 1, 5},
    {"daily-wanna-eat-together", "ycbuycyiqiiigefj", kTargets48, 1, 8},
    {"daily-nice-weather-today", "jbtmtmqivfbuco", kTargets49, 1, 7},
    {"work-move-to-monday", "gddcxxvzyikeyima", kTargets50, 1, 8},
    {"work-weekly-report-done", "vzbcwoxphcle", kTargets51, 1, 6},
    {"work-need-this-dataset", "woxuycveffuuju", kTargets52, 1, 7},
    {"work-too-much-overtime", "vevzjxbjyzdmdo", kTargets53, 1, 7},
    {"work-please-help-review", "mafjnibhwokjyixx", kTargets54, 1, 8},
    {"work-plan-approved", "vegefhantsgole", kTargets55, 1, 7},
    {"work-three-days-leave", "woqksjtmjx", kTargets56, 1, 5},
    {"work-client-calls-afternoon", "kehuxxwulddm", kTargets57, 1, 6},
    {"work-delivery-postponed", "jnfuuijmwhhzyjyivz", kTargets58, 1, 9},
    {"work-expense-filed", "bcxndjwoyijktijnle", kTargets59, 1, 9},
    {"tech-container-orchestration", "rsqibmpd", kTargets60, 1, 4},
    {"tech-frontend-framework", "qmdrkljx", kTargets61, 1, 4},
    {"tech-microservice-architecture", "wwfuwujxgz", kTargets62, 1, 5},
    {"tech-tokenizer", "ffciqi", kTargets63, 1, 3},
    {"tech-vector-database", "xllluujuku", kTargets64, 1, 5},
    {"tech-inference-speedup", "tvlijxsu", kTargets65, 1, 4},
    {"tech-fine-tuned-model", "wwtnmoxk", kTargets66, 1, 4},
    {"tech-canary-release", "hvdufabu", kTargets67, 1, 4},
    {"tech-load-balancing", "fuzdjyhg", kTargets68, 1, 4},
    {"tech-container-image", "rsqijkxl", kTargets69, 1, 4},
    {"entity-huawei", "hxww", kTargets70, 1, 2},
    {"entity-tencent", "tgxy", kTargets71, 1, 2},
    {"entity-xiaomi", "xnmi", kTargets72, 1, 2},
    {"entity-baidu", "bddu", kTargets73, 1, 2},
    {"entity-jingdong", "jkds", kTargets74, 1, 2},
    {"entity-wechat", "wwxb", kTargets75, 1, 2},
    {"entity-shanghai", "uhhd", kTargets76, 1, 2},
    {"entity-zhihu", "vihu", kTargets77, 1, 2},
    {"entity-graphics-processor", "tuxkiuliqi", kTargets78, 1, 5},
    {"entity-instruction-set-arch", "vilkjijxgz", kTargets79, 1, 5},
    {"long-meeting-notes-to-group", "hvyijpuuhzqkbajiycfadcxlmuqyli", kTargets80, 1, 15},
    {"long-flight-delay", "hhbjyjwulellgexnuiwomfcdngdgji", kTargets81, 1, 15},
    {"long-parcel-signed-confirm", "kkdixmuiyijkqmuzmafjniqtrfyixx", kTargets82, 1, 15},
    {"long-interview-preparation", "mktmuhwudemmuixuycvybwllgexlmuanli", kTargets83, 1, 17},
    {"long-rainy-drive", "wdmmxxvedayuwokdiekengwjyidmdc", kTargets84, 1, 15},
    {"long-deliver-on-time", "vegexlmuwomfycanuijnfu", kTargets85, 1, 11},
    {"long-book-meeting-room", "mafjbhwodkyijmmktmxxwudehvyiui", kTargets86, 2, 15},
    {"long-match-record-variant", "wokjleyixxbisdjilu", kTargets87, 2, 9},
    {"long-made-report-variant", "tazoleffxlxidebcgc", kTargets88, 2, 9},
    {"long-look-busier-variant", "takjqildbiwomfxlxldeycmh", kTargets89, 2, 12},
    {"ambiguous-matter-truth", "uiqk", kTargets90, 2, 2},
    {"ambiguous-mind-psyche", "xbli", kTargets91, 2, 2},
    {"ambiguous-idea-notice", "vuyi", kTargets92, 2, 2},
    {"ambiguous-century-actual", "uiji", kTargets93, 2, 2},
    {"ambiguous-use-try", "uiys", kTargets94, 2, 2},
    {"ambiguous-know-guide", "vidc", kTargets95, 2, 2},
    {"ambiguous-experience-energy", "jkli", kTargets96, 2, 2},
    {"ambiguous-machine-or", "jiqi", kTargets97, 2, 2},
    {"ambiguous-wronged-unjust", "wwqu", kTargets98, 2, 2},
    {"ambiguous-inspect-examine", "kcia", kTargets99, 2, 2},
    {"polyphone-husband", "vhfu", kTargets100, 1, 2},
    {"polyphone-biography", "vrji", kTargets101, 1, 2},
    {"polyphone-accounting", "kkji", kTargets102, 1, 2},
    {"polyphone-discount", "dave", kTargets103, 1, 2},
    {"polyphone-cheap", "pmyi", kTargets104, 1, 2},
    {"polyphone-indeed", "diqt", kTargets105, 1, 2},
    {"polyphone-length", "ihdu", kTargets106, 1, 2},
    {"polyphone-weight", "vsll", kTargets107, 1, 2},
    {"polyphone-almost", "iabudo", kTargets108, 1, 3},
    {"polyphone-teenager", "ucnm", kTargets109, 1, 2},
    {"zero-stay-up-late", "aoye", kTargets110, 1, 2},
    {"zero-europe", "ouvz", kTargets111, 1, 2},
    {"zero-on-time", "anui", kTargets112, 1, 2},
    {"zero-cherish", "aixi", kTargets113, 1, 2},
    {"zero-hungry", "eele", kTargets114, 1, 2},
    {"zero-expensive", "ahgv", kTargets115, 1, 2},
    {"zero-children", "erts", kTargets116, 1, 2},
    {"zero-nausea", "eexb", kTargets117, 1, 2},
    {"zero-amount", "jbee", kTargets118, 1, 2},
    {"zero-moreover", "erqp", kTargets119, 1, 2},
};

static const size_t kQualityCaseCount = 120;

#endif  // GOGAKU_QUALITY_CASES_INC
