import Foundation
import GogakuKit

private struct Fixture: Decodable {
    struct Vector: Decodable {
        let name: String
        let manifest: String
        let signature: String
        let result: String
    }
    let keyId: String
    let publicKey: String
    let vectors: [Vector]
}

private final class FixtureTransport: UpdateTransport {
    let vector: Fixture.Vector

    init(_ vector: Fixture.Vector) { self.vector = vector }

    func get(_ url: URL, headers: [String: String], timeout: TimeInterval,
             maxBytes: Int) async throws -> UpdateHTTPResponse {
        let body: Data
        switch url.lastPathComponent {
        case "catalog.json": body = Data(vector.manifest.utf8)
        case "catalog.json.sig": body = Data(vector.signature.utf8)
        default: throw UpdateTransportError.http(404)
        }
        return UpdateHTTPResponse(status: 200, headers: [:], body: body, finalURL: url)
    }

    func download(_ url: URL, timeout: TimeInterval,
                  progress: @escaping @Sendable (Int64) -> Void) async throws -> (URL, UpdateHTTPResponse) {
        throw UpdateTransportError.http(404)
    }
}

@main struct DictionaryCatalogSelfcheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: input))
        let configBytes = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "owner": "gomeen", "repo": "gogaku-dicts", "trustedKeyIds": [fixture.keyId]
        ])
        let config = try JSONDecoder().decode(DictionaryCatalog.Config.self, from: configBytes)
        let keys = [UpdateTrustedKey(keyId: fixture.keyId, publicKey: fixture.publicKey)]
        var failures = 0
        for vector in fixture.vectors {
            let actual: String
            do {
                let snapshot = try await DictionaryCatalog.fetch(transport: FixtureTransport(vector),
                                                                  config: config, updateKeys: keys, installed: [])
                actual = snapshot.entries.count == 1 ? "accepted" : "unexpected result"
            } catch DictionaryCatalog.CatalogError.signature {
                actual = "signature"
            } catch DictionaryCatalog.CatalogError.contract(let message) where message.contains("kind") {
                actual = "contract"
            } catch {
                actual = error.localizedDescription
            }
            let matches = actual == vector.result
            print("\(matches ? "PASS" : "FAIL") \(vector.name) \(actual)")
            if !matches { failures += 1 }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
