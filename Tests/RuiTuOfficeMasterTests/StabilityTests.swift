import XCTest
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import RuiTuOfficeMaster

private actor AttemptCounter {
    var counts: [String: Int] = [:]
    var active = 0
    var maxActive = 0
    func begin(_ name: String) -> Int {
        active += 1; maxActive = max(maxActive, active)
        counts[name, default: 0] += 1
        return counts[name]!
    }
    func end() { active -= 1 }
    func count(_ name: String) -> Int { counts[name, default: 0] }
}

final class StabilityTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ruit-stability-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func file(_ name: String, content: String = "RUITU") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url); return url
    }
    private func image(_ name: String = "image.png", width: Int = 64) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: width, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: 32))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest)); return url
    }
    @MainActor private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition timed out", file: file, line: line)
    }
    func testFolderImportIsRecursiveDeterministicAndDeduplicatesAliases() throws {
        let a = try image("照片/a.png"), b = try image("照片/子目录/b.png")
        _ = try file("照片/说明.txt")
        _ = try image("照片/.隐藏.png")
        let alias = directory.appendingPathComponent("a-link.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
        let loop = directory.appendingPathComponent("照片/子目录/loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: directory.appendingPathComponent("照片"))
        let result = try ImageFileImporter.collect([directory.appendingPathComponent("照片"), alias, a])
        XCTAssertEqual(Set(result.images.map(\.url)), Set([a, b]))
        XCTAssertEqual(result.images.map(\.url), try ImageFileImporter.collect([directory.appendingPathComponent("照片"), alias, a]).images.map(\.url))
        XCTAssertGreaterThanOrEqual(result.duplicates, 2)
    }
    func testImportDeduplicatesHardLinksAndExistingSelection() throws {
        let a = try image(), link = directory.appendingPathComponent("hard.png")
        try FileManager.default.linkItem(at: a, to: link)
        let result = try ImageFileImporter.collect([a, link, a], excluding: [a])
        XCTAssertTrue(result.images.isEmpty); XCTAssertEqual(result.duplicates, 3)
    }
    func testCorruptImageAndMissingFileAreReportedNotImported() throws {
        let bad = try file("损坏.png", content: "bad")
        let result = try ImageFileImporter.collect([bad, directory.appendingPathComponent("missing.png")])
        XCTAssertTrue(result.images.isEmpty); XCTAssertEqual(result.warnings.count, 2)
    }
    func testFolderImportLimitIsVisible() throws {
        _ = try image("a.png"); _ = try image("b.png")
        let result = try ImageFileImporter.collect([directory], limit: 2)
        XCTAssertEqual(result.images.count, 1)
        XCTAssertTrue(result.message?.contains("其余未导入") == true)
    }
    @MainActor func testBothImageImportModelsRejectDuplicatesInSameBatch() throws {
        let input = try image()
        let images = ImageCompressionViewModel(taskManager: FileTaskManager())
        images.addImages(from: [input, input])
        XCTAssertEqual(images.selectedImages.count, 1)
        let converter = FormatConversionViewModel(taskManager: FileTaskManager())
        converter.addFiles(from: [input, input]); converter.addFiles(from: [input])
        XCTAssertEqual(converter.selectedFiles.count, 1)
    }
    @MainActor func testAsyncFolderImportAndClearPreserveUserSettings() async throws {
        _ = try image("nested/a.png")
        let vm = FormatConversionViewModel(taskManager: FileTaskManager())
        vm.targetFormat = .png; vm.importFiles(from: [directory])
        try await waitUntil { !vm.isImporting }
        XCTAssertEqual(vm.selectedFiles.count, 1)
        vm.clearFiles(); XCTAssertTrue(vm.selectedFiles.isEmpty); XCTAssertEqual(vm.targetFormat, .png)
    }
    @MainActor func testCancelledImportDoesNotApplyPartialSelection() async throws {
        _ = try image("nested/a.png")
        let vm = FormatConversionViewModel(taskManager: FileTaskManager())
        vm.importFiles(from: [directory]); vm.cancelImport()
        try await waitUntil { !vm.isImporting }
        XCTAssertTrue(vm.selectedFiles.isEmpty); XCTAssertTrue(vm.errorMessage?.contains("已停止") == true)
    }
    @MainActor func testQueueSerializesBatchesAndExecutesActualOutputs() async throws {
        let manager = FileTaskManager(), tracker = AttemptCounter()
        let source = try file("source.txt")
        let operation: @Sendable (URL) async throws -> FileTaskOutput = { url in
            _ = await tracker.begin(url.lastPathComponent)
            try await Task.sleep(for: .milliseconds(20))
            await tracker.end()
            return FileTaskOutput(url: url, inputSize: 5, outputSize: 5)
        }
        let first = manager.enqueue(tool: "test", configuration: "first", sources: [source], operation: operation)
        let second = manager.enqueue(tool: "test", configuration: "second", sources: [source], operation: operation)
        XCTAssertEqual(manager.record(second)?.state, .waiting)
        try await waitUntil { manager.activeCount == 0 }
        XCTAssertEqual(manager.record(first)?.state, .completed); XCTAssertEqual(manager.record(second)?.state, .completed)
        let maxActive = await tracker.maxActive
        XCTAssertEqual(maxActive, 1)
        XCTAssertEqual(manager.record(second)?.files.first?.output?.url, source)
    }
    @MainActor func testCancellingQueuedTaskNeverExecutesItsFiles() async throws {
        let manager = FileTaskManager(), tracker = AttemptCounter()
        let firstSource = try file("first.txt"), secondSource = try file("second.txt")
        let first = manager.enqueue(tool: "test", configuration: "first", sources: [firstSource]) { url in
            try await Task.sleep(for: .seconds(1))
            return FileTaskOutput(url: url, inputSize: 5, outputSize: 5)
        }
        let second = manager.enqueue(tool: "test", configuration: "second", sources: [secondSource]) { url in
            _ = await tracker.begin(url.lastPathComponent)
            return FileTaskOutput(url: url, inputSize: 5, outputSize: 5)
        }
        manager.cancel(second); manager.cancel(first)
        try await waitUntil { manager.activeCount == 0 }
        let count = await tracker.count("second.txt")
        XCTAssertEqual(count, 0); XCTAssertEqual(manager.record(second)?.state, .cancelled)
        XCTAssertEqual(manager.record(second)?.progress, 0)
        XCTAssertEqual(manager.record(second)?.unfinished, 1)
    }
    @MainActor func testRetryReprocessesOnlyFailedFilesAndPreservesSuccessfulOutputs() async throws {
        let manager = FileTaskManager(), tracker = AttemptCounter()
        let good = try file("good.txt"), bad = try file("bad.txt")
        let id = manager.enqueue(tool: "test", configuration: "fixed settings", sources: [good, bad]) { url in
            let count = await tracker.begin(url.lastPathComponent); await tracker.end()
            if url.lastPathComponent == "bad.txt", count == 1 { throw CocoaError(.fileReadCorruptFile) }
            return FileTaskOutput(url: url, inputSize: 5, outputSize: 5)
        }
        try await waitUntil { manager.activeCount == 0 }
        XCTAssertEqual(manager.record(id)?.state, .partial)
        let old = manager.record(id)?.files.first?.output?.url
        manager.retry(id)
        try await waitUntil { manager.activeCount == 0 }
        XCTAssertEqual(manager.record(id)?.state, .completed); XCTAssertEqual(manager.record(id)?.succeeded, 2)
        XCTAssertEqual(manager.record(id)?.files.first?.output?.url, old)
        let goodCount = await tracker.count("good.txt"), badCount = await tracker.count("bad.txt")
        XCTAssertEqual(goodCount, 1); XCTAssertEqual(badCount, 2)
    }
    @MainActor func testCancellationErrorCannotProduceCompletedTask() async throws {
        let manager = FileTaskManager(), source = try file("source.txt")
        let id = manager.enqueue(tool: "test", configuration: "", sources: [source]) { _ in throw CancellationError() }
        try await waitUntil { manager.activeCount == 0 }
        XCTAssertEqual(manager.record(id)?.state, .cancelled); XCTAssertEqual(manager.record(id)?.unfinished, 1)
    }
    @MainActor func testCancelledBatchKeepsCompletedFilesAndRetryContinuesRemaining() async throws {
        let manager = FileTaskManager(), a = try file("a.txt"), b = try file("b.txt")
        var didCancel = false
        let id = manager.enqueue(tool: "test", configuration: "", sources: [a, b], operation: { url in
            return FileTaskOutput(url: url, inputSize: 5, outputSize: 5)
        }, onChange: { record in
            if record.succeeded == 1, record.state.isActive, !record.cancellationRequested, !didCancel {
                didCancel = true; manager.cancel(record.id)
            }
        })
        try await waitUntil { manager.activeCount == 0 }
        XCTAssertEqual(manager.record(id)?.state, .cancelled)
        XCTAssertEqual(manager.record(id)?.progress, 0.5)
        XCTAssertEqual(manager.record(id)?.files.first?.state, .completed)
        XCTAssertTrue(manager.canRetry(id)); XCTAssertEqual(manager.record(id)?.retryCount, 1)
        let firstOutput = manager.record(id)?.files.first?.output?.url
        manager.retry(id)
        try await waitUntil { manager.activeCount == 0 }
        XCTAssertEqual(manager.record(id)?.state, .completed)
        XCTAssertEqual(manager.record(id)?.succeeded, 2)
        XCTAssertEqual(manager.record(id)?.files.first?.attempts, 1)
        XCTAssertEqual(manager.record(id)?.files.first?.output?.url, firstOutput)
    }
    @MainActor func testPersistedTaskLoadsAsInterruptedWithoutReexecution() throws {
        let source = try file("source.txt"), store = directory.appendingPathComponent("Tasks.json")
        var record = FileTaskRecord(tool: "图片处理", configuration: "JPG", sources: [source])
        record.state = .running; record.files[0].state = .running
        try JSONEncoder().encode([record]).write(to: store)
        let manager = FileTaskManager(storageURL: store)
        XCTAssertEqual(manager.records.first?.state, .interrupted)
        XCTAssertEqual(manager.activeCount, 0); XCTAssertFalse(manager.canRetry(record.id))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "RUITU")
    }
    @MainActor func testCorruptTaskStoreIsPreservedAndReported() async throws {
        let data = Data("broken metadata".utf8), store = directory.appendingPathComponent("Tasks.json")
        try data.write(to: store)
        let source = try file("source.txt"), manager = FileTaskManager(storageURL: store)
        XCTAssertNotNil(manager.persistenceError)
        manager.enqueue(tool: "test", configuration: "", sources: [source]) { url in FileTaskOutput(url: url, inputSize: 5, outputSize: 5) }
        try await waitUntil { manager.activeCount == 0 }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(try Data(contentsOf: store), data)
    }
    @MainActor func testTaskMetadataPersistsResultsAndCanClearWithoutDeletingFiles() async throws {
        let store = directory.appendingPathComponent("store/Tasks.json")
        let source = try file("source.txt"), manager = FileTaskManager(storageURL: store)
        manager.enqueue(tool: "test", configuration: "", sources: [source]) { url in FileTaskOutput(url: url, inputSize: 5, outputSize: 5) }
        try await waitUntil { manager.activeCount == 0 }
        try await Task.sleep(for: .milliseconds(350))
        let restored = FileTaskManager(storageURL: store)
        XCTAssertEqual(restored.records.first?.state, .completed)
        XCTAssertEqual(restored.records.first?.files.first?.output?.url, source)
        manager.clearFinished()
        XCTAssertTrue(manager.records.isEmpty); XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    @MainActor func testRealFormatConversionFailureRetryKeepsFirstOutputAndOriginals() async throws {
        let a = try image("a.png"), b = try image("b.png", width: 128)
        let aData = try Data(contentsOf: a), bData = try Data(contentsOf: b)
        let manager = FileTaskManager(), vm = FormatConversionViewModel(taskManager: manager)
        vm.addFiles(from: [a, b]); vm.targetFormat = .png
        try Data("damaged after import".utf8).write(to: b)
        vm.executeConversion(); try await waitUntil { !vm.isProcessing }
        XCTAssertEqual(vm.results.count, 1); XCTAssertTrue(vm.canRetry)
        let successfulURL = vm.results.first?.convertedURL
        try bData.write(to: b)
        vm.retryFailed(); try await waitUntil { !vm.isProcessing }
        XCTAssertEqual(vm.results.count, 2); XCTAssertFalse(vm.canRetry)
        XCTAssertEqual(vm.results.first?.convertedURL, successfulURL)
        XCTAssertEqual(try Data(contentsOf: a), aData); XCTAssertEqual(try Data(contentsOf: b), bData)
        for result in vm.results { XCTAssertEqual(try ImageCodec.sourceType(at: result.convertedURL), .png) }
    }
    @MainActor func testChangingImageSettingsInvalidatesOldResultsAndRetryBinding() async throws {
        let input = try image(), vm = ImageCompressionViewModel(taskManager: FileTaskManager())
        vm.addImages(from: [input]); vm.executeCompression()
        try await waitUntil { !vm.isProcessing }
        XCTAssertEqual(vm.results.count, 1)
        vm.outputFormat = .jpg
        XCTAssertTrue(vm.results.isEmpty); XCTAssertNil(vm.taskID); XCTAssertNil(vm.successMessage)
    }
    @MainActor func testChangingConversionSettingsInvalidatesOldResults() async throws {
        let input = try image(), vm = FormatConversionViewModel(taskManager: FileTaskManager())
        vm.addFiles(from: [input]); vm.executeConversion()
        try await waitUntil { !vm.isProcessing }
        XCTAssertEqual(vm.results.count, 1)
        vm.targetFormat = .png
        XCTAssertTrue(vm.results.isEmpty); XCTAssertNil(vm.taskID)
    }
    func testPartialExportReportsOnlyActualRenamesAndKeepsExistingBytes() throws {
        let source = try file("source.txt", content: "new"), destination = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = destination.appendingPathComponent("source.txt"); try Data("old".utf8).write(to: existing)
        let report = ResultExporter.export([source, directory.appendingPathComponent("missing.txt")], to: destination)
        XCTAssertEqual(report.savedURLs.count, 1); XCTAssertEqual(report.renamedCount, 1); XCTAssertEqual(report.errors.count, 1)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: report.savedURLs[0], encoding: .utf8), "new")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destination.path).contains { $0.hasPrefix(".ruit-export-") })
    }
    func testSafeExportRejectsDirectoryWithoutLeavingTemporaryFiles() throws {
        let target = directory.appendingPathComponent("copy")
        XCTAssertThrowsError(try FileUtils.safeCopy(from: directory, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    @MainActor func testToolSearchSupportsKeywordsCaseAndMultipleTerms() {
        XCTAssertTrue(ToolCatalog.search("png").contains { $0.item == .formatConversion })
        XCTAssertTrue(ToolCatalog.search("pdf").contains { $0.item == .pdfTools })
        XCTAssertEqual(ToolCatalog.search("证件照 蓝底").map(\.item), [.idPhoto])
        XCTAssertEqual(ToolCatalog.search("  ").count, ToolCatalog.tools.count)
        XCTAssertTrue(ToolCatalog.search("不存在的工具").isEmpty)
    }
    func testRenameRejectsFileEditedAfterPreview() throws {
        let source = try file("old.txt")
        let service = FileRenameService()
        let preview = service.generatePreview(files: [source], mode: .prefix, prefix: "new-", suffix: "", findText: "", replaceText: "", numberText: "", startNumber: 1, numberDigits: 3)
        try Data("externally changed content".utf8).write(to: source)
        guard case .failure = service.execute(previewItems: preview, progressHandler: { _ in }) else { return XCTFail("Must require a fresh preview") }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "externally changed content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new-old.txt").path))
    }
    func testRenameUndoRejectsReplacedFile() throws {
        let source = try file("old.txt"), service = FileRenameService()
        let preview = service.generatePreview(files: [source], mode: .prefix, prefix: "new-", suffix: "", findText: "", replaceText: "", numberText: "", startNumber: 1, numberDigits: 3)
        guard case .success(let moves) = service.execute(previewItems: preview, progressHandler: { _ in }), let renamed = moves.first?.renamed else { return XCTFail() }
        try FileManager.default.removeItem(at: renamed)
        try Data("replacement file".utf8).write(to: renamed)
        guard case .failure = service.undo(moves) else { return XCTFail("Undo must not move a replacement file") }
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "replacement file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

}
