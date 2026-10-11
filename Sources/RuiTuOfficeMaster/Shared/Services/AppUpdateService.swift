import Foundation

enum AppLinks {
    static let website = URL(string: "https://rylanwei-creator.github.io/ruitu-office-master/")!
    static let releases = URL(string: "https://github.com/rylanwei-creator/ruitu-office-master/releases/latest")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/rylanwei-creator/ruitu-office-master/releases/latest")!
}

struct ReleaseVersion: Comparable, Sendable {
    let components: [UInt64]
    init?(_ value: String) {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } }) else { return nil }
        }
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        var result: [UInt64] = []
        for number in numbers {
            guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }),
                  number.count == 1 || !number.hasPrefix("0"), let parsed = UInt64(number) else { return nil }
            result.append(parsed)
        }
        components = result
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}

enum UpdateRelation: Sendable, Equatable { case updateAvailable, current, localNewer }
struct UpdateCheckResult: Sendable {
    let latestVersion: String
    let relation: UpdateRelation
}
enum AppUpdateError: LocalizedError {
    case invalidCurrentVersion, invalidRelease, noRelease, rateLimited, server(Int)
    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion: return "当前应用缺少有效版本号，无法比较。请查看发布页。"
        case .invalidRelease: return "发布信息格式异常，暂时无法判断是否有更新。请查看发布页。"
        case .noRelease: return "暂未查到正式发布版本，请查看发布页。"
        case .rateLimited: return "GitHub 请求受限，请稍后重试，或直接查看发布页。"
        case .server(let code): return "更新服务返回错误（\(code)），请稍后重试。"
        }
    }
}

struct AppUpdateService: Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let fetch: Fetch
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
    init(fetch: @escaping Fetch = { try await AppUpdateService.session.data(for: $0) }) { self.fetch = fetch }
    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", draft, prerelease }
    }
    func check(currentVersion: String) async throws -> UpdateCheckResult {
        guard let installed = ReleaseVersion(currentVersion) else { throw AppUpdateError.invalidCurrentVersion }
        var request = URLRequest(url: AppLinks.latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("RuiTuOfficeMaster/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw AppUpdateError.invalidRelease }
        switch http.statusCode {
        case 200: break
        case 404: throw AppUpdateError.noRelease
        case 403, 429: throw AppUpdateError.rateLimited
        default: throw AppUpdateError.server(http.statusCode)
        }
        guard data.count <= 1_048_576, let release = try? JSONDecoder().decode(Release.self, from: data),
              !release.draft, !release.prerelease, let latest = ReleaseVersion(release.tagName) else { throw AppUpdateError.invalidRelease }
        let relation: UpdateRelation = latest > installed ? .updateAvailable : latest == installed ? .current : .localNewer
        let version = latest.components.map(String.init).joined(separator: ".")
        return UpdateCheckResult(latestVersion: version, relation: relation)
    }
}
