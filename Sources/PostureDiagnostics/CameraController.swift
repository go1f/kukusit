import Foundation
import AVFoundation
import Vision
import CoreImage
import CryptoKit
import PostureCore

enum CameraStatus: Equatable {
    case idle, requestingPermission, starting, running, paused(String), denied, failed(String)
    var title: String {
        switch self {
        case .idle: return "未开始"
        case .requestingPermission: return "等待摄像头授权"
        case .starting: return "正在启动内置摄像头"
        case .running: return "正在观察"
        case .paused: return "已暂停"
        case .denied: return "摄像头权限未开启"
        case .failed: return "摄像头不可用"
        }
    }
    var detail: String {
        switch self {
        case .idle: return "点击开始后，仅使用 MacBook 内置摄像头。"
        case .requestingPermission: return "请在 macOS 权限提示中选择是否允许本应用使用摄像头。"
        case .starting: return "配置 720p 采集与约 6 Hz 的视觉分析。"
        case .running: return "图像仅在本机处理；持续偏离且识别稳定时才轻量提醒。"
        case .paused(let reason), .failed(let reason): return reason
        case .denied: return "在系统设置 → 隐私与安全性 → 摄像头中开启“坐姿诊断”，然后重新开始。"
        }
    }
    var isActive: Bool {
        self == .running || self == .starting || self == .requestingPermission
    }
}

struct AnalysisPacket {
    let generation: Int
    let observation: Observation
    let image: CGImage?
    let inferenceMilliseconds: Double
    let cameraName: String
    let bodyBackendName: String
    init(generation: Int, observation: Observation, image: CGImage?, inferenceMilliseconds: Double,
         cameraName: String, bodyBackendName: String = "Apple Vision") {
        self.generation = generation; self.observation = observation; self.image = image
        self.inferenceMilliseconds = inferenceMilliseconds; self.cameraName = cameraName
        self.bodyBackendName = bodyBackendName
    }
}

