//
//  iTermAgentSessionStore.swift
//  iTerm2
//
//  Finds recent GitHub Copilot CLI and Claude Code sessions on disk so they can
//  be listed in the left tab bar and resumed in a new tab.
//

import Foundation

@objc(iTermAgentSession)
final class iTermAgentSession: NSObject {
    enum Kind {
        case copilot
        case claude
    }

    let kind: Kind
    let sessionID: String
    let title: String
    let workingDirectory: String?
    let lastActive: Date
    // The repository containing the working directory, or the working directory
    // itself when it isn't in one. Sessions are grouped by this.
    let projectRoot: String?

    init(kind: Kind,
         sessionID: String,
         title: String,
         workingDirectory: String?,
         lastActive: Date,
         projectRoot: String? = nil) {
        self.kind = kind
        self.sessionID = sessionID
        self.title = title
        self.workingDirectory = workingDirectory
        self.lastActive = lastActive
        self.projectRoot = projectRoot ?? workingDirectory.flatMap { Self.repositoryRoot(containing: $0) } ?? workingDirectory
    }

    // The nearest folder at or above `path` that has a .git entry.
    static func repositoryRoot(containing path: String) -> String? {
        var current = (path as NSString).standardizingPath
        let home = NSHomeDirectory()
        while current != "/" && !current.isEmpty && current != home {
            let git = (current as NSString).appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: git) {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    var agentName: String {
        switch kind {
        case .copilot: return "Copilot"
        case .claude: return "Claude"
        }
    }

    // The ID is validated to be a UUID-like token when loaded, so this is safe
    // to type into a shell.
    @objc var resumeCommand: String {
        switch kind {
        case .copilot: return "copilot --yolo --experimental --resume \(sessionID)"
        case .claude: return "claude --resume \(sessionID)"
        }
    }

    // The folder the session ran in, if it still exists.
    @objc var directoryForNewTab: String? {
        guard let workingDirectory else {
            return nil
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return workingDirectory
    }
}

@objc(iTermAgentSessionStore)
final class iTermAgentSessionStore: NSObject {
    @objc static let shared = iTermAgentSessionStore()
    static let didUpdateNotification = Notification.Name("iTermAgentSessionStoreDidUpdate")

    private static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    private(set) var sessions: [iTermAgentSession] = []
    private let queue = DispatchQueue(label: "com.iterm2.agent-session-store", qos: .utility)
    private var scanInProgress = false
    private var scanRequestedDuringScan = false
    private var lastScan: Date?

    // Parsed results keyed by file path, reused while the file's modification
    // date is unchanged. Only touched on `queue`.
    private struct CacheEntry {
        var modificationDate: Date
        var session: iTermAgentSession?
    }
    private var cache = [String: CacheEntry]()

    // Rescans unless a scan finished within `minimumInterval` seconds.
    @objc func refresh(minimumInterval: TimeInterval = 0) {
        it_assert(Thread.isMainThread)
        if let lastScan, Date().timeIntervalSince(lastScan) < minimumInterval {
            return
        }
        if scanInProgress {
            scanRequestedDuringScan = true
            return
        }
        scanInProgress = true
        queue.async { [weak self] in
            guard let self else {
                return
            }
            let result = self.scan()
            DispatchQueue.main.async {
                self.sessions = result
                self.lastScan = Date()
                self.scanInProgress = false
                NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
                if self.scanRequestedDuringScan {
                    self.scanRequestedDuringScan = false
                    self.refresh()
                }
            }
        }
    }

    private func scan() -> [iTermAgentSession] {
        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        var seenPaths = Set<String>()
        var result = copilotSessions(after: cutoff, seenPaths: &seenPaths)
        result += claudeSessions(after: cutoff, seenPaths: &seenPaths)
        cache = cache.filter { seenPaths.contains($0.key) }
        result.sort { $0.lastActive > $1.lastActive }
        DLog("Found \(result.count) agent sessions")
        return result
    }

    fileprivate static func isValidSessionID(_ string: String) -> Bool {
        return !string.isEmpty &&
            string.count <= 64 &&
            string.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
    }

    fileprivate static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    fileprivate static func modificationDate(_ path: String) -> Date? {
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    fileprivate static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    fileprivate static func singleLine(_ string: String) -> String {
        let collapsed = string.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(200))
    }
}

// MARK: - GitHub Copilot CLI

extension iTermAgentSessionStore {
    // ~/.copilot/session-state/<id>/workspace.yaml holds the name, cwd, and
    // timestamps. A running CLI holds inuse.<pid>.lock in the same folder.
    fileprivate func copilotSessions(after cutoff: Date, seenPaths: inout Set<String>) -> [iTermAgentSession] {
        let root = (NSHomeDirectory() as NSString).appendingPathComponent(".copilot/session-state")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return []
        }
        var result = [iTermAgentSession]()
        for name in names where Self.isValidSessionID(name) {
            let folder = (root as NSString).appendingPathComponent(name)
            let yamlPath = (folder as NSString).appendingPathComponent("workspace.yaml")
            let eventsPath = (folder as NSString).appendingPathComponent("events.jsonl")
            let modified = [Self.modificationDate(yamlPath), Self.modificationDate(eventsPath)]
                .compactMap { $0 }
                .max()
            guard let modified, modified > cutoff else {
                continue
            }
            if Self.copilotSessionIsActive(folder: folder) {
                continue
            }
            seenPaths.insert(yamlPath)
            let session: iTermAgentSession?
            if let entry = cache[yamlPath], entry.modificationDate == modified {
                session = entry.session
            } else {
                session = Self.parseCopilotSession(id: name, yamlPath: yamlPath, modified: modified)
                cache[yamlPath] = CacheEntry(modificationDate: modified, session: session)
            }
            if let session {
                result.append(session)
            }
        }
        return result
    }

    fileprivate static func copilotSessionIsActive(folder: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            return false
        }
        for entry in entries where entry.hasPrefix("inuse.") && entry.hasSuffix(".lock") {
            let pidString = entry.dropFirst("inuse.".count).dropLast(".lock".count)
            if let pid = pid_t(pidString), isProcessAlive(pid) {
                return true
            }
        }
        return false
    }

    static func parseCopilotSession(id: String, yamlPath: String, modified: Date) -> iTermAgentSession? {
        guard let text = try? String(contentsOfFile: yamlPath, encoding: .utf8) else {
            return nil
        }
        var fields = [String: String]()
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else {
                continue
            }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = unquotedYAMLScalar(value)
        }
        // Sessions from the SDK or other clients can't be resumed with the CLI.
        if let client = fields["client_name"], client != "github/cli" {
            return nil
        }
        // An unnamed session never received a prompt.
        guard let title = fields["name"].map(singleLine), !title.isEmpty else {
            return nil
        }
        let updated = fields["updated_at"].flatMap { isoFormatter.date(from: $0) }
        let lastActive = [updated, modified].compactMap { $0 }.max() ?? modified
        return iTermAgentSession(kind: .copilot,
                                 sessionID: id,
                                 title: title,
                                 workingDirectory: fields["cwd"],
                                 lastActive: lastActive,
                                 projectRoot: fields["git_root"].flatMap { $0.isEmpty ? nil : $0 })
    }

