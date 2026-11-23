import Foundation
import Combine

public struct WorkspaceSkill: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var slug: String
    public var category: String
    public var description: String
    public var instructionsPrompt: String
    public var triggerKeywords: [String]
    public var isEnabled: Bool
    public let isBuiltIn: Bool
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        slug: String,
        category: String,
        description: String,
        instructionsPrompt: String,
        triggerKeywords: [String],
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.category = category
        self.description = description
        self.instructionsPrompt = instructionsPrompt
        self.triggerKeywords = triggerKeywords
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.updatedAt = updatedAt
    }
}

/// Manages built-in and user-created AI Skills available to both Offline (llama.cpp) and Online AI models.
@MainActor
public final class SkillRegistryService: ObservableObject {
    @Published public private(set) var skills: [WorkspaceSkill] = []

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
        seedBuiltInSkillsIfNeeded()
        reload()
    }

    public func reload() {
        do {
            let rows = try database.sqlite.query("SELECT * FROM workspace_skills ORDER BY is_builtin DESC, name ASC;")
            self.skills = rows.compactMap { row in
                guard let id = row.string("id"),
                      let name = row.string("name"),
                      let slug = row.string("slug"),
                      let cat = row.string("category"),
                      let desc = row.string("description"),
                      let prompt = row.string("instructions_prompt"),
                      let keywordsRaw = row.string("trigger_keywords"),
                      let updated = row.date("updated_at") else { return nil }
                let keywords = keywordsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return WorkspaceSkill(
                    id: id,
                    name: name,
                    slug: slug,
                    category: cat,
                    description: desc,
                    instructionsPrompt: prompt,
                    triggerKeywords: keywords,
                    isEnabled: row.bool("is_enabled"),
                    isBuiltIn: row.bool("is_builtin"),
                    updatedAt: updated
                )
            }
        } catch {
            AppLogger.shared.error("Skills", "Failed to load skills: \(error.localizedDescription)")
        }
    }

    public func saveSkill(_ skill: WorkspaceSkill) throws {
        let keywordsStr = skill.triggerKeywords.joined(separator: ", ")
        try database.sqlite.execute(
            """
            INSERT INTO workspace_skills (
                id, name, slug, category, description, instructions_prompt,
                trigger_keywords, is_enabled, is_builtin, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                slug = excluded.slug,
                category = excluded.category,
                description = excluded.description,
                instructions_prompt = excluded.instructions_prompt,
                trigger_keywords = excluded.trigger_keywords,
                is_enabled = excluded.is_enabled,
                updated_at = excluded.updated_at;
            """,
            bindings: [
                .text(skill.id),
                .text(skill.name),
                .text(skill.slug),
                .text(skill.category),
                .text(skill.description),
                .text(skill.instructionsPrompt),
                .text(keywordsStr),
                .integer(skill.isEnabled ? 1 : 0),
                .integer(skill.isBuiltIn ? 1 : 0),
                .real(Date().timeIntervalSince1970)
            ]
        )
        reload()
    }

    public func toggleSkill(_ skill: WorkspaceSkill) throws {
        var updated = skill
        updated.isEnabled.toggle()
        try saveSkill(updated)
    }

    public func deleteSkill(_ skill: WorkspaceSkill) throws {
        try database.sqlite.execute("DELETE FROM workspace_skills WHERE id = ?;", bindings: [.text(skill.id)])
        reload()
    }

    /// Imports a Markdown skill file (`SKILL.md`) from the user's mounted folder.
    @discardableResult
    public func importSkillMarkdown(from url: URL) throws -> WorkspaceSkill {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let content = try String(contentsOf: url, encoding: .utf8)
        let title = url.deletingPathExtension().lastPathComponent
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        let skill = WorkspaceSkill(
            name: title,
            slug: slug,
            category: "Imported",
            description: "Imported from \(url.lastPathComponent)",
            instructionsPrompt: String(content.prefix(12_000)),
            triggerKeywords: [slug],
            isEnabled: true,
            isBuiltIn: false
        )
        try saveSkill(skill)
        return skill
    }

    /// Returns active skills instructions relevant to the current user query for both Offline and Online AI.
    public func activeSkillsPromptBlock(for userQuery: String) -> String {
        let enabled = skills.filter(\.isEnabled)
        guard !enabled.isEmpty else { return "" }
        let lowerQuery = userQuery.lowercased()

        // Always include skills whose trigger keywords match the user query, plus a compact summary of all enabled skills.
        var matched: [WorkspaceSkill] = []
        var others: [WorkspaceSkill] = []

        for skill in enabled {
            if skill.triggerKeywords.contains(where: { lowerQuery.contains($0.lowercased()) }) {
                matched.append(skill)
            } else {
                others.append(skill)
            }
        }

        var lines: [String] = ["### Active Workspace Skills"]
        for s in matched {
            lines.append("#### Skill: \(s.name) (`\(s.slug)`)")
            lines.append(s.instructionsPrompt)
        }
        if !others.isEmpty {
            lines.append("Available enabled skills: " + others.map { "\($0.name) (\($0.description))" }.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    private func seedBuiltInSkillsIfNeeded() {
        let existingCount = (try? database.sqlite.query("SELECT COUNT(*) AS c FROM workspace_skills;").first?.int("c")) ?? 0
        guard existingCount == 0 else { return }

        let defaults: [WorkspaceSkill] = [
            WorkspaceSkill(
                id: "builtin-web-game-builder",
                name: "HTML5 Web App & Game Builder",
                slug: "web-game-builder",
                category: "Web & Browser",
                description: "Builds interactive HTML5/Canvas/JS games (like Snake) in the user's folder, starts the local HTTP server, opens the Custom Browser, and inspects via RAM-only screenshot.",
                instructionsPrompt: """
                When asked to build a web app, HTML page, or game (e.g. Snake, Pong, Breakout, dashboard):
                1. Use `generate_file` to write a complete, self-contained HTML5 file (with embedded CSS, Canvas, keyboard & iPad touch/on-screen D-pad controls, score counter, and restart button) inside the user's active mounted folder.
                2. Immediately call `open_in_browser` with the `relative_path` (e.g. `snake.html`) — this automatically starts ZinoAgent's Local HTTP Server on the user's folder and loads `http://127.0.0.1:8080/<filename>` in the built-in Browser.
                3. Optionally call `capture_browser_screenshot` to inspect the live rendered page and verify there are no console errors (screenshots stay strictly in RAM and are never saved to the device).
                """,
                triggerKeywords: ["snake", "game", "html", "website", "web", "browser", "server", "canvas", "app", "play"],
                isEnabled: true,
                isBuiltIn: true
            ),
            WorkspaceSkill(
                id: "builtin-folder-organizer",
                name: "Smart Folder Architect",
                slug: "folder-organizer",
                category: "Files",
                description: "Audits, reads, summarizes, and organizes files inside the user's selected Apple Files folder.",
                instructionsPrompt: """
                When working with the user's folder:
                1. Use `list_files` or `search_files` to inspect the active mounted folder.
                2. Use `read_supported_document` to read PDFs, DOCX, Markdown, JSON, CSV, or code files.
                3. Use `create_folder`, `move_file`, `copy_file`, `rename_file`, or `generate_file` within the permitted folder scope.
                """,
                triggerKeywords: ["folder", "file", "organize", "directory", "document", "read", "summarize", "rename", "clean"],
                isEnabled: true,
                isBuiltIn: true
            ),
            WorkspaceSkill(
                id: "builtin-github-workflow",
                name: "GitHub Repository Engineer",
                slug: "github-workflow",
                category: "Plugin",
                description: "Interacts with GitHub repositories, reads remote code, commits local folder files to GitHub, and manages issues.",
                instructionsPrompt: """
                When the user asks about GitHub repositories, commits, or issues:
                Use `github_plugin` with action `whoami`, `list_repos`, `list_files`, `read_file`, `push_local_file`, `list_issues`, or `create_issue`.
                You can push any file from the user's mounted folder directly to a GitHub repository with `push_local_file`.
                """,
                triggerKeywords: ["github", "repo", "repository", "commit", "push", "issue", "pull", "git", "gh"],
                isEnabled: true,
                isBuiltIn: true
            ),
            WorkspaceSkill(
                id: "builtin-cloudflare-devops",
                name: "Cloudflare Edge & Workers Engineer",
                slug: "cloudflare-devops",
                category: "Plugin",
                description: "Manages Cloudflare Zones, DNS records, Workers scripts, Pages projects, and D1 databases.",
                instructionsPrompt: """
                When the user asks about Cloudflare DNS, domains, Workers, Pages, or D1:
                Use `cloudflare_plugin` with action `verify`, `list_zones`, `list_dns`, `create_dns`, `list_workers`, `deploy_worker`, `list_pages`, or `list_d1`.
                You can deploy a JavaScript Worker file from the user's mounted folder directly to Cloudflare Workers using `deploy_worker`.
                """,
                triggerKeywords: ["cloudflare", "worker", "workers", "dns", "zone", "domain", "pages", "d1", "kv", "cf"],
                isEnabled: true,
                isBuiltIn: true
            ),
            WorkspaceSkill(
                id: "builtin-terminal-operator",
                name: "Workspace Terminal & JS Runtime",
                slug: "terminal-operator",
                category: "Development",
                description: "Executes workspace shell commands, JavaScript scripts, local server commands, and file pipelines.",
                instructionsPrompt: """
                Use `run_terminal_command` to run workspace commands such as `ls`, `cat`, `grep`, `find`, `tree`, `js <expression>`, `serve`, `open <file.html>`, `gh ...`, or `cf ...`.
                """,
                triggerKeywords: ["terminal", "command", "shell", "run", "script", "node", "js", "execute"],
                isEnabled: true,
                isBuiltIn: true
            )
        ]

        for skill in defaults {
            try? saveSkill(skill)
        }
    }
}
