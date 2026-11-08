#pragma once
#include "stdafx.h"
#include "../../GogakuWindows/platform.h"

// x86/x64 TSF 都只连接当前用户 x64 代理，不加载业务核心或联网。
class CoreBridge {
public:
    bool connect();
    bool warmUp();
    bool request(const gw::Json &request, gw::Json &view);
    bool connected() const { return rpc_.connected(); }
    void close() { rpc_.close(); }
private:
    gw::RpcClient rpc_;
};
