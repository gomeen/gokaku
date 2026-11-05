#include "core_bridge.h"

#include <shlobj.h>

std::string Utf16ToUtf8(const std::wstring &w) {
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

std::wstring Utf8ToUtf16(const std::string &s) {
    if (s.empty()) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), w.data(), n);
    return w;
}

HINSTANCE g_hInst = nullptr;

CoreBridge &CoreBridge::instance() {
    static CoreBridge b;
    return b;
}

bool CoreBridge::ensureLoaded() {
    if (m_core) return true;
    wchar_t path[MAX_PATH];
    if (!GetModuleFileNameW(g_hInst, path, MAX_PATH)) return false;
    std::wstring dir(path);
    size_t slash = dir.find_last_of(L'\\');
    if (slash == std::wstring::npos) return false;
    m_moduleDir = dir.substr(0, slash);
    m_dataDir = m_moduleDir + L"\\data";

    std::wstring corePath = m_moduleDir + L"\\gogaku_core.dll";
    /* LOAD_WITH_ALTERED_SEARCH_PATH：依赖 DLL 按本 DLL 目录解析。 */
    m_core = LoadLibraryExW(corePath.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!m_core) return false;

    p_create = (fn_gc_normal_session_create)GetProcAddress(m_core, "gc_normal_session_create");
    p_destroy = (fn_gc_normal_session_destroy)GetProcAddress(m_core, "gc_normal_session_destroy");
    p_handle = (fn_gc_normal_handle)GetProcAddress(m_core, "gc_normal_handle");
    p_copy_raw = (fn_gc_normal_copy_raw)GetProcAddress(m_core, "gc_normal_copy_raw");
    p_flush = (fn_gc_normal_flush)GetProcAddress(m_core, "gc_normal_flush");
    p_reload = (fn_gc_normal_reload_custom_words)GetProcAddress(m_core, "gc_normal_reload_custom_words");
    p_clear = (fn_gc_normal_clear_user_data)GetProcAddress(m_core, "gc_normal_clear_user_data");
    if (!p_create || !p_destroy || !p_handle || !p_flush) {
        FreeLibrary(m_core);
        m_core = nullptr;
        return false;
    }

    /* ABI 版本合同：加载即校验，不匹配拒绝工作。 */
    typedef int32_t (*fn_gc_abi_check)(int32_t);
    fn_gc_abi_check abiCheck = (fn_gc_abi_check)GetProcAddress(m_core, "gc_abi_check");
    if (!abiCheck || abiCheck(GOGAKU_CORE_ABI_VERSION) != 0) {
        FreeLibrary(m_core);
        m_core = nullptr;
        return false;
    }
    return true;
}

void CoreBridge::ensureUserDir() const {
    if (!m_userDir.empty()) return;
    wchar_t *appData = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &appData))) {
        m_userDir = std::wstring(appData) + L"\\Gogaku";
        CoTaskMemFree(appData);
    } else {
        m_userDir = m_moduleDir; /* 兜底：安装目录（可能无写权限） */
    }
    SHCreateDirectoryExW(nullptr, m_userDir.c_str(), nullptr);
    SHCreateDirectoryExW(nullptr, (m_userDir + L"\\user").c_str(), nullptr);
}

const std::wstring &CoreBridge::userDir() const {
    ensureUserDir();
    return m_userDir;
}

std::string CoreBridge::fileUtf8(const std::wstring &d, const wchar_t *name) const {
    return Utf16ToUtf8(d + L"\\" + name);
}

std::string CoreBridge::dataFileUtf8(const wchar_t *name) { return fileUtf8(m_dataDir, name); }

std::string CoreBridge::userFileUtf8(const wchar_t *name) {
    ensureUserDir();
    return fileUtf8(m_userDir, name);
}

