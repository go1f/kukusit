import Foundation
import Darwin
import PostureCore

let args = CommandLine.arguments
guard args.count == 2 else { exit(2) }
let configURL = URL(fileURLWithPath: args[1])
guard let data = try? Data(contentsOf: configURL), data.count < 16_384,
      let plan = try? JSONDecoder().decode(UpdateInstallPlan.self, from: data), plan.parentPID > 1 else { exit(2) }
func report(_ text: String) {
    try? Data(text.utf8).write(to: URL(fileURLWithPath: plan.statusFile), options: .atomic)
}
do {
    try UpdateInstallation.install(plan, verify: { app, expected in
        try UpdateInstallation.verifyBundle(app, expectedBuild: expected)
        if expected == nil {
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let value = info["CFBundleVersion"] as? String, let current = Int(value), current < plan.expectedBuild
            else { throw UpdateFailure.untrustedApp }
        }
    }, waitForParent: {
        let deadline = Date().addingTimeInterval(60)
        while kill(plan.parentPID, 0) == 0 {
            guard Date() < deadline else { throw UpdateFailure.process("应用尚未退出，保留原版本；请稍后重新更新。") }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }, relaunch: { app in
        _ = try UpdateInstallation.command("/usr/bin/open", ["-n", app.path])
    })
    report("已更新到构建 \(plan.expectedBuild)。原版本保留在 \(plan.workspace)/previous.app")
    try? FileManager.default.removeItem(at: configURL)
} catch {
    report("更新未完成，已保留或恢复原应用：\(error.localizedDescription)")
    exit(1)
}
