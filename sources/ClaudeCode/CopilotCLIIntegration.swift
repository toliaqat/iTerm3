//
//  CopilotCLIIntegration.swift
//  iTerm2
//
//  Installs iTerm2's session status hook for GitHub Copilot CLI, which reads user-level hooks
//  from every *.json file in ~/.copilot/hooks (or $COPILOT_HOME/hooks). iTerm2 owns one file
//  there, so installing and uninstalling never touch the user's own hooks.
//

import AppKit

@objc(iTermCopilotCLIIntegration)
final class CopilotCLIIntegration: NSObject {
    static let agentArguments = "--agent copilot"

    // PermissionRequest is left out: Copilot CLI sends it without hook_event_name, before the
    // permission check, even for tools that will be allowed. Notification's permission_prompt is
    // the one that means a prompt is up.
    static let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
                         "PostToolUse", "PostToolUseFailure", "Stop", "Notification",
                         "ErrorOccurred"]

    static var hooksFileURL: URL {
        let home: URL
        if let custom = ProcessInfo.processInfo.environment["COPILOT_HOME"], !custom.isEmpty {
            home = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")
        }
        return home.appendingPathComponent("hooks").appendingPathComponent("iterm2-session-status.json")
    }

    @objc static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: hooksFileURL),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.contains("handle-agent-hook \(agentArguments)")
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

    static func install() throws {
        guard let base = ClaudeCodeOnboarding.hookCommandForNewInstalls() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = hooksFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try hooksFileContents(command: base + " " + agentArguments).write(to: url, options: .atomic)
        RLog("Installed Copilot CLI hooks at \(url.path)")
    }

    static func uninstall() throws {
        guard isInstalled else {
            return
        }
        try FileManager.default.removeItem(at: hooksFileURL)
        RLog("Removed Copilot CLI hooks at \(hooksFileURL.path)")
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
        let path = CopilotCLIIntegration.hooksFileURL.path
        do {
            try CopilotCLIIntegration.install()
        } catch {
            RLog("Copilot CLI hook install failed: \(error)")
            show(heading: String(localized: "CopilotCLI.InstallFailedTitle", defaultValue: "Couldn\u{2019}t Install Copilot CLI Integration", comment: "Title shown when writing the Copilot CLI hook file failed"),
                 body: String(localized: "CopilotCLI.InstallFailedBody", defaultValue: "iTerm2 couldn\u{2019}t write \(path): \(error.localizedDescription)", comment: "Body shown when writing the Copilot CLI hook file failed. The first value is the file’s absolute path; the second is the system’s error description"))
            return
        }
        if !iTermToolbeltView.shouldShowTool(kStatusToolName, profileType: .terminal) {
            iTermToolbeltView.toggleShouldShowTool(kStatusToolName)
        }
        show(heading: String(localized: "CopilotCLI.InstalledTitle", defaultValue: "Copilot CLI Integration Installed", comment: "Title shown after installing the Copilot CLI integration"),
             body: String(localized: "CopilotCLI.InstalledBody", defaultValue: "iTerm2 added its status hook to \(path). Copilot CLI sessions started from now on report when they’re working, waiting for you, done, or failed in the Session Status tool (View > Toolbelt > Show Toolbelt).\n\nIf you turn on Copilot CLI’s sandbox, the hook may not be able to reach iTerm2.", comment: "Body shown after installing the Copilot CLI integration. The value is the absolute path to the hook file"))
    }

    @objc func uninstall(_ sender: Any?) {
        let path = CopilotCLIIntegration.hooksFileURL.path
        let confirm = iTermWarning()
        confirm.heading = String(localized: "CopilotCLI.UninstallTitle", defaultValue: "Uninstall Copilot CLI Integration?", comment: "Title of the Copilot CLI uninstall confirmation")
        confirm.title = String(localized: "CopilotCLI.UninstallBody", defaultValue: "This deletes \(path), which holds iTerm2’s status hook for Copilot CLI. Your other Copilot CLI hooks aren’t changed.", comment: "Body of the Copilot CLI uninstall confirmation. The value is the absolute path to the hook file")
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
                 body: String(localized: "CopilotCLI.UninstallFailedBody", defaultValue: "iTerm2 couldn\u{2019}t delete \(path): \(error.localizedDescription)", comment: "Body shown when deleting the Copilot CLI hook file failed. The first value is the file’s absolute path; the second is the system’s error description"))
        }
    }

    @objc func validateInstallMenuItem(_ item: NSMenuItem) -> Bool {
        item.isHidden = CopilotCLIIntegration.isInstalled
        return true
    }

    @objc func validateUninstallMenuItem(_ item: NSMenuItem) -> Bool {
        item.isHidden = !CopilotCLIIntegration.isInstalled
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
