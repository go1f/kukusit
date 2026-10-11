import Foundation
import CoreVideo
import Darwin
import PostureCore

enum BodyBackend: String, Codable, CaseIterable, Identifiable {
    case appleVision, mediaPipe
    var id: String { rawValue }
    var label: String { self == .appleVision ? "Apple Vision" : "MediaPipe Pose" }
}

private struct PoseConfiguration: Decodable {
    let pythonExecutable: String?
    let bundledExecutable: String?
    let modelFile: String
    let modelSHA256: String
    let packageVersion: String
}

private final class LineInbox {
    private let condition = NSCondition()
    private var buffered = Data()
    private var lines: [Data] = []
    private var ended: String?
    func append(_ data: Data) {
        condition.lock(); defer { condition.unlock() }
        guard ended == nil else { return }
        if data.isEmpty { ended = "肩部进程已结束。"; condition.broadcast(); return }
        buffered.append(data)
        if buffered.count > 256 * 1024 { ended = "肩部响应超出大小限制。"; condition.broadcast(); return }
        while let newline = buffered.firstIndex(of: 10) {
            lines.append(Data(buffered[..<newline]))
            buffered.removeSubrange(...newline)
        }
        if lines.count > 4 { ended = "肩部响应队列异常。" }
        condition.broadcast()
    }
    func finish(_ reason: String) {
        condition.lock(); ended = reason; condition.broadcast(); condition.unlock()
    }
    func next(timeout: TimeInterval) throws -> Data {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while lines.isEmpty && ended == nil {
            if !condition.wait(until: deadline) { throw workerError("肩部分析超时，请暂停后重新开始。") }
        }
        guard !lines.isEmpty else { throw workerError(ended ?? "肩部分析已停止。") }
        return lines.removeFirst()
    }
}

private func workerError(_ message: String) -> NSError {
    NSError(domain: "LocalPoseWorker", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

final class PoseWorker {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let inbox = LineInbox()
    private let cancellationLock = NSLock()
    private var cancelled = false
    private let config: PoseConfiguration
    let signature: String
    static var configuredSignature: String? {
        guard let location = Bundle.main.url(forResource: "pose-backend", withExtension: "json"),
              let data = try? Data(contentsOf: location), let config = try? JSONDecoder().decode(PoseConfiguration.self, from: data) else { return nil }
        return "mediapipe\(config.packageVersion)|\(config.modelSHA256)"
    }

    static var isAvailable: Bool {
        guard let location = Bundle.main.url(forResource: "pose-backend", withExtension: "json"),
              let data = try? Data(contentsOf: location), let config = try? JSONDecoder().decode(PoseConfiguration.self, from: data),
              let resources = Bundle.main.resourceURL else { return false }
        let executable = config.bundledExecutable.map { Bundle.main.bundleURL.appendingPathComponent($0).path } ?? config.pythonExecutable
        return (executable.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false)
            && FileManager.default.fileExists(atPath: resources.appendingPathComponent(config.modelFile).path)
    }

    init() throws {
        guard let configURL = Bundle.main.url(forResource: "pose-backend", withExtension: "json"),
              let resources = Bundle.main.resourceURL else { throw workerError("MediaPipe 未配置，请运行后端安装脚本并重新构建。") }
        config = try JSONDecoder().decode(PoseConfiguration.self, from: Data(contentsOf: configURL))
        signature = "mediapipe\(config.packageVersion)|\(config.modelSHA256)"
        if let bundled = config.bundledExecutable {
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent(bundled)
            process.arguments = ["--model", resources.appendingPathComponent(config.modelFile).path, "--sha256", config.modelSHA256]
        } else if let python = config.pythonExecutable {
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-u", resources.appendingPathComponent("pose_worker.py").path,
                                 "--model", resources.appendingPathComponent(config.modelFile).path, "--sha256", config.modelSHA256]
        } else { throw workerError("缺少本地推理运行时。") }
        var environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
        environment["PYTHONNOUSERSITE"] = "1"
        environment["OMP_NUM_THREADS"] = "2"
        environment["OPENBLAS_NUM_THREADS"] = "2"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output
        process.qualityOfService = .utility
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [weak inbox] _ in inbox?.finish("肩部进程已退出，请重新开始。") }
        output.fileHandleForReading.readabilityHandler = { [weak inbox] handle in inbox?.append(handle.availableData) }
    }

    func start() throws {
        cancellationLock.lock()
        guard !cancelled else { cancellationLock.unlock(); throw workerError("肩部启动已取消。") }
        do { try process.run(); cancellationLock.unlock() }
        catch { cancellationLock.unlock(); throw error }
        let readyData = try inbox.next(timeout: 15)
        let ready = try JSONSerialization.jsonObject(with: readyData) as? [String: Any]
        guard ready?["ready"] as? Bool == true, ready?["version"] as? String == config.packageVersion else {
            throw workerError(ready?["error"] as? String ?? "肩部后端版本或启动状态不一致。")
        }
    }

    func detect(_ buffer: CVPixelBuffer, timestamp: Double) throws -> [[PoseLandmark]] {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let timestampMS = Int64((timestamp * 1000).rounded())
        let header: [String: Any] = ["width": width, "height": height, "rowBytes": rowBytes, "timestampMS": timestampMS]
        var request = try JSONSerialization.data(withJSONObject: header)
        request.append(10)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard let address = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly); throw workerError("无法读取帧缓冲区。")
        }
        request.append(Data(bytes: address, count: rowBytes * height))
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        try input.fileHandleForWriting.write(contentsOf: request)
        struct Response: Decodable { let timestampMS: Int64?; let poses: [[PoseLandmark]]?; let error: String? }
        let response = try JSONDecoder().decode(Response.self, from: inbox.next(timeout: 2))
        if let error = response.error { throw workerError(error) }
        guard response.timestampMS == timestampMS, let poses = response.poses,
              poses.count <= 2, poses.allSatisfy({ $0.count == 33 }) else { throw workerError("肩部响应与当前帧不匹配。") }
        return poses
    }

    func cancel() {
        cancellationLock.lock()
        if cancelled { cancellationLock.unlock(); return }
        cancelled = true
        inbox.finish("肩部分析已暂停。")
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        cancellationLock.unlock()
    }
    deinit { cancel() }
}
