import XCTest
import PDFKit
import AppKit
@testable import RuiTuOfficeMaster

private actor PDFTestGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class PDFBatchTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ruitu-pdf-batch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func pdf(_ name: String, pages: Int = 1) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for i in 1...pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "PAGE \(i)", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            context.textPosition = CGPoint(x: 30, y: 200); CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    @MainActor private func select(_ files: [URL], in vm: PDFToolsViewModel) throws {
        vm.addFiles(from: files)
        guard vm.selectedFiles.count == files.count else {
            let details = files.map { "\($0.path): \(String(describing: try? $0.resourceValues(forKeys: [.typeIdentifierKey, .isRegularFileKey])))" }.joined(separator: "\n")
            throw NSError(domain: "PDFImportTest", code: 1, userInfo: [NSLocalizedDescriptionKey: details])
        }
    }
    @MainActor private func finish(_ vm: PDFToolsViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while vm.isProcessing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(vm.isProcessing, "后台处理必须结束")
    }
    @MainActor private func waitForGate(_ gate: PDFTestGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await gate.started) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let started = await gate.started
        XCTAssertTrue(started)
    }

    @MainActor func testWatermarkPartialFailureRetryOnlyFailedPreservesOutputsAndSources() async throws {
        let first = try pdf("甲/same.pdf"), third = try pdf("乙/same.pdf")
        let bad = directory.appendingPathComponent("坏文件.pdf")
        try Data("broken".utf8).write(to: bad)
        let originals = try [first, third].map { try Data(contentsOf: $0) }
        let vm = PDFToolsViewModel(); vm.selectedTool = .watermark
        try select([first, bad, third], in: vm); vm.execute(); try await finish(vm)
        XCTAssertEqual(vm.entries.map(\.state), [.succeeded, .failed, .succeeded])
        XCTAssertTrue(vm.entries[1].error?.contains("坏文件.pdf") == true)
        XCTAssertEqual(vm.results.count, 2); XCTAssertTrue(vm.canRetry)
        XCTAssertEqual(Set(vm.results.map(\.outputURL)).count, 2)
        let before = vm.results
        let bytes = try before.map { try Data(contentsOf: $0.outputURL) }
        try FileManager.default.removeItem(at: bad)
        try FileManager.default.copyItem(at: first, to: bad)
        vm.retryEntry(vm.entries[1].id); try await finish(vm)
        XCTAssertEqual(vm.entries.map(\.state), [.succeeded, .succeeded, .succeeded])
        XCTAssertEqual(vm.results.count, 3); XCTAssertFalse(vm.canRetry)
        let repaired = try XCTUnwrap(vm.results.first { $0.originalURL == bad })
        XCTAssertEqual(repaired.originalSize, Int64(try Data(contentsOf: bad).count))
        XCTAssertEqual(vm.originalSizes[bad], repaired.originalSize)
        XCTAssertEqual(Array(vm.results.prefix(2)).map(\.id), before.map(\.id))
        XCTAssertEqual(try before.map { try Data(contentsOf: $0.outputURL) }, bytes)
        XCTAssertEqual(try [first, third].map { try Data(contentsOf: $0) }, originals)
    }

    @MainActor func testStopFinishesCurrentFileAndRetryProcessesOnlyRemainingWithOriginalSettings() async throws {
        let files = try [pdf("one.pdf"), pdf("two.pdf"), pdf("three.pdf")]
        let gate = PDFTestGate(); let first = files[0]
        let vm = PDFToolsViewModel(processor: { job, config, stop in
            if job.sources.first == first { await gate.wait() }
            return try PDFBatchProcessor.process(job, configuration: config, stop: stop)
        })
        vm.selectedTool = .encrypt; vm.userPassword = "test-user"; vm.ownerPassword = "test-owner"
        vm.allowCopying = false; try select(files, in: vm); vm.execute()
        try await waitForGate(gate)
        XCTAssertEqual(vm.entries.map(\.state), [.processing, .waiting, .waiting])
        vm.stopProcessing(); vm.stopProcessing()
        XCTAssertTrue(vm.isProcessing); XCTAssertTrue(vm.cancellationRequested)
        await gate.release(); try await finish(vm)
        XCTAssertEqual(vm.entries.map(\.state), [.succeeded, .stopped, .stopped])
        XCTAssertTrue(vm.wasStopped); XCTAssertEqual(vm.progress, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(vm.results.count, 1); let existing = vm.results[0]
        let bytes = try Data(contentsOf: existing.outputURL)
        vm.retryEntry(vm.entries[1].id); try await finish(vm)
        XCTAssertEqual(vm.succeededCount, 2); XCTAssertEqual(vm.unfinishedCount, 1)
        XCTAssertEqual(vm.entries[2].state, .stopped); XCTAssertTrue(vm.canRetry)
        vm.retryUnfinished(); try await finish(vm)
        XCTAssertEqual(vm.results.count, 3); XCTAssertEqual(vm.succeededCount, 3); XCTAssertFalse(vm.wasStopped)
        XCTAssertEqual(vm.results[0].id, existing.id); XCTAssertEqual(try Data(contentsOf: existing.outputURL), bytes)
        for result in vm.results {
            let doc = try XCTUnwrap(PDFDocument(url: result.outputURL)); XCTAssertTrue(doc.isLocked)
            XCTAssertTrue(doc.unlock(withPassword: "test-user")); XCTAssertFalse(doc.allowsCopying)
        }
    }

    @MainActor func testSplitRangesHaveUniqueRowsAndRetryRetainsFirstRange() async throws {
        let source = try pdf("pages.pdf", pages: 4); let gate = PDFTestGate()
        let vm = PDFToolsViewModel(processor: { job, config, stop in
            if job.range?.start == 1 { await gate.wait() }
            return try PDFBatchProcessor.process(job, configuration: config, stop: stop)
        })
        vm.selectedTool = .split; try select([source], in: vm); vm.splitRangesText = "1-2, 3, 3"
        let previewDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while vm.splitPreview.isLoadingDocument && ContinuousClock.now < previewDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(vm.canExecute)
        vm.execute(); try await waitForGate(gate); vm.stopProcessing(); await gate.release(); try await finish(vm)
        XCTAssertEqual(vm.entries.map(\.state), [.succeeded, .stopped, .stopped])
        let firstID = vm.results.first?.id
        vm.retryUnfinished(); try await finish(vm)
        XCTAssertEqual(vm.results.count, 3); XCTAssertEqual(vm.results.first?.id, firstID)
        XCTAssertEqual(Set(vm.results.map(\.id)).count, 3)
        XCTAssertEqual(Set(vm.results.map(\.outputURL)).count, 3)
        XCTAssertEqual(vm.results.map { PDFDocument(url: $0.outputURL)?.pageCount }, [2, 1, 1])
        XCTAssertEqual(PDFDocument(url: source)?.pageCount, 4)
    }

    @MainActor func testMergeInvalidSourceBlocksWholeGroupAndRetryIncludesEverySource() async throws {
        let first = try pdf("first.pdf", pages: 2), last = try pdf("last.pdf", pages: 3)
        let bad = directory.appendingPathComponent("broken.pdf"); try Data("bad".utf8).write(to: bad)
        let vm = PDFToolsViewModel(); try select([first, bad, last], in: vm); vm.execute(); try await finish(vm)
        XCTAssertEqual(vm.entries.map(\.state), [.blocked, .failed, .blocked])
        XCTAssertTrue(vm.results.isEmpty); XCTAssertTrue(vm.canRetry)
        try FileManager.default.removeItem(at: bad); try FileManager.default.copyItem(at: first, to: bad)
        vm.retryUnfinished(); try await finish(vm)
        XCTAssertEqual(vm.succeededCount, 3); XCTAssertEqual(vm.results.count, 1)
        XCTAssertEqual(PDFDocument(url: vm.results[0].outputURL)?.pageCount, 7)
        XCTAssertFalse(vm.canRetry)
    }

    func testMergeStopNeverPublishesPartialOutputOrReplacesExistingDestination() throws {
        let first = try pdf("first.pdf", pages: 3), second = try pdf("second.pdf", pages: 2)
        let existing = directory.appendingPathComponent("existing.pdf"); let original = Data("keep".utf8)
        try original.write(to: existing)
        var checks = 0
        XCTAssertThrowsError(try PDFService().merge(urls: [first, second], outputURL: existing, shouldStop: {
            checks += 1; return checks >= 3
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: existing), original)
    }

    @MainActor func testChangedSettingsInvalidateRetryAndSuccessfulResults() async throws {
        let first = try pdf("good.pdf"); let bad = directory.appendingPathComponent("bad.pdf")
        try Data("bad".utf8).write(to: bad)
        let vm = PDFToolsViewModel(); vm.selectedTool = .watermark
        try select([first, bad], in: vm); vm.execute(); try await finish(vm)
        XCTAssertEqual(vm.results.count, 1); XCTAssertTrue(vm.canRetry)
        vm.watermarkText = "新的水印"
        XCTAssertFalse(vm.canRetry); XCTAssertTrue(vm.results.isEmpty); XCTAssertTrue(vm.entries.isEmpty)
        XCTAssertTrue(vm.canExecute)
        vm.clearFiles(); XCTAssertEqual(vm.watermarkText, "新的水印")
        XCTAssertTrue(vm.selectedFiles.isEmpty)
    }

    @MainActor func testConversionContinuesAfterBadPDFAndLabelsGrowthCorrectly() async throws {
        let first = try pdf("good.pdf")
        let bad = directory.appendingPathComponent("bad.pdf"); try Data("bad".utf8).write(to: bad)
        let vm = PDFToolsViewModel(); vm.selectedTool = .conversion; vm.conversionDirection = .pdfToWord
        try select([bad, first], in: vm); vm.execute(); try await finish(vm)
        XCTAssertEqual(vm.entries.map(\.state), [.failed, .succeeded]); XCTAssertEqual(vm.results.count, 1)
        XCTAssertEqual(vm.results[0].originalURL, first); XCTAssertEqual(vm.results[0].outputURL.pathExtension, "docx")
        XCTAssertGreaterThan(FileUtils.fileSize(of: vm.results[0].outputURL), 0)
        let item = PDFResultItem(originalURL: first, outputURL: first, originalSize: 100, outputSize: 150, operationDescription: "test")
        XCTAssertEqual(item.changeText, "增加 50%")
    }

    @MainActor func testMergeStopDuringCombineKeepsEverySourceAndPublishesNothing() async throws {
        let sources = try [pdf("one.pdf", pages: 2), pdf("two.pdf", pages: 2)]
        let originals = try sources.map { try Data(contentsOf: $0) }
        let gate = PDFTestGate()
        let vm = PDFToolsViewModel(processor: { job, config, stop in
            await gate.wait()
            return try PDFBatchProcessor.process(job, configuration: config, stop: stop)
        })
        try select(sources, in: vm); vm.execute(); try await waitForGate(gate)
        XCTAssertEqual(vm.entries.map(\.state), [.ready, .ready])
        vm.stopProcessing(); await gate.release(); try await finish(vm)
        XCTAssertTrue(vm.wasStopped); XCTAssertTrue(vm.results.isEmpty)
        XCTAssertEqual(vm.entries.map(\.state), [.stopped, .stopped]); XCTAssertTrue(vm.canRetry)
        XCTAssertLessThan(vm.progress, 1)
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, originals)
    }

    @MainActor func testRunningBatchUsesCapturedPasswordAndDisablesRetryAfterExternalSettingsChange() async throws {
        let source = try pdf("one.pdf"); let gate = PDFTestGate()
        let vm = PDFToolsViewModel(processor: { job, config, stop in
            await gate.wait()
            return try PDFBatchProcessor.process(job, configuration: config, stop: stop)
        })
        vm.selectedTool = .encrypt; vm.userPassword = "original-password"
        try select([source], in: vm); vm.execute(); try await waitForGate(gate)
        vm.userPassword = "changed-password"
        await gate.release(); try await finish(vm)
        let output = try XCTUnwrap(vm.results.first)
        let doc = try XCTUnwrap(PDFDocument(url: output.outputURL))
        XCTAssertFalse(doc.unlock(withPassword: "changed-password"))
        XCTAssertTrue(doc.unlock(withPassword: "original-password"))
        XCTAssertFalse(vm.canRetry)
        XCTAssertTrue(vm.successMessage?.contains("开始处理时的设置") == true)
    }
}
