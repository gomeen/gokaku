#include "platform.h"
#include <winhttp.h>
#ifdef __MINGW32__
#include <initguid.h>
#endif
#include <spellcheck.h>
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <future>
#include <limits>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <thread>

// Only the per-user agent / an explicit settings connection test calls translate.
// There is no startup request, local model, text log, or persistent text cache here.
namespace gw {
namespace {
using Clock = std::chrono::steady_clock;
struct ServiceError : std::runtime_error { using std::runtime_error::runtime_error; };

class Internet {
public:
    explicit Internet(HINTERNET value = nullptr) : value_(value) {}
    ~Internet() { close(); }
    Internet(const Internet &) = delete;
    Internet &operator=(const Internet &) = delete;
    HINTERNET get() const { return value_.load(); }
    void close() { if (auto value = value_.exchange(nullptr)) WinHttpCloseHandle(value); }
private:
    std::atomic<HINTERNET> value_;
};

// WinHTTP's synchronous calls run only on the caller's worker. Closing the request
// interrupts a pending call, including DNS/TLS, when cancelled or the total 10s
// deadline expires. Join the watcher BEFORE destroying the WinHTTP parents.
class RequestDeadline {
public:
    RequestDeadline(Internet &request, std::atomic_bool *cancel, Clock::time_point end)
        : request_(request), cancel_(cancel), end_(end), thread_([this] { watch(); }) {}
    ~RequestDeadline() {
        { std::lock_guard<std::mutex> lock(mutex_); done_ = true; }
        wake_.notify_one();
        thread_.join();
    }
    void check() const {
        if (cancel_ && cancel_->load()) throw ServiceError("cancelled");
        if (Clock::now() >= end_) throw ServiceError("timeout");
    }
private:
    void watch() {
        std::unique_lock<std::mutex> lock(mutex_);
        while (!done_) {
            if ((cancel_ && cancel_->load()) || Clock::now() >= end_) {
                request_.close();
                return;
            }
            wake_.wait_for(lock, std::chrono::milliseconds(20));
        }
    }
    Internet &request_;
    std::atomic_bool *cancel_;
    Clock::time_point end_;
    std::mutex mutex_;
    std::condition_variable wake_;
    bool done_ = false;
    std::thread thread_;
};

void networkFailure(RequestDeadline &deadline) {
    const DWORD error = GetLastError();
    deadline.check();
    if (error == ERROR_WINHTTP_TIMEOUT) throw ServiceError("timeout");
    if (error == ERROR_WINHTTP_SECURE_FAILURE || error == ERROR_WINHTTP_SECURE_CERT_DATE_INVALID
        || error == ERROR_WINHTTP_SECURE_INVALID_CA || error == ERROR_WINHTTP_SECURE_CERT_CN_INVALID)
        throw ServiceError("tls_error");
    throw ServiceError("network_error");
}

bool white(wchar_t c) {
    WORD type = 0;
    return c == L'\t' || c == L'\n' || c == L'\r'
        || (GetStringTypeW(CT_CTYPE1, &c, 1, &type) && (type & C1_SPACE));
}
std::wstring trim(std::wstring text) {
    size_t first = 0, last = text.size();
    while (first < last && white(text[first])) ++first;
    while (last > first && white(text[last - 1])) --last;
    return text.substr(first, last - first);
}

std::wstring checkedText(const std::string &source, size_t &scalars) {
    if (source.empty() || source.size() > 512 * 4) throw ServiceError("invalid_request");
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         source.data(), static_cast<int>(source.size()), nullptr, 0);
    if (!count) throw ServiceError("invalid_request");
    std::wstring text(static_cast<size_t>(count), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source.data(),
                            static_cast<int>(source.size()), text.data(), count) != count)
        throw ServiceError("invalid_request");
    scalars = 0;
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == 0) throw ServiceError("invalid_request");
        ++scalars;
        if (text[i] >= 0xd800 && text[i] <= 0xdbff) ++i;
    }
    if (scalars > 512 || trim(text).empty()) throw ServiceError("invalid_request");
    return text;
}

bool volcanoHost(const std::string &host) {
    // Do not allow ports, userinfo, control characters, trailing dots or suffix
    // lookalikes. Certificate verification remains WinHTTP's secure default.
    constexpr char suffix[] = ".volcengineapi.com";
    if (host.empty() || host.size() > 253) return false;
    for (unsigned char c : host)
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.')) return false;
    if (host.front() == '.' || host.back() == '.' || host.find("..") != std::string::npos) return false;
    return host == "translate.volcengineapi.com"
        || (host.size() > sizeof(suffix) - 1
            && host.compare(host.size() - sizeof(suffix) + 1, sizeof(suffix) - 1, suffix) == 0);
}

