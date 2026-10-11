import Foundation
import CoreVideo
import Vision
import PostureCore

@MainActor
enum DiagnosticsChecks {
    static func settings() {
        do {
            let legacy = Data(#"{"sustainedSeconds":25,"cooldownSeconds":180,"pipOnTop":false,"pipSize":"large","pipScreenID":"office","resumeOnLaunch":false}"#.utf8)
            let restored = try JSONDecoder().decode(MonitorSettings.self, from: legacy)
            precondition(restored.tuning.sustainedSeconds == 5 && restored.tuning.headEnterDegrees == 3)
            precondition(!restored.pipOnTop && restored.pipSize == .large && restored.pipScreenID == "office" && !restored.resumeOnLaunch)
            var customized = restored
            customized.tuning.sustainedSeconds = 1.5; customized.tuning.headEnterDegrees = 2
            customized.tuning.computePreference = .neuralEngine; customized.bodyBackend = .appleVision
            let copy = try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(customized))
            precondition(copy == customized)
            print("{\"passed\":true,\"checks\":[\"legacy window preferences retained\",\"new 5s/3deg default\",\"tuning and backend roundtrip\"]}")
            exit(0)
        } catch { fputs("Settings check failed: \(error)\n", stderr); exit(1) }
    }
    static func pipeline() {
        do {
            var source: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
                                            attributes as CFDictionary, &source) == kCVReturnSuccess)
            guard let source else { fatalError("buffer") }
            CVPixelBufferLockBaseAddress(source, [])
            let bytes = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(source)
            for y in 0..<720 { for x in 0..<1280 {
                let p = y * stride + x * 4
                bytes[p] = y < 360 ? 0 : 255; bytes[p+1] = 0; bytes[p+2] = y < 360 ? 255 : 0; bytes[p+3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(source, [])
            let camera = CameraController()
            let resized = try camera.reducedBodyBuffer(source)
            precondition(CVPixelBufferGetWidth(resized) == 640 && CVPixelBufferGetHeight(resized) == 360)
            CVPixelBufferLockBaseAddress(resized, .readOnly)
            let reduced = CVPixelBufferGetBaseAddress(resized)!.assumingMemoryBound(to: UInt8.self)
            let reducedStride = CVPixelBufferGetBytesPerRow(resized)
            precondition(reduced[20 * reducedStride + 20 * 4 + 2] > 240)
            precondition(reduced[340 * reducedStride + 20 * 4] > 240)
            CVPixelBufferUnlockBaseAddress(resized, .readOnly)
            camera.shutdown()
            let blankAttributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            var blank: CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA,
                                            blankAttributes as CFDictionary, &blank) == kCVReturnSuccess)
            let image = blank!
            CVPixelBufferLockBaseAddress(image, [])
            memset(CVPixelBufferGetBaseAddress(image), 0, CVPixelBufferGetBytesPerRow(image) * 360)
            CVPixelBufferUnlockBaseAddress(image, [])
            var timings: [String: Double] = [:]
            for preference in ComputePreference.allCases {
                let requests: [VNRequest] = [VNDetectFaceRectanglesRequest(), VNDetectFaceLandmarksRequest(), VNDetectHumanHandPoseRequest()]
                VisionCompute.configure(requests, preference: preference)
                let begin = ProcessInfo.processInfo.systemUptime
                try VNImageRequestHandler(cvPixelBuffer: image, orientation: .up).perform(requests)
                timings[preference.rawValue] = (ProcessInfo.processInfo.systemUptime - begin) * 1000
            }
            let report: [String: Any] = ["passed": true, "input": "synthetic color buffer + blank frames; no camera",
                "bodyBuffer": "640x360, BGRA orientation preserved", "computeCapabilities": VisionCompute.report(),
                "syntheticInferenceMilliseconds": timings]
            print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
            exit(0)
        } catch { fputs("Pipeline check failed: \(error)\n", stderr); exit(1) }
    }
}
