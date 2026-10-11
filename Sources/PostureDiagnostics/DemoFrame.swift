import Foundation
import CoreGraphics
import PostureCore

enum DemoScenario: String, CaseIterable, Identifiable {
    case clear, headTilt, shoulderShift, headAndShoulderTilt, turnedAway, croppedShoulder, multiplePeople, away, handNearMouth, lipChange, eyeChange
    var id: String { rawValue }
    var label: String {
        switch self {
        case .clear: return "脸与双肩"
        case .headTilt: return "持续歪头"
        case .shoulderShift: return "肩线偏移"
        case .headAndShoulderTilt: return "歪头与高低肩叠加"
        case .turnedAway: return "转头"
        case .croppedShoulder: return "肩部出画"
        case .multiplePeople: return "多个目标"
        case .away: return "离座"
        case .handNearMouth: return "手靠近嘴唇（模拟）"
        case .lipChange: return "口唇变化（模拟）"
        case .eyeChange: return "单侧眯眼（模拟）"
        }
    }
}

enum DemoFrame {
    private static let image: CGImage? = {
        guard let context = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8,
                                      bytesPerRow: 1280 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.05, green: 0.075, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        context.setStrokeColor(CGColor(gray: 0.25, alpha: 0.4))
        context.setLineWidth(1)
        for x in stride(from: 0, through: 1280, by: 80) {
            context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: 720))
        }
        for y in stride(from: 0, through: 720, by: 80) {
            context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: 1280, y: y))
        }
        context.strokePath()
        context.setFillColor(CGColor(red: 0.18, green: 0.27, blue: 0.30, alpha: 1))
        context.fillEllipse(in: CGRect(x: 538, y: 447, width: 205, height: 210))
        context.fill(CGRect(x: 600, y: 340, width: 80, height: 130))
        context.move(to: CGPoint(x: 350, y: 40))
        context.addLine(to: CGPoint(x: 360, y: 340))
        context.addQuadCurve(to: CGPoint(x: 920, y: 310), control: CGPoint(x: 640, y: 455))
        context.addLine(to: CGPoint(x: 930, y: 40)); context.closePath(); context.fillPath()
        return context.makeImage()
    }()

    static func packet(scenario: DemoScenario, timestamp: Double) -> AnalysisPacket {
        var joints: [Joint: JointPoint] = [
            .leftShoulder: JointPoint(Point(0.72, 0.43), confidence: 0.94),
            .rightShoulder: JointPoint(Point(0.28, 0.47), confidence: 0.93),
            .neck: JointPoint(Point(0.5, 0.53), confidence: 0.92),
            .nose: JointPoint(Point(0.5, 0.75), confidence: 0.96),
            .leftEye: JointPoint(Point(0.54, 0.81), confidence: 0.9),
            .rightEye: JointPoint(Point(0.46, 0.81), confidence: 0.9),
            .leftElbow: JointPoint(Point(0.77, 0.16), confidence: 0.84),
            .rightElbow: JointPoint(Point(0.23, 0.16), confidence: 0.86)
        ]
        if scenario == .croppedShoulder { joints[.leftShoulder] = JointPoint(Point(1.03, 0.43), confidence: 0.22) }
        if scenario == .shoulderShift || scenario == .headAndShoulderTilt { joints[.leftShoulder] = JointPoint(Point(0.72, 0.29), confidence: 0.94) }
        let facePoints = (0..<28).map { index in
            let angle = Double(index) / 28 * 2 * Double.pi
            return Point(0.5 + cos(angle) * 0.065, 0.77 + sin(angle) * 0.13)
        }
        let mouth = [Point(0.46,0.68), Point(0.48,0.69), Point(0.52,0.69), Point(0.54,0.68), Point(0.52,0.67), Point(0.48,0.67)]
        let oral = OralObservation(features: FacialFeatures(outerLipAspect: scenario == .lipChange ? 0.1 : 0.25,
            mouthOpening: 0.02, mouthShift: 0, cornerSlope: 0, eyelidDifference: scenario == .eyeChange ? 0.4 : 0),
            mouthOutline: mouth, fingerTips: scenario == .handNearMouth ? [JointPoint(Point(0.48,0.69),confidence:0.95)] : [],
            handsObserved: true)
        let observation = Observation(timestamp: timestamp, imageSize: ImageSize(1280, 720), cameraSignature: "synthetic-demo",
                                      faceCount: scenario == .away ? 0 : (scenario == .multiplePeople ? 2 : 1),
                                      bodyCount: scenario == .away ? 0 : (scenario == .multiplePeople ? 2 : 1),
                                      faceBox: FaceBox(x: 0.42, y: 0.62, width: 0.16, height: 0.30),
                                      faceConfidence: 0.98, roll: scenario == .headTilt || scenario == .headAndShoulderTilt ? 8.2 : 3.2,
                                      yaw: scenario == .turnedAway ? 50 : 1.8, pitch: -14.0, joints: joints,
                                      faceLandmarks: facePoints, oral: oral)
        return AnalysisPacket(generation: -1, observation: observation, image: image,
                              inferenceMilliseconds: 0, cameraName: "模拟画面（未启动摄像头）")
    }
    static let calibration: Calibration = {
        var collector = CalibrationCollector(context: .upperMonitor, startedAt: 0, signature: "synthetic-demo")
        for index in 0...120 {
            let frame = packet(scenario: .clear, timestamp: Double(index) / 6).observation
            collector.consume(frame, metrics: QualityGate.evaluate(frame))
        }
        return try! collector.finish(at: 20)
    }()
}
