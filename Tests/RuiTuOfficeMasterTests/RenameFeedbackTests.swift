import XCTest
@testable import RuiTuOfficeMaster

final class RenameFeedbackTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ruitu-rename-feedback-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func file(_ name: String, content: String = "keep original bytes") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }
    @MainActor private func finish(_ vm: FileRenameViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while vm.isProcessing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(vm.isProcessing)
    }
    @MainActor private func rename(_ files: [URL], in vm: FileRenameViewModel) async throws {
        vm.prefixText = "new_"
        vm.addFiles(from: files)
        XCTAssertTrue(vm.canExecute)
        vm.executeRename()
        try await finish(vm)
    }

    @MainActor func testSuccessKeepsFeedbackMappingsAndUndoWhenSelectionIsEmpty() async throws {
        let first = try file("甲.txt"), second = try file("乙.txt")
        let bytes = try [first, second].map { try Data(contentsOf: $0) }
        let vm = FileRenameViewModel()
        try await rename([first, second], in: vm)
        XCTAssertTrue(vm.selectedFiles.isEmpty)
        XCTAssertTrue(vm.previewItems.isEmpty)
        XCTAssertTrue(vm.hasOperationFeedback, "界面必须在待处理列表为空时继续显示结果")
        XCTAssertEqual(vm.successMessage, "成功改名 2 个文件")
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.canUndo)
        XCTAssertEqual(vm.completedMoves.map(\.original), [first, second])
        XCTAssertEqual(vm.completedMoves.map { $0.renamed.lastPathComponent }, ["new_甲.txt", "new_乙.txt"])
        XCTAssertEqual(try vm.completedMoves.map { try Data(contentsOf: $0.renamed) }, bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        vm.undoRename(); try await finish(vm)
        XCTAssertFalse(vm.canUndo)
        XCTAssertTrue(vm.didUndo)
        XCTAssertTrue(vm.hasOperationFeedback)
        XCTAssertEqual(vm.successMessage, "撤销成功，已恢复 2 个文件的原文件名")
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: $0) }, bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vm.completedMoves[0].renamed.path))
    }

    @MainActor func testClearingOrChangingSelectionPreservesOutcomeAndUndo() async throws {
        let first = try file("first.txt"), second = try file("second.txt")
        let vm = FileRenameViewModel(); try await rename([first], in: vm)
        vm.addFiles(from: [second]); vm.clearFiles()
        XCTAssertEqual(vm.prefixText, "new_")
        XCTAssertTrue(vm.canUndo); XCTAssertTrue(vm.hasOperationFeedback)
        XCTAssertEqual(vm.successMessage, "成功改名 1 个文件")
        let renamed = vm.completedMoves[0].renamed
        vm.addFiles(from: [renamed]); vm.undoRename(); try await finish(vm)
        XCTAssertEqual(vm.selectedFiles, [first])
        XCTAssertEqual(vm.previewItems.first?.originalURL, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    @MainActor func testStaleSourceFailsWithVisibleErrorAndPreservesSelection() async throws {
        let source = try file("edited.txt")
        let vm = FileRenameViewModel(); vm.prefixText = "new_"; vm.addFiles(from: [source])
        try Data("changed after preview".utf8).write(to: source)
        vm.executeRename(); try await finish(vm)
        XCTAssertTrue(vm.hasOperationFeedback)
        XCTAssertNil(vm.successMessage)
        XCTAssertTrue(vm.errorMessage?.contains("改名失败") == true)
        XCTAssertTrue(vm.errorMessage?.contains("edited.txt") == true)
        XCTAssertEqual(vm.selectedFiles, [source]); XCTAssertFalse(vm.canUndo)
        XCTAssertEqual(try Data(contentsOf: source), Data("changed after preview".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new_edited.txt").path))
    }

    @MainActor func testUndoFailureClearsOldSuccessKeepsFilesAndCanRetry() async throws {
        let source = try file("source.txt")
        let vm = FileRenameViewModel(); try await rename([source], in: vm)
        let renamed = vm.completedMoves[0].renamed
        try Data("blocker".utf8).write(to: source)
        vm.undoRename(); try await finish(vm)
        XCTAssertNil(vm.successMessage)
        XCTAssertTrue(vm.errorMessage?.contains("撤销失败") == true)
        XCTAssertTrue(vm.hasOperationFeedback); XCTAssertTrue(vm.canUndo); XCTAssertFalse(vm.didUndo)
        XCTAssertEqual(try Data(contentsOf: source), Data("blocker".utf8))
        XCTAssertEqual(try Data(contentsOf: renamed), Data("keep original bytes".utf8))
        try FileManager.default.removeItem(at: source)
        vm.undoRename(); try await finish(vm)
        XCTAssertNil(vm.errorMessage); XCTAssertTrue(vm.didUndo); XCTAssertFalse(vm.canUndo)
        XCTAssertEqual(try Data(contentsOf: source), Data("keep original bytes".utf8))
    }

    @MainActor func testUnchangedNamesAreReportedAsSkippedAndNotUndoMoves() async throws {
        let changed = try file("find.txt"), unchanged = try file("keep.txt")
        let vm = FileRenameViewModel(); vm.renameMode = .replace
        vm.findText = "find"; vm.replaceText = "replaced"; vm.addFiles(from: [changed, unchanged])
        vm.executeRename(); try await finish(vm)
        XCTAssertEqual(vm.successMessage, "成功改名 1 个文件，1 个文件名未变化，已跳过")
        XCTAssertEqual(vm.completedMoves.count, 1)
        XCTAssertEqual(vm.completedMoves[0].original, changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unchanged.path))
        vm.undoRename(); try await finish(vm)
        XCTAssertEqual(vm.successMessage, "撤销成功，已恢复 1 个文件的原文件名")
    }

    @MainActor func testFailedNextBatchKeepsPreviousSuccessfulUndoWithoutOldSuccessMessage() async throws {
        let first = try file("first.txt"), second = try file("second.txt")
        let vm = FileRenameViewModel(); try await rename([first], in: vm)
        vm.addFiles(from: [second]); try FileManager.default.removeItem(at: second)
        vm.executeRename(); try await finish(vm)
        XCTAssertNil(vm.successMessage); XCTAssertTrue(vm.errorMessage?.contains("改名失败") == true)
        XCTAssertEqual(vm.completedMoves.first?.original, first)
        XCTAssertTrue(vm.canUndo)
        vm.clearFiles(); XCTAssertTrue(vm.hasOperationFeedback)
        vm.undoRename(); try await finish(vm)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }
}
