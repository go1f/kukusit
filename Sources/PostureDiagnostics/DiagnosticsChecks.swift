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
            precondition(!MonitorSettings().mirrored && !restored.mirrored)
            let mirroredPreference = try JSONDecoder().decode(MonitorSettings.self, from: Data(#"{"mirrored":true}"#.utf8))
            precondition(mirroredPreference.mirrored)
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
    static func oralStore() {
        let signature = "synthetic-demo"
        func feed(_ store: OralSampleStore, _ times: [Double], valid: Bool = true, scenario: DemoScenario = .clear) {
            for time in times {
                var observation = DemoFrame.packet(scenario: scenario, timestamp: time).observation
                if !valid { observation.faceCount = 0; observation.faceConfidence = 0 }
                store.consume(observation, metrics: QualityGate.evaluate(observation))
            }
        }
        let continuous = OralSampleStore(persistent: false)
        continuous.begin(context: .upperMonitor, signature: signature, action: nil, label: "natural", at: 0)
        feed(continuous, (0...17).map { Double($0) / 6 })
        precondition(continuous.tick(at: 3))
        precondition(continuous.library(context: .upperMonitor, signature: signature)?.hasNeutralReference == true)
        let interrupted = OralSampleStore(persistent: false)
        interrupted.begin(context: .upperMonitor, signature: signature, action: nil, label: "natural", at: 0)
        feed(interrupted, (0...7).map { Double($0) / 6 })
        feed(interrupted, [1.3], valid: false)
        feed(interrupted, (0...8).map { 1.5 + Double($0) / 6 })
        precondition(interrupted.tick(at: 3))
        precondition(interrupted.libraries.isEmpty)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("kukusit-store-check-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let url = temporary.appendingPathComponent("oral-examples-v1.json")
            let store = OralSampleStore(persistent: true, archiveURL: url)
            store.begin(context: .upperMonitor, signature: signature, action: nil, label: "natural", at: 0)
            feed(store, (0...17).map { Double($0) / 6 }); precondition(store.tick(at: 3))
            store.begin(context: .upperMonitor, signature: signature, action: .lowerLip, label: "synthetic lower lip", at: 4)
            feed(store, (0...17).map { 4 + Double($0) / 6 }, scenario: .lipChange)
            precondition(store.tick(at: 7))
            precondition(store.library(context: .upperMonitor, signature: signature)?.sampleCount(for: .lowerLip) ?? 0 >= 6)
            precondition(FileManager.default.fileExists(atPath: url.path))
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            precondition(permissions?.intValue == 0o600)
            let copy = OralSampleStore(persistent: true, archiveURL: url)
            precondition(copy.libraries == store.libraries)
            let blocker = temporary.appendingPathComponent("not-a-directory")
            try Data().write(to: blocker)
            let unavailable = OralSampleStore(persistent: true, archiveURL: blocker.appendingPathComponent("samples.json"))
            unavailable.begin(context: .upperMonitor, signature: signature, action: nil, label: "natural", at: 0)
            feed(unavailable, (0...17).map { Double($0) / 6 }); precondition(unavailable.tick(at: 3))
            precondition(unavailable.libraries.isEmpty && unavailable.message.hasPrefix("保存示范失败"))
            print("{\"passed\":true,\"input\":\"synthetic observations; no camera or personal data\",\"checks\":[\"continuous coverage\",\"interrupted segments rejected\",\"private persistence roundtrip\",\"storage failure rolls back\"]}")
            exit(0)
        } catch { fputs("Oral store check failed: \(error)\n", stderr); exit(1) }
    }
}
