import XCTest
@testable import GogakuSettings

/// 侧栏页脚版本标签（2026-11-18 用户裁决）：stable 安装不显示「本机开发版」
/// 与构建号（显示「Gogaku」＋纯版本号）；只有 dev 通道（bundle ID 带 .dev
/// 后缀）才显示「本机开发版」。displayVersion 不再携带「构建 N」尾巴。
final class BuildIdentityLabelTests: XCTestCase {
    func testStableInstallationShowsNoDevLabelOrBuildNumber() {
        // 本测试进程的 bundle 是测试宿主（无 .dev 后缀），等价 stable 形态。
        XCTAssertFalse(BuildIdentity.isDevChannel)
        XCTAssertFalse(BuildIdentity.displayVersion.contains("构建"))
        XCTAssertFalse(BuildIdentity.displayVersion.contains("dirty"))
    }
}
