import Vision
import CoreML
import PostureCore

enum VisionCompute {
    static func name(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .neuralEngine: return "Neural Engine"
        @unknown default: return "system device"
        }
    }
    static func configure(_ requests: [VNRequest], preference: ComputePreference) {
        for request in requests {
            guard let stages = try? request.supportedComputeStageDevices else { continue }
            for (stage, devices) in stages {
                let selected = devices.first { name($0) == preference.deviceName }
                // Unsupported preferences fall back to Apple's automatic choice.
                request.setComputeDevice(preference == .automatic ? nil : selected, for: stage)
            }
        }
    }
    static func report() -> [String: [String]] {
        let requests: [VNRequest] = [VNDetectFaceRectanglesRequest(), VNDetectFaceLandmarksRequest(), VNDetectHumanHandPoseRequest()]
        return Dictionary(uniqueKeysWithValues: requests.map { r in
            (String(describing: type(of: r)), Array(Set(((try? r.supportedComputeStageDevices) ?? [:]).values.flatMap { $0 }.map(name))).sorted())
        })
    }
}