std::string dateUTC() {
    SYSTEMTIME time{};
    GetSystemTime(&time);
    char value[32]{};
    std::snprintf(value, sizeof(value), "%04u%02u%02uT%02u%02u%02uZ",
                  time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond);
    return value;
}

std::string postTranslation(const std::string &host, const std::string &body,
                             const std::string &authorization, const std::string &date,
                             std::atomic_bool *cancel, Clock::time_point end) {
    if (cancel && cancel->load()) throw ServiceError("cancelled");
    if (Clock::now() >= end) throw ServiceError("timeout");
    Internet session(WinHttpOpen(L"Gogaku/1 (translation)", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                 WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
    if (!session.get()) throw ServiceError("network_error");
    WinHttpSetTimeouts(session.get(), 10000, 10000, 10000, 10000);
    Internet connection(WinHttpConnect(session.get(), wide(host).c_str(), INTERNET_DEFAULT_HTTPS_PORT, 0));
    if (!connection.get()) throw ServiceError("network_error");
    Internet request(WinHttpOpenRequest(connection.get(), L"POST",
        L"/?Action=TranslateText&Version=2020-06-01", nullptr, WINHTTP_NO_REFERER,
        WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE));
    if (!request.get()) throw ServiceError("network_error");
    DWORD redirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    DWORD disabled = WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
    DWORD logon = WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH;
    if (!WinHttpSetOption(request.get(), WINHTTP_OPTION_REDIRECT_POLICY, &redirect, sizeof(redirect))
        || !WinHttpSetOption(request.get(), WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled))
        || !WinHttpSetOption(request.get(), WINHTTP_OPTION_AUTOLOGON_POLICY, &logon, sizeof(logon)))
        throw ServiceError("network_error");
    RequestDeadline deadline(request, cancel, end);
    const auto headers = wide("Content-Type: application/json\r\nHost: " + host
        + "\r\nX-Date: " + date + "\r\nAuthorization: " + authorization
        + "\r\nCache-Control: no-store\r\n");
    if (!WinHttpSendRequest(request.get(), headers.c_str(), static_cast<DWORD>(headers.size()),
                             const_cast<char *>(body.data()), static_cast<DWORD>(body.size()),
                             static_cast<DWORD>(body.size()), 0)
        || !WinHttpReceiveResponse(request.get(), nullptr)) networkFailure(deadline);
    deadline.check();
    DWORD status = 0, size = sizeof(status);
    if (!WinHttpQueryHeaders(request.get(), WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                              WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX))
        networkFailure(deadline);
    // A redirect is an error, not a second request carrying credentials/source.
    if (status != 200) {
        if (status >= 300 && status < 400) throw ServiceError("redirect_blocked");
        if (status == 401 || status == 403) throw ServiceError("authentication_error");
        if (status == 429) throw ServiceError("rate_limited");
        throw ServiceError("backend_error");
    }
    std::string response;
    constexpr size_t limit = 1024 * 1024;
    char buffer[16384];
    for (;;) {
        deadline.check();
        DWORD read = 0;
        if (!WinHttpReadData(request.get(), buffer, sizeof(buffer), &read)) networkFailure(deadline);
        if (!read) break;
        if (read > limit - response.size()) throw ServiceError("response_too_large");
        response.append(buffer, read);
    }
    deadline.check();
    return response;
}

std::string cleanTranslation(const std::string &value) {
    // Match VolcengineText / Python's orphan-tail rule, NOT a local-model quality
    // gate. In particular, valid brands, short translations and mixed scripts
    // are not rejected just because a heuristic dislikes their wording.
    auto result = trim(wide(value));
    const std::wstring punctuation = L"\u201d\u2019'\"\u300d\u300f\uff09)!\uff1f?\u3002\uff0e\uff0c,\uff1b;\uff1a:\u2026\u00b7";
    for (;;) {
        size_t first = result.size();
        while (first > 0 && punctuation.find(result[first - 1]) != std::wstring::npos) --first;
        if (first == result.size() || first == 0 || !white(result[first - 1])) break;
        result = trim(result.substr(0, first));
    }
    return utf8(result);
}

template<class T> class ComPtr {
public:
    ~ComPtr() { if (value_) value_->Release(); }
    T *operator->() const { return value_; }
    T **put() { return &value_; }
    T *get() const { return value_; }
private:
    T *value_ = nullptr;
};
struct Apartment {
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ~Apartment() { if (SUCCEEDED(result)) CoUninitialize(); }
};
std::wstring folded(const std::wstring &word) {
    const int count = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE,
                                   word.data(), static_cast<int>(word.size()), nullptr, 0, nullptr, nullptr, 0);
    if (count <= 0) return word;
    std::wstring lower(static_cast<size_t>(count), L'\0');
    LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, word.data(), static_cast<int>(word.size()),
                  lower.data(), count, nullptr, nullptr, 0);
    return lower;
}
bool letter(wchar_t c) {
    WORD type = 0;
    return GetStringTypeW(CT_CTYPE1, &c, 1, &type) && (type & C1_ALPHA);
}
bool apostrophe(wchar_t c) { return c == L'\'' || c == 0x2019; }
struct Span { size_t first, last; };

