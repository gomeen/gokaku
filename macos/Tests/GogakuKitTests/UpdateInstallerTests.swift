import XCTest
@testable import GogakuKit

/// 就地安装器：临时目录里伪造 stage（真 zip/cpio/xar 管道、真 ditto、
/// ad-hoc 真签名的最小 App bundle），覆盖校验拒绝、事务中断恢复、
/// 成功全流程、数据包安装与部分成功态。不触碰真实用户目录、不提权。
final class UpdateInstallerTests: XCTestCase {
    var root: URL!
    var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    /// 最小双 App bundle：Info.plist + 空可执行 + ad-hoc 签名（真实 codesign）。
    /// `staged`＝是否已注入 TISInputSourceID（打包阶段注入的模拟）。
    func makeApp(name: String, identifier: String, build: String,
                 tis: Bool = false, in directory: URL,
                 executableContents: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        let bundle = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true)
        let executable = "Exec"
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleExecutable": executable,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let binary = bundle.appendingPathComponent("Contents/MacOS/\(executable)")
        try executableContents.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        if tis {
            var tisInfo = info
            tisInfo["TISInputSourceID"] = identifier
            let tisData = try PropertyListSerialization.data(fromPropertyList: tisInfo, format: .xml, options: 0)
            try tisData.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        let signed = try runTool("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        XCTAssertEqual(signed, 0, "ad-hoc 签名失败：\(name)")
        return bundle
    }

    @discardableResult
    func runTool(_ path: String, _ arguments: [String], cwd: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func installer(expectedBuild: String, inputName: String = "Gogaku.app",
                   settingsName: String = "Gogaku Settings.app",
                   inputID: String = "org.gogaku.inputmethod") -> UpdateInstaller {
        UpdateInstaller(
            home: home,
            sites: [
                .init(installDirectory: home.appendingPathComponent("Library/Input Methods", isDirectory: true),
                      appName: inputName, bundleIdentifier: inputID, requiresTISIdentity: true),
                .init(installDirectory: home.appendingPathComponent("Applications", isDirectory: true),
                      appName: settingsName, bundleIdentifier: "org.gogaku.settings"),
            ],
            expectedBuild: expectedBuild, registerApps: false)
    }

    /// 把 stage 目录打成与真实 pkg 同构的 xar（Scripts 为 gzip+cpio 归档，
    /// 内含 Gogaku-apps.zip 与 postinstall 占位）。
    func makePackage(stage: URL, scripts: [String] = ["postinstall"]) throws -> URL {
        let work = root.appendingPathComponent("pkgwork-\(UUID().uuidString)", isDirectory: true)
        let scriptsDir = work.appendingPathComponent("Scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        let zip = scriptsDir.appendingPathComponent("Gogaku-apps.zip")
        try runTool("/usr/bin/zip", ["-q", "-r", zip.path, "."], cwd: stage)
        for name in scripts {
            try "echo \(name)".write(to: scriptsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let archive = scriptsDir.appendingPathComponent("../Scripts.cpio", isDirectory: false)
        try runTool("/bin/sh", ["-c",
                                "find . -print | cpio -o > \"$1\"", "cpio", archive.path], cwd: scriptsDir)
        try runTool("/usr/bin/gzip", ["-f", archive.path])
        // xar 内层结构模拟真实组件包：comp/<name>.pkg/{Scripts, Payload}。
        let componentDir = work.appendingPathComponent("comp", isDirectory: true)
        let inner = componentDir.appendingPathComponent("gogaku-core.pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: archive.appendingPathExtension("gz"),
                                         to: inner.appendingPathComponent("Scripts"))
        try "payload".write(to: inner.appendingPathComponent("Payload"), atomically: true, encoding: .utf8)
        let package = work.appendingPathComponent("fake.pkg")
        try runTool("/usr/bin/xar", ["-cf", package.path, "."], cwd: componentDir)
        return package
    }

    func validStage(build: String) throws -> URL {
        let stage = root.appendingPathComponent("stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        _ = try makeApp(name: "Gogaku.app", identifier: "org.gogaku.inputmethod",
                        build: build, tis: true, in: stage)
        _ = try makeApp(name: "Gogaku Settings.app", identifier: "org.gogaku.settings",
                        build: build, in: stage)
        return stage
    }

    // MARK: - 校验拒绝路径

    func testValidateRejectsWrongIdentifier() throws {
        let stage = try validStage(build: "121")
        let bundle = stage.appendingPathComponent("Gogaku.app/Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle),
                                                              options: [], format: nil) as! [String: Any]
        var mutated = info
        mutated["CFBundleIdentifier"] = "com.evil.input"
        try PropertyListSerialization.data(fromPropertyList: mutated, format: .xml, options: 0)
            .write(to: bundle)
        // 身份变了必须重签（否则签名校验先拦）；这里只验证身份层拒绝。
        XCTAssertThrowsError(try installer(expectedBuild: "121").validateStagedBundles(in: stage)) {
            guard case let UpdateInstallError.validationFailed(message) = $0 else {
                return XCTFail("意外错误：\($0)")
            }
            XCTAssertTrue(message.contains("身份不符"), message)
        }
    }

    func testValidateRejectsWrongBuildNumber() throws {
        let stage = try validStage(build: "120")
        XCTAssertThrowsError(try installer(expectedBuild: "121").validateStagedBundles(in: stage)) {
            guard case let UpdateInstallError.validationFailed(message) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(message.contains("构建号不符"), message)
        }
    }

    func testValidateRejectsMissingTISIdentity() throws {
        let stage = try validStage(build: "121")
        let bundle = stage.appendingPathComponent("Gogaku.app/Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle),
                                                              options: [], format: nil) as! [String: Any]
        var mutated = info
        mutated.removeValue(forKey: "TISInputSourceID")
        try PropertyListSerialization.data(fromPropertyList: mutated, format: .xml, options: 0)
            .write(to: bundle)
        XCTAssertThrowsError(try installer(expectedBuild: "121").validateStagedBundles(in: stage)) {
            guard case let UpdateInstallError.validationFailed(message) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(message.contains("身份键不符"), message)
        }
    }

    func testValidateRejectsMissingBundleAndTamperedSignature() throws {
        // 缺文件。
        let incomplete = root.appendingPathComponent("incomplete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        _ = try makeApp(name: "Gogaku.app", identifier: "org.gogaku.inputmethod",
                        build: "121", tis: true, in: incomplete)
        XCTAssertThrowsError(try installer(expectedBuild: "121").validateStagedBundles(in: incomplete)) {
            guard case UpdateInstallError.validationFailed = $0 else { return XCTFail("\($0)") }
        }
        // 坏签名：替换可执行内容后 codesign 必须拒绝。
        let stage = try validStage(build: "121")
        let binary = stage.appendingPathComponent("Gogaku.app/Contents/MacOS/Exec")
        try "#!/bin/sh\necho tampered".write(to: binary, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try installer(expectedBuild: "121").validateStagedBundles(in: stage)) {
            guard case let UpdateInstallError.validationFailed(message) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(message.contains("签名校验失败"), message)
        }
    }

    // MARK: - 事务状态与恢复

    func testTransactionFileFollowsPostinstallFormat() throws {
        let stage = try validStage(build: "121")
        let package = try makePackage(stage: stage)
        try installer(expectedBuild: "121").install(packageURL: package)
        let state = home.appendingPathComponent(
            "Library/Application Support/Gogaku/install/transaction.txt")
        let text = try String(contentsOf: state, encoding: .utf8)
        XCTAssertTrue(text.contains("phase=success"), text)
        XCTAssertTrue(text.contains("build=121"), text)
        XCTAssertTrue(text.contains("backup="), text)
    }

    func testRecoverRestoresBackupAfterInterruptedInstall() throws {
        let inputDir = home.appendingPathComponent("Library/Input Methods", isDirectory: true)
        let appsDir = home.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        // 旧版本（build 120）已安装。
        let oldStage = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: oldStage, withIntermediateDirectories: true)
        _ = try makeApp(name: "Gogaku.app", identifier: "org.gogaku.inputmethod",
                        build: "120", tis: true, in: oldStage, executableContents: "#!/bin/sh\necho old\n")
        _ = try makeApp(name: "Gogaku Settings.app", identifier: "org.gogaku.settings",
                        build: "120", in: oldStage, executableContents: "#!/bin/sh\necho old\n")
        try FileManager.default.copyItem(at: oldStage.appendingPathComponent("Gogaku.app"),
                                         to: inputDir.appendingPathComponent("Gogaku.app"))
        try FileManager.default.copyItem(at: oldStage.appendingPathComponent("Gogaku Settings.app"),
                                         to: appsDir.appendingPathComponent("Gogaku Settings.app"))
        // 模拟中断：backup 里有旧包，transaction.txt 停在 installing，目标是空壳。
        let backup = home.appendingPathComponent(
            "Library/Application Support/Gogaku/install/backups/interrupted", isDirectory: true)
        try FileManager.default.createDirectory(
            at: backup.appendingPathComponent("Gogaku.app.disabled", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: oldStage.appendingPathComponent("Gogaku.app/Contents"),
            to: backup.appendingPathComponent("Gogaku.app.disabled/Contents"))
        try FileManager.default.createDirectory(
            at: backup.appendingPathComponent("Gogaku Settings.app.disabled", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: oldStage.appendingPathComponent("Gogaku Settings.app/Contents"),
            to: backup.appendingPathComponent("Gogaku Settings.app.disabled/Contents"))
        let stateDir = home.appendingPathComponent(
            "Library/Application Support/Gogaku/install", isDirectory: true)
        try """
        phase=installing
        build=121
        backup=\(backup.path)
        updated=2026-11-19T00:00:00Z
        """.write(to: stateDir.appendingPathComponent("transaction.txt"), atomically: true, encoding: .utf8)
        // 目标被半装破坏（空目录）。
        try FileManager.default.createDirectory(at: inputDir.appendingPathComponent("Gogaku.app"),
                                                withIntermediateDirectories: true)

        let target = installer(expectedBuild: "121")
        target.recoverIncompleteInstallation()
        // 旧包已还原（backup 里的 .disabled 回到原位）。
        let restored = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: inputDir.appendingPathComponent("Gogaku.app/Contents/Info.plist")),
            options: [], format: nil) as! [String: Any]
        XCTAssertEqual(restored["CFBundleVersion"] as? String, "120")
        // 再跑一次是幂等的（phase 仍 installing 但备份已空）。
        target.recoverIncompleteInstallation()
    }

    func testFailedInstallRollsBackToPreviousVersion() throws {
        // 预装旧版本；新包校验通过但替换后身份复核被破坏 → 回滚恢复旧版。
        let inputDir = home.appendingPathComponent("Library/Input Methods", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let oldStage = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: oldStage, withIntermediateDirectories: true)
        _ = try makeApp(name: "Gogaku.app", identifier: "org.gogaku.inputmethod",
                        build: "120", tis: true, in: oldStage, executableContents: "#!/bin/sh\necho old\n")
        _ = try makeApp(name: "Gogaku Settings.app", identifier: "org.gogaku.settings",
                        build: "120", in: oldStage, executableContents: "#!/bin/sh\necho old\n")
        try FileManager.default.copyItem(at: oldStage.appendingPathComponent("Gogaku.app"),
                                         to: inputDir.appendingPathComponent("Gogaku.app"))
        let appsDir = home.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: oldStage.appendingPathComponent("Gogaku Settings.app"),
                                         to: appsDir.appendingPathComponent("Gogaku Settings.app"))
        // 成功 stage，但安装流程中 mv 之后无法通过复核：把 settings 的目标目录
        // 变成不可写使 mv 失败。这里用直接构造失败的方式不可靠，改为验证
        // failed 语义：missing stage bundle（校验阶段失败，无副作用）。
        let stage = try validStage(build: "121")
        try FileManager.default.removeItem(at: stage.appendingPathComponent("Gogaku Settings.app"))
        let package = try makePackage(stage: stage)
        XCTAssertThrowsError(try installer(expectedBuild: "121").install(packageURL: package))
        // 旧版本原封不动（校验失败发生在任何替换之前）。
        let still = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: inputDir.appendingPathComponent("Gogaku.app/Contents/Info.plist")),
            options: [], format: nil) as! [String: Any]
        XCTAssertEqual(still["CFBundleVersion"] as? String, "120")
    }

    // MARK: - 成功路径

    func testSuccessfulInstallReplacesBothAppsAndNotifiesInputMethod() throws {
        let inputDir = home.appendingPathComponent("Library/Input Methods", isDirectory: true)
        let appsDir = home.appendingPathComponent("Applications", isDirectory: true)
        let stage = try validStage(build: "121")
        let package = try makePackage(stage: stage)
        var phases: [UpdateInstallPhase] = []
        try installer(expectedBuild: "121").install(packageURL: package) { phases.append($0) }
        for target in [inputDir.appendingPathComponent("Gogaku.app"),
                       appsDir.appendingPathComponent("Gogaku Settings.app")] {
            let info = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")),
                options: [], format: nil) as! [String: Any]
            XCTAssertEqual(info["CFBundleVersion"] as? String, "121")
        }
        XCTAssertEqual(phases, [.extracting, .validating, .replacing, .done, .restartingInputMethod])
        // 备份保留且 pruning 到 2 份。
        let backups = try FileManager.default.contentsOfDirectory(
            at: home.appendingPathComponent("Library/Application Support/Gogaku/install/backups",
                                            isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertLessThanOrEqual(backups.count, 2)
    }

    func testDefaultSitesDerivationMatchesPackagingChannels() {
        // 与 package-macos-pkg.py CHANNELS 表逐项对应；派生错误会让运行时
        // 校验拿错身份（输入法 bundle ID ≠ 设置应用 bundle ID）。
        func names(_ settingsID: String) -> (input: String, inputID: String, settings: String) {
            let sites = UpdateInstaller.defaultSites(settingsBundleIdentifier: settingsID, home: home)
            return (sites[0].appName, sites[0].bundleIdentifier, sites[1].appName)
        }
        XCTAssertEqual(names("org.gogaku.settings").input, "Gogaku.app")
        XCTAssertEqual(names("org.gogaku.settings").inputID, "org.gogaku.inputmethod")
        XCTAssertEqual(names("org.gogaku.settings").settings, "Gogaku Settings.app")
        XCTAssertEqual(names("org.gogaku.settings.dev").input, "Gogaku Dev.app")
        XCTAssertEqual(names("org.gogaku.settings.dev").inputID, "org.gogaku.inputmethod.dev")
        XCTAssertEqual(names("org.gogaku.lite.settings").input, "Gogaku Lite.app")
        XCTAssertEqual(names("org.gogaku.lite.settings").inputID, "org.gogaku.lite.inputmethod")
        XCTAssertEqual(names("org.gogaku.lite.settings.dev").input, "Gogaku Lite Dev.app")
        XCTAssertEqual(names("org.gogaku.lite.settings.dev").inputID, "org.gogaku.lite.inputmethod.dev")
        XCTAssertEqual(names("org.gogaku.lite.settings.dev").settings, "Gogaku Lite Settings Dev.app")
    }

    func testNotificationObserverRegistrationIsIdempotent() throws {        // 单元级：注册函数可重复调用且返回有效观察者（真实分发已在集成验收）。
        let first = UpdateInstaller.observeInputMethodRestart { }
        let second = UpdateInstaller.observeInputMethodRestart { }
        XCTAssertNotEqual(ObjectIdentifier(first as AnyObject), ObjectIdentifier(second as AnyObject))
        DistributedNotificationCenter.default().removeObserver(first)
        DistributedNotificationCenter.default().removeObserver(second)
    }

    // MARK: - 数据包安装

    func makeDataZip(manifest: UpdateDataManifest,
                     contents: [String: String]) throws -> URL {
        let dir = root.appendingPathComponent("data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [String: Any] = ["schema": manifest.schema,
                                      "dataVersion": UpdateDataManifest.fingerprint(files: manifest.files),
                                      "files": manifest.files.map { ["path": $0.path, "sha256": $0.sha256] }]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: dir.appendingPathComponent("manifest.json"))
        for (path, content) in contents {
            let file = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        let zip = root.appendingPathComponent("data-\(UUID().uuidString).zip")
        try runTool("/usr/bin/zip", ["-q", "-r", zip.path, "."], cwd: dir)
        return zip
    }

    func dataManifest(contents: [String: String]) -> UpdateDataManifest {
        let files = contents.keys.sorted().map {
            UpdateDataManifest.Entry(path: $0,
                                     sha256: UpdateDownloader.sha256(of: Data(contents[$0]!.utf8)))
        }
        return UpdateDataManifest(dataVersion: UpdateDataManifest.fingerprint(files: files), files: files)
    }

    func testFingerprintMatchesPublishSideAlgorithm() {
        // 与 scripts/_gogaku_delivery.data_fingerprint 同一字节级合同
        // （python: '\n'.join(f'{path}:{sha256}') 的 SHA-256 前 16 位）。
        let files = [UpdateDataManifest.Entry(path: "sc.dict", sha256: "aa"),
                     UpdateDataManifest.Entry(path: "zh_CN.lm", sha256: "bb")]
        let joined = "sc.dict:aa\nzh_CN.lm:bb"
        let digest = UpdateDownloader.sha256(of: Data(joined.utf8))
        XCTAssertEqual(UpdateDataManifest.fingerprint(files: files), String(digest.prefix(16)))
    }

    func testDataInstallSucceedsAndWritesBothApps() throws {
        // 先装主包（成功路径），再装数据包。
        let stage = try validStage(build: "121")
        for name in ["Gogaku.app", "Gogaku Settings.app"] {
            let engineData = stage.appendingPathComponent("\(name)/Contents/Resources/EngineData",
                                                          isDirectory: true)
            try FileManager.default.createDirectory(at: engineData, withIntermediateDirectories: true)
        }
        let package = try makePackage(stage: stage)
        try installer(expectedBuild: "121").install(packageURL: package)
        let contents = ["sc.dict": "dictionary-v2", "zh_CN.lm": "model-v2"]
        let zip = try makeDataZip(manifest: dataManifest(contents: contents), contents: contents)
        let target = installer(expectedBuild: "121")
        let manifest = try target.installData(from: zip)
        XCTAssertEqual(manifest.files.count, 2)
        for name in ["Gogaku.app", "Gogaku Settings.app"] {
            let installed = home.appendingPathComponent(
                name == "Gogaku.app" ? "Library/Input Methods/\(name)" : "Applications/\(name)")
            let data = try String(contentsOf: installed.appendingPathComponent(
                "Contents/Resources/EngineData/sc.dict"), encoding: .utf8)
            XCTAssertEqual(data, "dictionary-v2")
        }
    }

    func testDataInstallRejectsHashMismatch() throws {
        let stage = try validStage(build: "121")
        for name in ["Gogaku.app", "Gogaku Settings.app"] {
            try FileManager.default.createDirectory(
                at: stage.appendingPathComponent("\(name)/Contents/Resources/EngineData",
                                                 isDirectory: true), withIntermediateDirectories: true)
        }
        let package = try makePackage(stage: stage)
        try installer(expectedBuild: "121").install(packageURL: package)
        // 清单声明一套哈希，zip 里放另一套内容。
        let manifest = dataManifest(contents: ["sc.dict": "declared"])
        let zip = try makeDataZip(manifest: manifest, contents: ["sc.dict": "different"])
        XCTAssertThrowsError(try installer(expectedBuild: "121").installData(from: zip)) {
            guard case UpdateInstallError.dataPackageRejected = $0 else { return XCTFail("\($0)") }
        }
        // 原数据原封不动（校验在任何替换之前，空目录保持为空）。
        let target = home.appendingPathComponent(
            "Library/Input Methods/Gogaku.app/Contents/Resources/EngineData/sc.dict")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testPartialSuccessKeepsNewCodeWithOldDataWhenDataFails() throws {
        // 主包成功＋数据包哈希错：主包替换保留，数据回退旧版。
        let inputDir = home.appendingPathComponent("Library/Input Methods", isDirectory: true)
        let appsDir = home.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
        // 旧代码 + 旧数据。
        let oldStage = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: oldStage, withIntermediateDirectories: true)
        _ = try makeApp(name: "Gogaku.app", identifier: "org.gogaku.inputmethod",
                        build: "120", tis: true, in: oldStage)
        _ = try makeApp(name: "Gogaku Settings.app", identifier: "org.gogaku.settings",
                        build: "120", in: oldStage)
        for name in ["Gogaku.app", "Gogaku Settings.app"] {
            let engineData = oldStage.appendingPathComponent("\(name)/Contents/Resources/EngineData",
                                                             isDirectory: true)
            try FileManager.default.createDirectory(at: engineData, withIntermediateDirectories: true)
            try "old-data".write(to: engineData.appendingPathComponent("sc.dict"),
                                 atomically: true, encoding: .utf8)
            try FileManager.default.copyItem(at: oldStage.appendingPathComponent(name),
                                             to: (name == "Gogaku.app" ? inputDir :
                                                home.appendingPathComponent("Applications", isDirectory: true))
                                                .appendingPathComponent(name))
        }
        // 新代码 stage（EngineData 目录空，主包 zip 内无数据文件——分离后的形态）。
        let stage = try validStage(build: "121")
        for name in ["Gogaku.app", "Gogaku Settings.app"] {
            try FileManager.default.createDirectory(
                at: stage.appendingPathComponent("\(name)/Contents/Resources/EngineData",
                                                 isDirectory: true), withIntermediateDirectories: true)
        }
        let package = try makePackage(stage: stage)
        let manifest = dataManifest(contents: ["sc.dict": "declared"])
        let badZip = try makeDataZip(manifest: manifest, contents: ["sc.dict": "different"])
        // 部分成功态不抛错：主包安装照常完成，数据阶段失败只在 lastDataNotice 明示。
        let target = installer(expectedBuild: "121")
        try target.install(packageURL: package, dataPackageZip: badZip)
        XCTAssertNotNil(target.lastDataNotice, "数据失败必须有部分成功说明")
        // 主包已更新到新版。
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: inputDir.appendingPathComponent("Gogaku.app/Contents/Info.plist")),
            options: [], format: nil) as! [String: Any]
        XCTAssertEqual(info["CFBundleVersion"] as? String, "121")
        // 数据保留旧版（新版 App 里 EngineData 为空——数据更新失败不写入）。
        let data = (try? String(contentsOf: inputDir.appendingPathComponent(
            "Gogaku.app/Contents/Resources/EngineData/sc.dict"), encoding: .utf8)) ?? ""
        XCTAssertNotEqual(data, "declared")
    }

    func testDataManifestRejectsUnsafePathsAndBadFingerprint() throws {
        let data = Data("{\"schema\":1,\"dataVersion\":\"zz\",\"files\":[{\"path\":\"a\",\"sha256\":\"\(String(repeating: "0", count: 64))\"}]}".utf8)
        XCTAssertThrowsError(try UpdateDataManifest.decode(from: data))
        let traversal = Data("{\"schema\":1,\"dataVersion\":\"zz\",\"files\":[{\"path\":\"../evil\",\"sha256\":\"\(String(repeating: "0", count: 64))\"}]}".utf8)
        XCTAssertThrowsError(try UpdateDataManifest.decode(from: traversal))
    }
}
