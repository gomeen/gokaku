/* 共享核心 C ABI 桥：从本 DLL 所在目录加载 gogaku_core.dll（Clang64 构建），
 * 解析 gc_* 函数；数据与用户目录路径在此集中管理。
 *
 * 关键细节：核心 DLL 依赖同目录的 IMECore/Fcitx5Utils 等，必须用
 * LOAD_WITH_ALTERED_SEARCH_PATH 让依赖按被加载 DLL 自身目录解析。
 */
#pragma once

#include "stdafx.h"

class CoreBridge {
public:
    static CoreBridge &instance();

    /* 加载核心 DLL；成功后路径均就绪。重复调用幂等。 */
    bool ensureLoaded();
    bool loaded() const { return m_core != nullptr; }

    const std::wstring &moduleDir() const { return m_moduleDir; }
    const std::wstring &dataDir() const { return m_dataDir; }   /* <dir>\data */
    const std::wstring &userDir() const;                        /* %LOCALAPPDATA%\Gogaku */

    std::string dataFileUtf8(const wchar_t *name);              /* data\ 下文件 */
    std::string userFileUtf8(const wchar_t *name);              /* 用户目录下文件 */

    /* 普通模式会话。 */
    int normalCreate(GcNormalSession **out, char *err, size_t errLen);
    void normalDestroy(GcNormalSession *s);
    int normalHandle(GcNormalSession *s, const GcKeyEvent *ev, GcSnapshot **out);
    size_t normalCopyRaw(GcNormalSession *s, char *buf, size_t cap);
    int normalFlush(GcNormalSession *s);
    int normalReloadCustomWords(GcNormalSession *s);
    int normalClearUserData(GcNormalSession *s);

    /* 设置项（settings.txt 简单键值；设置应用之后接入）。 */
    struct Settings {
        int32_t scheme = GC_SCHEME_XIAOHE;
        uint32_t fuzzyMask = 0;
        int32_t fullPinyinPreedit = 1;
        int32_t freqEnabled = 1;
        int32_t englishEnabled = 1;
        bool learningEnabled = false;
    };
    Settings readSettings() const;

private:
    CoreBridge() = default;
    HMODULE m_core = nullptr;
    std::wstring m_moduleDir, m_dataDir;
    mutable std::wstring m_userDir;

    typedef int (*fn_gc_normal_session_create)(const GcNormalConfig *, GcNormalSession **, char *, size_t);
    typedef void (*fn_gc_normal_session_destroy)(GcNormalSession *);
    typedef int (*fn_gc_normal_handle)(GcNormalSession *, const GcKeyEvent *, GcSnapshot **);
    typedef size_t (*fn_gc_normal_copy_raw)(GcNormalSession *, char *, size_t);
    typedef int (*fn_gc_normal_flush)(GcNormalSession *);
    typedef int (*fn_gc_normal_reload_custom_words)(GcNormalSession *);
    typedef int (*fn_gc_normal_clear_user_data)(GcNormalSession *);

    fn_gc_normal_session_create p_create = nullptr;
    fn_gc_normal_session_destroy p_destroy = nullptr;
    fn_gc_normal_handle p_handle = nullptr;
    fn_gc_normal_copy_raw p_copy_raw = nullptr;
    fn_gc_normal_flush p_flush = nullptr;
    fn_gc_normal_reload_custom_words p_reload = nullptr;
    fn_gc_normal_clear_user_data p_clear = nullptr;

    std::string fileUtf8(const std::wstring &dir, const wchar_t *name) const;
    void ensureUserDir() const;
};
