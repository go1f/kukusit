import Foundation
import CryptoKit

public struct UpdateManifest: Codable, Equatable {
    public let schema: Int
    public let version: String
    public let build: Int
    public let minimumOS: String
    public let architecture: String
    public let url: String
    public let size: Int64
    public let sha256: String
    public let notes: String
    public init(schema: Int = 1, version: String, build: Int, minimumOS: String = "14.0", architecture: String = "arm64",
                url: String, size: Int64, sha256: String, notes: String) {
        self.schema = schema; self.version = version; self.build = build; self.minimumOS = minimumOS
        self.architecture = architecture; self.url = url; self.size = size; self.sha256 = sha256; self.notes = notes
    }
    public static func verified(_ data: Data, publicKey: Data) throws -> UpdateManifest {
        guard data.count <= 100_000 else { throw UpdateFailure.invalidManifest }
        let envelope = try JSONDecoder().decode(SignedUpdateEnvelope.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload), payload.count <= 60_000,
              let signature = Data(base64Encoded: envelope.signature), signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(signature, for: payload)
        else { throw UpdateFailure.invalidSignature }
        let item = try JSONDecoder().decode(Self.self, from: payload)
        guard item.schema == 1, item.build > 0, item.architecture == "arm64",
              item.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              item.minimumOS.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil,
              item.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              item.size > 0, item.size <= 400_000_000, item.notes.count <= 20_000,
              item.url == "https://github.com/go1f/kukusit/releases/download/v\(item.version)/Kukusit-\(item.version)-macOS-arm64.zip"
        else { throw UpdateFailure.invalidManifest }
        return item
    }
    public func supports(os: OperatingSystemVersion) -> Bool {
        let values = minimumOS.split(separator: ".").compactMap { Int($0) }
        let current = [os.majorVersion, os.minorVersion, os.patchVersion]
        let minimum = values + Array(repeating: 0, count: max(0, 3-values.count))
        return !current.lexicographicallyPrecedes(minimum)
    }
}

public struct SignedUpdateEnvelope: Codable {
    public let payload: String
    public let signature: String
    public init(payload: String, signature: String) { self.payload = payload; self.signature = signature }
}
public enum UpdateFailure: Error, LocalizedError {
    case invalidManifest, invalidSignature, invalidArchive, untrustedApp, unsupportedOS, installLocation, busy, process(String)
    public var errorDescription: String? {
        switch self {
        case .invalidManifest: return "更新信息格式或下载地址不正确。"
        case .invalidSignature: return "更新信息签名不正确，已停止更新。"
        case .invalidArchive: return "安装包内容、大小或哈希不正确，已停止更新。"
        case .untrustedApp: return "应用签名或版本不符合预期，已停止更新。"
        case .unsupportedOS: return "新版本需要更新的 macOS。"
        case .installLocation: return "当前应用位置不能自动更新，请先移到可写的“应用程序”目录。"
        case .busy: return "更新任务正在进行。"
        case .process(let text): return text
        }
    }
}