std::vector<Span> exemptSpans(const std::wstring &text, const Json &ignoredWords) {
    std::set<std::wstring> ignored{
        L"gogaku", L"github", L"gitlab", L"openai", L"chatgpt", L"iphone", L"ipad",
        L"macos", L"ios", L"xcode", L"volcengine", L"nvidia", L"microsoft", L"google"
    };
    if (ignoredWords.is_array()) for (const auto &word : ignoredWords)
        if (word.is_string() && word.get_ref<const std::string &>().size() <= 2048)
            ignored.insert(folded(wide(word.get<std::string>())));
    std::vector<Span> spans;
    // URLs, emails, paths and code shapes: inspect a whole non-whitespace token,
    // so a spell issue inside a URL cannot escape through punctuation splitting.
    for (size_t i = 0; i < text.size();) {
        while (i < text.size() && white(text[i])) ++i;
        const size_t first = i;
        while (i < text.size() && !white(text[i])) ++i;
        if (i == first) break;
        const auto token = text.substr(first, i - first);
        bool code = token.find_first_of(L"@_\\/{}[]<>=`|#$%+~") != std::wstring::npos
            || token.find(L"::") != std::wstring::npos;
        for (size_t j = 0; j < token.size(); ++j) {
            if (token[j] >= L'0' && token[j] <= L'9') code = true;
            // Internal dots / hyphens are domain names, dotted code or brands;
            // a sentence-final dot is a word boundary, not an exemption.
            if ((token[j] == L'.' || token[j] == L'-') && j > 0 && j + 1 < token.size()
                && letter(token[j - 1]) && letter(token[j + 1])) code = true;
        }
        if (code) spans.push_back({first, i});
    }
    for (size_t i = 0; i < text.size();) {
        if (!letter(text[i])) { ++i; continue; }
        const size_t first = i;
        bool proper = false;
        while (i < text.size() && (letter(text[i]) || apostrophe(text[i]))) {
            // Conservative: capitalization / non-ASCII names are not dictionary
            // failures. This intentionally does not diagnose grammar/casing.
            if ((text[i] >= L'A' && text[i] <= L'Z') || text[i] > 127) proper = true;
            ++i;
        }
        if (proper || i == text.size() || ignored.count(folded(text.substr(first, i - first))))
            spans.push_back({first, i});
    }
    return spans;
}

