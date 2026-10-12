import Foundation
import PostureCore

@MainActor enum UpdateDiagnostics {
    static func check(manifest: String, archive: String) {
        do {
            guard let keyText = Bundle.main.object(forInfoDictionaryKey: "KukusitUpdatePublicKey") as? String,
                  let key = Data(base64Encoded: keyText) else { throw UpdateFailure.invalidManifest }
            let item = try UpdateManifest.verified(Data(contentsOf: URL(fileURLWithPath: manifest)), publicKey: key)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("kukusit-package-check-\(UUID())").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let destination = root.appendingPathComponent("Kukusit.app")
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: destination)
            _ = try AppUpdater.prepare(file: URL(fileURLWithPath: archive), item: item, destination: destination)
            print("{\"passed\":true,\"checks\":[\"Ed25519 manifest\",\"archive size and SHA256\",\"zip paths\",\"application certificate and build\"],\"build\":\(item.build)}")
            exit(0)
        } catch { fputs("Update validation failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
