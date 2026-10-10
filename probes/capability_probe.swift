// Read-only capability inventory. No camera session or permission request is made.
// --smoke additionally runs Vision on a generated blank image, never camera input.
import Foundation
import AVFoundation
import AppKit
import Vision
import CoreGraphics
import CoreMedia

func permissionName(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
}

func cameraInventory() -> [[String: Any]] {
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
        position: .unspecified)
    return discovery.devices.map { device in
        var formats: [String: [String: Any]] = [:]
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let key = "\(dimensions.width)x\(dimensions.height)"
            let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            if let previous = formats[key], (previous["maximumFPS"] as? Double ?? 0) >= maxFPS {
                continue
            }
            formats[key] = [
                "width": dimensions.width, "height": dimensions.height,
                "maximumFPS": maxFPS,
                "frameRateRanges": format.videoSupportedFrameRateRanges.map {
                    ["minimumFPS": $0.minFrameRate, "maximumFPS": $0.maxFrameRate]
                }
            ]
        }
        return [
            "name": device.localizedName,
            "deviceType": device.deviceType.rawValue,
            "connected": device.isConnected,
            "suspended": device.isSuspended,
            "formats": formats.values.sorted {
                let area0 = ($0["width"] as? Int32 ?? 0) * ($0["height"] as? Int32 ?? 0)
                let area1 = ($1["width"] as? Int32 ?? 0) * ($1["height"] as? Int32 ?? 0)
                if area0 != area1 { return area0 < area1 }
                return ($0["width"] as? Int32 ?? 0) < ($1["width"] as? Int32 ?? 0)
            }
        ]
    }
}

func displayInventory() -> [[String: Any]] {
    _ = NSApplication.shared
    return NSScreen.screens.map { screen in
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return [
            "name": screen.localizedName,
            "isBuiltIn": CGDisplayIsBuiltin(displayID) != 0,
            "isMainDisplay": displayID == CGMainDisplayID(),
            "framePoints": ["x": screen.frame.minX, "y": screen.frame.minY,
                            "width": screen.frame.width, "height": screen.frame.height],
            "scaleFactor": screen.backingScaleFactor
        ]
    }
}

func blankImage() throws -> CGImage {
    let context = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8,
                            bytesPerRow: 1280 * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    guard let context else { throw NSError(domain: "CapabilityProbe", code: 1) }
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
    guard let image = context.makeImage() else { throw NSError(domain: "CapabilityProbe", code: 2) }
    return image
}

func smokeTest() throws -> [String: Any] {
    let image = try blankImage()
    let requests: [(String, VNImageBasedRequest)] = [
        ("faceRectangles", VNDetectFaceRectanglesRequest()),
        ("faceLandmarks", VNDetectFaceLandmarksRequest()),
        ("bodyPose2D", VNDetectHumanBodyPoseRequest()),
        ("handPose", VNDetectHumanHandPoseRequest())
    ]
    var results: [[String: Any]] = []
    for (name, request) in requests {
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            results.append(["request": name, "completed": true,
                            "revision": request.revision,
                            "observationCount": request.results?.count ?? 0])
        } catch {
            results.append(["request": name, "completed": false,
                            "error": error.localizedDescription])
        }
    }
    return [
        "input": "generated blank 1280x720 image; not a person or camera frame",
        "interpretation": "runtime compatibility only; no accuracy or realistic performance claim",
        "requests": results
    ]
}

do {
    let arguments = Set(CommandLine.arguments.dropFirst())
    guard arguments.isSubset(of: ["--smoke"]) else {
        fputs("Usage: capability-probe [--smoke]\n", stderr)
        exit(2)
    }
    let body = VNDetectHumanBodyPoseRequest()
    let hand = VNDetectHumanHandPoseRequest()
    var report: [String: Any] = [
        "schemaVersion": 1,
        "generatedAtUTC": ISO8601DateFormatter().string(from: Date()),
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "cameraPermission": permissionName(AVCaptureDevice.authorizationStatus(for: .video)),
        "cameraSessionStarted": false,
        "permissionRequested": false,
        "builtInCameras": cameraInventory(),
        "screens": displayInventory(),
        "vision": [
            "bodyJointNames": try body.supportedJointNames.map { $0.rawValue.rawValue }.sorted(),
            "handJointNames": try hand.supportedJointNames.map { $0.rawValue.rawValue }.sorted(),
            "faceRectangleSupportedRevisions": Array(VNDetectFaceRectanglesRequest.supportedRevisions),
            "faceLandmarkSupportedRevisions": Array(VNDetectFaceLandmarksRequest.supportedRevisions),
            "bodyPoseSupportedRevisions": Array(VNDetectHumanBodyPoseRequest.supportedRevisions),
            "handPoseSupportedRevisions": Array(VNDetectHumanHandPoseRequest.supportedRevisions)
        ]
    ]
    if arguments.contains("--smoke") { report["smokeTest"] = try smokeTest() }
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    if let smoke = report["smokeTest"] as? [String: Any],
       let requests = smoke["requests"] as? [[String: Any]],
       requests.contains(where: { ($0["completed"] as? Bool) != true }) {
        exit(1)
    }
} catch {
    fputs("Capability probe failed: \(error)\n", stderr)
    exit(1)
}
