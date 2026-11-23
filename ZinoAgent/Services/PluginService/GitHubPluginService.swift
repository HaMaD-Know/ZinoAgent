import Foundation
import Combine

public struct GitHubRepoSummary: Identifiable, Codable, Sendable, Equatable {
    public let id: Int
    public let fullName: String
    public let description: String?
    public let isPrivate: Bool
    public let defaultBranch: String
    public let htmlURL: String
    public let updatedAt: String
}

public struct GitHubFileEntry: Identifiable, Codable, Sendable, Equatable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let type: String // "file" or "dir"
    public let size: Int
    public let sha: String
}

public struct GitHubIssueSummary: Identifiable, Codable, Sendable, Equatable {
    public let id: Int
    public let number: Int
    public let title: String
    public let state: String
    public let htmlURL: String
}

/// Official GitHub REST API v3 plugin (`https://api.github.com`).
/// Personal Access Token is stored solely in the iOS Keychain (`plugin.github.token`).
@MainActor
public final class GitHubPluginService: ObservableObject {
    public static let keychainAccount = "plugin.github.token"

    @Published public private(set) var connectedUsername: String?
    @Published public private(set) var repositories: [GitHubRepoSummary] = []
    @Published public var defaultRepository: String = ""

    private let keychain: KeychainStoring
    private let http: HTTPClient
    private let database: AppDatabase

    public init(database: AppDatabase, keychain: KeychainStoring, http: HTTPClient = HTTPClient()) {
        self.database = database
        self.keychain = keychain
        self.http = http
        self.defaultRepository = (try? database.getSetting(key: "plugin.github.defaultRepo")) ?? ""
        self.connectedUsername = try? database.getSetting(key: "plugin.github.username")
    }

    public var hasToken: Bool {
        keychain.hasSecret(forAccount: Self.keychainAccount)
    }

    public var maskedToken: String? {
        keychain.maskedHint(forAccount: Self.keychainAccount)
    }

    public func saveToken(_ token: String, defaultRepo: String? = nil) throws {
        try keychain.setSecret(token, forAccount: Self.keychainAccount)
        if let defaultRepo {
            self.defaultRepository = defaultRepo.trimmingCharacters(in: .whitespacesAndNewlines)
            try? database.setSetting(key: "plugin.github.defaultRepo", value: self.defaultRepository)
        }
    }

    public func disconnect() throws {
        try keychain.deleteSecret(forAccount: Self.keychainAccount)
        connectedUsername = nil
        repositories = []
        try? database.setSetting(key: "plugin.github.username", value: "")
    }

    public func verifyAndFetchUser() async throws -> String {
        let data = try await request(path: "/user")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String else {
            throw ZinoError(.networkFailure, "Unexpected response from GitHub /user.")
        }
        connectedUsername = login
        try? database.setSetting(key: "plugin.github.username", value: login)
        return login
    }

