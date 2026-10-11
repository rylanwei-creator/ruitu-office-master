import XCTest
import Foundation
@testable import RuiTuOfficeMaster

final class OrganizerTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("source") }
    private var output: URL { root.appendingPathComponent("整理结果") }
    private var store: OrganizerJournalStore { .init(directory: directory.appendingPathComponent("logs")) }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ruitu-organizer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    @discardableResult private func file(_ name: String, _ text: String = "content", in base: URL? = nil) throws -> URL {
        let url = (base ?? root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func config(mode: OrganizerMode = .copy, conflict: OrganizerConflict = .number, recursive: Bool = true, excluded: [URL] = []) -> OrganizerConfiguration {
        .init(roots: [root], destination: output, recursive: recursive, excluded: excluded, mode: mode, conflict: conflict)
    }
    func testPreviewClassifiesWithoutWritingAndReportsExactPaths() throws {
        for name in ["a.JPG","a.pdf","a.mp4","a.mp3","a.zip","a.swift","unknown","a.xlsx"] { try file(name) }
        let plan = try FileOrganizerService.preview(config())
        XCTAssertEqual(plan.items.count, 8); XCTAssertEqual(Set(plan.items.map(\.category)), Set(["图片","文档","视频","音频","压缩包","代码","其他"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        for item in plan.items { XCTAssertEqual(item.destination, output.appendingPathComponent(item.category).appendingPathComponent(item.source.lastPathComponent)) }
    }
    func testNumberingAndSkippingHandleBatchAndExistingDuplicates() throws {
        try file("one/a.txt","one"); try file("two/a.txt","two")
        let existing = try file("a.txt","keep",in: output.appendingPathComponent("文档"))
        let numbered = try FileOrganizerService.preview(config())
        XCTAssertEqual(numbered.items.map { $0.destination.lastPathComponent }, ["a (1).txt","a (2).txt"])
        let result = try FileOrganizerService.execute(numbered,store: store)
        XCTAssertEqual(result.successCount,2); XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8),"keep")
        XCTAssertEqual(try String(contentsOf: result.items[0].destination, encoding: .utf8),"one")
        let skipped = try FileOrganizerService.preview(config(conflict: .skip))
        XCTAssertEqual(skipped.actionable.count,0); XCTAssertEqual(skipped.items.filter { $0.phase == .skipped }.count,2)
    }
    func testRecursiveExclusionHiddenPackagesLinksAndOverlappingRoots() throws {
        try file("top.txt"); try file("nested/a.txt"); try file("excluded/no.txt"); try file(".hidden"); try file("Fake.app/Contents/no.txt")
        try file("old.txt",in: output)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"),withDestinationURL: root)
        try FileManager.default.linkItem(at: root.appendingPathComponent("top.txt"), to: root.appendingPathComponent("hard.txt"))
        var c = config(excluded: [root.appendingPathComponent("excluded")]); c.roots.append(root.appendingPathComponent("nested"))
        let plan = try FileOrganizerService.preview(c)
        XCTAssertEqual(plan.items.count,2)
        XCTAssertTrue(plan.items.contains { $0.source.lastPathComponent == "a.txt" })
        XCTAssertFalse(plan.items.contains { $0.source.path.contains("整理结果") || $0.source.path.contains("Fake.app") })
        XCTAssertGreaterThan(plan.skippedCount,0)
        let direct = try FileOrganizerService.preview(config(recursive: false))
        XCTAssertEqual(direct.items.count,1)
    }
    func testScanLimitCannotProducePartialExecutablePlan() throws {
        for i in 0..<4 { try file("\(i).txt") }
        XCTAssertThrowsError(try FileOrganizerService.preview(config(),limit:2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testRejectsSameAncestorAndSymlinkDestination() throws {
        try file("a.txt")
        for destination in [root,directory!] {
            var c=config();c.destination=destination; XCTAssertThrowsError(try FileOrganizerService.preview(c))
        }
        let alias=directory.appendingPathComponent("alias");try FileManager.default.createSymbolicLink(at: alias,withDestinationURL: root)
        var c=config();c.destination=alias.appendingPathComponent("out"); XCTAssertThrowsError(try FileOrganizerService.preview(c))
    }
    func testCopyUndoSurvivesStoreReloadAndPreservesModifiedOriginal() throws {
        let source=try file("a.txt","original"), bytes=try Data(contentsOf: source)
        let result=try FileOrganizerService.execute(FileOrganizerService.preview(config()),store: store)
        XCTAssertEqual(result.successCount,1);XCTAssertEqual(try Data(contentsOf: source),bytes)
        XCTAssertEqual(try Data(contentsOf: result.items[0].destination),bytes)
        try Data("source edited later".utf8).write(to: source)
        let reloaded=try XCTUnwrap(store.recent().first)
        let undone=try FileOrganizerService.undo(reloaded,store: store)
        XCTAssertEqual(undone.items[0].phase,.undone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.items[0].destination.path))
        XCTAssertEqual(try String(contentsOf: source,encoding:.utf8),"source edited later")
    }
    func testMoveUndoRestoresOriginalPathAndBytes() throws {
        let source=try file("nested/a.pdf","test-pdf-bytes"), bytes=try Data(contentsOf: source)
        let result=try FileOrganizerService.execute(FileOrganizerService.preview(config(mode:.move)),store:store)
        XCTAssertEqual(result.successCount,1);XCTAssertFalse(FileManager.default.fileExists(atPath:source.path))
        XCTAssertEqual(try Data(contentsOf:result.items[0].destination),bytes)
        let undone=try FileOrganizerService.undo(try XCTUnwrap(store.recent().first),store:store)
        XCTAssertEqual(undone.items[0].phase,.undone, undone.items[0].message ?? "none");XCTAssertEqual(try Data(contentsOf:source),bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:result.items[0].destination.path))
    }
    func testEditedOutputIsNotDeletedEvenIfSizeAndDateAreRestored() throws {
        try file("a.txt","AAAA")
        let result=try FileOrganizerService.execute(FileOrganizerService.preview(config()),store:store)
        let item=result.items[0];let stamp=try XCTUnwrap(item.outputStamp)
        let handle=try FileHandle(forWritingTo:item.destination);try handle.write(contentsOf:Data("BBBB".utf8));try handle.close()
        try FileManager.default.setAttributes([.modificationDate:stamp.modified],ofItemAtPath:item.destination.path)
        let undone=try FileOrganizerService.undo(result,store:store)
        XCTAssertNotEqual(undone.items[0].phase,.undone);XCTAssertNotNil(undone.error)
        XCTAssertEqual(try String(contentsOf:item.destination,encoding:.utf8),"BBBB")
    }
    func testOccupiedOriginalPreventsUndoAndCanBeRetried() throws {
        let source=try file("a.txt","source")
        let result=try FileOrganizerService.execute(FileOrganizerService.preview(config(mode:.move)),store:store)
        try Data("new occupant".utf8).write(to:source)
        let failed=try FileOrganizerService.undo(result,store:store)
        XCTAssertNotNil(failed.error);XCTAssertEqual(try String(contentsOf:source,encoding:.utf8),"new occupant")
        XCTAssertTrue(FileManager.default.fileExists(atPath:result.items[0].destination.path))
        try FileManager.default.removeItem(at:source)
        let retry=try FileOrganizerService.undo(failed,store:store)
        XCTAssertEqual(retry.items[0].phase,.undone);XCTAssertNil(retry.error)
        XCTAssertEqual(try String(contentsOf:source,encoding:.utf8),"source")
    }
    func testSourceChangedAfterPreviewIsRetainedAndReported() throws {
        let source=try file("a.txt","before"),plan=try FileOrganizerService.preview(config(mode:.move))
        try Data("after".utf8).write(to:source)
        let result=try FileOrganizerService.execute(plan,store:store)
        XCTAssertEqual(result.failureCount,1);XCTAssertEqual(result.undoableCount,0)
        XCTAssertEqual(try String(contentsOf:source,encoding:.utf8),"after")
    }
    func testTargetOccupiedAfterPreviewDoesNotRenumberOrOverwrite() throws {
        try file("a.txt","source");let plan=try FileOrganizerService.preview(config())
        let target=plan.items[0].destination;try file(target.lastPathComponent,"occupant",in:target.deletingLastPathComponent())
        let result=try FileOrganizerService.execute(plan,store:store)
        XCTAssertEqual(result.failureCount,1);XCTAssertEqual(result.undoableCount,0)
        XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"occupant")
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.deletingLastPathComponent().appendingPathComponent("a (1).txt").path))
    }
    func testCategorySymlinkReplacementCannotWriteOutsideDestination() throws {
        try file("a.txt");let plan=try FileOrganizerService.preview(config())
        let outside=directory.appendingPathComponent("outside");try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:output.appendingPathComponent("文档"),withDestinationURL:outside)
        let result=try FileOrganizerService.execute(plan,store:store)
        XCTAssertEqual(result.failureCount,1);XCTAssertFalse(FileManager.default.fileExists(atPath:outside.appendingPathComponent("a.txt").path))
    }
    func testAnchorReplacementRejectsWholeExecution() throws {
        try file("a.txt");try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let plan=try FileOrganizerService.preview(config())
        try FileManager.default.moveItem(at:output,to:root.appendingPathComponent("former"))
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        XCTAssertThrowsError(try FileOrganizerService.execute(plan,store:store))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("a.txt").path))
    }
    func testLogFailureOccursBeforeAnyFileMutation() throws {
        try file("a.txt");let bad=try file("not-a-folder",in:directory)
        XCTAssertThrowsError(try FileOrganizerService.execute(FileOrganizerService.preview(config(mode:.move)),store:.init(directory:bad)))
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("a.txt").path))
    }
    func testCancellationBetweenFilesKeepsCompletedItemsUndoable() async throws {
        try file("a.txt");try file("b.txt")
        let plan=try FileOrganizerService.preview(config(mode:.move)),store=store
        let result=try await Task.detached {
            try FileOrganizerService.execute(plan,store:store) { _,_ in withUnsafeCurrentTask { $0?.cancel() } }
        }.value
        XCTAssertTrue(result.stopped);XCTAssertEqual(result.successCount,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("b.txt").path))
        let undone=try FileOrganizerService.undo(result,store:store)
        XCTAssertEqual(undone.items[0].phase,.undone)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("a.txt").path))
    }
    func testPreparedJournalRecoveryCleansOnlyOwnedTemporaryCopy() throws {
        let source=try file("a.txt","keep"),plan=try FileOrganizerService.preview(config(mode:.move))
        var item=plan.items[0];let temporary=item.destination.deletingLastPathComponent().appendingPathComponent(".ruit-organize-test")
        try FileManager.default.createDirectory(at:temporary.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:source,to:temporary)
        item.phase = .prepared;item.outputStamp=try OrganizerStamp.read(temporary);item.digest=try FileOrganizerService.hash(temporary);item.temporary=temporary
        let journal=OrganizerJournal(id:UUID(),date:Date(),configuration:plan.configuration,items:[item]);try store.save(journal)
        let undone=try FileOrganizerService.undo(try XCTUnwrap(store.recent().first),store:store)
        XCTAssertEqual(undone.items[0].phase,.undone);XCTAssertEqual(try String(contentsOf:source,encoding:.utf8),"keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath:temporary.path))
    }
    func testCopiedButNotRemovedMoveCanBeUndoneAfterRestart() throws {
        let source=try file("a.txt","keep"),plan=try FileOrganizerService.preview(config(mode:.move))
        var item=plan.items[0]
        try FileManager.default.createDirectory(at:item.destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:source,to:item.destination)
        item.phase = .copied;item.outputStamp=try OrganizerStamp.read(item.destination);item.digest=try FileOrganizerService.hash(item.destination)
        let journal=OrganizerJournal(id:UUID(),date:Date(),configuration:plan.configuration,items:[item]);try store.save(journal)
        let undone=try FileOrganizerService.undo(try XCTUnwrap(store.recent().first),store:store)
        XCTAssertEqual(undone.items[0].phase,.undone);XCTAssertEqual(try String(contentsOf:source,encoding:.utf8),"keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath:item.destination.path))
    }
    func testMissingOriginalFolderBlocksUndoAndRetainsRetryOwnership() throws {
        let source = try file("nested/a.txt", "keep")
        let result = try FileOrganizerService.execute(FileOrganizerService.preview(config(mode: .move)), store: store)
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        let failed = try FileOrganizerService.undo(result, store: store)
        XCTAssertEqual(failed.undoableCount, 1); XCTAssertNotNil(failed.error)
        XCTAssertEqual(try String(contentsOf: result.items[0].destination, encoding: .utf8), "keep")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let retry = try FileOrganizerService.undo(failed, store: store)
        XCTAssertEqual(retry.items[0].phase, .undone)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep")
    }
    func testCaseVariantCreatedAfterPreviewDoesNotBecomeAnotherOutput() throws {
        try file("a.txt", "source")
        let plan = try FileOrganizerService.preview(config())
        let target = plan.items[0].destination
        let occupant = try file("A.TXT", "keep", in: target.deletingLastPathComponent())
        let result = try FileOrganizerService.execute(plan, store: store)
        XCTAssertEqual(result.failureCount, 1); XCTAssertEqual(result.undoableCount, 0)
        XCTAssertEqual(try String(contentsOf: occupant, encoding: .utf8), "keep")
    }
    @MainActor private func ready(_ vm:FileOrganizerViewModel) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(20))
        while vm.busy && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertFalse(vm.busy)
    }
    @MainActor func testDeleteSelectedRecordPreservesFilesAndOtherUndoAfterRestart() async throws {
        let source = try file("a.txt", "keep")
        let first = try FileOrganizerService.execute(FileOrganizerService.preview(config()), store: store)
        let second = try FileOrganizerService.execute(FileOrganizerService.preview(config()), store: store)
        let vm = FileOrganizerViewModel(store: store)
        await vm.loadRecords(); vm.selectRecord(first.id)
        await vm.deleteRecord(first.id)
        XCTAssertEqual(vm.records.map(\.id), [second.id]); XCTAssertEqual(vm.journal?.id, second.id)
        XCTAssertNil(vm.errorMessage); XCTAssertNotNil(vm.statusMessage); XCTAssertTrue(vm.canUndo)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "keep")
        for record in [first, second] { XCTAssertEqual(try String(contentsOf: record.items[0].destination, encoding: .utf8), "keep") }
        let restarted = FileOrganizerViewModel(store: store); await restarted.loadRecords()
        XCTAssertEqual(restarted.records.map(\.id), [second.id]); XCTAssertTrue(restarted.canUndo)
        restarted.undo(); try await ready(restarted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.items[0].destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.items[0].destination.path))
    }
    @MainActor func testDeletingLastMoveRecordClearsResultWithoutRestoringOrDeletingFiles() async throws {
        let source = try file("a.txt", "keep")
        let record = try FileOrganizerService.execute(FileOrganizerService.preview(config(mode: .move)), store: store)
        let vm = FileOrganizerViewModel(store: store); await vm.loadRecords()
        await vm.deleteRecord(record.id)
        XCTAssertTrue(vm.records.isEmpty); XCTAssertNil(vm.journal); XCTAssertFalse(vm.canUndo)
        XCTAssertFalse(vm.busy); XCTAssertFalse(vm.canDeleteRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: record.items[0].destination, encoding: .utf8), "keep")
        let restarted = FileOrganizerViewModel(store: store); await restarted.loadRecords()
        XCTAssertTrue(restarted.records.isEmpty); XCTAssertNil(restarted.journal)
    }
    @MainActor func testFailedRecordDeletionKeepsSelectionAndReportsError() async throws {
        try file("a.txt", "keep")
        let record = try FileOrganizerService.execute(FileOrganizerService.preview(config()), store: store)
        let vm = FileOrganizerViewModel(store: store); await vm.loadRecords()
        // Simulate an unavailable journal directory; a failed delete must retain the visible result.
        let logDirectory = store.directory
        try FileManager.default.moveItem(at: logDirectory, to: directory.appendingPathComponent("retained-logs"))
        try Data("blocked".utf8).write(to: logDirectory)
        await vm.deleteRecord(record.id)
        XCTAssertEqual(vm.journal?.id, record.id); XCTAssertEqual(vm.records.map(\.id), [record.id])
        XCTAssertNotNil(vm.errorMessage); XCTAssertNil(vm.statusMessage); XCTAssertFalse(vm.busy)
        XCTAssertEqual(try String(contentsOf: record.items[0].destination, encoding: .utf8), "keep")
    }
    @MainActor func testDeletingVisibleRecordRefillsFromOlderPersistedRecords() async throws {
        let base = Date()
        var journals: [OrganizerJournal] = []
        for i in 0..<21 {
            let record = OrganizerJournal(id: UUID(), date: base.addingTimeInterval(Double(i)), configuration: config(), items: [])
            try store.save(record)
            try FileManager.default.setAttributes([.modificationDate: record.date], ofItemAtPath: store.directory.appendingPathComponent(record.id.uuidString + ".json").path)
            journals.append(record)
        }
        let vm = FileOrganizerViewModel(store: store); await vm.loadRecords()
        XCTAssertEqual(vm.records.count, 20); XCTAssertFalse(vm.records.contains { $0.id == journals[0].id })
        await vm.deleteRecord(journals[20].id)
        XCTAssertEqual(vm.records.count, 20); XCTAssertTrue(vm.records.contains { $0.id == journals[0].id })
        XCTAssertFalse(vm.records.contains { $0.id == journals[20].id })
    }
    @MainActor func testViewModelSettingsResultsUndoAndRestart() async throws {
        try file("a.txt","keep");let vm=FileOrganizerViewModel(store:store)
        vm.addRoots([root]);XCTAssertEqual(vm.mode,.copy);XCTAssertFalse(vm.canExecute)
        vm.preview();try await ready(vm);XCTAssertTrue(vm.canExecute)
        vm.mode = .move;XCTAssertFalse(vm.canExecute);vm.mode = .copy
        vm.execute();try await ready(vm);XCTAssertNotNil(vm.statusMessage);XCTAssertTrue(vm.canUndo);XCTAssertNil(vm.plan)
        vm.clear();XCTAssertTrue(vm.canUndo);XCTAssertNotNil(vm.journal)
        let restarted=FileOrganizerViewModel(store:store);await restarted.loadRecords();XCTAssertTrue(restarted.canUndo)
        restarted.undo();try await ready(restarted);XCTAssertFalse(restarted.canUndo)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("a.txt").path))
        XCTAssertEqual(ToolCatalog.search("文件夹 整理").map(\.item),[.fileOrganizer])
    }
}
