// Candidate theme data, bounded ZIP v1 and real WIC image normalization.
// miniz 3.0.2 is used only for bounded, in-memory inflate (no archive extraction).
#include "platform.h"
#include "../GogakuCore/include/gogaku_core.h"
#include <wincodec.h>
#include <objbase.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <stdexcept>
#include "third_party/miniz.h"
// Keep the inflate-only implementation in this TU: no additional build target.
#include "third_party/miniz_tinfl.c"

namespace gw {
namespace {
constexpr size_t MiB = 1024 * 1024, ImageLimit = 8 * MiB, ManifestLimit = 16 * MiB;
constexpr size_t ArchiveLimit = 24 * MiB, ExpandedLimit = 20 * MiB;
const char *Colors[] = {"background", "border", "text", "comment", "index", "highlight", "highlightText", "highlightComment", "cursor", "page"};
[[noreturn]] void bad(const char *s) { throw std::runtime_error(s); }
void check(HRESULT hr, const char *s) { if (FAILED(hr)) bad(s); }
template<class T> struct Com {
    T *p = nullptr;
    ~Com() { if (p) p->Release(); }
    T **out() { if (p) { p->Release(); p = nullptr; } return &p; }
    T *operator->() const { return p; }
};
struct Apartment {
    HRESULT result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ~Apartment() { if (SUCCEEDED(result)) CoUninitialize(); }
};
uint16_t le16(const std::string &s, size_t i) {
    if (i > s.size() || s.size() - i < 2) bad("ZIP/图片结构截断。");
    return uint8_t(s[i]) | uint16_t(uint8_t(s[i + 1])) << 8;
}
uint32_t le32(const std::string &s, size_t i) { return le16(s, i) | uint32_t(le16(s, i + 2)) << 16; }
uint32_t be32(const std::string &s, size_t i) {
    if (i > s.size() || s.size() - i < 4) bad("图片结构截断。");
    return uint32_t(uint8_t(s[i])) << 24 | uint32_t(uint8_t(s[i + 1])) << 16 |
           uint32_t(uint8_t(s[i + 2])) << 8 | uint8_t(s[i + 3]);
}
uint32_t crc(const char *data, size_t length) {
    static const std::array<uint32_t, 256> table = [] {
        std::array<uint32_t, 256> t{};
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int b = 0; b < 8; ++b) c = (c >> 1) ^ ((c & 1) ? 0xedb88320u : 0);
            t[i] = c;
        }
        return t;
    }();
    uint32_t c = ~0u;
    for (size_t i = 0; i < length; ++i) c = table[(c ^ uint8_t(data[i])) & 255] ^ (c >> 8);
    return ~c;
}
std::string inflateBytes(const char *data, size_t size, size_t expected, bool zlib) {
    // Fixed output budget; never permit the decompressor to allocate from a declaration.
    if (!expected || expected > 135 * MiB) bad("展开长度无效。");
    std::string out(expected, '\0');
    tinfl_decompressor d{};
    tinfl_init(&d);
    size_t input = size, output = expected;
    const auto status = tinfl_decompress(&d, reinterpret_cast<const mz_uint8 *>(data), &input,
        reinterpret_cast<mz_uint8 *>(out.data()), reinterpret_cast<mz_uint8 *>(out.data()), &output,
        TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF | (zlib ? TINFL_FLAG_PARSE_ZLIB_HEADER : 0));
    if (status != TINFL_STATUS_DONE || input != size || output != expected) bad("压缩流损坏、截断或展开长度不一致。");
    return out;
}
size_t stringLength(const Json &j, const char *label, size_t max) {
    if (!j.is_string()) bad(label);
    const auto s = j.get<std::string>();
    if (s.empty() || s.size() > max * 4 || !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), int(s.size()), nullptr, 0)) bad(label);
    size_t n = 0; bool visible = false;
    for (unsigned char c : s) { if ((c & 0xc0) != 0x80) ++n; if (c > 32) visible = true; if (c < 32 || c == 127) bad(label); }
    if (!visible || n > max) bad(label);
    return n;
}
void number(const Json &j, const char *key, double fallback, double low, double high) {
    if (!j.contains(key)) return;
    if (!j[key].is_number()) bad("主题参数必须是数字。");
    const auto v = j.value(key, fallback);
    if (!std::isfinite(v) || v < low || v > high) bad("主题参数超出允许范围。");
}
// Image containers are inspected in addition to WIC: WIC may tolerate truncation.
void inspectImage(const std::string &s) {
    if (s.empty() || s.size() > ImageLimit) bad("图片不能为空，且不能超过 8 MiB。");
    if (s.compare(0, 8, "\x89PNG\r\n\x1a\n", 8) == 0) {
        size_t p = 8; bool header = false, pixels = false, pixelsEnded = false;
        std::string compressed; std::vector<size_t> rows;
        while (p + 12 <= s.size()) {
            size_t n = be32(s, p);
            if (n > s.size() - p - 12) bad("PNG 数据截断。");
            const auto type = s.substr(p + 4, 4);
            if (crc(s.data() + p + 4, n + 4) != be32(s, p + 8 + n)) bad("PNG CRC 校验失败。");
            if (!header) {
                if (type != "IHDR" || n != 13) bad("PNG 缺少有效 IHDR。");
                const size_t w = be32(s, p + 8), h = be32(s, p + 12);
                if (!w || !h || w > 4096 || h > 4096) bad("图片宽高必须在 1–4096 像素之间。");
                int depth = uint8_t(s[p + 16]), color = uint8_t(s[p + 17]), channels = 0;
                bool validDepth = false;
                if (color == 0) { channels = 1; validDepth = depth == 1 || depth == 2 || depth == 4 || depth == 8 || depth == 16; }
                if (color == 2) { channels = 3; validDepth = depth == 8 || depth == 16; }
                if (color == 3) { channels = 1; validDepth = depth == 1 || depth == 2 || depth == 4 || depth == 8; }
                if (color == 4) { channels = 2; validDepth = depth == 8 || depth == 16; }
                if (color == 6) { channels = 4; validDepth = depth == 8 || depth == 16; }
                unsigned interlace = uint8_t(s[p + 20]);
                if (!channels || !validDepth || s[p + 18] || s[p + 19] || interlace > 1) bad("PNG 颜色、位深或交错参数无效。");
                if (!interlace) rows.assign(h, (w * channels * depth + 7) / 8 + 1);
                else {
                    const int passes[][4] = {{0,0,8,8},{4,0,8,8},{0,4,4,8},{2,0,4,4},{0,2,2,4},{1,0,2,2},{0,1,1,2}};
                    for (const auto &pass : passes) if (w > size_t(pass[0]) && h > size_t(pass[1])) {
                        size_t width = (w - pass[0] + pass[2] - 1) / pass[2];
                        size_t height = (h - pass[1] + pass[3] - 1) / pass[3];
                        rows.insert(rows.end(), height, (width * channels * depth + 7) / 8 + 1);
                    }
                }
                header = true;
            } else if (type == "IHDR") bad("PNG 包含重复 IHDR。");
            if (type == "acTL" || type == "fcTL" || type == "fdAT") bad("不接受动画图片。");
            if (type == "IDAT") {
                if (pixelsEnded) bad("PNG 像素块顺序无效。");
                pixels = true; compressed.append(s, p + 8, n);
            } else if (pixels) pixelsEnded = true;
            p += n + 12;
            if (type == "IEND") {
                if (n || !pixels || p != s.size()) bad("PNG 结尾或像素数据无效。");
                size_t expected = 0; for (auto row : rows) expected += row;
                const auto raw = inflateBytes(compressed.data(), compressed.size(), expected, true);
                size_t offset = 0;
                for (auto row : rows) { if (uint8_t(raw[offset]) > 4) bad("PNG 过滤字节无效。"); offset += row; }
                return;
            }
        }
        bad("PNG 未完整结束。");
    }
    if (s.size() >= 4 && uint8_t(s[0]) == 255 && uint8_t(s[1]) == 216) {
        size_t p = 2; bool scan = false, hasScan = false;
        while (p < s.size()) {
            if (scan && uint8_t(s[p]) != 255) { ++p; continue; }
            if (uint8_t(s[p]) != 255) bad("JPEG 标记损坏。");
            while (p < s.size() && uint8_t(s[p]) == 255) ++p;
            if (p == s.size()) break;
            unsigned marker = uint8_t(s[p++]);
            if (scan && (!marker || (marker >= 208 && marker <= 215))) continue;
            scan = false;
            if (marker == 217) { if (hasScan && p == s.size()) return; break; }
            if (!marker || marker == 216 || (marker >= 208 && marker <= 215) || p + 2 > s.size()) break;
            size_t n = uint8_t(s[p]) * 256 + uint8_t(s[p + 1]);
            if (n < 2 || n > s.size() - p) break;
            p += n;
            if (marker == 218) { scan = true; hasScan = true; }
        }
        bad("JPEG 截断、标记损坏或含有尾随内容。");
    }
    if (s.size() >= 12 && s.compare(0, 4, "RIFF") == 0 && s.compare(8, 4, "WEBP") == 0) {
        if (le32(s, 4) != s.size() - 8) bad("WebP 长度不一致。");
        size_t p = 12, pixels = 0;
        while (p + 8 <= s.size()) {
            const auto type = s.substr(p, 4); size_t n = le32(s, p + 4);
            if (n > s.size() - p - 8) bad("WebP 数据截断。");
            if (type == "ANIM" || type == "ANMF" || (type == "VP8X" && n && (uint8_t(s[p+8]) & 2))) bad("不接受动画 WebP。");
            if (type == "VP8 " || type == "VP8L") ++pixels;
            p += 8 + n + (n & 1);
        }
        if (p == s.size() && pixels == 1) return;
        bad("WebP 数据不完整或帧数无效。");
    }
    bad("只接受完整的单帧 PNG、JPEG 或 WebP 图片。");
}
std::string normalizedImage(const std::string &s) {
    inspectImage(s);
    Apartment apartment;
    Com<IWICImagingFactory> factory;
    check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(factory.out())), "Windows 图片解码服务不可用。");
    Com<IWICStream> input;
    check(factory->CreateStream(input.out()), "无法建立图片流。");
    check(input->InitializeFromMemory(reinterpret_cast<BYTE *>(const_cast<char *>(s.data())), DWORD(s.size())), "无法读取图片流。");
    Com<IWICBitmapDecoder> decoder;
    const auto decode = factory->CreateDecoderFromStream(input.p, nullptr, WICDecodeMetadataCacheOnLoad, decoder.out());
    if (FAILED(decode)) {
        if (s.size() > 12 && s.compare(8, 4, "WEBP") == 0) bad("此系统未提供可用的 WebP 解码器；请选择 PNG 或 JPEG。未导入图片。");
        bad("图片无法实际解码，请重新导出后再试。");
    }
    UINT frames = 0; check(decoder->GetFrameCount(&frames), "无法读取图片帧数。");
    if (frames != 1) bad("只接受单帧图片。");
    Com<IWICBitmapFrameDecode> frame;
    check(decoder->GetFrame(0, frame.out()), "无法解码图片帧。");
    UINT w = 0, h = 0; check(frame->GetSize(&w, &h), "无法读取图片尺寸。");
    if (!w || !h || w > 4096 || h > 4096) bad("图片宽高必须在 1–4096 像素之间。");
    Com<IWICFormatConverter> converter;
    check(factory->CreateFormatConverter(converter.out()), "无法转换图片。");
    check(converter->Initialize(frame.p, GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom), "无法完整解码图片像素。");
    // Honor embedded color profiles, converting to sRGB. Unprofiled sources are sRGB.
    Com<IWICColorContext> source, destination;
    Com<IWICColorTransform> transform;
    IWICBitmapSource *pixels = converter.p;
    UINT contexts = 0;
    if (SUCCEEDED(frame->GetColorContexts(0, nullptr, &contexts)) && contexts) {
        check(factory->CreateColorContext(source.out()), "无法读取图片色彩空间。");
        IWICColorContext *context = source.p;
        check(frame->GetColorContexts(1, &context, &contexts), "图片色彩配置损坏。");
        check(factory->CreateColorContext(destination.out()), "无法创建 sRGB 色彩空间。");
        check(destination->InitializeFromExifColorSpace(1), "无法初始化 sRGB。");
        check(factory->CreateColorTransformer(transform.out()), "无法转换色彩空间。");
        check(transform->Initialize(frame.p, source.p, destination.p, GUID_WICPixelFormat32bppBGRA), "图片色彩配置无法转换为 sRGB。");
        pixels = transform.p;
    }
    std::vector<BYTE> raster(size_t(w) * h * 4);
    check(pixels->CopyPixels(nullptr, w * 4, UINT(raster.size()), raster.data()), "图片像素解码失败；未保存不完整图片。");
    Com<IWICBitmap> bitmap;
    check(factory->CreateBitmapFromMemory(w, h, GUID_WICPixelFormat32bppBGRA, w * 4, UINT(raster.size()), raster.data(), bitmap.out()), "无法创建安全位图。");
    Com<IStream> output;
    check(CreateStreamOnHGlobal(nullptr, TRUE, output.out()), "无法建立 PNG 输出流。");
    Com<IWICBitmapEncoder> encoder; Com<IWICBitmapFrameEncode> encoded;
    check(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, encoder.out()), "PNG 编码器不可用。");
    check(encoder->Initialize(output.p, WICBitmapEncoderNoCache), "无法开始 PNG 编码。");
    check(encoder->CreateNewFrame(encoded.out(), nullptr), "无法创建 PNG 帧。");
    check(encoded->Initialize(nullptr), "无法初始化 PNG 帧。");
    check(encoded->SetSize(w, h), "无法设置 PNG 尺寸。");
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    check(encoded->SetPixelFormat(&format), "无法设置 PNG 像素格式。");
    check(encoded->WriteSource(bitmap.p, nullptr), "PNG 像素编码失败。");
    check(encoded->Commit(), "PNG 帧保存失败。"); check(encoder->Commit(), "PNG 保存失败。");
    STATSTG stat{}; check(output->Stat(&stat, STATFLAG_NONAME), "无法读取 PNG 输出。");
    if (!stat.cbSize.QuadPart || stat.cbSize.QuadPart > ImageLimit) bad("转换后的 PNG 超过 8 MiB，请缩小图片。");
    LARGE_INTEGER zero{}; check(output->Seek(zero, STREAM_SEEK_SET, nullptr), "无法读取 PNG 输出流。");
    std::string result(size_t(stat.cbSize.QuadPart), '\0'); ULONG count = 0;
    check(output->Read(result.data(), ULONG(result.size()), &count), "无法读取 PNG 数据。");
    if (count != result.size()) bad("PNG 输出不完整。");
    return result;
}
void validate(const Json &t, bool decodeImages) {
    if (!t.is_object() || !t.contains("id") || !t.contains("name") || !t.contains("light")) bad("主题缺少 ID、名称或浅色配色。");
    stringLength(t["id"], "主题 ID 无效（最多 256 UTF-8 字节）。", 256);
    if (t["id"].get<std::string>().size() > 256) bad("主题 ID 超过 256 字节。");
    stringLength(t["name"], "主题名称不能为空，且不能超过 128 字符。", 128);
    if (t.contains("typography")) {
        const auto &v = t["typography"];
        if (!v.is_object()) bad("主题字体格式无效。");
        for (const char *key : {"fontCN", "fontEN"}) if (v.contains(key)) stringLength(v[key], "字体名称无效（最多 128 字符）。", 128);
        number(v, "fontSize", 14, 12, 24); number(v, "indexSize", 11, 8, 20);
    }
    for (const char *key : {"light", "dark"}) {
        if (!t.contains(key) || t[key].is_null()) { if (std::strcmp(key, "light") == 0) bad("缺少浅色配色。"); continue; }
        const auto &p = t[key];
        if (!p.is_object()) bad("主题配色格式无效。");
        for (const auto *c : Colors) if (!p.contains(c) || !p[c].is_number_integer() || p[c].get<int64_t>() < 0 || p[c].get<int64_t>() > 0xffffff) bad("主题颜色必须为 0–16777215 的整数。");
        if (p.contains("visual")) {
            const auto &v = p["visual"];
            if (!v.is_object()) bad("主题视觉参数格式无效。");
            number(v, "radius", 8, 0, 20); number(v, "padding", 8, 0, 20); number(v, "rowHeight", 100, 80, 140);
            number(v, "opacity", 100, 40, 100); number(v, "bgOpacity", 100, 0, 100); number(v, "imageOpacity", 25, 0, 100);
        }
        if (p.contains("imageData") && !p["imageData"].is_null()) {
            if (!p["imageData"].is_string() || p["imageData"].get_ref<const std::string &>().size() > (ImageLimit + 2) / 3 * 4) bad("主题图片过大或格式无效。");
            const auto data = base64Decode(p["imageData"].get<std::string>());
            if (data.empty() || data.size() > ImageLimit) bad("主题图片 Base64 无效或超过 8 MiB。");
            if (decodeImages) (void)normalizedImage(data);
        }
    }
}
Json normalizedTheme(Json t) {
    validate(t, false);
    for (const char *key : {"light", "dark"}) if (t.contains(key) && t[key].is_object() && t[key].contains("imageData") && !t[key]["imageData"].is_null())
        t[key]["imageData"] = base64Encode(normalizedImage(base64Decode(t[key]["imageData"].get<std::string>())));
    return t;
}
void extra(const std::string &s, size_t p, size_t end) {
    while (p < end) {
        if (end - p < 4) bad("ZIP 附加字段截断。");
        unsigned tag = le16(s, p), n = le16(s, p + 2); p += 4;
        if (tag == 1 || tag == 0x7075 || tag == 0x6375 || tag == 0x17 || tag == 0x9901 || n > end - p) bad("主题包含不支持的 ZIP64、路径或加密字段。");
        p += n;
    }
}
std::string manifest(const std::string &s) {
    if (s.size() < 22 || s.size() > ArchiveLimit) bad("主题包过大或截断（最大 24 MiB）。");
    size_t end = s.size() - 22, min = s.size() > 65557 ? s.size() - 65557 : 0;
    for (;;) {
        if (le32(s, end) == 0x06054b50 && end + 22 + le16(s, end + 20) == s.size()) break;
        if (end == min) bad("ZIP 结束记录无效。");
        --end;
    }
    if (le16(s,end+4) || le16(s,end+6) || le16(s,end+8)!=1 || le16(s,end+10)!=1) bad("v1 主题包必须仅包含唯一 theme.json，且不能分卷。");
    size_t dir = le32(s,end+16), dirSize = le32(s,end+12);
    if (dir > end || dirSize != end-dir || end-dir < 46 || le32(s,dir)!=0x02014b50) bad("ZIP 中央目录无效。");
    unsigned version=le16(s,dir+6), flags=le16(s,dir+8), method=le16(s,dir+10);
    uint32_t checksum=le32(s,dir+16); size_t compressed=le32(s,dir+20), size=le32(s,dir+24);
    size_t names=le16(s,dir+28), extras=le16(s,dir+30), comments=le16(s,dir+32);
    if (version>20 || le16(s,dir+34) || le32(s,dir+42) || names!=10 || 46+names+extras+comments!=end-dir || s.compare(dir+46,names,"theme.json")!=0)
        bad("ZIP 路径、本地偏移或目录长度不安全；仅接受 theme.json。");
    unsigned attributes=le32(s,dir+38), type=(attributes>>16)&0xf000;
    if ((type && type!=0x8000) || (attributes & 0x10)) bad("主题包不能包含目录、符号链接或特殊文件。");
    if ((flags & ~0x080eu) || (method!=0 && method!=8) || (method==0 && (flags&6))) bad("主题包包含加密或不支持的压缩方式。");
    if (!size || size>ManifestLimit || size>ExpandedLimit || compressed>ArchiveLimit) bad("主题清单超过展开限制（清单 16 MiB，总量 20 MiB）。");
    extra(s,dir+46+names,dir+46+names+extras);
    if (dir<30 || le32(s,0)!=0x04034b50 || le16(s,4)!=version || le16(s,6)!=flags || le16(s,8)!=method || le16(s,26)!=names) bad("ZIP 本地头与中央目录不一致。");
    size_t start=30+names+le16(s,28);
    if (start>dir || compressed>dir-start || s.compare(30,names,"theme.json")!=0) bad("ZIP 数据偏移不安全。");
    extra(s,30+names,start);
    const bool descriptor=(flags&8)!=0;
    const uint32_t expected[]={checksum,uint32_t(compressed),uint32_t(size)};
    for (int i=0;i<3;++i) { auto v=le32(s,14+i*4); if (v!=expected[i] && !(descriptor && !v)) bad("ZIP 本地长度或 CRC 不一致。"); }
    size_t cursor=start+compressed;
    if (descriptor) {
        if (cursor+12>dir) bad("ZIP 数据描述符截断。");
        if (le32(s,cursor)==0x08074b50) cursor+=4;
        if (cursor+12>dir) bad("ZIP 数据描述符截断。");
        for (int i=0;i<3;++i) if (le32(s,cursor+i*4)!=expected[i]) bad("ZIP 数据描述符校验失败。");
        cursor+=12;
    }
    if (cursor!=dir || (method==0 && compressed!=size)) bad("ZIP 含重叠、额外数据或不一致长度。");
    auto result = method==0 ? s.substr(start,size) : inflateBytes(s.data()+start,compressed,size,false);
    if (result.size()!=size || crc(result.data(),result.size())!=checksum) bad("主题清单 CRC 校验失败。");
    return result;
}
void append16(std::string &s, uint16_t v) { s.push_back(char(v)); s.push_back(char(v>>8)); }
void append32(std::string &s, uint32_t v) { append16(s,uint16_t(v)); append16(s,uint16_t(v>>16)); }
void extension(const fs::path &path) {
    auto s=path.extension().wstring(); std::transform(s.begin(),s.end(),s.begin(),::towlower);
    if (s!=L".gogakutheme") bad("请选择 .gogakutheme 文件。");
}
} // namespace

