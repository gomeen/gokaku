import XCTest
@testable import GogakuCore

final class TranslationTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    func service(script: String) throws -> TranslationService {
        let file = directory.appendingPathComponent("test-worker")
        try ("#!/usr/bin/env python3\n" + script).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return TranslationService(executable: file)
    }
    func request(_ text: String) -> TranslationRequest {
        TranslationRequest(stamp: InputStamp(mode: .learning, direction: .enToZh), sourceID: "english:full", source: text, resource: "test-only")
    }
    func testOneRunningAndOnlyLatestPendingAndNoStaleDelivery() throws {
        let trace = directory.appendingPathComponent("trace.jsonl")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = String(data: try encoder.encode(trace.path), encoding: .utf8)!
        let s = try service(script: """
        import json, sys, time
        for line in sys.stdin:
            r = json.loads(line)
            with open(\(encoded), 'a') as f: f.write(json.dumps(r['source']) + '\\n')
            time.sleep(0.6)
            r.update(target='synthetic', error=None, milliseconds=600)
            print(json.dumps(r), flush=True)
        """)
        let done = expectation(description: "latest")
        s.onResult = { result in XCTAssertEqual(result.source, "latest"); XCTAssertNil(result.error); done.fulfill() }
        s.request(request("first"))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { s.request(self.request("discarded")) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.45) { s.request(self.request("latest")) }
        wait(for: [done], timeout: 8)
        let traceText = try String(contentsOf: trace, encoding: .utf8)
        XCTAssertEqual(traceText.split(separator: "\n"), ["\"first\"", "\"latest\""])
        withExtendedLifetime(s) {}
    }
    func testCacheHitIsMarkedAndNotCountedAsNewRequest() throws {
        let counter = directory.appendingPathComponent("requests.txt")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = String(data: try encoder.encode(counter.path), encoding: .utf8)!
        let s = try service(script: """
        import json, sys
        for line in sys.stdin:
            r = json.loads(line)
            with open(\(encoded), 'a') as f: f.write('x')
            r.update(target='synthetic', error=None, milliseconds=0)
            print(json.dumps(r), flush=True)
        """)
        let first = expectation(description: "first")
        let second = expectation(description: "second")
        s.onResult = { result in
            if result.cached == true {
                XCTAssertEqual(result.target, "synthetic")
                second.fulfill()
            } else {
                XCTAssertNil(result.error)
                first.fulfill()
                s.requestImmediately(self.request("same"))
            }
        }
        s.requestImmediately(request("same"))
        wait(for: [first, second], timeout: 8)
        let count = (try? String(contentsOf: counter, encoding: .utf8).count) ?? 0
        XCTAssertEqual(count, 1)
        withExtendedLifetime(s) {}
    }

    func testInvalidationPreventsSuccessfulLateResponse() throws {
        let s = try service(script: """
        import json, sys, time
        for line in sys.stdin:
            r = json.loads(line)
            time.sleep(0.3)
            r.update(target='synthetic', error=None, milliseconds=300)
            print(json.dumps(r), flush=True)
        """)
        let noResult = expectation(description: "invalidated"); noResult.isInverted = true
        s.onResult = { _ in noResult.fulfill() }
        s.request(request("first"))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { s.invalidate() }
        wait(for: [noResult], timeout: 1)
        withExtendedLifetime(s) {}
    }
    func testWrongResourceResponseIsRejected() throws {
        let s = try service(script: """
        import json, sys
        for line in sys.stdin:
            r = json.loads(line)
            r.update(target='synthetic', error=None, milliseconds=0, resource='wrong')
            print(json.dumps(r), flush=True)
        """)
        let done = expectation(description: "rejected")
        s.onResult = { result in XCTAssertEqual(result.error, "invalid_response"); XCTAssertNil(result.target); done.fulfill() }
        s.request(request("first")); wait(for: [done], timeout: 5)
        withExtendedLifetime(s) {}
    }
    func testHungHelperTimesOutThenRunsLatestAfterExit() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let marker = String(data: try encoder.encode(directory.appendingPathComponent("started").path), encoding: .utf8)!
        let s = try service(script: """
        import json, os, sys, time
        from pathlib import Path
        marker = Path(\(marker))
        if not marker.exists():
            marker.write_text(str(os.getpid()))
            time.sleep(30)
        for line in sys.stdin:
            r = json.loads(line)
            r.update(target='recovered', error=None, milliseconds=0)
            print(json.dumps(r), flush=True)
        """)
        let done = expectation(description: "latest after hung helper actually exits")
        s.onResult = { result in
            XCTAssertEqual(result.source, "latest"); XCTAssertEqual(result.target, "recovered"); XCTAssertNil(result.error)
            done.fulfill()
        }
        var first = request("first")
        first.ignoredWords = [String(repeating: "a", count: 60_000)]
        s.request(first)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { s.invalidate(); s.request(self.request("latest")) }
        wait(for: [done], timeout: 16)
        withExtendedLifetime(s) {}
    }
    func testInputLimitPreservesOriginalRequest() throws {
        let s = try service(script: "import sys\nfor line in sys.stdin: pass\n")
        let source = String(repeating: "😀", count: 513)
        let done = expectation(description: "limit")
        s.onResult = { result in XCTAssertEqual(result.error, "input_limit"); XCTAssertEqual(result.source, source); done.fulfill() }
        s.request(request(source)); wait(for: [done], timeout: 5)
        withExtendedLifetime(s) {}
    }
}

final class SpellingTests: XCTestCase {
    func testFinishedWordUTF16AndExemptions() {
        let source = "😀 metting https://example.com/a test@example.com foo_bar Gogaku NASA customword "
        let issues = Spelling.check(source, ignored: ["customword"])
        let expected = (source as NSString).range(of: "metting")
        XCTAssertTrue(issues.contains { $0.location == expected.location && $0.length == expected.length })
        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(Spelling.check("metting", ignored: []).isEmpty)
        XCTAssertTrue(Spelling.check("metting ", ignored: ["metting"]).isEmpty)
    }
    func testAsyncSpellRangesBelongToExactText() {
        let done = expectation(description: "spelling")
        let text = "😀 metting "
        let executable = Bundle(for: SpellingTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("GogakuTranslator")
        let s = TranslationService(executable: executable, arguments: ["--spell"])
        s.onResult = { result in
            let issues = result.issues ?? []
            let range = (text as NSString).range(of: "metting")
            XCTAssertTrue(issues.contains { $0.location == range.location && $0.length == range.length })
            done.fulfill()
        }
        s.request(TranslationRequest(stamp: InputStamp(mode: .learning, direction: .enToZh), sourceID: "spelling", source: text, resource: "NSSpellChecker:en_US"))
        wait(for: [done], timeout: 8)
        withExtendedLifetime(s) {}
    }
}