Json spellOnWorker(const std::string &source, const Json &ignoredWords) {
    Json out{{"available", false}, {"availability", "unavailable"}, {"issues", Json::array()}};
    try {
        size_t scalars = 0;
        if (source.empty()) {
            // Still probe the dictionary; an empty input does not prove that the
            // system language dictionary exists.
            scalars = 0;
        }
        const auto text = source.empty() ? std::wstring() : checkedText(source, scalars);
        Apartment apartment;
        if (FAILED(apartment.result)) throw ServiceError("com_unavailable");
        ComPtr<ISpellCheckerFactory> factory;
        if (FAILED(CoCreateInstance(CLSID_SpellCheckerFactory, nullptr, CLSCTX_INPROC_SERVER,
                                    __uuidof(ISpellCheckerFactory), reinterpret_cast<void **>(factory.put()))))
            throw ServiceError("com_unavailable");
        ComPtr<ISpellChecker> checker;
        std::string language;
        for (const auto tag : {L"en-US", L"en-GB"}) {
            BOOL supported = FALSE;
            const HRESULT supportedResult = factory->IsSupported(tag, &supported);
            if (FAILED(supportedResult)) throw ServiceError("dictionary_unavailable");
            if (supported) {
                if (FAILED(factory->CreateSpellChecker(tag, checker.put())) || !checker.get())
                    throw ServiceError("dictionary_unavailable");
                language = utf8(tag);
                break;
            }
        }
        if (!checker.get()) throw ServiceError("dictionary_unavailable");
        ComPtr<IEnumSpellingError> errors;
        if (FAILED(checker->Check(text.c_str(), errors.put())) || !errors.get())
            throw ServiceError("spell_check_failed");
        const auto exempt = exemptSpans(text, ignoredWords);
        Json issues = Json::array();
        for (size_t count = 0; count <= text.size(); ++count) {
            ComPtr<ISpellingError> error;
            const HRESULT next = errors->Next(error.put());
            if (next == S_FALSE) break;
            if (FAILED(next) || !error.get()) throw ServiceError("spell_check_failed");
            ULONG start = 0, length = 0;
            CORRECTIVE_ACTION action = CORRECTIVE_ACTION_NONE;
            if (FAILED(error->get_StartIndex(&start)) || FAILED(error->get_Length(&length))
                || FAILED(error->get_CorrectiveAction(&action))) throw ServiceError("spell_check_failed");
            if (!length || action == CORRECTIVE_ACTION_NONE) continue;
            if (start > text.size() || length > text.size() - start)
                throw ServiceError("spell_check_failed");
            const size_t end = static_cast<size_t>(start) + length;
            const bool suppressed = std::any_of(exempt.begin(), exempt.end(), [&](const Span &span) {
                return static_cast<size_t>(start) < span.last && end > span.first;
            });
            if (!suppressed) issues.push_back({{"location", start}, {"length", length},
                {"explanation", "系统英语词典提示疑似拼写问题；可能是未收录词，可忽略，不会自动纠正。"}});
            if (count == text.size()) throw ServiceError("spell_check_failed");
        }
        out["available"] = true;
        out["availability"] = "available";
        out["language"] = language;
        out["error"] = nullptr;
        out["issues"] = std::move(issues);
    } catch (const ServiceError &error) {
        out["availability"] = error.what();
        out["error"] = error.what();
    } catch (...) {
        out["availability"] = "spell_check_failed";
        out["error"] = "spell_check_failed";
    }
    return out;
}
} // namespace

