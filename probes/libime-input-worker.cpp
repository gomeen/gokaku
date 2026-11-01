// 独立 libime I0 JSONL 探针；仅显式加载传入的出厂数据，不读取用户配置。
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <json-c/json.h>
#include <fcitx-utils/log.h>
#include <libime/core/userlanguagemodel.h>
#include <libime/pinyin/pinyincontext.h>
#include <libime/pinyin/pinyindictionary.h>
#include <libime/pinyin/pinyinime.h>
#include <libime/pinyin/shuangpinprofile.h>

namespace {
using Clock = std::chrono::steady_clock;
constexpr const char *Version = "1.1.17@5be1300ea00e899b3f2c46d1e9f6bca21139cdeb";
using Json = std::unique_ptr<json_object, decltype(&json_object_put)>;
Json own(json_object *value) { return Json(value, json_object_put); }
void add(json_object *obj, const char *key, const std::string &value) {
    json_object_object_add(obj, key, json_object_new_string_len(value.data(), value.size()));
}
void flag(json_object *obj, const char *key, bool value) {
    json_object_object_add(obj, key, json_object_new_boolean(value));
}
void number(json_object *obj, const char *key, int64_t value) {
    json_object_object_add(obj, key, json_object_new_int64(value));
}
void emit(json_object *obj) {
    std::cout << json_object_to_json_string_ext(obj, JSON_C_TO_STRING_PLAIN) << '\n' << std::flush;
}
int64_t elapsed(Clock::time_point a, Clock::time_point b) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(b - a).count();
}
json_object *field(json_object *obj, const char *name) {
    json_object *value = nullptr;
    if (obj && json_object_is_type(obj, json_type_object)) {
        json_object_object_get_ex(obj, name, &value);
    }
    return value;
}
struct Snapshot {
    std::string preedit, raw;
    std::vector<std::string> candidates;
    bool composing;
};
Snapshot collect(libime::PinyinContext &context) {
    Snapshot result;
    // candidatesToCursor() 可以惰性求值；实际枚举、复制均在 collect_ns 内。
    const auto &candidates = context.candidatesToCursor();
    for (size_t i = 0; i < std::min<size_t>(10, candidates.size()); ++i) {
        result.candidates.push_back(candidates[i].toString());
    }
    result.preedit = context.preedit(libime::PinyinPreeditMode::Pinyin);
    // 本探针只接收 ASCII；selectedLength 的字符偏移也就是字节偏移。
    result.raw = context.userInput().substr(context.selectedLength());
    result.composing = !context.empty() || !context.selectedSentence().empty();
    return result;
}
} // namespace

