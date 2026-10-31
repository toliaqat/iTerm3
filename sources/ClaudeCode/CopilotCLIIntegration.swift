//
//  CopilotCLIIntegration.swift
//  iTerm2
//
//  Installs iTerm2's session status hook for GitHub Copilot CLI, which reads user-level hooks
//  from every *.json file in ~/.copilot/hooks (or $COPILOT_HOME/hooks), and the iterm2-workspace
//  skill in ~/.copilot/skills. iTerm2 owns one file and one skill folder there, so installing and
//  uninstalling never touch the user's own hooks or skills.
//

import AppKit

@objc(iTermCopilotCLIIntegration)
final class CopilotCLIIntegration: NSObject {
    static let agentArguments = "--agent copilot"
    static let skillName = "iterm2-workspace"

    // PermissionRequest is left out: Copilot CLI sends it without hook_event_name, before the
    // permission check, even for tools that will be allowed. Notification's permission_prompt is
    // the one that means a prompt is up.
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                         "PostToolUse", "PostToolUseFailure", "Stop", "Notification",
                         "ErrorOccurred"]

    static var copilotHome: URL {
        if let custom = ProcessInfo.processInfo.environment["COPILOT_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")
    }

    static func hooksFileURL(home: URL = copilotHome) -> URL {
        return home.appendingPathComponent("hooks").appendingPathComponent("iterm2-session-status.json")
    }

    /// The iterm2-workspace skill, which lets the top-level session orchestrate agents in other
    /// tabs of its workspace.
    static func skillDirectoryURL(home: URL = copilotHome) -> URL {
        return home.appendingPathComponent("skills").appendingPathComponent(skillName)
    }

    static func hooksInstalled(home: URL = copilotHome) -> Bool {
        guard let text = try? String(contentsOf: hooksFileURL(home: home), encoding: .utf8) else {
            return false
        }
        return text.contains("handle-agent-hook \(agentArguments)")
    }

    static func skillInstalled(home: URL = copilotHome) -> Bool {
        let skill = skillDirectoryURL(home: home).appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skill, encoding: .utf8) else {
            return false
        }
        return text.contains("name: \(skillName)")
    }

    @objc static var isInstalled: Bool {
        return hooksInstalled() && skillInstalled()
    }

    static var isPartlyInstalled: Bool {
        return hooksInstalled() || skillInstalled()
    }

    static func hooksFileContents(command: String) throws -> Data {
        let entry: [String: Any] = ["type": "command", "bash": command, "timeoutSec": 10]
        var hooks = [String: Any]()
        for event in events {
            hooks[event] = [entry]
        }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "hooks": hooks],
                                          options: [.prettyPrinted, .sortedKeys])
    }

    /// Writes SKILL.md and its ws helper from the templates in `resources`, naming `it2Path`.
    static func installSkill(home: URL = copilotHome, it2Path: String, resources: Bundle = .main) throws {
        guard let skillTemplate = resources.url(forResource: "\(skillName)-SKILL", withExtension: "md"),
              let helperTemplate = resources.url(forResource: "\(skillName)-ws", withExtension: "sh") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let directory = skillDirectoryURL(home: home)
        let helper = directory.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let skill = try String(contentsOf: skillTemplate, encoding: .utf8)
            .replacingOccurrences(of: "__WS_PATH__", with: helper.path)
        try skill.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let script = try String(contentsOf: helperTemplate, encoding: .utf8)
            .replacingOccurrences(of: "__IT2_PATH__", with: it2Path)
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    }

    static func install() throws {
        guard let base = ClaudeCodeOnboarding.hookCommandForNewInstalls(),
              let dotDir = FileManager.default.homeDirectoryDotDir() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = hooksFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try hooksFileContents(command: base + " " + agentArguments).write(to: url, options: .atomic)
        try installSkill(it2Path: (dotDir as NSString).appendingPathComponent("it2"))
        RLog("Installed Copilot CLI hooks at \(url.path) and the \(skillName) skill")
    }

    /// Removes only what install wrote: the hook file and the skill, each if it is ours.
    static func uninstall(home: URL = copilotHome) throws {
        if hooksInstalled(home: home) {
            try FileManager.default.removeItem(at: hooksFileURL(home: home))
        }
        if skillInstalled(home: home) {
            try FileManager.default.removeItem(at: skillDirectoryURL(home: home))
        }
        RLog("Removed Copilot CLI integration from \(home.path)")
    }
}

@objc(iTermCopilotCLIIntegrationMenuController)
final class CopilotCLIIntegrationMenuController: NSObject {
    @objc static let shared = CopilotCLIIntegrationMenuController()

    private override init() {
        super.init()
    }