    @discardableResult
    public func listRepositories() async throws -> [GitHubRepoSummary] {
        let data = try await request(path: "/user/repos?sort=updated&per_page=30")
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ZinoError(.networkFailure, "Unexpected response from GitHub /user/repos.")
        }
        let parsed = arr.compactMap { item -> GitHubRepoSummary? in
            guard let id = item["id"] as? Int,
                  let fullName = item["full_name"] as? String else { return nil }
            return GitHubRepoSummary(
                id: id,
                fullName: fullName,
                description: item["description"] as? String,
                isPrivate: (item["private"] as? Bool) ?? false,
                defaultBranch: (item["default_branch"] as? String) ?? "main",
                htmlURL: (item["html_url"] as? String) ?? "https://github.com/\(fullName)",
                updatedAt: (item["updated_at"] as? String) ?? ""
            )
        }
        repositories = parsed
        if defaultRepository.isEmpty, let first = parsed.first {
            defaultRepository = first.fullName
            try? database.setSetting(key: "plugin.github.defaultRepo", value: first.fullName)
        }
        return parsed
    }

    public func listFiles(repoFullName: String, path: String = "") async throws -> [GitHubFileEntry] {
        let cleanRepo = try validateRepo(repoFullName)
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let endpoint = cleanPath.isEmpty ? "/repos/\(cleanRepo)/contents" : "/repos/\(cleanRepo)/contents/\(cleanPath)"
        let data = try await request(path: endpoint)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ZinoError(.networkFailure, "GitHub path '\(cleanPath)' is not a directory or returned invalid JSON.")
        }
        return arr.compactMap { item in
            guard let name = item["name"] as? String,
                  let p = item["path"] as? String,
                  let type = item["type"] as? String,
                  let sha = item["sha"] as? String else { return nil }
            return GitHubFileEntry(
                name: name,
                path: p,
                type: type,
                size: (item["size"] as? Int) ?? 0,
                sha: sha
            )
        }
    }

    public func readFileContent(repoFullName: String, path: String) async throws -> String {
        let cleanRepo = try validateRepo(repoFullName)
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let data = try await request(path: "/repos/\(cleanRepo)/contents/\(cleanPath)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = (json["content"] as? String)?.replacingOccurrences(of: "\n", with: ""),
              let decoded = Data(base64Encoded: b64),
              let text = String(data: decoded, encoding: .utf8) else {
            throw ZinoError(.networkFailure, "Could not decode file '\(cleanPath)' from GitHub repository '\(cleanRepo)'.")
        }
        return text
    }

    /// Commits and pushes a file (from the user's mounted folder or generated text) directly to a GitHub repository.
    public func pushFile(
        repoFullName: String,
        remotePath: String,
        contentData: Data,
        commitMessage: String,
        branch: String? = nil
    ) async throws -> String {
        let cleanRepo = try validateRepo(repoFullName)
        let cleanPath = remotePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let endpoint = "/repos/\(cleanRepo)/contents/\(cleanPath)"

        // Check if file already exists to include its current `sha` for update.
        var existingSHA: String?
        if let existingData = try? await request(path: endpoint),
           let existingJSON = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            existingSHA = existingJSON["sha"] as? String
        }

        var body: [String: Any] = [
            "message": commitMessage,
            "content": contentData.base64EncodedString()
        ]
        if let sha = existingSHA {
            body["sha"] = sha
        }
        if let branch, !branch.isEmpty {
            body["branch"] = branch
        }

        let respData = try await request(path: endpoint, method: "PUT", jsonBody: body)
        if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let commit = json["commit"] as? [String: Any],
           let sha = commit["sha"] as? String {
            return "Committed '\(cleanPath)' to \(cleanRepo) (commit \(sha.prefix(7)))."
        }
        return "Committed '\(cleanPath)' to \(cleanRepo)."
    }

    public func listIssues(repoFullName: String) async throws -> [GitHubIssueSummary] {
        let cleanRepo = try validateRepo(repoFullName)
        let data = try await request(path: "/repos/\(cleanRepo)/issues?state=open&per_page=20")
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { item in
            guard let id = item["id"] as? Int,
                  let number = item["number"] as? Int,
                  let title = item["title"] as? String else { return nil }
            return GitHubIssueSummary(
                id: id,
                number: number,
                title: title,
                state: (item["state"] as? String) ?? "open",
                htmlURL: (item["html_url"] as? String) ?? ""
            )
        }
    }

    public func createIssue(repoFullName: String, title: String, body: String) async throws -> String {
        let cleanRepo = try validateRepo(repoFullName)
        let respData = try await request(
            path: "/repos/\(cleanRepo)/issues",
            method: "POST",
            jsonBody: ["title": title, "body": body]
        )
        if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let num = json["number"] as? Int,
           let url = json["html_url"] as? String {
            return "Created GitHub issue #\(num): \(url)"
        }
        return "Created GitHub issue in \(cleanRepo)."
    }

    // MARK: - Internal HTTP Helper

    private func validateRepo(_ input: String) throws -> String {
        let candidate = input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultRepository : input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.contains("/") else {
            throw ZinoError(.invalidArgument, "Specify a GitHub repository in 'owner/repo' format (e.g. HaMaD-Know/ZinoAgent).")
        }
        return candidate
    }

    private func request(path: String, method: String = "GET", jsonBody: [String: Any]? = nil) async throws -> Data {
        guard let token = keychain.getSecret(forAccount: Self.keychainAccount), !token.isEmpty else {
            throw ZinoError(.authenticationFailure, "GitHub plugin is not connected. Add your GitHub Personal Access Token in Skills & Plugins > GitHub.")
        }
        guard let url = URL(string: "https://api.github.com\(path)") else {
            throw ZinoError(.invalidArgument, "Invalid GitHub API path: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("ZinoAgent/2.0", forHTTPHeaderField: "User-Agent")
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let resp = try await http.data(for: req)
        guard (200...299).contains(resp.statusCode) else {
            let detail = String(data: resp.data, encoding: .utf8)?.prefix(300) ?? ""
            let code: ZinoError.Code = (resp.statusCode == 401 || resp.statusCode == 403) ? .authenticationFailure : .networkFailure
            throw ZinoError(code, "GitHub API HTTP \(resp.statusCode): \(detail)")
        }
        return resp.data
    }
}
