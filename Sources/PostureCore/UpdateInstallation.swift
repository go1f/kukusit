import Foundation
import Darwin

public struct UpdateInstallPlan: Codable {
    public let destination: String
    public let staged: String
    public let workspace: String
    public let parentPID: Int32
    public let expectedBuild: Int
    public let statusFile: String
    public init(destination: String, staged: String, workspace: String, parentPID: Int32, expectedBuild: Int, statusFile: String) {
        self.destination = destination; self.staged = staged; self.workspace = workspace
        self.parentPID = parentPID; self.expectedBuild = expectedBuild; self.statusFile = statusFile
    }
}
public enum UpdateInstallation {
    public static let bundleID = "com.kojyufu.posturediagnostics"
    public static let requirement = "identifier \"com.kojyufu.posturediagnostics\" and certificate leaf = H\"2817523E7E9887A9E9D1C50D39FA0D2ACB1C9758\""

    /// The helper never elevates privileges. Both renames stay on the destination volume.
    /// A failed validation or relaunch restores the previous bundle.
    public static func install(_ plan: UpdateInstallPlan,
                               verify: (URL, Int?) throws -> Void,
                               waitForParent: () throws -> Void,
                               relaunch: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let destination = URL(fileURLWithPath: plan.destination).standardizedFileURL
        let workspace = URL(fileURLWithPath: plan.workspace).standardizedFileURL
        let staged = URL(fileURLWithPath: plan.staged).standardizedFileURL
        guard destination.pathExtension == "app", destination.resolvingSymlinksInPath() == destination,
              workspace.deletingLastPathComponent() == destination.deletingLastPathComponent(),
              workspace.lastPathComponent.hasPrefix(".kukusit-update-"),
              workspace.resolvingSymlinksInPath() == workspace,
              staged == workspace.appendingPathComponent("next.app"),
              staged.resolvingSymlinksInPath() == staged,
              plan.expectedBuild > 0 else { throw UpdateFailure.installLocation }
        let lock = destination.deletingLastPathComponent().appendingPathComponent(".kukusit-update-lock")
        guard mkdir(lock.path, 0o700) == 0 else { throw UpdateFailure.busy }
        defer { try? fm.removeItem(at: lock) }
        try verify(destination, nil)
        try verify(staged, plan.expectedBuild)
        try waitForParent()
        let previous = workspace.appendingPathComponent("previous.app")
        guard !fm.fileExists(atPath: previous.path) else { throw UpdateFailure.busy }
        try fm.moveItem(at: destination, to: previous)
        do {
            try fm.moveItem(at: staged, to: destination)
            try verify(destination, plan.expectedBuild)
            try relaunch(destination)
        } catch {
            if fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: destination, to: workspace.appendingPathComponent("failed.app"))
            }
            try fm.moveItem(at: previous, to: destination)
            try? relaunch(destination)
            throw error
        }
        // Retain previous.app for recovery; the next startup records this path.
    }
    public static func verifyBundle(_ url: URL, expectedBuild: Int?) throws {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              let buildString = info["CFBundleVersion"] as? String, let build = Int(buildString),
              expectedBuild == nil || build == expectedBuild else { throw UpdateFailure.untrustedApp }
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + requirement, url.path])
    }
    @discardableResult public static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        let output = Pipe(); task.standardOutput = output; task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw UpdateFailure.process(String(data: data, encoding: .utf8) ?? "操作失败") }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