int CoreBridge::normalCreate(GcNormalSession **out, char *err, size_t errLen) {
    if (!m_core) return 1;
    GcNormalConfig cfg{};
    std::string dict = dataFileUtf8(L"sc.dict");
    std::string model = dataFileUtf8(L"zh_CN.lm");
    std::string custom = userFileUtf8(L"custom-words.tsv");
    std::string english = dataFileUtf8(L"english-words.txt");
    std::string gloss = dataFileUtf8(L"gloss.tsv");
    std::string user = Utf16ToUtf8(userDir() + L"\\user");
    cfg.dict_path = dict.c_str();
    cfg.model_path = model.c_str();
    cfg.user_dir = user.c_str();
    cfg.custom_words_path = custom.c_str();
    cfg.english_words_path = english.c_str();
    cfg.gloss_path = gloss.c_str();
    Settings st = readSettings();
    cfg.scheme = st.scheme;
    cfg.fuzzy_mask = st.fuzzyMask;
    cfg.full_pinyin_preedit = st.fullPinyinPreedit;
    cfg.freq_enabled = st.freqEnabled;
    cfg.english_enabled = st.englishEnabled;
    return p_create(&cfg, out, err, errLen);
}

void CoreBridge::normalDestroy(GcNormalSession *s) { if (p_destroy) p_destroy(s); }
int CoreBridge::normalHandle(GcNormalSession *s, const GcKeyEvent *ev, GcSnapshot **out) {
    return p_handle ? p_handle(s, ev, out) : 1;
}
size_t CoreBridge::normalCopyRaw(GcNormalSession *s, char *buf, size_t cap) {
    return p_copy_raw ? p_copy_raw(s, buf, cap) : 0;
}
int CoreBridge::normalFlush(GcNormalSession *s) { return p_flush ? p_flush(s) : 1; }
int CoreBridge::normalReloadCustomWords(GcNormalSession *s) { return p_reload ? p_reload(s) : 1; }
int CoreBridge::normalClearUserData(GcNormalSession *s) { return p_clear ? p_clear(s) : 1; }

CoreBridge::Settings CoreBridge::readSettings() const {
    ensureUserDir();
    Settings st;
    std::wstring path = m_userDir + L"\\settings.txt";
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return st;
    char buf[4096] = {};
    DWORD got = 0;
    ReadFile(h, buf, sizeof(buf) - 1, &got, nullptr);
    CloseHandle(h);
    /* 简单 key=value 解析（每行一条，# 开头为注释）。 */
    char *ctx = nullptr;
    for (char *line = strtok_s(buf, "\r\n", &ctx); line; line = strtok_s(nullptr, "\r\n", &ctx)) {
        char *hash = strchr(line, '#');
        if (hash) *hash = '\0';
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = '\0';
        std::string key(line), val(eq + 1);
        auto trim = [](std::string &x) {
            size_t a = x.find_first_not_of(" \t");
            size_t b = x.find_last_not_of(" \t");
            x = (a == std::string::npos) ? std::string() : x.substr(a, b - a + 1);
        };
        trim(key);
        trim(val);
        if (key == "scheme") st.scheme = val == "full" ? GC_SCHEME_FULLPINYIN : GC_SCHEME_XIAOHE;
        else if (key == "full_pinyin_preedit") st.fullPinyinPreedit = val == "1" ? 1 : 0;
        else if (key == "freq_enabled") st.freqEnabled = val == "1" ? 1 : 0;
        else if (key == "english_enabled") st.englishEnabled = val == "1" ? 1 : 0;
        else if (key == "learning_enabled") st.learningEnabled = val == "1";
        else if (key == "fuzzy") {
            st.fuzzyMask = 0;
            if (val.find("z/zh") != std::string::npos) st.fuzzyMask |= GC_FUZZY_Z_ZH;
            if (val.find("c/ch") != std::string::npos) st.fuzzyMask |= GC_FUZZY_C_CH;
            if (val.find("s/sh") != std::string::npos) st.fuzzyMask |= GC_FUZZY_S_SH;
            if (val.find("n/l") != std::string::npos) st.fuzzyMask |= GC_FUZZY_N_L;
            if (val.find("f/h") != std::string::npos) st.fuzzyMask |= GC_FUZZY_F_H;
            if (val.find("l/r") != std::string::npos) st.fuzzyMask |= GC_FUZZY_L_R;
        }
    }
    return st;
}