int main(int argc, char **argv) {
    try {
        auto start = Clock::now();
        fcitx::Log::setLogStream(std::cerr);
        auto profile = std::make_shared<libime::ShuangpinProfile>(libime::ShuangpinBuiltinProfile::Xiaohe);
        // 准备脚本用真实 API 核对合成样例编码，不涉及词库质量或性能。
        if (argc == 2 && std::string(argv[1]) == "--dump-profile") {
            auto output = own(json_object_new_object());
            for (const auto &[code, syllables] : profile->table()) {
                auto *values = json_object_new_array();
                for (const auto &[syllable, fuzzy] : syllables) {
                    if (fuzzy == libime::PinyinFuzzyFlag::None) {
                        const auto text = syllable.toString();
                        json_object_array_add(values, json_object_new_string(text.c_str()));
                    }
                }
                json_object_object_add(output.get(), code.c_str(), values);
            }
            emit(output.get());
            return 0;
        }
        if (argc != 3) {
            std::cerr << "usage: libime-input-worker SC_DICT ZH_CN_LM\n";
            return 2;
        }
        libime::PinyinIME ime(std::make_unique<libime::PinyinDictionary>(),
                             std::make_unique<libime::UserLanguageModel>(argv[2]));
        ime.dict()->load(libime::PinyinDictionary::SystemDict, argv[1], libime::PinyinDictFormat::Binary);
        ime.setShuangpinProfile(profile);
        ime.setPreeditMode(libime::PinyinPreeditMode::Pinyin);
        libime::PinyinContext context(&ime);
        context.setUseShuangpin(true);
        const auto loaded = Clock::now();
        auto ready = own(json_object_new_object());
        flag(ready.get(), "ready", true);
        add(ready.get(), "engine", "libime");
        add(ready.get(), "version", Version);
        json_object_object_add(ready.get(), "load_ms", json_object_new_double(elapsed(start, loaded) / 1e6));
        auto *config = json_object_new_object();
        add(config, "id", "I0");
        add(config, "profile", "Xiaohe");
        add(config, "dictionary", argv[1]);
        add(config, "language_model", argv[2]);
        add(config, "load_boundary", "main entry through profile, model, dictionary and context construction; excludes ready JSON serialization");
        add(config, "raw_input", "userInput().substr(selectedLength()); selected prefix retained internally until full commit");
        add(config, "selection", "candidatesToCursor/selectCandidatesToCursor; partial selection retains preedit; full selection commits selectedSentence and clears");
        add(config, "learning", "no learn/load-user/history/context-word calls; fresh in-memory user model");
        add(config, "settings", "libime API defaults except Xiaohe, useShuangpin=true and Pinyin preedit; not a complete fcitx frontend configuration");
        number(config, "candidate_limit", 10);
        number(config, "nbest", ime.nbest());
        number(config, "beam_size", ime.beamSize());
        number(config, "frame_size", ime.frameSize());
        number(config, "word_candidate_limit", ime.wordCandidateLimit());
        json_object_object_add(ready.get(), "config", config);
        emit(ready.get());

        std::string line;
        while (std::getline(std::cin, line)) {
            auto *tok = json_tokener_new();
            json_tokener_set_flags(tok, JSON_TOKENER_STRICT | JSON_TOKENER_VALIDATE_UTF8);
            auto request = own(json_tokener_parse_ex(tok, line.data(), line.size()));
            bool valid = json_tokener_get_error(tok) == json_tokener_success;
            const auto parsed = json_tokener_get_parse_end(tok);
            valid = valid && line.find_first_not_of(" \r\t", parsed) == std::string::npos;
            json_tokener_free(tok);
            auto *opValue = field(request.get(), "op");
            valid = valid && opValue && json_object_is_type(opValue, json_type_string);
            std::string op = valid ? json_object_get_string(opValue) : "";
            // 使用长度比较拒绝包含 NUL 的操作名。
            valid = valid && op.size() == static_cast<size_t>(json_object_get_string_len(opValue));
            auto *keyValue = field(request.get(), "key");
            auto *indexValue = field(request.get(), "index");
            const bool keyValid = keyValue && json_object_is_type(keyValue, json_type_int);
            const bool indexValid = indexValue && json_object_is_type(indexValue, json_type_int);
            const int64_t key = keyValid ? json_object_get_int64(keyValue) : -1;
            const int64_t index = indexValid ? json_object_get_int64(indexValue) : -1;
            if (valid && op == "quit") {
                auto reply = own(json_object_new_object());
                flag(reply.get(), "ok", true);
                flag(reply.get(), "quit", true);
                emit(reply.get());
                return 0;
            }
            std::string commit, error;
            bool ok = valid, handled = false;
            const auto t0 = Clock::now();
            try {
                auto select = [&](int64_t idx) {
                    const auto &candidates = context.candidatesToCursor();
                    if (idx < 0 || idx >= 10 || static_cast<size_t>(idx) >= candidates.size()) {
                        throw std::runtime_error("candidate index outside returned page");
                    }
                    context.selectCandidatesToCursor(static_cast<size_t>(idx));
                    if (context.selected()) {
                        commit = context.selectedSentence();
                        context.clear();
                    }
                    handled = true;
                };
                if (!valid) {
                    throw std::runtime_error("invalid JSON object or op");
                } else if (op == "reset") {
                    context.clear();
                    context.clearContextWords();
                    handled = true;
                } else if (op == "peek") {
                    handled = true;
                } else if (op == "select") {
                    if (!indexValid) throw std::runtime_error("index must be an integer");
                    select(index);
                } else if (op == "key") {
                    if (!keyValid) throw std::runtime_error("key must be an ASCII integer");
                    if (key == 8) {
                        handled = context.backspace();
                    } else if (key == 27) {
                        handled = !context.empty();
                        context.clear();
                    } else if (key == 32) {
                        if (!context.candidatesToCursor().empty()) select(0);
                    } else if ((key >= 'a' && key <= 'z') || (key == '\'' && !context.empty())) {
                        handled = context.type(static_cast<uint32_t>(key));
                    } else {
                        throw std::runtime_error("unsupported key");
                    }
                } else {
                    throw std::runtime_error("unknown op");
                }
            } catch (const std::exception &exception) {
                ok = false;
                handled = false;
                error = exception.what();
            }
            const auto t1 = Clock::now();
            const auto state = collect(context);
            const auto t2 = Clock::now();
            // JSON 分配与序列化在测量终点之后。
            auto reply = own(json_object_new_object());
            flag(reply.get(), "ok", ok);
            flag(reply.get(), "handled", handled);
            add(reply.get(), "preedit", state.preedit);
            add(reply.get(), "raw_input", state.raw);
            add(reply.get(), "commit", commit);
            flag(reply.get(), "composing", state.composing);
            auto *candidates = json_object_new_array();
            for (const auto &candidate : state.candidates) {
                json_object_array_add(candidates, json_object_new_string(candidate.c_str()));
            }
            json_object_object_add(reply.get(), "candidates", candidates);
            number(reply.get(), "process_ns", elapsed(t0, t1));
            number(reply.get(), "collect_ns", elapsed(t1, t2));
            number(reply.get(), "total_ns", elapsed(t0, t2));
            if (!error.empty()) add(reply.get(), "error", error);
            emit(reply.get());
        }
        return 0;
    } catch (const std::exception &exception) {
        std::cerr << "libime worker: " << exception.what() << '\n';
        return 1;
    }
}
