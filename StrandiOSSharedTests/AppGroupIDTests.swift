import XCTest

final class AppGroupIDTests: XCTestCase {
    func testUsesExpandedInfoPlistValue() {
        XCTAssertEqual(AppGroupID.resolve(infoValue: "group.com.yourname.noop", fallback: "group.x"),
                       "group.com.yourname.noop")
    }

    func testFallsBackWhenMissingUnexpandedOrMalformed() {
        XCTAssertEqual(AppGroupID.resolve(infoValue: nil, fallback: "group.x"), "group.x")
        XCTAssertEqual(AppGroupID.resolve(infoValue: "$(APP_GROUP_ID)", fallback: "group.x"), "group.x")
        XCTAssertEqual(AppGroupID.resolve(infoValue: "", fallback: "group.x"), "group.x")
        XCTAssertEqual(AppGroupID.resolve(infoValue: "com.not.a.group", fallback: "group.x"), "group.x")
        XCTAssertEqual(AppGroupID.resolve(infoValue: 42, fallback: "group.x"), "group.x")
    }

    func testTestBundleWithoutKeyUsesUpstreamDefaults() {
        XCTAssertEqual(AppGroupID.resolve(infoKey: AppGroupID.phoneInfoKey,
                                          fallback: AppGroupID.phoneFallback,
                                          bundle: Bundle(for: AppGroupIDTests.self)),
                       "group.com.noopapp.noop")
    }
}
