import XCTest
import Foundation
@testable import RuiTuOfficeMaster

final class AppUpdateTests: XCTestCase, @unchecked Sendable {
    private static func response(_ tag: String = "v1.5.2", status: Int = 200, draft: Bool = false, prerelease: Bool = false) -> (Data, URLResponse) {
        let data = Data("{\"tag_name\":\"\(tag)\",\"draft\":\(draft),\"prerelease\":\(prerelease)}".utf8)
        return (data, HTTPURLResponse(url: AppLinks.latestReleaseAPI, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func testVersionComparisonUsesNumbersAndIgnoresBuildMetadata() throws {
        XCTAssertTrue(try XCTUnwrap(ReleaseVersion("1.10.0")) > XCTUnwrap(ReleaseVersion("1.9.9")))
        XCTAssertEqual(ReleaseVersion("v1.5.2+build.19"), ReleaseVersion("1.5.2"))
        for version in ["", "1.5", "1.5.2.3", "1.05.2", "1.-5.2", "1.5.2-beta", "1.5.2+", "1.5.2+bad/path", "999999999999999999999999.1.0"] {
            XCTAssertNil(ReleaseVersion(version), version)
        }
    }
    func testUpdateRequestTargetsPublicLatestReleaseWithoutCredentials() async throws {
        let service = AppUpdateService { request in
            XCTAssertEqual(request.url, AppLinks.latestReleaseAPI)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.httpBody)
            return Self.response("v1.10.0")
        }
        let result = try await service.check(currentVersion: "1.9.9")
        XCTAssertEqual(result.relation, .updateAvailable); XCTAssertEqual(result.latestVersion, "1.10.0")
    }
    func testEqualAndLocalNewerAreDistinct() async throws {
        let service = AppUpdateService { _ in Self.response() }
        let equal = try await service.check(currentVersion: "1.5.2")
        let local = try await service.check(currentVersion: "1.5.4")
        XCTAssertEqual(equal.relation, .current); XCTAssertEqual(local.relation, .localNewer)
    }
    func testInvalidReleasesAndHTTPFailuresNeverReportCurrent() async {
        let invalid = [Self.response(draft: true), Self.response(prerelease: true), Self.response("banana"), Self.response(status: 404), Self.response(status: 403), Self.response(status: 429), Self.response(status: 500), (Data("not JSON".utf8), Self.response().1)]
        for value in invalid {
            do { _ = try await AppUpdateService(fetch: { _ in value }).check(currentVersion: "1.5.2"); XCTFail("Invalid response should fail") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
    @MainActor func testViewModelLabelsAllThreeRelations() async {
        for (version, expected) in [("1.5.1", "发现新版本 1.5.2"), ("1.5.2", "已是最新正式发布版"), ("1.5.4", "当前版本较新")] {
            let vm = AppUpdateViewModel(currentVersion: version, service: .init(fetch: { _ in Self.response() }))
            await vm.check()
            XCTAssertEqual(vm.statusTitle, expected); XCTAssertNotNil(vm.checkedAt); XCTAssertNil(vm.errorMessage); XCTAssertFalse(vm.isChecking)
        }
    }
    private actor Requests {
        var count = 0
        func next() -> Int { count += 1; return count }
        func total() -> Int { count }
    }
    @MainActor func testDuplicateChecksShareBusyStateAndDoNotFetchTwice() async throws {
        let requests = Requests()
        let vm = AppUpdateViewModel(currentVersion: "1.5.2", service: .init(fetch: { _ in
            _ = await requests.next(); try await Task.sleep(for: .milliseconds(100)); return Self.response()
        }))
        let first = Task { await vm.check() }
        while !vm.isChecking { await Task.yield() }
        await vm.check(); await first.value
        let count = await requests.total(); XCTAssertEqual(count, 1); XCTAssertEqual(vm.result?.relation, .current)
    }
    @MainActor func testFailedRecheckClearsPreviousSuccessAndCanRetry() async {
        let requests = Requests()
        let vm = AppUpdateViewModel(currentVersion: "1.5.2", service: .init(fetch: { _ in
            let count = await requests.next()
            if count == 2 { throw URLError(.timedOut) }
            return Self.response()
        }))
        await vm.check(); XCTAssertEqual(vm.result?.relation, .current)
        await vm.check(); XCTAssertNil(vm.result); XCTAssertNil(vm.checkedAt)
        XCTAssertEqual(vm.statusTitle, "未能完成检查"); XCTAssertTrue(vm.statusDetail.contains("超时")); XCTAssertFalse(vm.isChecking)
        await vm.check(); XCTAssertEqual(vm.result?.relation, .current); XCTAssertNil(vm.errorMessage)
    }
    @MainActor func testOfflineAndInvalidInstalledVersionShowFailure() async {
        let offline = AppUpdateViewModel(currentVersion: "1.5.2", service: .init(fetch: { _ in throw URLError(.notConnectedToInternet) }))
        await offline.check(); XCTAssertNil(offline.result); XCTAssertEqual(offline.statusTitle, "未能完成检查")
        let invalid = AppUpdateViewModel(currentVersion: "未标记", service: .init(fetch: { _ in XCTFail("Should validate current version before requesting"); return Self.response() }))
        await invalid.check(); XCTAssertNil(invalid.result); XCTAssertTrue(invalid.statusDetail.contains("版本号"))
    }
}
