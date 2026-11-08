import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib

/// v1 为 ZIP 内唯一的 theme.json：{"formatVersion":1,"theme":候选主题}。
/// 字体、视觉参数与两种外观的 PNG 图片均由主题 Codable 内嵌保存，不携带可执行资源。
/// 只读写 .gogakutheme；保留原 ID，导入界面必须分配新的用户 ID 后再加入设置，不能覆盖内置主题。
public enum CandidateThemePackage {
    private static let imageLimit = 8 * 1_024 * 1_024
    private static let manifestLimit = 16 * 1_024 * 1_024
    private static let expandedLimit = 20 * 1_024 * 1_024
    private static let archiveLimit = 24 * 1_024 * 1_024
    private static let entryName = Data("theme.json".utf8)

    private struct Manifest: Codable {
        let formatVersion: Int
        let theme: CandidateTheme
    }

    private struct PackageError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    public static func read(from url: URL) throws -> CandidateTheme {
        try checkExtension(url)
        do {
            // 分块读取限制真实字节数，不能仅信任可能在读取期间变化的文件大小。
            let archive = try boundedFile(url, limit: archiveLimit)
            let entry = try inspectArchive(archive)
            let json: Data
            if entry.method == 0 {
                json = archive.subdata(in: entry.payload)
            } else {
                // 仅对已预检的不可变快照调用 unzip；-p 输出单文件，绝不展开路径到磁盘。
                let temporary = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: temporary) }
                let snapshot = temporary.appendingPathComponent("package.zip")
                try archive.write(to: snapshot, options: .atomic)
                json = try inflate(snapshot, expectedSize: entry.size)
            }
            guard json.count == entry.size, crc32(json) == entry.crc else {
                throw PackageError("主题包校验失败：文件长度或 CRC 不一致。")
            }
            let manifest: Manifest
            do { manifest = try JSONDecoder().decode(Manifest.self, from: json) }
            catch { throw PackageError("主题清单损坏，无法读取主题、字体或视觉参数。") }
            guard manifest.formatVersion == 1 else { throw PackageError("不支持此主题包版本，请使用版本 1。") }
            return try normalizedTheme(manifest.theme)
        } catch let error as PackageError {
            throw error
        } catch {
            throw PackageError("无法读取主题包，请检查文件及访问权限。")
        }
    }

    public static func write(_ theme: CandidateTheme, to url: URL) throws {
        try checkExtension(url)
        do {
            let normalized = try normalizedTheme(theme)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let json: Data
            do { json = try encoder.encode(Manifest(formatVersion: 1, theme: normalized)) }
            catch { throw PackageError("主题内容无效，无法保存字体或视觉参数。") }
            guard json.count <= manifestLimit else { throw PackageError("主题清单不能超过 16 MiB，请缩小背景图片。") }
            // 单文件不压缩 ZIP：无外部工具、无额外字段，所有长度和 CRC 都由实际内容生成。
            let archive = storedArchive(json)
            try archive.write(to: url, options: .atomic)
        } catch let error as PackageError {
            throw error
        } catch {
            throw PackageError("无法保存主题包，请检查目标位置和可用空间。")
        }
    }

    /// 只接受完整的单帧 PNG、JPEG、WebP；实际解码后绘制为 sRGB 并重新编码 PNG，丢弃元数据。
    /// 输入及规范化输出均不超过 8 MiB，宽高各不超过 4096 像素，不将原始图片交给渲染层。
    public static func validatedImage(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= imageLimit else { throw PackageError("图片不能为空，且不能超过 8 MiB。") }
        let type = try inspectImageContainer(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == type,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw PackageError("图片损坏或格式不受支持，请选择完整的 PNG、JPEG 或 WebP 图片。")
        }
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw PackageError("图片宽度和高度均不能超过 4096 像素。")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == width, image.height == height,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw PackageError("图片无法完整解码，请重新导出后再试。")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        guard let raster = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw PackageError("无法将图片转换为安全的 PNG。")
        }
        CGImageDestinationAddImage(destination, raster, nil)
        guard CGImageDestinationFinalize(destination), output.length <= imageLimit else {
            throw PackageError("转换后的 PNG 超过 8 MiB 或无法保存，请缩小图片。")
        }
        return output as Data
    }

    private static func normalizedTheme(_ theme: CandidateTheme) throws -> CandidateTheme {
        var result = theme
        if let data = result.light.imageData { result.light.imageData = try validatedImage(data) }
        if var dark = result.dark {
            if let data = dark.imageData { dark.imageData = try validatedImage(data) }
            result.dark = dark
        }
        return result
    }

    private static func checkExtension(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "gogakutheme" else {
            throw PackageError("请选择扩展名为 .gogakutheme 的本地主题包。")
        }
    }

    private static func boundedFile(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, limit - data.count + 1)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= limit else { throw PackageError("主题包过大，最多允许 24 MiB。") }
        }
        return data
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GogakuTheme-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func inflate(_ snapshot: URL, expectedSize: Int) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", snapshot.path, "theme.json"]
        // 不继承 UNZIP/UNZIPOPT 等可以改变工具行为的环境变量。
        process.environment = ["LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        defer { try? pipe.fileHandleForReading.close() }
        var output = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: min(65_536, expectedSize - output.count + 1)), !chunk.isEmpty {
                output.append(chunk)
                guard output.count <= expectedSize else {
                    throw PackageError("主题包展开长度超过清单声明，已拒绝读取。")
                }
            }
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PackageError("主题包压缩内容损坏，无法完整展开。") }
        return output
    }

    private struct Entry {
        let method: UInt16
        let size: Int
        let crc: UInt32
        let payload: Range<Int>
    }

    /// 检查完整中央目录与每个本地头，再决定是否允许任何展开。拒绝 ZIP64、多卷、自解压及多余尾部。
    private static func inspectArchive(_ data: Data) throws -> Entry {
        func invalid() -> PackageError { PackageError("主题包 ZIP 结构不安全或已损坏。") }
        guard data.count >= 22 else { throw invalid() }
        let first = max(0, data.count - 22 - 65_535)
        let end = (first...(data.count - 22)).reversed().first {
            data.le32($0) == 0x06054b50 && $0 + 22 + Int(data.le16($0 + 20)) == data.count
        }
        guard let end, data.le16(end + 4) == 0, data.le16(end + 6) == 0 else { throw invalid() }
        let count = Int(data.le16(end + 10))
        guard count > 0, count <= 8, data.le16(end + 8) == count else {
            throw PackageError("主题包文件数无效，最多允许 8 个文件。")
        }
        let directorySize = Int(data.le32(end + 12))
        let directoryOffset = Int(data.le32(end + 16))
        guard directoryOffset <= end, directorySize == end - directoryOffset else { throw invalid() }
        var cursor = directoryOffset
        var localCursor = 0
        var total = 0
        var seen = Set<Data>()
        var entries: [Entry] = []
        for _ in 0..<count {
            guard cursor + 46 <= end, data.le32(cursor) == 0x02014b50 else { throw invalid() }
            let flags = data.le16(cursor + 8)
            let method = data.le16(cursor + 10)
            let crc = data.le32(cursor + 16)
            let compressed = Int(data.le32(cursor + 20))
            let size = Int(data.le32(cursor + 24))
            let nameLength = Int(data.le16(cursor + 28))
            let extraLength = Int(data.le16(cursor + 30))
            let commentLength = Int(data.le16(cursor + 32))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= end, nameLength > 0, nameLength <= 255,
                  data.le16(cursor + 6) <= 20, data.le16(cursor + 34) == 0,
                  compressed <= archiveLimit, size <= expandedLimit else { throw invalid() }
            // 只支持普通 deflate/store；禁用加密、补丁、强加密、隐藏头等所有额外标志。
            guard flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  method == 8 || flags & 0x0006 == 0 else {
                throw PackageError("主题包包含加密文件或不支持的压缩方式。")
            }
            let attributes = data.le32(cursor + 38)
            let fileType = (attributes >> 16) & 0xf000
            guard (fileType == 0 || fileType == 0x8000), attributes & 0x10 == 0 else {
                throw PackageError("主题包不能包含符号链接、目录或特殊文件。")
            }
            let name = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard seen.insert(name).inserted else { throw PackageError("主题包包含重复路径。") }
            // v1 没有外置资源；精确允许名单同时排除绝对路径、..、反斜线、NUL 与大小写别名。
            guard name == entryName else { throw PackageError("主题包 v1 只允许包含 theme.json，不允许其他文件或路径。") }
            total += size
            guard total <= expandedLimit, size <= manifestLimit else {
                throw PackageError("主题包展开内容超过限制：总量 20 MiB，主题清单 16 MiB。")
            }
            try inspectExtra(data, range: (cursor + 46 + nameLength)..<(cursor + 46 + nameLength + extraLength))
            let local = Int(data.le32(cursor + 42))
            guard local == localCursor, local + 30 <= directoryOffset,
                  data.le32(local) == 0x04034b50,
                  data.le16(local + 4) == data.le16(cursor + 6),
                  data.le16(local + 6) == flags, data.le16(local + 8) == method else { throw invalid() }
            let localNameLength = Int(data.le16(local + 26))
            let localExtraLength = Int(data.le16(local + 28))
            let payloadStart = local + 30 + localNameLength + localExtraLength
            guard payloadStart <= directoryOffset, compressed <= directoryOffset - payloadStart,
                  localNameLength == nameLength,
                  data.subdata(in: (local + 30)..<(local + 30 + localNameLength)) == name else { throw invalid() }
            try inspectExtra(data, range: (local + 30 + localNameLength)..<payloadStart)
            let descriptor = flags & 0x0008 != 0
            let localValues = [data.le32(local + 14), data.le32(local + 18), data.le32(local + 22)]
            let expected = [crc, UInt32(compressed), UInt32(size)]
            guard zip(localValues, expected).allSatisfy({ $0 == $1 || (descriptor && $0 == 0) }) else { throw invalid() }
            localCursor = payloadStart + compressed
            if descriptor {
                guard localCursor + 12 <= directoryOffset else { throw invalid() }
                // 可选签名；随后三项必须与中央目录完全一致。
                if data.le32(localCursor) == 0x08074b50 { localCursor += 4 }
                guard localCursor + 12 <= directoryOffset,
                      data.le32(localCursor) == crc, data.le32(localCursor + 4) == compressed,
                      data.le32(localCursor + 8) == size else { throw invalid() }
                localCursor += 12
            }
            guard method != 0 || compressed == size else { throw invalid() }
            entries.append(Entry(method: method, size: size, crc: crc, payload: payloadStart..<(payloadStart + compressed)))
            cursor = next
        }
        guard cursor == end, localCursor == directoryOffset, entries.count == 1 else { throw invalid() }
        return entries[0]
    }

    private static func inspectExtra(_ data: Data, range: Range<Int>) throws {
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard cursor + 4 <= range.upperBound else { throw PackageError("主题包附加字段损坏。") }
            let tag = data.le16(cursor)
            let length = Int(data.le16(cursor + 2))
            cursor += 4
            // ZIP64、Unicode 路径和加密字段会改变路径或长度的解释，全部拒绝。
            guard tag != 0x0001, tag != 0x7075, tag != 0x6375, tag != 0x0017, tag != 0x9901,
                  length <= range.upperBound - cursor else { throw PackageError("主题包含有不支持的 ZIP 附加字段。") }
            cursor += length
        }
    }

    private static func storedArchive(_ json: Data) -> Data {
        let crc = crc32(json)
        var data = Data()
        data.appendLE(UInt32(0x04034b50)); data.appendLE(UInt16(20)); data.appendLE(UInt16(0))
        data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
        data.appendLE(crc); data.appendLE(UInt32(json.count)); data.appendLE(UInt32(json.count))
        data.appendLE(UInt16(entryName.count)); data.appendLE(UInt16(0))
        data.append(entryName); data.append(json)
        let offset = data.count
        data.appendLE(UInt32(0x02014b50)); data.appendLE(UInt16(0x0314)); data.appendLE(UInt16(20))
        data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
        data.appendLE(crc); data.appendLE(UInt32(json.count)); data.appendLE(UInt32(json.count))
        data.appendLE(UInt16(entryName.count)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
        data.appendLE(UInt16(0)); data.appendLE(UInt16(0)); data.appendLE(UInt32(0o100600 << 16))
        data.appendLE(UInt32(0)); data.append(entryName)
        let size = data.count - offset
        data.appendLE(UInt32(0x06054b50)); data.appendLE(UInt16(0)); data.appendLE(UInt16(0))
        data.appendLE(UInt16(1)); data.appendLE(UInt16(1)); data.appendLE(UInt32(size))
        data.appendLE(UInt32(offset)); data.appendLE(UInt16(0))
        return data
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        return crc
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }

    /// 由 IHDR 计算过滤后的每行长度，包含 Adam7 七趟；在解压任何像素前限制尺寸。
    private static func pngRows(_ data: Data, header: Int) throws -> [Int] {
        let width = Int(data.be32(header)), height = Int(data.be32(header + 4))
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw PackageError("图片宽度和高度必须为 1 到 4096 像素。")
        }
        let depth = Int(data[header + 8]), color = data[header + 9], interlace = data[header + 12]
        let channels: Int
        let depths: [Int]
        switch color {
        case 0: channels = 1; depths = [1, 2, 4, 8, 16]
        case 2: channels = 3; depths = [8, 16]
        case 3: channels = 1; depths = [1, 2, 4, 8]
        case 4: channels = 2; depths = [8, 16]
        case 6: channels = 4; depths = [8, 16]
        default: throw PackageError("PNG 颜色格式无效。")
        }
        guard depths.contains(depth), data[header + 10] == 0, data[header + 11] == 0, interlace <= 1 else {
            throw PackageError("PNG 位深、压缩或交错格式无效。")
        }
        if interlace == 0 { return Array(repeating: (width * channels * depth + 7) / 8 + 1, count: height) }
        let passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
                      (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        var rows: [Int] = []
        for (x, y, stepX, stepY) in passes where width > x && height > y {
            let columns = (width - x + stepX - 1) / stepX
            let count = (height - y + stepY - 1) / stepY
            rows.append(contentsOf: repeatElement((columns * channels * depth + 7) / 8 + 1, count: count))
        }
        return rows
    }

    /// ImageIO 会容错输出部分 PNG；额外要求 zlib 完整结束、Adler 校验通过、每行过滤字节及总像素长度正确。
    /// 只使用 64 KiB 的解压缓冲，避免为校验额外分配整张高位深位图。
    private static func validatePNGStream(_ data: Data, rowLengths: [Int]) throws {
        func invalid() -> PackageError { PackageError("PNG 像素流损坏、截断或展开长度异常。") }
        guard !data.isEmpty else { throw invalid() }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid() }
        defer { inflateEnd(&stream) }
        let expected = rowLengths.reduce(0, +)
        var total = 0
        var row = 0
        var remaining = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(input.count)
            try buffer.withUnsafeMutableBytes { output in
                while true {
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(output.count)
                    let status = zlib.inflate(&stream, Z_NO_FLUSH)
                    let produced = output.count - Int(stream.avail_out)
                    total += produced
                    guard total <= expected else { throw invalid() }
                    var position = 0
                    while position < produced {
                        if remaining == 0 {
                            guard row < rowLengths.count, output[position] <= 4 else { throw invalid() }
                            remaining = rowLengths[row]; row += 1
                        }
                        let consumed = min(remaining, produced - position)
                        remaining -= consumed; position += consumed
                    }
                    if status == Z_STREAM_END {
                        guard total == expected, stream.avail_in == 0, remaining == 0, row == rowLengths.count else { throw invalid() }
                        return
                    }
                    guard status == Z_OK, produced > 0 else { throw invalid() }
                }
            }
        }
    }

    private static func inspectImageContainer(_ data: Data) throws -> String {
        func invalid() -> PackageError { PackageError("图片格式错误、内容截断或包含不支持的动画。") }
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) {
            var cursor = 8
            var hasHeader = false
            var hasPixels = false
            var pixelsEnded = false
            var pixelStream = Data()
            var rowLengths: [Int] = []
            while cursor + 12 <= data.count {
                let length = Int(data.be32(cursor))
                guard length <= data.count - cursor - 12 else { throw invalid() }
                let name = data.subdata(in: (cursor + 4)..<(cursor + 8))
                let end = cursor + 12 + length
                guard crc32(data.subdata(in: (cursor + 4)..<(end - 4))) == data.be32(end - 4) else { throw invalid() }
                if !hasHeader {
                    guard name == Data("IHDR".utf8), length == 13 else { throw invalid() }
                    rowLengths = try pngRows(data, header: cursor + 8)
                    hasHeader = true
                } else if name == Data("IHDR".utf8) { throw invalid() }
                if name == Data("acTL".utf8) { throw invalid() }
                if name == Data("IDAT".utf8) {
                    guard !pixelsEnded else { throw invalid() }
                    hasPixels = true
                    pixelStream.append(data.subdata(in: (cursor + 8)..<(cursor + 8 + length)))
                } else if hasPixels { pixelsEnded = true }
                if name == Data("IEND".utf8) {
                    guard length == 0, hasPixels, end == data.count else { throw invalid() }
                    try validatePNGStream(pixelStream, rowLengths: rowLengths)
                    return UTType.png.identifier
                }
                cursor = end
            }
            throw invalid()
        }
        if data.starts(with: [0xff, 0xd8]) {
            // 检查标记及长度，含扫描数据中的转义 FF 与重启标记；拒绝缺失 EOI 和尾随内容。
            var cursor = 2
            var scanning = false
            var hasScan = false
            while cursor < data.count {
                if scanning && data[cursor] != 0xff { cursor += 1; continue }
                guard data[cursor] == 0xff else { throw invalid() }
                while cursor < data.count && data[cursor] == 0xff { cursor += 1 }
                guard cursor < data.count else { throw invalid() }
                let marker = data[cursor]; cursor += 1
                if scanning && (marker == 0 || (0xd0...0xd7).contains(marker)) { continue }
                scanning = false
                if marker == 0xd9 {
                    guard hasScan, cursor == data.count else { throw invalid() }
                    return UTType.jpeg.identifier
                }
                guard marker != 0, marker != 0xd8, !(0xd0...0xd7).contains(marker),
                      cursor + 2 <= data.count else { throw invalid() }
                let length = Int(data[cursor]) << 8 | Int(data[cursor + 1])
                guard length >= 2, length <= data.count - cursor else { throw invalid() }
                cursor += length
                if marker == 0xda { scanning = true; hasScan = true }
            }
            throw invalid()
        }
        if data.count >= 12, data.prefix(4) == Data("RIFF".utf8), data.subdata(in: 8..<12) == Data("WEBP".utf8) {
            guard Int(data.le32(4)) == data.count - 8 else { throw invalid() }
            var cursor = 12
            var pixels = 0
            while cursor + 8 <= data.count {
                let name = data.subdata(in: cursor..<(cursor + 4))
                let length = Int(data.le32(cursor + 4))
                guard length <= data.count - cursor - 8 else { throw invalid() }
                if name == Data("ANIM".utf8) || name == Data("ANMF".utf8) { throw invalid() }
                if name == Data("VP8 ".utf8) || name == Data("VP8L".utf8) { pixels += 1 }
                cursor += 8 + length + (length & 1)
            }
            guard cursor == data.count, pixels == 1 else { throw invalid() }
            return UTType.webP.identifier
        }
        throw PackageError("仅支持 PNG、JPEG 和 WebP 图片，不能使用伪装扩展名的其他文件。")
    }
}

// 显式逐字节读取，避免未对齐内存载入；所有调用方都先检查相应字段边界。
private extension Data {
    func le16(_ index: Int) -> UInt16 { UInt16(self[index]) | UInt16(self[index + 1]) << 8 }
    func le32(_ index: Int) -> UInt32 { UInt32(le16(index)) | UInt32(le16(index + 2)) << 16 }
    func be32(_ index: Int) -> UInt32 {
        UInt32(self[index]) << 24 | UInt32(self[index + 1]) << 16 | UInt32(self[index + 2]) << 8 | UInt32(self[index + 3])
    }
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
