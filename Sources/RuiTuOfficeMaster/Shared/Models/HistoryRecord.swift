import SwiftData
import Foundation

/// 历史记录 — SwiftData 持久化模型
@Model
final class HistoryRecord {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var toolName: String
    var operationType: String
    var fileCount: Int
    /// JSON 编码的文件名数组（SwiftData 不直接支持 [String]）
    var inputFileNamesData: Data
    var status: String
    var inputSize: Int64
    var outputSize: Int64
    var descriptionText: String

    /// 解码后的文件名数组
    @Transient
    var inputFileNames: [String] {
        get { (try? JSONDecoder().decode([String].self, from: inputFileNamesData)) ?? [] }
        set { inputFileNamesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(toolName: String, operationType: String, fileCount: Int,
         inputFileNames: [String], status: String, inputSize: Int64,
         outputSize: Int64, descriptionText: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.toolName = toolName
        self.operationType = operationType
        self.fileCount = fileCount
        self.inputFileNamesData = (try? JSONEncoder().encode(inputFileNames)) ?? Data()
        self.status = status
        self.inputSize = inputSize
        self.outputSize = outputSize
        self.descriptionText = descriptionText
    }
}
