import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 文件改名 ViewModel

@MainActor
@Observable
final class FileRenameViewModel {

    // MARK: 文件选择
    var selectedFiles: [URL] = []

    // MARK: 改名模式与参数
    var renameMode: RenameMode = .prefix
    var prefixText = ""
    var suffixText = ""
    var findText = ""
    var replaceText = ""
    var numberText = "文件"
    var startNumber = 1
    var numberDigits = 3

    // MARK: 预览
    var previewItems: [RenamePreviewItem] = []

    // MARK: 处理状态
    var isProcessing = false { didSet { ProcessingActivity.setActive(isProcessing, owner: ObjectIdentifier(self)) } }
    var progress: Double = 0
    var currentFileName = ""

    // MARK: 结果
    var successMessage: String?
    var errorMessage: String?

    private var lastMoves: [RenameMove] = []
    private(set) var completedMoves: [RenameMove] = []
    private(set) var didUndo = false
    private(set) var isUndoing = false
    var hasOperationFeedback: Bool {
        isProcessing || successMessage != nil || errorMessage != nil || !completedMoves.isEmpty
    }
    var canUndo: Bool { !isProcessing && !lastMoves.isEmpty }

    private let service = FileRenameService()

    // MARK: 计算属性

    /// 文件总数字符串
    var fileCountText: String {
        "已选择 \(selectedFiles.count) 个文件"
    }

    /// 是否可以执行改名
    var canExecute: Bool {
        guard !selectedFiles.isEmpty, !isProcessing, !hasConflicts, previewItems.contains(where: { $0.isValid }) else { return false }
        switch renameMode {
        case .prefix:
            return !prefixText.isEmpty
        case .suffix:
            return !suffixText.isEmpty
        case .replace:
            return !findText.isEmpty
        case .numbering:
            return !numberText.isEmpty
        }
    }

    /// 是否有预览结果
    var hasPreview: Bool {
        !previewItems.isEmpty
    }

    /// 有冲突的预览项数量
    var conflictCount: Int {
        previewItems.filter { $0.conflictReason != nil }.count
    }

    /// 是否有任何冲突
    var hasConflicts: Bool {
        conflictCount > 0
    }

    // MARK: 文件选择

#if os(macOS)
    @MainActor
    func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.item]  // 允许任意文件

        if panel.runModal() == .OK {
            addFiles(from: panel.urls)
        }
    }
#endif


    // MARK: 拖拽添加文件

    func addFiles(from urls: [URL]) {
        guard !isProcessing else { return }
        let newURLs = urls.filter { url in
            url.isFileURL && !selectedFiles.contains(url)
        }
        selectedFiles.append(contentsOf: newURLs)
        generatePreview()
    }

    // MARK: 管理已选文件

    func removeFile(url: URL) {
        guard !isProcessing else { return }
        guard let index = selectedFiles.firstIndex(of: url) else { return }
        selectedFiles.remove(at: index)
        generatePreview()
    }

    func moveFiles(from source: IndexSet, to destination: Int) {
        guard !isProcessing else { return }
        selectedFiles.move(fromOffsets: source, toOffset: destination)
        generatePreview()
    }

    /// 清空待处理文件不应丢失上一批结果、撤销记录或改名参数。
    func clearFiles() {
        guard !isProcessing else { return }
        selectedFiles = []
        previewItems = []
    }

    // MARK: 预览

    func generatePreview() {
        guard !selectedFiles.isEmpty else {
            previewItems = []
            return
        }

        previewItems = service.generatePreview(
            files: selectedFiles,
            mode: renameMode,
            prefix: prefixText,
            suffix: suffixText,
            findText: findText,
            replaceText: replaceText,
            numberText: numberText,
            startNumber: startNumber,
            numberDigits: numberDigits
        )
    }

    // MARK: 执行改名

    func executeRename() {
        guard canExecute else { return }
        isProcessing = true
        progress = 0
        clearMessages()

        let items = previewItems
        let validItems = items.filter(\.isValid)
        let mode = renameMode
        currentFileName = validItems.first?.originalName ?? ""
        Task {
            let result = await Task.detached(priority: .userInitiated) { [self] in
                FileRenameService().execute(previewItems: items) { value in
                    Task { @MainActor [weak self] in
                        guard let self, self.isProcessing, !self.isUndoing else { return }
                        self.progress = value
                        let index = max(0, min(validItems.count - 1, Int(value * Double(validItems.count)) - 1))
                        self.currentFileName = validItems[index].originalName
                    }
                }
            }.value
            isProcessing = false
            currentFileName = ""
            switch result {
            case .success(let moves):
                progress = 1
                lastMoves = moves
                completedMoves = moves
                didUndo = false
                let skipped = items.count - moves.count
                successMessage = "成功改名 \(moves.count) 个文件" + (skipped > 0 ? "，\(skipped) 个文件名未变化，已跳过" : "")
                selectedFiles = []
                previewItems = []
                HistoryService().addRecord(
                    toolName: "文件改名", operationType: mode.rawValue, fileCount: moves.count,
                    inputFileNames: moves.map { $0.original.lastPathComponent }, status: "成功",
                    inputSize: 0, outputSize: 0, descriptionText: successMessage ?? ""
                )
            case .failure(let errors):
                errorMessage = "改名失败：\n" + errors.joined(separator: "\n")
            }
        }
    }

    func undoRename() {
        guard canUndo else { return }
        let moves = lastMoves
        isProcessing = true
        isUndoing = true
        clearMessages()
        Task {
            let result = await Task.detached(priority: .userInitiated) { FileRenameService().undo(moves) }.value
            isProcessing = false
            isUndoing = false
            switch result {
            case .success:
                lastMoves = []
                didUndo = true
                successMessage = "撤销成功，已恢复 \(moves.count) 个文件的原文件名"
                // 若用户已重新选中了改名后的文件，撤销后更新选择路径。
                selectedFiles = selectedFiles.map { url in moves.first { $0.renamed == url }?.original ?? url }
                generatePreview()
            case .failure(let errors):
                errorMessage = "撤销失败：\n" + errors.joined(separator: "\n")
            }
        }
    }

    // MARK: 辅助

    private func clearMessages() {
        successMessage = nil
        errorMessage = nil
    }
}
