import Foundation

public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public var isInFrame: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}

public struct ImageSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
}

public struct FaceBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var center: Point { Point(x + width / 2, y + height / 2) }
    public func contains(_ point: Point, expansion: Double = 0) -> Bool {
        (x - width * expansion ... x + width * (1 + expansion)).contains(point.x)
            && (y - height * expansion ... y + height * (1 + expansion)).contains(point.y)
    }
    public var hasMargin: Bool {
        x >= 0.01 && y >= 0.01 && width > 0 && height > 0
            && x + width <= 0.99 && y + height <= 0.99
    }
}

public enum Joint: String, Codable, CaseIterable, Sendable {
    case nose, neck, leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case leftEye, rightEye, leftEar, rightEar
    public var label: String {
        switch self {
        case .leftShoulder: return "左肩"
        case .rightShoulder: return "右肩"
        case .neck: return "颈"
        case .nose: return "鼻"
        case .leftElbow: return "左肘"
        case .rightElbow: return "右肘"
        case .leftWrist: return "左腕"
        case .rightWrist: return "右腕"
        case .leftEye: return "左眼"
        case .rightEye: return "右眼"
        case .leftEar: return "左耳"
        case .rightEar: return "右耳"
        }
    }
}

public struct JointPoint: Codable, Equatable, Sendable {
    public var location: Point
    public var confidence: Double
    public init(_ location: Point, confidence: Double) { self.location = location; self.confidence = confidence }
    public var isReliable: Bool {
        confidence.isFinite && confidence >= 0.6 && location.isInFrame
            && (0.02...0.98).contains(location.x) && (0.02...0.98).contains(location.y)
    }
}

public struct Observation: Sendable {
    public var timestamp: Double
    public var imageSize: ImageSize
    public var cameraSignature: String
    public var faceCount: Int
    public var bodyCount: Int
    public var faceBox: FaceBox?
    public var faceConfidence: Double
    // Native Vision angles converted to degrees; nil stays nil.
    public var roll: Double?
    public var yaw: Double?
    public var pitch: Double?
    public var joints: [Joint: JointPoint]
    public var faceLandmarks: [Point]
    public var bodyFailureReason: String?
    public var oral: OralObservation?
    public init(timestamp: Double, imageSize: ImageSize, cameraSignature: String,
                faceCount: Int, bodyCount: Int, faceBox: FaceBox?, faceConfidence: Double,
                roll: Double?, yaw: Double?, pitch: Double?, joints: [Joint: JointPoint], faceLandmarks: [Point] = [],
                bodyFailureReason: String? = nil, oral: OralObservation? = nil) {
        self.timestamp = timestamp; self.imageSize = imageSize; self.cameraSignature = cameraSignature
        self.faceCount = faceCount; self.bodyCount = bodyCount; self.faceBox = faceBox
        self.faceConfidence = faceConfidence; self.roll = roll; self.yaw = yaw; self.pitch = pitch
        self.joints = joints
        self.faceLandmarks = faceLandmarks
        self.bodyFailureReason = bodyFailureReason
        self.oral = oral
    }
}

public struct Metrics: Sendable {
    public var roll: Double?
    public var yaw: Double?
    public var pitch: Double?
    public var shoulderAngle: Double?
    public var faceReason: String
    public var shoulderReason: String
    public var faceUsable: Bool { roll != nil }
    public var shouldersUsable: Bool { shoulderAngle != nil }
}

public enum Geometry {
    public static func wrapDegrees(_ value: Double, period: Double = 360) -> Double {
        let remainder = (value + period / 2).truncatingRemainder(dividingBy: period)
        return (remainder < 0 ? remainder + period : remainder) - period / 2
    }
    public static func lineAngle(from first: Point, to second: Point, imageSize: ImageSize) -> Double {
        let angle = atan2((second.y - first.y) * imageSize.height,
                          (second.x - first.x) * imageSize.width) * 180 / .pi
        return wrapDegrees(angle, period: 180)
    }
    // Shared fit transform keeps preview and overlays aligned, including letterboxing.
    public static func previewPoint(_ point: Point, source: ImageSize, viewport: ImageSize,
                                    mirrored: Bool) -> Point {
        let scale = min(viewport.width / source.width, viewport.height / source.height)
        let width = source.width * scale, height = source.height * scale
        return Point((viewport.width - width) / 2 + (mirrored ? 1 - point.x : point.x) * width,
                     (viewport.height - height) / 2 + (1 - point.y) * height)
    }
}

