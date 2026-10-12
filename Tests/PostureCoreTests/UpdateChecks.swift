import Foundation
import CryptoKit
import PostureCore

struct UpdateChecks {
    let key = Curve25519.Signing.PrivateKey()
    func item(url: String = "https://github.com/go1f/kukusit/releases/download/v0.7.0/Kukusit-0.7.0-macOS-arm64.zip", build: Int = 12, size: Int64 = 100) -> UpdateManifest {
        UpdateManifest(version: "0.7.0", build: build, url: url, size: size, sha256: String(repeating: "a", count: 64), notes: "更新测试")
    }
    func signed(_ value: UpdateManifest) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        return try JSONEncoder().encode(SignedUpdateEnvelope(payload: payload.base64EncodedString(), signature: key.signature(for: payload).base64EncodedString()))
    }
    func validSignature() throws {
        let value = item(); let result = try UpdateManifest.verified(signed(value), publicKey: key.publicKey.rawRepresentation)
        expectEqual(result, value)
        expectTrue(result.supports(os: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0)))
        expectFalse(result.supports(os: .init(majorVersion: 13, minorVersion: 6, patchVersion: 0)))
    }
    func tampering() throws {
        let original = try JSONDecoder().decode(SignedUpdateEnvelope.self, from: signed(item()))
        let changed = SignedUpdateEnvelope(payload: Data("changed".utf8).base64EncodedString(), signature: original.signature)
        expectThrowsError(try UpdateManifest.verified(JSONEncoder().encode(changed), publicKey: key.publicKey.rawRepresentation)) { _ in }
        expectThrowsError(try UpdateManifest.verified(signed(item()), publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)) { _ in }
    }
    func constraints() throws {
        for invalid in [item(url: "http://github.com/file.zip"), item(url: "https://github.com/other/repo/file.zip"), item(build: 0), item(size: 400_000_001)] {
            expectThrowsError(try UpdateManifest.verified(signed(invalid), publicKey: key.publicKey.rawRepresentation)) { _ in }
        }
        expectThrowsError(try UpdateManifest.verified(Data(repeating: 0, count: 100_001), publicKey: key.publicKey.rawRepresentation)) { _ in }
    }
    func fixture(_ body: (UpdateInstallPlan) throws -> Void) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kukusit-update-test-\(UUID())").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("Kukusit.app")
        let workspace = root.appendingPathComponent(".kukusit-update-test")
        let staged = workspace.appendingPathComponent("next.app")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("version"))
        try Data("new".utf8).write(to: staged.appendingPathComponent("version"))
        try body(UpdateInstallPlan(destination: destination.path, staged: staged.path, workspace: workspace.path, parentPID: 1, expectedBuild: 12, statusFile: root.appendingPathComponent("status").path))
    }
    func read(_ path: String) throws -> String { try String(contentsOfFile: path + "/version") }
    func success() throws {
        try fixture { plan in
            var launches = 0
            try UpdateInstallation.install(plan, verify: { _, _ in }, waitForParent: {}, relaunch: { _ in launches += 1 })
            expectEqual(try read(plan.destination), "new")
            expectEqual(try read(plan.workspace + "/previous.app"), "old")
            expectEqual(launches, 1)
        }
    }
    func launchRollback() throws {
        try fixture { plan in
            var launches = 0
            expectThrowsError(try UpdateInstallation.install(plan, verify: { _, _ in }, waitForParent: {}, relaunch: { _ in
                launches += 1; if launches == 1 { throw UpdateFailure.process("injected launch failure") }
            })) { _ in }
            expectEqual(try read(plan.destination), "old"); expectEqual(launches, 2)
        }
    }
    func verificationRollback() throws {
        try fixture { plan in
            var verification = 0
            expectThrowsError(try UpdateInstallation.install(plan, verify: { _, _ in
                verification += 1; if verification == 3 { throw UpdateFailure.untrustedApp }
            }, waitForParent: {}, relaunch: { _ in })) { _ in }
            expectEqual(try read(plan.destination), "old")
        }
    }
    func failedStageOrParent() throws {
        try fixture { plan in
            expectThrowsError(try UpdateInstallation.install(plan, verify: { _, build in
                if build != nil { throw UpdateFailure.untrustedApp }
            }, waitForParent: {}, relaunch: { _ in })) { _ in }
            expectEqual(try read(plan.destination), "old")
            expectThrowsError(try UpdateInstallation.install(plan, verify: { _, _ in }, waitForParent: { throw UpdateFailure.busy }, relaunch: { _ in })) { _ in }
            expectEqual(try read(plan.destination), "old")
        }
    }
    func pathAndLock() throws {
        try fixture { plan in
            let unsafe = UpdateInstallPlan(destination: plan.destination, staged: plan.destination, workspace: plan.workspace, parentPID: 1, expectedBuild: 12, statusFile: plan.statusFile)
            expectThrowsError(try UpdateInstallation.install(unsafe, verify: { _, _ in }, waitForParent: {}, relaunch: { _ in })) { _ in }
            let lock = URL(fileURLWithPath: plan.destination).deletingLastPathComponent().appendingPathComponent(".kukusit-update-lock")
            try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
            expectThrowsError(try UpdateInstallation.install(plan, verify: { _, _ in }, waitForParent: {}, relaunch: { _ in })) { _ in }
            expectEqual(try read(plan.destination), "old")
        }
    }
}
