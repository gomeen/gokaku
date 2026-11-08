import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import GogakuKit

final class ThemePackageTests: XCTestCase {
    private struct FixtureEntry {
        var name = "theme.json"
        var localName: String? = nil
        var bytes = Data("{}".utf8)
        var flags: UInt16 = 0
        var method: UInt16 = 0
        var mode: UInt32 = 0o100600
        var declaredSize: UInt32? = nil
        var localExtra = Data()
        var centralExtra = Data()
        var crc: UInt32? = nil
        var descriptor = false
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThemePackageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func theme() throws -> CandidateTheme {
        let source = BuiltinCandidateThemes.theme(.claude)
        return CandidateTheme(id: try XCTUnwrap(CandidateThemeID(rawValue: "用户主题/" + UUID().uuidString)),
                              name: "纸与墨", light: source.light, dark: source.dark)
    }

    private func manifest(_ theme: CandidateTheme, version: Int = 1) throws -> Data {
        // 独立构造文档，避免读取测试只覆盖生产写入器能产生的情况。
        let object: [String: Any] = ["formatVersion": version,
                                    "theme": try JSONSerialization.jsonObject(with: JSONEncoder().encode(theme))]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func image(width: Int = 3, height: Int = 2, type: UTType = .png) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let raster = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        // 规范化后不应保留可能包含路径等隐私信息的源元数据。
        CGImageDestinationAddImage(destination, raster,
            [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "private-metadata"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func assertPNG(_ data: Data, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(data.prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]), file: file, line: line)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file: file, line: line)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier, file: file, line: line)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
        XCTAssertEqual(decoded.width, width, file: file, line: line)
        XCTAssertEqual(decoded.height, height, file: file, line: line)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-metadata"), file: file, line: line)
    }

    func testPackageRoundTripPreservesIdentityTypographyMetricsAndBothImages() throws {
        var original = try theme()
        original.typography = CandidateThemeTypography(fontCN: "Kaiti SC", fontEN: "Menlo", fontSize: 18, indexSize: 12)
        original.light.visual = CandidateThemeVisual(radius: 12, padding: 9, rowHeight: 120, opacity: 80, bgOpacity: 50, imageOpacity: 30)
        original.dark?.visual = CandidateThemeVisual(radius: 3, padding: 4, rowHeight: 90, opacity: 95, bgOpacity: 75, imageOpacity: 15)
        original.light.imageData = try CandidateThemePackage.validatedImage(image())
        original.dark?.imageData = try CandidateThemePackage.validatedImage(image(width: 5, height: 4, type: .jpeg))
        let url = try temporaryDirectory().appendingPathComponent("双色.gogakutheme")
        try CandidateThemePackage.write(original, to: url)
        let imported = try CandidateThemePackage.read(from: url)
        XCTAssertEqual(imported, original)
        XCTAssertEqual(imported.id, original.id)
        try assertPNG(XCTUnwrap(imported.light.imageData), width: 3, height: 2)
        try assertPNG(XCTUnwrap(imported.dark?.imageData), width: 5, height: 4)
        // 再次覆盖同一路径，确认写入器可以替换已有包。
        original.name = "第二版"
        try CandidateThemePackage.write(original, to: url)
        XCTAssertEqual(try CandidateThemePackage.read(from: url), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count, 1)
    }

    func testSingleAppearanceWithoutImagesAndVersionOneEnvelope() throws {
        var original = try theme()
        original.dark = nil
        let url = try temporaryDirectory().appendingPathComponent("single.gogakutheme")
        try CandidateThemePackage.write(original, to: url)
        XCTAssertEqual(try CandidateThemePackage.read(from: url), original)
        let archive = try Data(contentsOf: url)
        // 写入器采用 store；直接检查导出的公开清单结构。
        let json = archive.subdata(in: 40..<(40 + Int(read32(archive, 18))))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        XCTAssertNotNil(object["theme"])
    }

    func testBuiltinIdentityIsPreservedButCannotOverrideSettings() throws {
        var spoof = BuiltinCandidateThemes.theme(.claude)
        spoof.name = "外来同 ID 主题"
        let url = try temporaryDirectory().appendingPathComponent("builtin.gogakutheme")
        try CandidateThemePackage.write(spoof, to: url)
        let imported = try CandidateThemePackage.read(from: url)
        XCTAssertEqual(imported.id, .claude)
        var settings = Settings()
        settings.userCandidateThemes = [imported]
        settings.candidateTheme = .claude
        XCTAssertEqual(settings.resolvedCandidateTheme, BuiltinCandidateThemes.theme(.claude))
    }

