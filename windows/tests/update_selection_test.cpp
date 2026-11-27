// Include the Windows implementation to exercise the real scanner with an offline transport.
#include "../GogakuWindows/update.cpp"
#include <iostream>

namespace gw {
namespace {
void expect(bool value, const char *message) {
    if (!value) throw std::runtime_error(message);
}

void testSelection() {
    uint8_t seed[32] = {42}, secret[64], key[32];
    crypto_ed25519_key_pair(secret, key, seed);
    const Source source{"gomeen", "gokaku", Json::array({
        {{"keyId", "production"}, {"publicKey", base64Encode(std::string(reinterpret_cast<char *>(key), 32))}}
    })};
    const Installation current{"0.3.0", "stable", "10.0.22631", 121};
    const std::string setup =
#ifdef GOGAKU_LITE
        "GogakuLite-0.5.3-windows-x64-setup.exe";
    const std::string otherSetup = "Gogaku-0.5.3-windows-x64-setup.exe";
    const std::string manifest = "update-manifest-lite.json";
    const std::string otherManifest = "update-manifest.json";
#else
        "Gogaku-0.5.3-windows-x64-setup.exe";
    const std::string otherSetup = "GogakuLite-0.5.3-windows-x64-setup.exe";
    const std::string manifest = "update-manifest.json";
    const std::string otherManifest = "update-manifest-lite.json";
#endif
    std::map<uint64_t, std::string> blobs;
    auto release = [&](int id, int build, const char *keyId, const std::string &manifestName,
                       const std::string &setupName, bool tamper = false) {
        auto asset = [id](int index, const std::string &name, size_t size) -> Json {
            return {{"id", id * 10 + index}, {"name", name}, {"size", size},
                    {"browser_download_url", "https://github.com/gomeen/gokaku/releases/download/v0.5.3/" + name}};
        };
        auto signedAsset = [&](int index, const std::string &name, const char *platform) -> Json {
            return {{"assetId", id * 10 + index}, {"name", name}, {"size", 1}, {"arch", "x86_64"},
                    {"platform", platform}, {"minOS", "10.0"}, {"sha256", std::string(64, 'a')}};
        };
        auto raw = Json{{"schema", 1}, {"version", "0.5.3"}, {"channel", "stable"},
                        {"buildNumber", build}, {"keyId", keyId}, {"notes", ""},
                        {"assets", Json::array({signedAsset(3, "main.pkg", "macos"),
                                                signedAsset(4, setupName, "windows")})}}.dump();
        uint8_t signature[64];
        crypto_ed25519_sign(signature, secret, reinterpret_cast<const uint8_t *>(raw.data()), raw.size());
        if (tamper) signature[0] ^= 1;
        auto sig = std::string(reinterpret_cast<char *>(signature), 64);
        blobs[id * 10 + 1] = raw;
        blobs[id * 10 + 2] = sig;
        return Json{{"id", id}, {"draft", false}, {"prerelease", false}, {"tag_name", "v0.5.3"},
                    {"assets", Json::array({asset(1, manifestName, raw.size()), asset(2, manifestName + ".sig", sig.size()),
                                            asset(3, "main.pkg", 1), asset(4, setupName, 1)})}};
    };
    auto evaluate = [&](const Json &releases, const Installation &installed) {
        try {
            return evaluateReleases(releases, source, installed, nullptr,
                [&](const Json &asset, uint64_t, std::atomic_bool *) { return blobs.at(positive(asset, "id")); });
        } catch (const UpdateError &error) { return failed(error); }
    };
    const auto latest = release(1, 135, "production", manifest, setup);
    const auto old = release(2, 113, "old-development", manifest, setup);
    const auto wrongFlavor = release(3, 136, "production", otherManifest, otherSetup);
    const auto wrongPackage = release(4, 136, "production", manifest, otherSetup);
    const auto tampered = release(5, 137, "production", manifest, setup, true);
    const auto intermediate = release(6, 134, "production", manifest, setup);

    auto result = evaluate(Json::array({wrongFlavor, intermediate, latest, old}), current);
    expect(result["status"] == "available" && result["offer"]["buildNumber"] == 135 &&
           result["offer"]["asset"]["name"] == setup, "历史未知密钥、产品隔离或最高可信构建选择失败");
    expect(evaluate(Json::array({latest, old}), {"0.5.3", "stable", current.os, 135})["status"] == "upToDate",
           "当前构建不能因历史未知密钥而报错");
    expect(evaluate(Json::array({old}), current)["error"] == "unknown_key", "只有未知密钥时必须失败");
    expect(evaluate(Json::array({latest, tampered}), current)["error"] == "invalid_signature", "已知密钥的坏签名必须失败");
    expect(evaluate(Json::array({wrongFlavor}), current)["status"] == "noManifest", "不能回退到另一产品的清单");
    expect(evaluate(Json::array({wrongPackage}), current)["error"] == "invalid_manifest", "不能选择另一产品的安装包");
}
} // namespace
} // namespace gw

int main() {
    try {
        gw::testSelection();
        std::cout << "Windows update selection: PASS\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
