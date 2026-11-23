// 扩展词库渠道（Windows 设置应用侧）的共享声明；实现在 dictionaries.cpp。
// 合同见 docs/dictionaries.md §七：字段与合同校验只有共享核心一份实现
// （gc_dict_catalog_parse／gc_dict_install 由调用方传入函数指针）；
// 本模块只做 WinHTTP 传输与 monocypher Ed25519 验签。
#ifndef GOGAKU_DICTINARIES_H
#define GOGAKU_DICTINARIES_H
#include "platform.h"
#include <atomic>
#include <functional>

namespace gw {

// 核心侧函数指针（由调用方从 libgogaku_core.dll 解析后传入；本文件不加载 DLL）。
struct DictCoreApis {
    int (*catalog_parse)(const uint8_t *, size_t, const char *, const char *, char **, char *, size_t);
    int (*install)(const char *, const char *, const char *, char *, size_t);
    void (*contract_free)(void *);
};

// 拉取并校验官方清单。catalogConfig：{owner, repo, trustedKeyIds}；
// updateKeys：检查更新配置里的 trustedKeys（公钥材料同源）；installed：本地列表。
// 返回 {ok, catalogVersion, entries, rejected}；失败抛出稳定错误码（调用方转文案）。
Json fetchDictionaryCatalog(const DictCoreApis &apis, const Json &catalogConfig,
                            const Json &updateKeys, const Json &installed,
                            std::atomic_bool *cancel = nullptr);

// 下载并安装一个官方词库（entry 含 catalogVersion 透传）。
// 哈希与大小校验在核心（gc_dict_install 返回 4 = 不符）。
void installDictionary(const DictCoreApis &apis, const std::string &dictionariesDir,
                       const Json &entry, long long catalogVersion, std::atomic_bool *cancel = nullptr,
                       const std::function<void(double)> &progress = {});

}
#endif