    func testPNGAndJPEGActuallyDecodeAndNormalize() throws {
        for type in [UTType.png, .jpeg] {
            let normalized = try CandidateThemePackage.validatedImage(image(type: type))
            try assertPNG(normalized, width: 3, height: 2)
        }
    }

    func testWebPActuallyDecodesAndNormalizes() throws {
        // 完整的 1×1 VP8 WebP 固定样本，无需第三方编码器。
        let webp = try XCTUnwrap(Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"))
        try assertPNG(CandidateThemePackage.validatedImage(webp), width: 1, height: 1)
        XCTAssertThrowsError(try CandidateThemePackage.validatedImage(Data(webp.dropLast())))
        var forged = webp
        forged[4] = 0xff
        XCTAssertThrowsError(try CandidateThemePackage.validatedImage(forged))
    }

    func testFakeTruncatedCorruptAndOversizedImagesAreRejected() throws {
        let png = try image()
        let jpeg = try image(type: .jpeg)
        let fakePNG = Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data("not-pixels".utf8)
        for bad in [Data(), Data("<svg></svg>".utf8), fakePNG, Data(png.dropLast()),
                    Data(png.prefix(png.count / 2)), Data(jpeg.dropLast(2)),
                    png + Data([0]), Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1)] {
            XCTAssertThrowsError(try CandidateThemePackage.validatedImage(bad)) { error in
                XCTAssertFalse(error.localizedDescription.isEmpty)
                XCTAssertFalse(error.localizedDescription.contains("The operation"))
            }
        }
        var corrupt = png
        corrupt[29] ^= 1 // IHDR 的 CRC 不匹配，即使 ImageIO 容错也必须拒绝。
        XCTAssertThrowsError(try CandidateThemePackage.validatedImage(corrupt))
        // 容器及各块 CRC 都正确，但 IDAT 像素流被截断，不能仅靠文件签名和 IEND 放行。
        var truncatedPixels = Data(png.prefix(8))
        var cursor = 8
        while cursor + 12 <= png.count {
            let length = Int(readBig32(png, cursor))
            let name = png.subdata(in: (cursor + 4)..<(cursor + 8))
            if name == Data("IDAT".utf8) {
                let payload = png.subdata(in: (cursor + 8)..<(cursor + 8 + max(1, length / 2)))
                var block = name; block.append(payload)
                appendBig(UInt32(payload.count), to: &truncatedPixels)
                truncatedPixels.append(block); appendBig(crc32(block), to: &truncatedPixels)
            } else {
                truncatedPixels.append(png.subdata(in: cursor..<(cursor + 12 + length)))
            }
            cursor += 12 + length
        }
        XCTAssertThrowsError(try CandidateThemePackage.validatedImage(truncatedPixels))
        XCTAssertThrowsError(try CandidateThemePackage.validatedImage(image(width: 4097, height: 1)))
        XCTAssertThrowsError(try CandidateThemePackage.validatedImage(image(width: 1, height: 4097)))
        try assertPNG(CandidateThemePackage.validatedImage(image(width: 4096, height: 1)), width: 4096, height: 1)
    }