// At most one main-thread delivery is queued. New results replace pending ones.
private final class LatestMainDelivery<Value> {
    private let lock = NSLock()
    private var pending: Value?
    private var scheduled = false
    var handler: ((Value) -> Void)?
    func submit(_ value: Value) {
        lock.lock()
        pending = value
        let enqueue = !scheduled
        scheduled = true
        lock.unlock()
        if enqueue { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        lock.lock()
        let value = pending
        pending = nil; scheduled = false
        lock.unlock()
        if let value { handler?(value) }
    }
}

final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onStatus: ((CameraStatus) -> Void)?
    var onFrame: ((AnalysisPacket) -> Void)?
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "posture.capture.session")
    private let analysisQueue = DispatchQueue(label: "posture.capture.analysis", qos: .userInitiated)
    private let lifecycleLock = NSLock()
    private var generation = 0
    private var desiredRunning = false
    private var capturing = false
    private var needsPreviewImage = false
    private var needsFaceLandmarks = false
    private var selectedBackend: BodyBackend = .appleVision
    private var poseWorker: PoseWorker?
    private var configured = false
    private var deviceName = "内置摄像头"
    private var deviceHash = ""
    private var observations: [NSObjectProtocol] = []
    private let delivery = LatestMainDelivery<AnalysisPacket>()
    // These fields are accessed only on analysisQueue.
    private var analysisGeneration = -1
    private var scheduler = AnalysisScheduler()
    private var analysisBodyFailure: String?
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let landmarksRequest = VNDetectFaceLandmarksRequest()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    override init() {
        super.init()
        delivery.handler = { [weak self] packet in
            guard let self, self.isCurrent(packet.generation, requireCapturing: true) else { return }
            self.onFrame?(packet)
        }
        observations.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.halt(.failed(error?.localizedDescription ?? "采集发生错误，请重新开始。"))
        })
        observations.append(NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { [weak self] _ in self?.halt(.paused("摄像头采集被系统中断，请重新开始。")) })
        observations.append(NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice,
                  device.deviceType == .builtInWideAngleCamera else { return }
            self?.halt(.failed("内置摄像头已断开，请重新开始。"))
        })
    }

    deinit { observations.forEach(NotificationCenter.default.removeObserver) }

    func start(backend: BodyBackend = .appleVision) {
        lifecycleLock.lock()
        generation += 1
        let token = generation
        desiredRunning = true; capturing = false
        selectedBackend = backend
        let oldWorker = poseWorker; poseWorker = nil
        lifecycleLock.unlock()
        oldWorker?.cancel()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: launch(token)
        case .notDetermined:
            emit(.requestingPermission, token: token)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                guard let self, self.isCurrent(token) else { return }
                if allowed { self.launch(token) }
                else { self.fail(.denied, token: token) }
            }
        case .denied, .restricted: fail(.denied, token: token)
        @unknown default: fail(.failed("无法读取摄像头权限状态。"), token: token)
        }
    }

    func stop(reason: String = "已停止摄像头采集。") { halt(.paused(reason)) }

    func setRendering(image: Bool, faceLandmarks: Bool) {
        lifecycleLock.lock()
        needsPreviewImage = image; needsFaceLandmarks = faceLandmarks
        lifecycleLock.unlock()
    }

    func shutdown() {
        lifecycleLock.lock(); generation += 1; desiredRunning = false; capturing = false
        let worker = poseWorker; poseWorker = nil
        lifecycleLock.unlock()
        worker?.cancel()
        sessionQueue.sync { if session.isRunning { session.stopRunning() } }
    }

    private func snapshot() -> (Int, Bool, BodyBackend) {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return (generation, desiredRunning && capturing, selectedBackend)
    }
    private func isCurrent(_ token: Int, requireCapturing: Bool = false) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return generation == token && desiredRunning && (!requireCapturing || capturing)
    }
    private func emit(_ status: CameraStatus, token: Int, allowStopped: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lifecycleLock.lock()
            let current = self.generation == token && (allowStopped || self.desiredRunning)
            self.lifecycleLock.unlock()
            if current { self.onStatus?(status) }
        }
    }
    private func fail(_ status: CameraStatus, token: Int) {
        lifecycleLock.lock()
        guard generation == token else { lifecycleLock.unlock(); return }
        desiredRunning = false; capturing = false
        lifecycleLock.unlock()
        emit(status, token: token, allowStopped: true)
    }
    private func halt(_ status: CameraStatus) {
        lifecycleLock.lock()
        generation += 1
        let token = generation
        desiredRunning = false; capturing = false
        let worker = poseWorker; poseWorker = nil
        lifecycleLock.unlock()
        worker?.cancel()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            // Reconfigure on every resume, including after a disconnect/reset.
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
            self.configured = false
        }
        emit(status, token: token, allowStopped: true)
    }

    private func launch(_ token: Int) {
        emit(.starting, token: token)
        sessionQueue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            do {
                if !self.configured { try self.configure() }
                guard self.isCurrent(token) else { return }
                self.session.startRunning()
                self.lifecycleLock.lock()
                let current = self.generation == token && self.desiredRunning
                if current { self.capturing = self.session.isRunning }
                self.lifecycleLock.unlock()
                if current {
                    if self.session.isRunning { self.emit(.running, token: token) }
                    else { self.fail(.failed("摄像头未能送出画面，请检查系统权限或其它摄像头应用。"), token: token) }
                } else if self.session.isRunning { self.session.stopRunning() }
            } catch { self.fail(.failed(error.localizedDescription), token: token) }
        }
    }

    private func configure() throws {
        let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                       mediaType: .video, position: .unspecified).devices
        guard let device = cameras.first(where: { $0.isConnected && !$0.isSuspended }) else {
            throw NSError(domain: "PostureCamera", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "未找到可用的 MacBook 内置摄像头。请保持笔记本敞开。"])
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        let preferredFormat = device.formats.first { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == 1280 && dimensions.height == 720
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }
        }
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw captureError("不能连接内置摄像头。") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        var outputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if preferredFormat != nil {
            outputSettings[kCVPixelBufferWidthKey as String] = 1280
            outputSettings[kCVPixelBufferHeightKey as String] = 720
        }
        output.videoSettings = outputSettings
        output.setSampleBufferDelegate(self, queue: analysisQueue)
        guard session.canAddOutput(output) else { throw captureError("不能创建视频输出。") }
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if let preferredFormat { device.activeFormat = preferredFormat }
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
        }
        lifecycleLock.lock()
        deviceName = device.localizedName
        deviceHash = SHA256.hash(data: Data(device.uniqueID.utf8)).map { String(format: "%02x", $0) }.joined()
        lifecycleLock.unlock()
        configured = true
    }
    private func captureError(_ message: String) -> NSError {
        NSError(domain: "PostureCamera", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let (token, active, backend) = snapshot()
        guard active, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if analysisGeneration != token { analysisGeneration = token; scheduler.reset(); analysisBodyFailure = nil }
        guard scheduler.shouldProcess(at: now) else { return }
        lifecycleLock.lock()
        let capturedDeviceName = deviceName, capturedDeviceHash = deviceHash
        let renderImage = needsPreviewImage, renderFaceLandmarks = needsFaceLandmarks
        lifecycleLock.unlock()
        autoreleasepool {
            do {
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
                let requests: [VNRequest] = backend == .appleVision ? [faceRequest, bodyRequest] : [faceRequest]
                try handler.perform(requests)
                let faces = faceRequest.results ?? []
                let bodies = backend == .appleVision ? bodyRequest.results ?? [] : []
                let face = faces.count == 1 ? faces[0] : nil
                let body = bodies.count == 1 ? bodies[0] : nil
                var bodyCount = bodies.count
                var bodySignature = "vision\(bodyRequest.revision)"
                var joints: [PostureCore.Joint: JointPoint] = [:]
                let keys: [(PostureCore.Joint, VNHumanBodyPoseObservation.JointName)] = [
                    (.nose, .nose), (.neck, .neck), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
                    (.leftElbow, .leftElbow), (.rightElbow, .rightElbow), (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
                    (.leftEye, .leftEye), (.rightEye, .rightEye), (.leftEar, .leftEar), (.rightEar, .rightEar)
                ]
                if let body {
                    for (name, key) in keys {
                        if let point = try? body.recognizedPoint(key), point.confidence > 0 {
                            joints[name] = JointPoint(Point(point.location.x, point.location.y), confidence: Double(point.confidence))
                        }
                    }
                }
                if backend == .mediaPipe {
                    bodySignature = "mediapipe-unavailable"
                    if analysisBodyFailure == nil {
                        var localWorker: PoseWorker?
                        do {
                            lifecycleLock.lock(); localWorker = poseWorker; lifecycleLock.unlock()
                            if localWorker == nil {
                                let worker = try PoseWorker()
                                localWorker = worker
                                lifecycleLock.lock()
                                let current = generation == token && desiredRunning && capturing
                                if current { poseWorker = worker }
                                lifecycleLock.unlock()
                                guard current else { worker.cancel(); return }
                                try worker.start()
                            }
                            if let worker = localWorker {
                                bodySignature = worker.signature
                                let poses = try worker.detect(buffer, timestamp: now)
                                bodyCount = poses.count
                                if poses.count == 1 { joints = PoseAdapter.joints(from: poses[0]) }
                            }
                        } catch {
                            localWorker?.cancel()
                            guard isCurrent(token, requireCapturing: true) else { return }
                            analysisBodyFailure = "肩部分析暂不可用：\(error.localizedDescription)"
                            lifecycleLock.lock(); poseWorker = nil; lifecycleLock.unlock()
                        }
                    }
                }
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                let box = face.map { FaceBox(x: $0.boundingBox.minX, y: $0.boundingBox.minY,
                                             width: $0.boundingBox.width, height: $0.boundingBox.height) }
                var facePoints: [Point] = []
                if renderFaceLandmarks, let face, let box {
                    landmarksRequest.inputFaceObservations = [face]
                    try handler.perform([landmarksRequest])
                    if let region = landmarksRequest.results?.first?.landmarks?.allPoints {
                        facePoints = (0..<region.pointCount).map {
                            let point = region.normalizedPoints[$0]
                            return Point(box.x + point.x * box.width, box.y + point.y * box.height)
                        }
                    }
                }
                let signature = "\(capturedDeviceHash)|\(width)x\(height)|up|face\(faceRequest.revision)|\(bodySignature)"
                let observation = Observation(timestamp: now, imageSize: ImageSize(Double(width), Double(height)),
                                              cameraSignature: signature, faceCount: faces.count, bodyCount: bodyCount,
                                              faceBox: box, faceConfidence: Double(face?.confidence ?? 0),
                                              roll: face?.roll.map { $0.doubleValue * 180 / .pi },
                                              yaw: face?.yaw.map { $0.doubleValue * 180 / .pi },
                                              pitch: face?.pitch.map { $0.doubleValue * 180 / .pi }, joints: joints,
                                              faceLandmarks: facePoints, bodyFailureReason: analysisBodyFailure)
                let image = renderImage ? ciContext.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: width, height: height)) : nil
                guard isCurrent(token, requireCapturing: true) else { return }
                delivery.submit(AnalysisPacket(generation: token, observation: observation, image: image,
                                               inferenceMilliseconds: (ProcessInfo.processInfo.systemUptime - now) * 1000,
                                               cameraName: capturedDeviceName, bodyBackendName: backend.label))
            } catch {
                // Stop rather than showing a previous successful observation as current.
                if isCurrent(token, requireCapturing: true) {
                    halt(.failed("视觉分析失败：\(error.localizedDescription)"))
                }
            }
        }
    }
}
