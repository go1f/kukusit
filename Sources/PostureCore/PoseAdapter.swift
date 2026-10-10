import Foundation

public struct PoseLandmark: Codable, Sendable {
    public let x: Double
    public let y: Double
    public let confidence: Double
    public init(x: Double, y: Double, confidence: Double) { self.x = x; self.y = y; self.confidence = confidence }
}

public enum PoseAdapter {
    // MediaPipe uses a top-left origin. Core/Vision use a bottom-left origin.
    public static func joints(from landmarks: [PoseLandmark]) -> [Joint: JointPoint] {
        guard landmarks.count == 33 else { return [:] }
        let indices: [(Joint, Int)] = [(.nose, 0), (.leftEye, 2), (.rightEye, 5), (.leftEar, 7), (.rightEar, 8),
                                       (.leftShoulder, 11), (.rightShoulder, 12), (.leftElbow, 13), (.rightElbow, 14),
                                       (.leftWrist, 15), (.rightWrist, 16)]
        return Dictionary(uniqueKeysWithValues: indices.map { name, index in
            let point = landmarks[index]
            return (name, JointPoint(Point(point.x, 1 - point.y), confidence: point.confidence))
        })
    }
}
