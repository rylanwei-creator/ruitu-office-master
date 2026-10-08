import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 文件改名 ViewModel

@Observable
final class FileRenameViewModel: @unchecked Sendable {

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
        clearMessages()
        generatePreview()
    }

    // MARK: 管理已选文件

    func removeFile(url: URL) {
        guard !isProcessing else { return }
        guard let index = selectedFiles.firstIndex(of: url) else { return }
        selectedFiles.remove(at: index)
        clearMessages()
        generatePreview()
    }

    func moveFiles(from source: IndexSet, to destination: Int) {
        guard !isProcessing else { return }
        selectedFiles.move(fromOffsets: source, toOffset: destination)
        clearMessages()
        generatePreview()
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
        guard canExecute, !previewItems.isEmpty else { return }

        isProcessing = true
        progress = 0
        clearMessages()

        let items = previewItems

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let result = self.service.execute(previewItems: items) { prog in
                DispatchQueue.main.async { [weak self] in
                    self?.progress = prog
                    let idx = Int(prog * Double(items.count))
                    if idx < items.count {
                        self?.currentFileName = items[idx].originalName
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                switch result {
                case .success(let moves):
                    let count = moves.count
                    self.lastMoves = moves
                    self.successMessage = "成功改名 \(count) 个文件"
                    self.selectedFiles = []
                    self.previewItems = []
                    HistoryService().addRecord(
                        toolName: "文件改名",
                        operationType: self.renameMode.rawValue,
                        fileCount: count,
                        inputFileNames: items.map(\.originalName),
                        status: "成功",
                        inputSize: 0,
                        outputSize: 0,
                        descriptionText: "成功改名 \(count) 个文件"
                    )
                case .failure(let errors):
                    self.errorMessage = errors.joined(separator: "\n")
                }
            }
        }
    }

    @MainActor
    func undoRename() {
        guard canUndo else { return }
        let moves = lastMoves
        isProcessing = true
        Task {
            let result = await Task.detached { FileRenameService().undo(moves) }.value
            isProcessing = false
            switch result {
            case .success:
                lastMoves = []
                successMessage = "已恢复上次改名的原文件名"
                errorMessage = nil
            case .failure(let errors): errorMessage = errors.joined(separator: "\n")
            }
        }
    }

    // MARK: 辅助

    private func clearMessages() {
        successMessage = nil
        errorMessage = nil
    }
}