    func testImportValidatesEachEmbeddedImageAndExportFailurePreservesDestination() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("images.gogakutheme")
        var original = try theme()
        original.light.imageData = try image(type: .jpeg)
        original.dark?.imageData = try image(width: 7, height: 6)
        try archive([FixtureEntry(bytes: manifest(original))]).write(to: url)
        let imported = try CandidateThemePackage.read(from: url)
        try assertPNG(XCTUnwrap(imported.light.imageData), width: 3, height: 2)
        try assertPNG(XCTUnwrap(imported.dark?.imageData), width: 7, height: 6)
        for dark in [false, true] {
            var bad = original
            if dark { bad.dark?.imageData = Data("假图".utf8) }
            else { bad.light.imageData = Data("假图".utf8) }
            try archive([FixtureEntry(bytes: manifest(bad))]).write(to: url)
            XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
            let previous = try Data(contentsOf: url)
            XCTAssertThrowsError(try CandidateThemePackage.write(bad, to: url))
            XCTAssertEqual(try Data(contentsOf: url), previous)
        }
    }

    func testRejectsUnsupportedExtensionJSONAndVersion() throws {
        let directory = try temporaryDirectory()
        let original = try theme()
        let plain = directory.appendingPathComponent("theme.json")
        try manifest(original).write(to: plain)
        XCTAssertThrowsError(try CandidateThemePackage.read(from: plain))
        XCTAssertThrowsError(try CandidateThemePackage.write(original, to: plain))
        let url = directory.appendingPathComponent("bad.gogakutheme")
        for bytes in [try manifest(original, version: 2), Data("{}".utf8), Data("bad json".utf8)] {
            try archive([FixtureEntry(bytes: bytes)]).write(to: url)
            XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
        }
    }

    func testRejectsTraversalAbsolutePathsBackslashesAndUnsupportedFiles() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("paths.gogakutheme")
        for name in ["../outside", "/tmp/theme.json", "a/../theme.json", "a\\theme.json", "theme.json\0x",
                     "Theme.json", "background.png", "run.sh", "nested/theme.json"] {
            try archive([FixtureEntry(name: name)]).write(to: url)
            XCTAssertThrowsError(try CandidateThemePackage.read(from: url), name)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["paths.gogakutheme"])
    }

    func testRejectsSymlinksDirectoriesAndSpecialFiles() throws {
        let url = try temporaryDirectory().appendingPathComponent("types.gogakutheme")
        for mode: UInt32 in [0o120777, 0o040755, 0o010600, 0o020600, 0o140600] {
            try archive([FixtureEntry(mode: mode)]).write(to: url)
            XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
        }
    }

    func testRejectsDuplicatesEncryptionUnsupportedCompressionAndExcessFileCount() throws {
        let url = try temporaryDirectory().appendingPathComponent("flags.gogakutheme")
        let fixtures: [[FixtureEntry]] = [
            [FixtureEntry(), FixtureEntry()], Array(repeating: FixtureEntry(), count: 9),
            [FixtureEntry(flags: 1)], [FixtureEntry(flags: 0x40)], [FixtureEntry(flags: 0x2000)],
            [FixtureEntry(method: 99)], [FixtureEntry(method: 9)], [FixtureEntry(flags: 2)],
        ]
        for entries in fixtures {
            try archive(entries).write(to: url)
            XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
        }
    }

    func testRejectsZipBombDeclarationsAndActualArchiveLimit() throws {
        let url = try temporaryDirectory().appendingPathComponent("bomb.gogakutheme")
        for size: UInt32 in [16 * 1_024 * 1_024 + 1, 21 * 1_024 * 1_024, UInt32.max] {
            try archive([FixtureEntry(method: 8, declaredSize: size)]).write(to: url)
            XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
        }
        try Data(repeating: 0, count: 24 * 1_024 * 1_024 + 1).write(to: url)
        XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
    }

    func testRejectsMismatchedLocalHeaderCRCExtraFieldsAndTruncation() throws {
        let url = try temporaryDirectory().appendingPathComponent("headers.gogakutheme")
        let json = try manifest(theme())
        var zip64 = Data(); append(UInt16(1), to: &zip64); append(UInt16(0), to: &zip64)
        var unicodePath = Data(); append(UInt16(0x7075), to: &unicodePath); append(UInt16(0), to: &unicodePath)
        for entry in [FixtureEntry(localName: "other.json", bytes: json), FixtureEntry(bytes: json, crc: 0),
                      FixtureEntry(bytes: json, localExtra: zip64), FixtureEntry(bytes: json, centralExtra: unicodePath),
                      FixtureEntry(bytes: json, centralExtra: Data([0]))] {
            try archive([entry]).write(to: url)
            XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
        }
        let valid = archive([FixtureEntry(bytes: json)])
        for bytes in [Data(valid.prefix(10)), Data(valid.dropLast()), valid + Data([0]), Data([0]) + valid] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
        }
        var mismatched = valid
        mismatched[6] = 1
        try mismatched.write(to: url)
        XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
    }

    func testDescriptorSupportedAndDamagedDescriptorRejected() throws {
        let url = try temporaryDirectory().appendingPathComponent("descriptor.gogakutheme")
        let original = try theme()
        var bytes = archive([FixtureEntry(bytes: try manifest(original), flags: 8, descriptor: true)])
        try bytes.write(to: url)
        XCTAssertEqual(try CandidateThemePackage.read(from: url), original)
        bytes[40 + (try manifest(original)).count + 4] ^= 1
        try bytes.write(to: url)
        XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
    }

    func testSystemDeflatedArchiveRoundTripAndCRCFailure() throws {
        let directory = try temporaryDirectory()
        let original = try theme()
        let json = try manifest(original)
        try json.write(to: directory.appendingPathComponent("theme.json"))
        let url = directory.appendingPathComponent("deflated.gogakutheme")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "-X", "-9", url.path, "theme.json"]
        process.environment = ["LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try CandidateThemePackage.read(from: url), original)
        var bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes[8], 8) // 确认测试走真实 deflate 路径，而非 store。
        // 本地头和中央目录一致地少报展开长度；必须在 stdout 超出声明时停止。
        var undersized = bytes
        let directoryOffset = Int(read32(bytes, bytes.count - 6))
        for position in [22, directoryOffset + 24] {
            let value = UInt32(json.count - 1)
            for byte in 0..<4 { undersized[position + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        }
        try undersized.write(to: url)
        XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
        let localNameLength = Int(bytes[26]) | Int(bytes[27]) << 8
        let localExtraLength = Int(bytes[28]) | Int(bytes[29]) << 8
        bytes[30 + localNameLength + localExtraLength] ^= 0xff
        try bytes.write(to: url)
        XCTAssertThrowsError(try CandidateThemePackage.read(from: url))
    }

    // 恶意样例直接写 ZIP 字段，不能依赖 zip 工具替我们修复非法标志或路径。
    private func archive(_ entries: [FixtureEntry]) -> Data {
        var data = Data()
        var directory = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let localName = Data((entry.localName ?? entry.name).utf8)
            let crc = entry.crc ?? crc32(entry.bytes)
            let size = entry.declaredSize ?? UInt32(entry.bytes.count)
            let offset = data.count
            append(UInt32(0x04034b50), to: &data); append(UInt16(20), to: &data)
            append(entry.flags, to: &data); append(entry.method, to: &data)
            append(UInt16(0), to: &data); append(UInt16(0), to: &data)
            append(entry.descriptor ? UInt32(0) : crc, to: &data)
            append(entry.descriptor ? UInt32(0) : UInt32(entry.bytes.count), to: &data)
            append(entry.descriptor ? UInt32(0) : size, to: &data)
            append(UInt16(localName.count), to: &data); append(UInt16(entry.localExtra.count), to: &data)
            data.append(localName); data.append(entry.localExtra); data.append(entry.bytes)
            if entry.descriptor {
                append(UInt32(0x08074b50), to: &data); append(crc, to: &data)
                append(UInt32(entry.bytes.count), to: &data); append(size, to: &data)
            }
            append(UInt32(0x02014b50), to: &directory); append(UInt16(0x0314), to: &directory)
            append(UInt16(20), to: &directory); append(entry.flags, to: &directory); append(entry.method, to: &directory)
            append(UInt16(0), to: &directory); append(UInt16(0), to: &directory); append(crc, to: &directory)
            append(UInt32(entry.bytes.count), to: &directory); append(size, to: &directory)
            append(UInt16(name.count), to: &directory); append(UInt16(entry.centralExtra.count), to: &directory)
            append(UInt16(0), to: &directory); append(UInt16(0), to: &directory); append(UInt16(0), to: &directory)
            append(entry.mode << 16, to: &directory); append(UInt32(offset), to: &directory)
            directory.append(name); directory.append(entry.centralExtra)
        }
        let offset = data.count
        data.append(directory)
        append(UInt32(0x06054b50), to: &data); append(UInt16(0), to: &data); append(UInt16(0), to: &data)
        append(UInt16(entries.count), to: &data); append(UInt16(entries.count), to: &data)
        append(UInt32(directory.count), to: &data); append(UInt32(offset), to: &data); append(UInt16(0), to: &data)
        return data
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func read32(_ data: Data, _ position: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[position + $1]) << ($1 * 8) }
    }

    private func readBig32(_ data: Data, _ position: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[position + $1]) << ((3 - $1) * 8) }
    }

    private func appendBig(_ value: UInt32, to data: inout Data) {
        for byte in (0..<4).reversed() { data.append(UInt8(truncatingIfNeeded: value >> (byte * 8))) }
    }

    private func crc32(_ data: Data) -> UInt32 {
        var result: UInt32 = 0xffffffff
        for byte in data {
            result ^= UInt32(byte)
            for _ in 0..<8 { result = result & 1 == 0 ? result >> 1 : (result >> 1) ^ 0xedb88320 }
        }
        return result ^ 0xffffffff
    }
}
