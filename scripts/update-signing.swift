#!/usr/bin/env swift
import Foundation
import CryptoKit

/// Ed25519 更新清单签名工具（CryptoKit；不自行实现密码学）。
///
/// 用法：
///   swift scripts/update-signing.swift generate --private <path> [--public-out <path>]
///   swift scripts/update-signing.swift sign --private <path> --input <manifest> --output <sig>
///   swift scripts/update-signing.swift verify --public <base64> --input <manifest> --sig <sig>
///
/// 私钥文件是 base64 原始 32 字节，权限 0600；只存发布环境，绝不入库。
/// 签名文件默认写 base64 文本（客户端也接受原始 64 字节）。

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), args.index(after: index) < args.endIndex else {
        return nil
    }
    return args[args.index(after: index)]
}

func command() -> String {
    let args = CommandLine.arguments.dropFirst()
    guard let first = args.first, !first.hasPrefix("--") else {
        fail("缺少子命令：generate｜sign｜verify")
    }
    return first
}

func writePrivate(_ key: Curve25519.Signing.PrivateKey, to path: String) throws {
    let data = Data(key.rawRepresentation.base64EncodedString().utf8)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: path)
}

func loadPrivate(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          data.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("私钥文件非法：\(path)")
    }
    return key
}

func loadSignature(_ path: String) -> Data {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        fail("无法读取签名文件：\(path)")
    }
    if data.count == 64 { return data }
    guard let text = String(data: data, encoding: .utf8),
          let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          decoded.count == 64 else {
        fail("签名格式非法：\(path)")
    }
    return decoded
}

switch command() {
case "generate":
    guard let path = argument("--private") else { fail("generate 需要 --private") }
    let key = Curve25519.Signing.PrivateKey()
    do {
        try writePrivate(key, to: path)
    } catch {
        fail("写入私钥失败：\(error.localizedDescription)")
    }
    let publicBase64 = key.publicKey.rawRepresentation.base64EncodedString()
    if let publicOut = argument("--public-out") {
        do {
            try Data((publicBase64 + "\n").utf8).write(to: URL(fileURLWithPath: publicOut))
        } catch {
            fail("写入公钥失败：\(error.localizedDescription)")
        }
    }
    print(publicBase64)

case "sign":
    guard let privatePath = argument("--private"),
          let inputPath = argument("--input"),
          let outputPath = argument("--output") else {
        fail("sign 需要 --private、--input、--output")
    }
    guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: inputPath)) else {
        fail("无法读取清单：\(inputPath)")
    }
    let key = loadPrivate(privatePath)
    guard let signature = try? key.signature(for: bytes) else { fail("签名失败") }
    let encoded = Data((signature.base64EncodedString() + "\n").utf8)
    do {
        try encoded.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    } catch {
        fail("写入签名失败：\(error.localizedDescription)")
    }
    print("signed \(inputPath) -> \(outputPath) (\(signature.count) bytes)")

case "verify":
    guard let publicBase64 = argument("--public"),
          let inputPath = argument("--input"),
          let signaturePath = argument("--sig") else {
        fail("verify 需要 --public、--input、--sig")
    }
    guard let publicData = Data(base64Encoded: publicBase64), publicData.count == 32,
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicData) else {
        fail("公钥格式非法")
    }
    guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: inputPath)) else {
        fail("无法读取清单：\(inputPath)")
    }
    let signature = loadSignature(signaturePath)
    guard publicKey.isValidSignature(signature, for: bytes) else {
        fail("签名验证失败")
    }
    print("signature ok")

default:
    fail("未知子命令：\(command())")
}
