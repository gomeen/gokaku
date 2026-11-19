import XCTest
@testable import GogakuSettings

/// 构建身份展示（2026-11-19 裁决）：侧栏页脚已删除，版本与通道标注只在
/// 「关于」页出现。displayVersion 不携带构建号尾巴；stable 安装不显示
/// 「本机开发版」标注；完整身份行（commit 前 8 位＋dirty）只在包内
/// build-identity.json 存在时提供，开发直接运行时省略。
final class BuildIdentityLabelTests: XCTestCase {
    func testStableInstallationShowsNoDevLabelOrBuildNumber() {
        // 本测试进程的 bundle 是测试宿主（无 .dev 后缀），等价 stable 形态。
        XCTAssertFalse(BuildIdentity.isDevChannel)
        XCTAssertFalse(BuildIdentity.displayVersion.contains("构建"))
        XCTAssertFalse(BuildIdentity.displayVersion.contains("dirty"))
    }

    func testBuildDetailLineFormatWhenPresent() {
        // 测试宿主没有包内 build-identity.json：必须省略完整身份行（返回 nil）。
        // 若未来测试宿主附带身份文件，格式必须是「commit 前 8 位［ · dirty］」。
        guard let detail = BuildIdentity.buildDetailLine else { return }
        XCTAssertGreaterThanOrEqual(detail.count, 8)
        let commitPart = detail.split(separator: " ").first.map(String.init) ?? detail
        XCTAssertEqual(commitPart.count, 8)
        if detail.contains("dirty") {
            XCTAssertTrue(detail.hasSuffix("dirty"))
        }
    }
}