Json builtinThemes() {
    // 内置主题数据来自共享契约 gc_themes_builtin（theme_contract.cpp），
    // 调色板与排版只有这一份；本文件保留主题包解析、校验与导入导出。
    static const Json themes = [] {
        char *buffer = nullptr;
        size_t length = 0;
        const int32_t code = gc_themes_builtin(&buffer, &length);
        if (code != 0 || !buffer) throw std::runtime_error("共享主题契约不可用");
        std::unique_ptr<char, void (*)(void *)> holder(buffer, gc_contract_free);
        Json parsed = Json::parse(buffer, buffer + length);
        if (!parsed.is_array() || parsed.size() != 4) throw std::runtime_error("共享主题契约输出异常");
        return parsed;
    }();
    return themes;
}
Json resolvedTheme(const Json &settings) {
    auto all=builtinThemes(); const auto id=settings.value("candidateTheme",std::string("rime-macos-like"));
    if (id=="rime-macos-like") { auto t=all[0]; t["id"]=id; return t; }
    for (const auto &t:all) if (t["id"]==id) return t;
    if (settings.contains("userCandidateThemes") && settings["userCandidateThemes"].is_array()) for (const auto &t:settings["userCandidateThemes"]) {
        try { if (t.value("id",std::string())==id) { validate(t,false); return t; } } catch (...) {}
    }
    auto fallback=all[0]; fallback["id"]="rime-macos-like"; return fallback;
}
void validateTheme(const Json &theme) { validate(theme,true); }
Json normalizeImage(const fs::path &path) { return {{"imageData",base64Encode(normalizedImage(readFile(path,ImageLimit)))}}; }
Json importTheme(const fs::path &path) {
    extension(path);
    const auto bytes=readFile(path,ArchiveLimit);
    Json package;
    try { package=Json::parse(manifest(bytes)); }
    catch (const Json::exception &) { bad("主题 JSON 清单损坏。"); }
    if (!package.is_object() || !package.contains("formatVersion") || package["formatVersion"]!=1 || !package.contains("theme")) bad("不支持此主题包版本（只支持 v1）。");
    return normalizedTheme(package["theme"]);
}
void exportTheme(const fs::path &path,const Json &theme) {
    extension(path);
    auto content=Json({{"formatVersion",1},{"theme",normalizedTheme(theme)}}).dump();
    if (content.size()>ManifestLimit) bad("主题清单超过 16 MiB，请缩小背景图片。");
    uint32_t checksum=crc(content.data(),content.size()); std::string zip;
    append32(zip,0x04034b50); append16(zip,20); append16(zip,0); append16(zip,0); append16(zip,0); append16(zip,0);
    append32(zip,checksum); append32(zip,uint32_t(content.size())); append32(zip,uint32_t(content.size())); append16(zip,10); append16(zip,0); zip+="theme.json"; zip+=content;
    uint32_t offset=uint32_t(zip.size());
    append32(zip,0x02014b50); append16(zip,0x314); append16(zip,20); append16(zip,0); append16(zip,0); append16(zip,0); append16(zip,0);
    append32(zip,checksum); append32(zip,uint32_t(content.size())); append32(zip,uint32_t(content.size())); append16(zip,10); append16(zip,0); append16(zip,0); append16(zip,0); append16(zip,0); append32(zip,0x81800000); append32(zip,0); zip+="theme.json";
    uint32_t directorySize=uint32_t(zip.size())-offset;
    append32(zip,0x06054b50); append16(zip,0); append16(zip,0); append16(zip,1); append16(zip,1); append32(zip,directorySize); append32(zip,offset); append16(zip,0);
    atomicWrite(path,zip,false);
}
} // namespace gw
