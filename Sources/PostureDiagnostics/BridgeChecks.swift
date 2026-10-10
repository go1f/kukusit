import Foundation
import CoreVideo

enum BridgeChecks {
    static func run() -> Never {
        do {
            let worker = try PoseWorker()
            defer { worker.cancel() }
            try worker.start()
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else { throw checkError("Cannot allocate synthetic frame") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let address = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(address, 128, CVPixelBufferGetBytesPerRow(pixelBuffer) * 720)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let first = try worker.detect(pixelBuffer, timestamp: 1)
            let second = try worker.detect(pixelBuffer, timestamp: 1.2)
            guard first.isEmpty && second.isEmpty else { throw checkError("Blank image produced a pose") }
            worker.cancel()
            var cancellationRejected = false
            do { _ = try worker.detect(pixelBuffer, timestamp: 1.4) }
            catch { cancellationRejected = true }
            guard cancellationRejected else { throw checkError("Cancelled worker accepted input") }
            print("{\"passed\":true,\"input\":\"two synthetic blank BGRA frames\",\"frameCount\":2,\"poseCount\":0,\"cancellationRejectedFurtherFrames\":true}")
            exit(0)
        } catch {
            fputs("Bridge checks failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    private static func checkError(_ message: String) -> NSError {
        NSError(domain: "BridgeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
