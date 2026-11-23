import XCTest
import AppKit
@testable import GogakuKit
@testable import GogakuSettings

/// 完整版内 Lite 模式（2026-11-18）：设置字段编解码、首次引导只出现一次、
/// 侧栏可见页与快捷键命令的运行时过滤、学习门禁、释义生效值。
/// 编译形态相关断言分列：GOGAKU_LITE 构建固定四页、无引导、门禁恒假。
final class LiteModeTests: XCTestCase {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    // MARK: 设置存储

    func testLiteFieldsDecodeDefaultsOff() throws {
        let settings = try decode("{}")
        XCTAssertFalse(settings.liteModeEnabled)
        XCTAssertFalse(settings.modeOnboardingCompleted)
    }

    func testLiteFieldsRoundTrip() throws {
        var settings = Settings()
        settings.liteModeEnabled = true
        settings.modeOnboardingCompleted = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(decoded.liteModeEnabled)
        XCTAssertTrue(decoded.modeOnboardingCompleted)
        // schemaVersion 不动，新字段是可选解码（旧文件缺键＝false）。
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

    func testSharedContractNormalizesLiteFields() throws {
        // 类型不对一律回默认 false，不让坏字段把整份设置打成默认。
        let broken = Data(#"{"liteModeEnabled":"yes","modeOnboardingCompleted":1,"candidateFontSize":15}"#.utf8)
        let canonical = try XCTUnwrap(Settings.normalize(broken))
        var settings = try JSONDecoder().decode(Settings.self, from: canonical)
        XCTAssertFalse(settings.liteModeEnabled)
        XCTAssertFalse(settings.modeOnboardingCompleted)
        XCTAssertEqual(settings.candidateFontSize, 15)

        // 正常值经共享契约保留；glossEnabled 存储值不被规范化改动。
        settings.liteModeEnabled = true
        settings.glossEnabled = true
        let normalized = try XCTUnwrap(Settings.normalize(try JSONEncoder().encode(settings)))
        let reread = try JSONDecoder().decode(Settings.self, from: normalized)
        XCTAssertTrue(reread.liteModeEnabled)
        XCTAssertTrue(reread.glossEnabled)
    }

    // MARK: 首次引导

    func testOnboardingShowsOnceAndPersistsChoice() throws {
        #if GOGAKU_LITE
        XCTAssertFalse(ModeOnboarding.isSupported)
        var settings = Settings()
        XCTAssertFalse(ModeOnboarding.shouldShow(for: settings))
        #else
        XCTAssertTrue(ModeOnboarding.isSupported)
        var settings = Settings()
        XCTAssertTrue(ModeOnboarding.shouldShow(for: settings), "未选择就关窗时下次仍显示")

        settings.glossEnabled = false        // 用户此前手动关过释义
        ModeOnboarding.apply(.lite, to: &settings)
        XCTAssertTrue(settings.liteModeEnabled)
        XCTAssertTrue(settings.modeOnboardingCompleted)
        XCTAssertFalse(settings.glossEnabled, "引导不改写用户存的 glossEnabled")
        XCTAssertFalse(ModeOnboarding.shouldShow(for: settings), "选择后不再出现")

        // 落盘再读：仍然只出现一次。
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertFalse(ModeOnboarding.shouldShow(for: decoded))
        XCTAssertTrue(decoded.liteModeEnabled)

        // 选完整模式：liteMode 关闭、引导同样只出现一次。
        var full = Settings()
        ModeOnboarding.apply(.full, to: &full)
        XCTAssertFalse(full.liteModeEnabled)
        XCTAssertFalse(ModeOnboarding.shouldShow(for: full))
        #endif
    }

    // MARK: 侧栏可见页

    func testSettingsPageVisibleCasesFollowLiteMode() {
        #if GOGAKU_LITE
        // Lite 独立安装包固定六页（五个功能页＋关于；2026-11-26 扩展词库裁决），
        // 与运行开关无关。
        XCTAssertEqual(SettingsPage.visibleCases(liteModeEnabled: false),
                       [.normalInput, .customWords, .dictionaries, .skin, .shortcuts, .about])
        XCTAssertEqual(SettingsPage.visibleCases(liteModeEnabled: true),
                       [.normalInput, .customWords, .dictionaries, .skin, .shortcuts, .about])
        #else
        // 完整版九页；扩展词库紧跟「自定义词语」（2026-11-26 裁决）。
        XCTAssertEqual(SettingsPage.allCases,
                       [.normalInput, .resources, .customWords, .dictionaries, .skin,
                        .shortcuts, .privacy, .records, .about])
        XCTAssertEqual(SettingsPage.visibleCases(liteModeEnabled: false), SettingsPage.allCases)
        XCTAssertEqual(SettingsPage.visibleCases(liteModeEnabled: true),
                       [.normalInput, .customWords, .dictionaries, .skin, .shortcuts, .about])
        XCTAssertTrue(SettingsPage.visibleCases(liteModeEnabled: true).allSatisfy { !$0.isLearningPage })
        #endif
        XCTAssertEqual(SettingsPage.allCases.filter(\.isLearningPage),
                       [.resources, .privacy, .records])
        // 关于页在所有安装形态可见（2026-11-19 裁决）：排 allCases 最后、
        // 不属于学习页、Lite 集合包含它。
        XCTAssertEqual(SettingsPage.allCases.last, .about)
        XCTAssertFalse(SettingsPage.about.isLearningPage)
        XCTAssertTrue(SettingsPage.liteCases.contains(.about))
        XCTAssertFalse(SettingsPage.visibleCases(liteModeEnabled: true).isEmpty)
        XCTAssertTrue(SettingsPage.visibleCases(liteModeEnabled: true).contains(.about))
    }

    // MARK: 快捷键命令过滤

    func testConfigurableCommandFilterFollowsLiteMode() {
        #if GOGAKU_LITE
        XCTAssertTrue(ConfigurableCommand.uiCases.isEmpty)
        XCTAssertTrue(ConfigurableCommand.uiCases(liteModeEnabled: false).isEmpty)
        #else
        XCTAssertEqual(ConfigurableCommand.uiCases.count, 2)
        XCTAssertEqual(ConfigurableCommand.uiCases(liteModeEnabled: false),
                       [.modeSwitch, .directionSwitch])
        XCTAssertTrue(ConfigurableCommand.uiCases(liteModeEnabled: true).isEmpty)
        var settings = Settings()
        XCTAssertEqual(ConfigurableCommand.uiCases(for: settings).count, 2)
        settings.liteModeEnabled = true
        XCTAssertTrue(ConfigurableCommand.uiCases(for: settings).isEmpty)
        // Lite 下隐藏的学习命令不参与冲突判断。
        XCTAssertNil(KeyCombo.conflict(
            target: .directionSwitch, keyID: "k",
            modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue,
            settings: settings))
        #endif
    }

    // MARK: 学习门禁

    func testLearningGateAlsoChecksLiteMode() {
        #if GOGAKU_LITE
        // 编译期已裁掉学习链路：门禁恒假，与运行开关无关。
        var settings = Settings()
        settings.learningTranslationEnabled = true
        XCTAssertFalse(settings.learningEnabled)
        settings.liteModeEnabled = false
        XCTAssertFalse(settings.learningEnabled)
        #else
        var settings = Settings()
        settings.learningTranslationEnabled = true
        XCTAssertTrue(settings.learningEnabled)
        settings.liteModeEnabled = true
        XCTAssertFalse(settings.learningEnabled, "Lite 模式关闭学习入口")
        XCTAssertTrue(settings.learningTranslationEnabled, "学习开关存储值不变，切回即恢复")

        settings.liteModeEnabled = false
        XCTAssertTrue(settings.learningEnabled)
        settings.learningTranslationEnabled = false
        XCTAssertFalse(settings.learningEnabled)
        #endif
    }

    // MARK: 释义生效值

    func testGlossEffectiveValueForcedOffByLiteMode() {
        var settings = Settings()
        XCTAssertTrue(settings.effectiveGlossEnabled)
        settings.liteModeEnabled = true
        XCTAssertFalse(settings.effectiveGlossEnabled, "Lite 生效值强制关闭")
        XCTAssertTrue(settings.glossEnabled, "不覆写用户存的 glossEnabled")

        settings.liteModeEnabled = false
        XCTAssertTrue(settings.effectiveGlossEnabled, "切回完整即恢复")

        settings.glossEnabled = false
        XCTAssertFalse(settings.effectiveGlossEnabled)
        settings.liteModeEnabled = true
        settings.liteModeEnabled = false
        XCTAssertFalse(settings.effectiveGlossEnabled, "恢复的是用户此前选的值")
    }
}
