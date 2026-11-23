// 扩展词库挂载向量：挂载生效、停用释放、删除中间一本、空槽复用、组合中延迟、
// 学习阈值、删词提示、权重 0 不越权、英文候选排序不变。
// 合同见 docs/dictionaries.md §四；词典／模型路径同普通模式测试
// （GOGAKU_CORE_TEST_DATA，缺数据时显式 SKIP，不当作通过）。
#include "gogaku_core.h"

#include "../../third_party/json.hpp"

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include <libime/pinyin/pinyindictionary.h>

#ifdef _WIN32
#include "windows_io.h"
#include <windows.h>
#endif

namespace {

using Json = nlohmann::json;

int failures = 0;

void check(bool condition, const char *name, const std::string &detail) {
    if (condition) return;
    std::fprintf(stderr, "FAIL %s: %s\n", name, detail.c_str());
    ++failures;
}

void write_file(const std::string &path, const std::string &content) {
    std::ofstream out(path, std::ios::binary);
    out << content;
    if (!out) {
        std::fprintf(stderr, "FATAL 无法写出 %s\n", path.c_str());
        std::exit(2);
    }
}

std::string read_file(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

std::string temp_dir() {
#ifdef _WIN32
    char base[MAX_PATH];
    if (GetTempPathA(MAX_PATH, base) == 0) return ".";
    static unsigned counter = 0;
    const std::string dir = std::string(base) + "gogaku-dict-mount-" +
                            std::to_string(static_cast<unsigned>(GetCurrentProcessId())) + "-" +
                            std::to_string(++counter);
    std::filesystem::create_directories(dir);
    return dir;
#else
    char tpl[] = "/tmp/gogaku-dict-mount-XXXXXX";
    if (mkdtemp(tpl) == nullptr) {
        std::fprintf(stderr, "FATAL 无法创建临时目录\n");
        std::exit(2);
    }
    return tpl;
#endif
}

struct Case {
    std::string dir;
    std::string dictPath;   // 出厂词典
    std::string modelPath;  // 语言模型
    std::string dictsDir;   // 词库目录
    GcNormalSession *normal = nullptr;
    GcLearningSession *learning = nullptr;
};

bool make_case(Case &c) {
    const char *dataDir = getenv("GOGAKU_CORE_TEST_DATA");
    std::string base = dataDir != nullptr && *dataDir != '\0' ? dataDir
        : std::string(getenv("HOME") == nullptr ? "" : getenv("HOME")) +
              "/Library/Caches/Gogaku/libime-1.1.17/data";
    c.modelPath = base + "/zh_CN.lm";
    std::ifstream probe(c.modelPath, std::ios::binary);
    if (!probe) {
        std::fprintf(stderr, "SKIP: 未找到 libime 出厂模型 %s（设置 GOGAKU_CORE_TEST_DATA）\n",
                     c.modelPath.c_str());
        return false;
    }
    c.dir = temp_dir();
    const char *factoryText =
        "你 ni\n好 hao\n你好 ni'hao\n我们 wo'men\n中国 zhong'guo\n时间 shi'jian\n学习 xu'e'xi\n";
    write_file(c.dir + "/factory.text", factoryText);
    try {
        libime::PinyinDictionary d;
        d.load(0, (c.dir + "/factory.text").c_str(), libime::PinyinDictFormat::Text);
        c.dictPath = c.dir + "/factory.dict";
        d.save(0, c.dictPath.c_str(), libime::PinyinDictFormat::Binary);
    } catch (const std::exception &e) {
        std::fprintf(stderr, "SKIP: 测试词典生成失败：%s\n", e.what());
        return false;
    }
    c.dictsDir = c.dir + "/dicts";

    GcNormalConfig cfg{};
    cfg.dict_path = c.dictPath.c_str();
    cfg.model_path = c.modelPath.c_str();
    cfg.user_dir = nullptr;
    cfg.custom_words_path = nullptr;
    cfg.english_words_path = nullptr;
    cfg.gloss_path = nullptr;
    cfg.scheme = GC_SCHEME_FULLPINYIN;
    cfg.fuzzy_mask = 0;
    cfg.full_pinyin_preedit = 0;
    cfg.freq_enabled = 0;
    cfg.english_enabled = 0;
    char err[512] = {0};
    if (gc_normal_session_create(&cfg, &c.normal, err, sizeof(err)) != 0) {
        std::fprintf(stderr, "SKIP: 普通会话创建失败：%s\n", err);
        return false;
    }
    GcLearningConfig lcfg{};
    lcfg.dict_path = c.dictPath.c_str();
    lcfg.model_path = c.modelPath.c_str();
    if (gc_learning_session_create(&lcfg, &c.learning, err, sizeof(err)) != 0) {
        std::fprintf(stderr, "SKIP: 学习会话创建失败：%s\n", err);
        return false;
    }
    return true;
}

// 导入一本扩展词库（display name＝文件名去扩展）；返回 id。
std::string import_dict(const Case &c, const std::string &fileName, const std::string &content) {
    write_file(c.dir + "/in-" + fileName, content);
    const std::string inputPath = c.dir + "/in-" + fileName;
    GcDictImportRequest req{};
    req.input_path = inputPath.c_str();
    req.dictionaries_dir = c.dictsDir.c_str();
    req.system_dict_path = c.dictPath.c_str();
    req.display_name = nullptr;
    char *result = nullptr;
    char err[512] = {0};
    const int code = gc_dict_import(&req, nullptr, nullptr, &result, err, sizeof(err));
    if (code != 0 || result == nullptr) {
        std::fprintf(stderr, "FATAL 导入失败（%s）：%s\n", err, fileName.c_str());
        std::exit(2);
    }
    const Json r = Json::parse(result, nullptr, false);
    gc_contract_free(result);
    return r.value("id", "");
}

void load_handle(const Case &c, const std::string &id, GcDictHandle **handle) {
    char err[512] = {0};
    const int code = gc_dict_load(c.dictsDir.c_str(), id.c_str(), handle, err, sizeof(err));
    if (code != 0) {
        std::fprintf(stderr, "FATAL 加载失败（%s）：%s\n", err, id.c_str());
        std::exit(2);
    }
}

std::vector<std::string> mounted_normal(const Case &c) {
    char *json = nullptr;
    if (gc_normal_dicts_mounted(c.normal, &json) != 0 || json == nullptr) return {};
    const Json arr = Json::parse(json, nullptr, false);
    gc_contract_free(json);
    std::vector<std::string> out;
    for (const auto &v : arr) out.push_back(v.get<std::string>());
    return out;
}

std::vector<std::string> mounted_learning(const Case &c) {
    char *json = nullptr;
    if (gc_learning_dicts_mounted(c.learning, &json) != 0 || json == nullptr) return {};
    const Json arr = Json::parse(json, nullptr, false);
    gc_contract_free(json);
    std::vector<std::string> out;
    for (const auto &v : arr) out.push_back(v.get<std::string>());
    return out;
}

// 依次输入文本，返回最后一个快照的候选文本列表；结束后 Esc 清空组合，
// 让后续的 dicts_apply 不落在组合中（组合中返回 3 是单独的场景）。
std::vector<std::string> type_candidates(GcNormalSession *s, const std::string &keys) {
    std::vector<std::string> texts;
    for (char ch : keys) {
        char buf[2] = {ch, '\0'};
        GcKeyEvent ev{};
        ev.kind = GC_EV_TEXT;
        ev.text = buf;
        GcSnapshot *snap = nullptr;
        if (gc_normal_handle(s, &ev, &snap) != 0 || snap == nullptr) return texts;
        texts.clear();
        for (size_t i = 0; i < snap->count; ++i) texts.emplace_back(snap->candidates[i].text);
        gc_snapshot_free(snap);
    }
    GcKeyEvent esc{};
    esc.kind = GC_EV_ESC;
    GcSnapshot *snap = nullptr;
    gc_normal_handle(s, &esc, &snap);
    gc_snapshot_free(snap);
    return texts;
}

bool candidates_contain(const std::vector<std::string> &candidates, const std::string &word) {
    for (const auto &c : candidates) {
        if (c == word) return true;
    }
    return false;
}

// 挂载 helper：加载句柄并 apply。
int apply_one(const Case &c, const std::string &id) {
    GcDictHandle *handle = nullptr;
    load_handle(c, id, &handle);
    const char *ids[1] = {id.c_str()};
    GcDictHandle *handles[1] = {handle};
    return gc_normal_dicts_apply(c.normal, ids, handles, 1);
}

}  // namespace

int main() {
    Case c;
    if (!make_case(c)) return 3;

    // ── 挂载生效：扩展词出现在候选 ──
    const std::string dictA = import_dict(c, "a.txt", "网络热词 wang'luo're'ci\n网王 wang'luo\n");
    check(apply_one(c, dictA) == 0, "挂载 A", dictA);
    auto mounted = mounted_normal(c);
    check(mounted.size() == 1 && mounted[0] == dictA, "挂载状态", dictA);
    auto candidates = type_candidates(c.normal, "wangluoreci");
    check(candidates_contain(candidates, "网络热词"), "扩展词参与排序", "");

    {   // ── 停用等于卸载：目标集合为空集合 ──
        check(gc_normal_dicts_apply(c.normal, nullptr, nullptr, 0) == 0, "空集卸载", "");
        check(mounted_normal(c).empty(), "卸载后无挂载", "");
        candidates = type_candidates(c.normal, "wangluoreci");
        check(!candidates_contain(candidates, "网络热词"), "卸载后扩展词消失", "");
    }

    {   // ── 删除中间一本与空槽复用 ──
        const std::string dictB = import_dict(c, "b.txt", "学习资料 xu'e'xi'zi'liao\n");
        const std::string dictC = import_dict(c, "c.txt", "中转站 zhong'zhuan'zhan\n");
        {
            GcDictHandle *hb = nullptr;
            GcDictHandle *hc = nullptr;
            load_handle(c, dictB, &hb);
            load_handle(c, dictC, &hc);
            const char *ids[2] = {dictB.c_str(), dictC.c_str()};
            GcDictHandle *hs[2] = {hb, hc};
            check(gc_normal_dicts_apply(c.normal, ids, hs, 2) == 0, "挂载 B、C", "");
        }
        mounted = mounted_normal(c);
        check(mounted.size() == 2 && mounted[0] == dictB && mounted[1] == dictC,
              "两本挂载", "");

        // 移除中间的 B（C 保留句柄传 NULL）：B 槽位变占位，不收拢尾部。
        const char *ids2[1] = {dictC.c_str()};
        GcDictHandle *handles2[1] = {nullptr};
        check(gc_normal_dicts_apply(c.normal, ids2, handles2, 1) == 0, "移除中间本", "");
        mounted = mounted_normal(c);
        check(mounted.size() == 1 && mounted[0] == dictC, "移除后集合", "");

        // 空槽复用：目标 {C(保留), D}，新挂 D 应落在 B 腾出的槽位。
        const std::string dictD = import_dict(c, "d.txt", "测试样本 ce'shi'yang'ben\n");
        {
            GcDictHandle *hd = nullptr;
            load_handle(c, dictD, &hd);
            const char *ids3[2] = {dictC.c_str(), dictD.c_str()};
            GcDictHandle *hs3[2] = {nullptr, hd};
            check(gc_normal_dicts_apply(c.normal, ids3, hs3, 2) == 0, "挂载 D", "");
        }
        mounted = mounted_normal(c);
        check(mounted.size() == 2 && mounted[0] == dictD && mounted[1] == dictC,
              "空槽复用顺序", "");
    }

    {   // ── 组合进行中 apply 返回 3，组合结束后生效 ──
        const std::string dictE = import_dict(c, "e.txt", "电风扇 dian'feng'shan\n");
        // 先打出组合（不提交；手动输入，不经 type_candidates 的收尾 Esc）。
        {
            GcKeyEvent ev{};
            ev.kind = GC_EV_TEXT;
            ev.text = "n";
            GcSnapshot *snap = nullptr;
            check(gc_normal_handle(c.normal, &ev, &snap) == 0, "组合输入", "");
            gc_snapshot_free(snap);
        }
        const char *ids[1] = {dictE.c_str()};
        GcDictHandle *handles[1] = {nullptr};
        check(gc_normal_dicts_apply(c.normal, ids, handles, 1) == 3, "组合中返回 3", "");
        // 组合中现有挂载不受影响。
        check(mounted_normal(c).size() == 2, "组合中挂载不变", "");
        // 结束组合（Esc）。
        GcKeyEvent esc{};
        esc.kind = GC_EV_ESC;
        GcSnapshot *snap = nullptr;
        check(gc_normal_handle(c.normal, &esc, &snap) == 0, "Esc 成功", "");
        gc_snapshot_free(snap);
        GcDictHandle *handleE = nullptr;
        load_handle(c, dictE, &handleE);
        GcDictHandle *handlesE[1] = {handleE};
        check(gc_normal_dicts_apply(c.normal, ids, handlesE, 1) == 0, "组合后挂载成功", "");
        candidates = type_candidates(c.normal, "dianfengshan");
        check(candidates_contain(candidates, "电风扇"), "新挂载生效", "");
    }

    {   // ── 删词提示：扩展词 Ctrl＋Backspace 不删除（手动输入保持组合） ──
        {
            for (char ch : std::string("dianfengshan")) {
                GcKeyEvent ev{};
                ev.kind = GC_EV_TEXT;
                char b[2] = {ch, '\0'};
                ev.text = b;
                GcSnapshot *snap = nullptr;
                gc_normal_handle(c.normal, &ev, &snap);
                gc_snapshot_free(snap);
            }
        }
        GcKeyEvent del{};
        del.kind = GC_EV_DELETE_WORD;
        GcSnapshot *snap = nullptr;
        check(gc_normal_handle(c.normal, &del, &snap) == 0, "删词事件", "");
        check(snap != nullptr && std::string(snap->status).find("扩展词") != std::string::npos,
              "扩展词删词提示", snap == nullptr ? "" : snap->status);
        gc_snapshot_free(snap);
        {
            GcKeyEvent esc{};
            esc.kind = GC_EV_ESC;
            GcSnapshot *snapEsc = nullptr;
            gc_normal_handle(c.normal, &esc, &snapEsc);
            gc_snapshot_free(snapEsc);
        }
        // 词仍在。
        candidates = type_candidates(c.normal, "dianfengshan");
        check(candidates_contain(candidates, "电风扇"), "删词不生效", "");
    }

    {   // ── 出厂词删词行为不变（手动输入保持组合） ──
        // 出厂词典（测试词典）没有可删学习词；这里验证提示不再是「扩展词」。
        {
            GcKeyEvent esc{};
            esc.kind = GC_EV_ESC;
            GcSnapshot *snapEsc = nullptr;
            gc_normal_handle(c.normal, &esc, &snapEsc);
            gc_snapshot_free(snapEsc);
        }
        {
            for (char ch : std::string("nihao")) {
                GcKeyEvent ev{};
                ev.kind = GC_EV_TEXT;
                char b[2] = {ch, '\0'};
                ev.text = b;
                GcSnapshot *snap = nullptr;
                gc_normal_handle(c.normal, &ev, &snap);
                gc_snapshot_free(snap);
            }
        }
        GcKeyEvent del{};
        del.kind = GC_EV_DELETE_WORD;
        GcSnapshot *snap = nullptr;
        check(gc_normal_handle(c.normal, &del, &snap) == 0, "出厂删词事件", "");
        const std::string status = snap == nullptr ? "" : snap->status;
        check(status.find("扩展词") == std::string::npos, "出厂词不提示扩展词", status);
        gc_snapshot_free(snap);
        {
            GcKeyEvent esc{};
            esc.kind = GC_EV_ESC;
            GcSnapshot *snapEsc = nullptr;
            gc_normal_handle(c.normal, &esc, &snapEsc);
            gc_snapshot_free(snapEsc);
        }
    }

    {   // ── 权重 0：常用拼音上出厂候选与英文候选排序不变 ──
        const std::string dictF = import_dict(c, "f.txt", "网王 wang'luo\n wojiao wo'jiao\n");
        check(apply_one(c, dictF) == 0, "挂载 F", dictF);
        // 英文候选：挂载前后的首选都是英文词（english_enabled 关闭时不出现英文）。
        // 这里验证中文候选：出厂词「你好」仍是 "nihao" 首选。
        auto top = type_candidates(c.normal, "nihaoshijian");
        check(!top.empty() && top[0].find("你好") != std::string::npos, "常用组合首选不变",
              top.empty() ? "(空)" : top[0]);
        // 扩展词默认全参与，但权重 0 不挤掉出厂词——「women」首选应为出厂「我们」。
        top = type_candidates(c.normal, "women");
        check(!top.empty() && top[0] == "我们", "权重 0 不越权", top.empty() ? "(空)" : top[0]);
    }

    {   // ── 学习会话：阈值过滤（单本 8MiB／累计 16MiB；每次 apply 都是完整目标集合） ──
        const std::string small = import_dict(c, "s.txt", "小词库 xiao'ci'ku\n");
        const char *idSmall[1] = {small.c_str()};
        GcDictHandle *handle = nullptr;
        load_handle(c, small, &handle);
        GcDictHandle *handles[1] = {handle};
        check(gc_learning_dicts_apply(c.learning, idSmall, handles, 1) == 0, "学习挂载小词库", "");
        auto lm = mounted_learning(c);
        check(lm.size() == 1 && lm[0] == small, "学习挂载状态", "");

        // 伪造超大词库元数据（真实的 .dict 字节，sizeBytes 改大）。
        const std::string huge = import_dict(c, "h.txt", "大词库 da'ci'ku\n");
        {
            Json meta = Json::parse(read_file(c.dictsDir + "/" + huge + ".json"), nullptr, false);
            meta["sizeBytes"] = 9ull * 1024 * 1024;
            write_file(c.dictsDir + "/" + huge + ".json", meta.dump());
        }
        GcDictHandle *hugeHandle = nullptr;
        load_handle(c, huge, &hugeHandle);
        const char *idsHuge[2] = {small.c_str(), huge.c_str()};
        GcDictHandle *handlesHuge[2] = {nullptr, hugeHandle};
        check(gc_learning_dicts_apply(c.learning, idsHuge, handlesHuge, 2) == 0,
              "学习挂载超限不报错", "");
        lm = mounted_learning(c);
        check(lm.size() == 1 && lm[0] == small, "超阈值词库未挂载", "");

        // 累计阈值：两本 8MiB 恰好到限（≤16MiB 边界内），第三本 1 字节也挂不上。
        const std::string big1 = import_dict(c, "b1.txt", "大一号 da'yi'hao\n");
        const std::string big2 = import_dict(c, "b2.txt", "大二号 da'er'hao\n");
        for (const std::string &id : {big1, big2}) {
            Json meta = Json::parse(read_file(c.dictsDir + "/" + id + ".json"), nullptr, false);
            meta["sizeBytes"] = 8ull * 1024 * 1024;
            write_file(c.dictsDir + "/" + id + ".json", meta.dump());
        }
        GcDictHandle *h1 = nullptr;
        GcDictHandle *h2 = nullptr;
        load_handle(c, big1, &h1);
        load_handle(c, big2, &h2);
        const char *ids3[2] = {big1.c_str(), big2.c_str()};
        GcDictHandle *handles3[2] = {h1, h2};
        check(gc_learning_dicts_apply(c.learning, ids3, handles3, 2) == 0, "学习边界累计", "");
        lm = mounted_learning(c);
        check(lm.size() == 2, "两本 8MiB 都挂上（目标集合不含 small）", "");

        const char *ids4[3] = {big1.c_str(), big2.c_str(), small.c_str()};
        GcDictHandle *handles4[3] = {nullptr, nullptr, nullptr};
        check(gc_learning_dicts_apply(c.learning, ids4, handles4, 3) == 0, "累计超限拒绝小词库", "");
        lm = mounted_learning(c);
        bool hasSmall = false;
        for (const auto &id : lm) {
            if (id == small) hasSmall = true;
        }
        check(lm.size() == 2 && !hasSmall, "16MiB 满额后不再挂载", "");

        // 学习组合进行中 apply 返回 3。
        {
            GcLearningEvent ev{};
            ev.kind = GC_LEV_CONFIGURE;
            ev.arg0 = 1;
            ev.arg1 = GC_LEARN_MODE_NORMAL;
            ev.arg2 = GC_LEARN_DIR_ZH_TO_EN;
            GcLearningSnapshot *snap = nullptr;
            check(gc_learning_handle(c.learning, &ev, &snap) == 0, "学习 configure", "");
            gc_learning_snapshot_free(snap);
            ev.kind = GC_LEV_TYPE;
            ev.text = "n";
            snap = nullptr;
            check(gc_learning_handle(c.learning, &ev, &snap) == 0, "学习输入", "");
            gc_learning_snapshot_free(snap);
            const char *ids5[1] = {small.c_str()};
            GcDictHandle *handles5[1] = {nullptr};
            check(gc_learning_dicts_apply(c.learning, ids5, handles5, 1) == 3, "学习组合中返回 3", "");
            ev.kind = GC_LEV_CANCEL;
            snap = nullptr;
            check(gc_learning_handle(c.learning, &ev, &snap) == 0, "学习取消", "");
            gc_learning_snapshot_free(snap);
            check(gc_learning_dicts_apply(c.learning, ids5, handles5, 1) == 0, "学习组合后挂载", "");
        }
    }

    gc_normal_session_destroy(c.normal);
    gc_learning_session_destroy(c.learning);

    if (failures != 0) {
        std::fprintf(stderr, "dict_mount: %d 项失败\n", failures);
        return 1;
    }
    std::printf("dict_mount: 全部通过\n");
    return 0;
}