    fileprivate static func unquotedYAMLScalar(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""),
           let data = value.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
            return decoded
        }
        return value
    }
}

// MARK: - Claude Code

extension iTermAgentSessionStore {
    fileprivate var claudeConfigDirectory: String {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return (custom as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
    }

    // ~/.claude/projects/<encoded cwd>/<id>.jsonl is the transcript. A running
    // Claude Code writes ~/.claude/sessions/<pid>.json naming its session.
    fileprivate func claudeSessions(after cutoff: Date, seenPaths: inout Set<String>) -> [iTermAgentSession] {
        let projects = (claudeConfigDirectory as NSString).appendingPathComponent("projects")
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: projects) else {
            return []
        }
        let active = activeClaudeSessionIDs()
        var result = [iTermAgentSession]()
        for folder in folders {
            let folderPath = (projects as NSString).appendingPathComponent(folder)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: folderPath) else {
                continue
            }
            for file in files where file.hasSuffix(".jsonl") {
                let id = String(file.dropLast(".jsonl".count))
                guard Self.isValidSessionID(id), !active.contains(id) else {
                    continue
                }
                let path = (folderPath as NSString).appendingPathComponent(file)
                guard let modified = Self.modificationDate(path), modified > cutoff else {
                    continue
                }
                seenPaths.insert(path)
                let session: iTermAgentSession?
                if let entry = cache[path], entry.modificationDate == modified {
                    session = entry.session
                } else {
                    session = Self.parseClaudeSession(id: id, path: path, modified: modified)
                    cache[path] = CacheEntry(modificationDate: modified, session: session)
                }
                if let session {
                    result.append(session)
                }
            }
        }
        return result
    }

    fileprivate func activeClaudeSessionIDs() -> Set<String> {
        let folder = (claudeConfigDirectory as NSString).appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else {
            return []
        }
        var result = Set<String>()
        for file in files where file.hasSuffix(".json") {
            let path = (folder as NSString).appendingPathComponent(file)
            guard let data = FileManager.default.contents(atPath: path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = object["sessionId"] as? String else {
                continue
            }
            let pid = (object["pid"] as? NSNumber)?.int32Value ?? pid_t(file.dropLast(".json".count)) ?? 0
            if Self.isProcessAlive(pid) {
                result.insert(sessionID)
            }
        }
        return result
    }

    // Title preference: a user-set title, then Claude's generated title, then a
    // legacy summary, then the first prompt.
    static func parseClaudeSession(id: String, path: String, modified: Date) -> iTermAgentSession? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        var firstPrompt: String?
        var cwd: String?
        let text = String(decoding: data, as: UTF8.self)
        text.enumerateLines { line, _ in
            let interesting = line.contains("\"custom-title\"") ||
                line.contains("\"ai-title\"") ||
                line.contains("\"type\":\"summary\"") ||
                (cwd == nil && line.contains("\"cwd\"")) ||
                (firstPrompt == nil && line.contains("\"type\":\"user\""))
            guard interesting,
                  let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return
            }
            if cwd == nil, let value = object["cwd"] as? String {
                cwd = value
            }
            switch object["type"] as? String {
            case "custom-title":
                customTitle = (object["customTitle"] as? String) ?? customTitle
            case "ai-title":
                aiTitle = (object["aiTitle"] as? String) ?? aiTitle
            case "summary":
                summary = (object["summary"] as? String) ?? summary
            case "user":
                if firstPrompt == nil,
                   (object["isSidechain"] as? Bool) != true,
                   (object["isMeta"] as? Bool) != true,
                   let message = object["message"] as? [String: Any],
                   let content = message["content"] as? String,
                   !content.hasPrefix("<") {
                    firstPrompt = content
                }
            default:
                break
            }
        }
        guard let rawTitle = customTitle ?? aiTitle ?? summary ?? firstPrompt else {
            return nil
        }
        let title = singleLine(rawTitle)
        guard !title.isEmpty else {
            return nil
        }
        return iTermAgentSession(kind: .claude,
                                 sessionID: id,
                                 title: title,
                                 workingDirectory: cwd,
                                 lastActive: modified)
    }
}
