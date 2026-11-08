#include "core_bridge.h"
std::string Utf16ToUtf8(const std::wstring &value) { return gw::utf8(value); }
std::wstring Utf8ToUtf16(const std::string &value) { return gw::wide(value); }
bool CoreBridge::connect() { return rpc_.connect(g_hInst); }
bool CoreBridge::warmUp() { return rpc_.connect(g_hInst, 5000); }
bool CoreBridge::request(const gw::Json &request, gw::Json &view) {
    gw::Json response;
    // Keep the request bounded while allowing a cold Windows host to be
    // scheduled. A 60 ms deadline disconnected live compositions in the VM.
    // 200 ms was exceeded by lock-held frequency flushes on slow VMs, which
    // made already-processed keys fall through and duplicate in the host.
    if (!rpc_.call(request,response,400)) return false;
    if (!response.value("ok",false)) return false;
    view=response.value("view",gw::Json::object()); return true;
}