Json translate(const std::string &source, int direction, std::atomic_bool *cancel) {
    const auto start = Clock::now();
    Json out{{"ok", false}, {"target", nullptr}, {"characters", nullptr}, {"milliseconds", 0.0}, {"error", nullptr}};
    try {
        if (cancel && cancel->load()) throw ServiceError("cancelled");
        size_t scalars = 0;
        checkedText(source, scalars);
        if (direction != 0 && direction != 1) throw ServiceError("invalid_request");
        // Hot-read for EVERY explicit invocation, including settings tests.
        Json credentials;
        try { credentials = readCredentials(); } catch (...) { throw ServiceError("credentials_missing"); }
        if (!credentials.is_object() || !credentials.contains("accessKeyId")
            || !credentials["accessKeyId"].is_string() || !credentials.contains("secretAccessKey")
            || !credentials["secretAccessKey"].is_string()) throw ServiceError("credentials_missing");
        const auto access = credentials["accessKeyId"].get<std::string>();
        const auto secret = credentials["secretAccessKey"].get<std::string>();
        if (access.empty() || secret.empty()) throw ServiceError("credentials_missing");
        const auto host = credentials.value("host", std::string("translate.volcengineapi.com"));
        const auto region = credentials.value("region", std::string("cn-north-1"));
        if (!volcanoHost(host)) throw ServiceError("unsupported_host");
        if (access.size() > 4096 || secret.size() > 4096 || region.empty() || region.size() > 128
            || access.find_first_of("\r\n") != std::string::npos || access.find('\0') != std::string::npos
            || region.find_first_of("\r\n") != std::string::npos || region.find('\0') != std::string::npos)
            throw ServiceError("invalid_credentials");
        Json payload{{"SourceLanguage", direction == 0 ? "zh" : "en"},
                     {"TargetLanguage", direction == 0 ? "en" : "zh"}, {"TextList", Json::array({source})}};
        if (credentials.contains("requestOverrides") && !credentials["requestOverrides"].is_null()) {
            if (!credentials["requestOverrides"].is_object()) throw ServiceError("invalid_credentials");
            payload.update(credentials["requestOverrides"]);
        }
        // std::map key order, compact separators, literal UTF-8, unescaped '/' :
        // byte-for-byte Swift payload(...sortedKeys, withoutEscapingSlashes).
        // The Python signer accepts these same bytes (it does not reserialize).
        const auto body = payload.dump(-1, ' ', false, Json::error_handler_t::strict);
        if (body.size() >= 65536) throw ServiceError("invalid_request");
        const std::string query = "Action=TranslateText&Version=2020-06-01";
        const auto date = dateUTC(), day = date.substr(0, 8);
        const std::string canonicalHeaders = "content-type:application/json\nhost:" + host + "\nx-date:" + date + "\n";
        const std::string signedHeaders = "content-type;host;x-date";
        const auto canonical = "POST\n/\n" + query + "\n" + canonicalHeaders + "\n" + signedHeaders + "\n" + sha256(body);
        const auto scope = day + "/" + region + "/translate/request";
        const auto kDate = hmac256(secret, day);
        const auto kRegion = hmac256(kDate, region);
        const auto kService = hmac256(kRegion, "translate");
        const auto kSigning = hmac256(kService, "request");
        const auto signature = hex(hmac256(kSigning, "HMAC-SHA256\n" + date + "\n" + scope + "\n" + sha256(canonical)));
        const auto authorization = "HMAC-SHA256 Credential=" + access + "/" + scope
            + ", SignedHeaders=" + signedHeaders + ", Signature=" + signature;
        const auto bytes = postTranslation(host, body, authorization, date, cancel, start + std::chrono::seconds(10));
        const auto response = Json::parse(bytes, [](int depth, Json::parse_event_t, Json &) {
            if (depth > 32) throw ServiceError("invalid_response");
            return true;
        });
        if (cancel && cancel->load()) throw ServiceError("cancelled");
        if (response.contains("ResponseMetadata") && response["ResponseMetadata"].is_object()
            && response["ResponseMetadata"].contains("Error") && !response["ResponseMetadata"]["Error"].is_null())
            throw ServiceError("backend_error");
        if (!response.contains("TranslationList") || !response["TranslationList"].is_array()
            || response["TranslationList"].empty()) throw ServiceError("backend_error");
        const auto &entry = response["TranslationList"][0];
        if (!entry.is_object() || !entry.contains("Translation") || !entry["Translation"].is_string())
            throw ServiceError("empty_output");
        const auto target = cleanTranslation(entry["Translation"].get<std::string>());
        if (target.empty()) throw ServiceError("empty_output");
        uint64_t characters = scalars;
        if (entry.contains("Extra") && entry["Extra"].is_object()) {
            const auto &extra = entry["Extra"];
            if (extra.contains("input_characters")) {
                const auto &number = extra["input_characters"];
                if (number.is_number_unsigned()) characters = number.get<uint64_t>();
                else if (number.is_number_integer() && number.get<int64_t>() >= 0)
                    characters = static_cast<uint64_t>(number.get<int64_t>());
                else if (number.is_string()) {
                    const auto value = number.get<std::string>();
                    if (!value.empty() && value.size() <= 19
                        && std::all_of(value.begin(), value.end(), [](char c) { return c >= '0' && c <= '9'; })) {
                        try { characters = std::stoull(value); } catch (...) {}
                    }
                }
            }
        }
        out["ok"] = true;
        out["target"] = target;
        out["characters"] = characters;
        // A bookkeeping failure must not discard a usable external translation.
        try { addUsage(characters); out["usageRecorded"] = true; }
        catch (...) { out["usageRecorded"] = false; }
    } catch (const ServiceError &error) {
        out["error"] = error.what();
    } catch (const Json::exception &) {
        out["error"] = "invalid_response";
    } catch (...) {
        out["error"] = "backend_error";
    }
    out["milliseconds"] = std::chrono::duration<double, std::milli>(Clock::now() - start).count();
    return out;
}

Json spell(const std::string &source, const Json &ignoredWords) {
    // A fresh MTA worker owns every COM pointer: no apartment-bound interface is
    // shared with TSF / the settings UI. The agent should itself dispatch RPCs
    // off its pipe accept loop; this function never edits a host document.
    try {
        return std::async(std::launch::async, [&] { return spellOnWorker(source, ignoredWords); }).get();
    } catch (...) {
        return Json{{"available", false}, {"availability", "com_unavailable"},
                    {"issues", Json::array()}, {"error", "com_unavailable"}};
    }
}
} // namespace gw