    @objc func install(_ sender: Any?) {
        if !iTermAPIHelper.isEnabled() {
            guard iTermAPIHelper.confirmShouldStartServerAndUpdateUserDefaultsForced(true) else {
                return
            }
            _ = iTermAPIHelper.sharedInstance()
            guard iTermAPIHelper.isEnabled() else {
                return
            }
        }
        let path = CopilotCLIIntegration.hooksFileURL().path
        let skillPath = CopilotCLIIntegration.skillDirectoryURL().path
        do {
            try CopilotCLIIntegration.install()
        } catch {
            RLog("Copilot CLI hook install failed: \(error)")
            show(heading: String(localized: "CopilotCLI.InstallFailedTitle", defaultValue: "Couldn\u{2019}t Install Copilot CLI Integration", comment: "Title shown when writing the Copilot CLI hook file failed"),
                 body: String(localized: "CopilotCLI.InstallFailedBody", defaultValue: "iTerm2 couldn\u{2019}t write to \(CopilotCLIIntegration.copilotHome.path): \(error.localizedDescription)", comment: "Body shown when writing the Copilot CLI hook file or skill failed. The first value is the absolute path to Copilot CLI’s settings folder; the second is the system’s error description"))
            return
        }
        if !iTermToolbeltView.shouldShowTool(kStatusToolName, profileType: .terminal) {
            iTermToolbeltView.toggleShouldShowTool(kStatusToolName)
        }
        show(heading: String(localized: "CopilotCLI.InstalledTitle", defaultValue: "Copilot CLI Integration Installed", comment: "Title shown after installing the Copilot CLI integration"),
             body: String(localized: "CopilotCLI.InstalledBody", defaultValue: "iTerm2 added its status hook to \(path). Copilot CLI sessions started from now on report when they’re working, waiting for you, done, or failed in the Session Status tool (View > Toolbelt > Show Toolbelt).\n\nIt also added the iterm2-workspace skill to \(skillPath). Ask a Copilot CLI session to split a job across other agents and it opens and directs them in tabs of its project. Sessions it opens can’t do the same.\n\nIf you turn on Copilot CLI’s sandbox, the hook and skill may not be able to reach iTerm2.", comment: "Body shown after installing the Copilot CLI integration. The first value is the absolute path to the hook file; the second is the absolute path to the skill folder. iterm2-workspace is the skill’s name and is not translated"))
    }

    @objc func uninstall(_ sender: Any?) {
        let path = CopilotCLIIntegration.hooksFileURL().path
        let skillPath = CopilotCLIIntegration.skillDirectoryURL().path
        let confirm = iTermWarning()
        confirm.heading = String(localized: "CopilotCLI.UninstallTitle", defaultValue: "Uninstall Copilot CLI Integration?", comment: "Title of the Copilot CLI uninstall confirmation")
        confirm.title = String(localized: "CopilotCLI.UninstallBody", defaultValue: "This deletes \(path), which holds iTerm2’s status hook for Copilot CLI, and the iterm2-workspace skill in \(skillPath). Your other Copilot CLI hooks and skills aren’t changed.", comment: "Body of the Copilot CLI uninstall confirmation. The first value is the absolute path to the hook file; the second is the absolute path to the skill folder. iterm2-workspace is the skill’s name and is not translated")
        confirm.actionLabels = [String(localized: "CopilotCLI.Uninstall", defaultValue: "Uninstall", comment: "Button to confirm uninstalling the Copilot CLI integration"),
                                iTermLocalizedCancel()]
        confirm.cancelLabel = iTermLocalizedCancel()
        confirm.warningType = .kiTermWarningTypePersistent
        guard confirm.runModal() == .kiTermWarningSelection0 else {
            return
        }
        do {
            try CopilotCLIIntegration.uninstall()
        } catch {
            RLog("Copilot CLI hook uninstall failed: \(error)")
            show(heading: String(localized: "CopilotCLI.UninstallFailedTitle", defaultValue: "Couldn\u{2019}t Uninstall Copilot CLI Integration", comment: "Title shown when deleting the Copilot CLI hook file failed"),
                 body: String(localized: "CopilotCLI.UninstallFailedBody", defaultValue: "iTerm2 couldn\u{2019}t delete files in \(CopilotCLIIntegration.copilotHome.path): \(error.localizedDescription)", comment: "Body shown when deleting the Copilot CLI hook file or skill failed. The first value is the absolute path to Copilot CLI’s settings folder; the second is the system’s error description"))
        }
    }

    @objc func validateInstallMenuItem(_ item: NSMenuItem) -> Bool {
        item.isHidden = CopilotCLIIntegration.isInstalled
        return true
    }

    @objc func validateUninstallMenuItem(_ item: NSMenuItem) -> Bool {
        item.isHidden = !CopilotCLIIntegration.isPartlyInstalled
        return true
    }

    private func show(heading: String, body: String) {
        let warning = iTermWarning()
        warning.heading = heading
        warning.title = body
        warning.actionLabels = [iTermLocalizedOK()]
        warning.warningType = .kiTermWarningTypePersistent
        warning.runModal()
    }
}
