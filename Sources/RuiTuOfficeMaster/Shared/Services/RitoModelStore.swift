import Foundation
import CryptoKit

struct RitoModelManifest: Decodable, Sendable {
    struct Entry: Decodable, Sendable { let name: String; let bytes: Int64; let sha256: String }
    let repository: String
    let revision: String
    let files: [Entry]
    let totalBytes: Int64
    static func bundled() throws -> Self {
        guard let url = AppResources.bundle.url(forResource: "RitoModelManifest", withExtension: "json") else { throw RitoModelError.manifest }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard manifest.repository == "Qwen/Qwen3-1.7B-MLX-4bit", manifest.revision.count == 40,
              !manifest.files.isEmpty, manifest.files.allSatisfy({ !$0.name.contains("/") && $0.name != "." && $0.name != ".." && $0.bytes > 0 && $0.sha256.count == 64 }) else { throw RitoModelError.manifest }
        return manifest
    }
}
enum RitoModelError: LocalizedError {
    case manifest, missing, corrupt(String), download, busy, inputLimit, empty
    var errorDescription: String? {
        switch self {
        case .manifest: "模型校验清单不可用，请重新安装应用"
        case .missing: "本地模型尚未安装，请在 AI 设置中下载或导入模型；普通工具仍可使用"
        case .corrupt(let name): "模型文件校验失败：\(name)。请重新下载，不会加载损坏的模型"
        case .download: "模型下载失败，请检查网络后重试。已完成且通过校验的文件会保留"
        case .busy: "本地模型正在处理其他请求，请先停止生成"
        case .inputLimit: "本地模型上下文过长，请缩短消息或新建对话"
        case .empty: "模型未生成可显示的回答，请重试"
        }
    }
}
struct RitoModelStore: Sendable {
    let directory: URL
    static var standard: Self {
        .init(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RuiTuOfficeMaster/AIModels/Qwen3-1.7B-4bit"))
    }
    func verify(_ manifest: RitoModelManifest) throws {
        for entry in manifest.files { try Task.checkCancellation(); try verify(entry) }
    }
    func verify(_ entry: RitoModelManifest.Entry) throws {
        let url = directory.appendingPathComponent(entry.name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RitoModelError.missing }
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true, let size = values.fileSize, Int64(size) == entry.bytes else { throw RitoModelError.corrupt(entry.name) }
        guard try Self.hash(url) == entry.sha256 else { throw RitoModelError.corrupt(entry.name) }
    }
    static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func prepare() throws {
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else { throw RitoModelError.corrupt("模型目录包含符号链接") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func importFiles(from source: URL, manifest: RitoModelManifest) throws {
        try RitoModelStore(directory: source).verify(manifest); try prepare()
        for entry in manifest.files {
            try Task.checkCancellation()
            if (try? verify(entry)) != nil { continue }
            let destination = directory.appendingPathComponent(entry.name)
            let stage = directory.appendingPathComponent(".import-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            try FileManager.default.copyItem(at: source.appendingPathComponent(entry.name), to: stage)
            guard try Self.hash(stage) == entry.sha256 else { throw RitoModelError.corrupt(entry.name) }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: stage, to: destination)
        }
        try verify(manifest)
    }
}
