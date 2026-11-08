import XCTest
@testable import RuiTuOfficeMaster

final class RitoOrganizationSummaryTests: XCTestCase, @unchecked Sendable {
    func testStructuredResultsGroupOnlySuccessfulCopies() {
        let results: [RToolAIResult] = [
            .init(sourceName: "a", detail: "", organizationCategory: "文档", organizationPhase: .completed),
            .init(sourceName: "b", detail: "", organizationCategory: "图片", organizationPhase: .completed),
            .init(sourceName: "c", detail: "", organizationCategory: "文档", organizationPhase: .completed),
            .init(sourceName: "d", detail: "", organizationCategory: "视频", organizationPhase: .skipped),
            .init(sourceName: "e", detail: "", organizationCategory: "代码", organizationPhase: .failed),
            .init(sourceName: "f", detail: "", organizationCategory: "音频", organizationPhase: .pending)]
        let summary = RitoOrganizationSummary(results: results)
        XCTAssertEqual(summary.categories, [.init(name: "图片", count: 1), .init(name: "文档", count: 2)])
        XCTAssertEqual(summary.successCount, 3); XCTAssertEqual(summary.skippedCount, 1)
        XCTAssertEqual(summary.failureCount, 1); XCTAssertEqual(summary.otherCount, 1)
    }
    func testLegacyHistoryUsesActualDestinationCategory() throws {
        let result = RToolAIResult(sourceName: "photo.txt", detail: "成功：图片/photo.txt")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        object.removeValue(forKey: "organizationCategory"); object.removeValue(forKey: "organizationPhase")
        let old = try JSONDecoder().decode(RToolAIResult.self, from: JSONSerialization.data(withJSONObject: object))
        let summary = RitoOrganizationSummary(results: [old, .init(sourceName: "skip", detail: "跳过：视频/skip.mp4")])
        XCTAssertEqual(summary.categories, [.init(name: "图片", count: 1)])
        XCTAssertEqual(summary.skippedCount, 1); XCTAssertEqual(summary.otherCount, 0)
    }
    func testUnknownRecordsNeverInventSuccessfulCategories() {
        let summary = RitoOrganizationSummary(results: [
            .init(sourceName: "image.png", detail: "无法读取文件"),
            .init(sourceName: "image.png", detail: "成功：无效类别/image.png")])
        XCTAssertTrue(summary.categories.isEmpty)
        XCTAssertEqual(summary.successCount, 1); XCTAssertEqual(summary.otherCount, 1)
        XCTAssertEqual(summary.uncategorizedSuccessCount, 1)
    }
    func testManyFilesProduceBoundedCategoryRowsAndRoundTrip() throws {
        let results = (0..<1000).map {
            RToolAIResult(sourceName: "file\($0)", detail: "", organizationCategory: $0 % 2 == 0 ? "文档" : "图片", organizationPhase: .completed)
        }
        let decoded = try JSONDecoder().decode([RToolAIResult].self, from: JSONEncoder().encode(results))
        let summary = RitoOrganizationSummary(results: decoded)
        XCTAssertEqual(summary.categories.count, 2)
        XCTAssertEqual(summary.categories.map(\.count), [500, 500])
        XCTAssertEqual(summary.successCount, 1000)
    }
}