public enum QualityGate {
    public static func evaluate(_ observation: Observation) -> Metrics {
        var result = Metrics(roll: nil, yaw: nil, pitch: nil, shoulderAngle: nil,
                             faceReason: "未识别到脸部", shoulderReason: "未识别到双肩")
        guard observation.faceCount <= 1, observation.bodyCount <= 1 else {
            result.faceReason = "画面有多个目标，暂停判定"
            result.shoulderReason = result.faceReason
            return result
        }
        guard observation.imageSize.width > 0, observation.imageSize.height > 0 else {
            result.faceReason = "画面尺寸无效"; result.shoulderReason = result.faceReason
            return result
        }
        if observation.faceCount == 1, let box = observation.faceBox {
            if !box.hasMargin {
                result.faceReason = "脸部靠近边缘或被裁切"
            } else if box.width * observation.imageSize.width < 80 {
                result.faceReason = "脸部在画面中过小"
            } else if !observation.faceConfidence.isFinite || observation.faceConfidence < 0.6 {
                result.faceReason = "脸部置信度不足"
            } else if let roll = observation.roll, roll.isFinite {
                result.roll = roll
                result.yaw = observation.yaw.flatMap { $0.isFinite ? $0 : nil }
                result.pitch = observation.pitch.flatMap { $0.isFinite ? $0 : nil }
                result.faceReason = "脸部可判定"
            } else {
                result.faceReason = "脸部角度暂不可用"
            }
        }
        if let failure = observation.bodyFailureReason { result.shoulderReason = failure; return result }
        guard observation.bodyCount == 1 else { return result }
        guard let left = observation.joints[.leftShoulder] else {
            result.shoulderReason = "左肩关键点未识别"; return result
        }
        guard let right = observation.joints[.rightShoulder] else {
            result.shoulderReason = "右肩关键点未识别"; return result
        }
        for (point, label) in [(left, "左肩"), (right, "右肩")] {
            if !point.confidence.isFinite || point.confidence < 0.6 {
                result.shoulderReason = "\(label)点置信度不足"; return result
            }
            if !point.isReliable {
                result.shoulderReason = "\(label)靠近画面边缘或被裁切"; return result
            }
        }
        let shoulderWidth = abs(left.location.x - right.location.x)
        guard shoulderWidth * observation.imageSize.width >= 120 else {
            result.shoulderReason = "双肩间距过小，暂不判定"; return result
        }
        guard result.faceUsable, let face = observation.faceBox else {
            result.shoulderReason = "需看清脸部以确认肩部目标"; return result
        }
        // MediaPipe has no neck point; use reliable eye/ear anchors if the nose is occluded.
        let faceAnchorMatches = [Joint.nose, .leftEye, .rightEye, .leftEar, .rightEar].contains {
            observation.joints[$0].map { $0.isReliable && face.contains($0.location, expansion: 0.35) } ?? false
        }
        let neckMatches = observation.joints[.neck].map {
            $0.isReliable && abs($0.location.x - face.center.x) < shoulderWidth * 0.45
                && $0.location.y <= face.center.y && $0.location.y > face.y - face.height
        } ?? false
        guard faceAnchorMatches || neckMatches else {
            result.shoulderReason = "脸部与肩部目标暂未关联"; return result
        }
        if let yaw = result.yaw, abs(yaw) > 35 {
            result.shoulderReason = "侧转角度较大，肩线暂不判定"; return result
        }
        result.shoulderAngle = Geometry.lineAngle(from: left.location, to: right.location, imageSize: observation.imageSize)
        result.shoulderReason = "双肩可判定"
        return result
    }
}
