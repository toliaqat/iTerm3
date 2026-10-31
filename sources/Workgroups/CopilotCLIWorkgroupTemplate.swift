//
//  CopilotCLIWorkgroupTemplate.swift
//  iTerm2SharedARC
//

import Foundation

// Factory for the Copilot CLI workgroup the Copilot CLI integration
// installer adds to the user's iTermWorkgroupModel. Like the Claude Code
// workgroup, the IDs stay stable so the installed Enter Workgroup trigger
// keeps resolving. Its Code Review peer runs Copilot instead of Claude.
enum CopilotCLIWorkgroupTemplate {
    enum ID {
        static let workgroup = "builtin.copilotCLI"
        static let main = "builtin.copilotCLI.main"
        static let diff = "builtin.copilotCLI.diff"
        static let review = "builtin.copilotCLI.review"
    }

    static let jobName = "copilot"

    static let config: iTermWorkgroup =
        WorkgroupPresets.buildCodingAgentPlusDiffPlusCodeReview(
            workgroupID: ID.workgroup,
            rootID: ID.main,
            diffID: ID.diff,
            reviewID: ID.review,
            name: "Copilot CLI",
            reviewCommand: WorkgroupPresets.copilotCodeReviewCommand)
}
