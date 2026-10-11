import Foundation
import Vision
import ImageIO
import PostureCore

// Explicit, local-only still-image inspection. This path never opens the camera or archives pixels/landmarks.
@MainActor
enum ImageSampleChecks {
    static func run(paths: [String]) {
        do {
            guard !paths.isEmpty else { throw NSError(domain: "ImageSampleChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "--image-check requires image paths"]) }
            var rows: [[String: Any]] = []
            for path in paths {
                let url = URL(fileURLWithPath: path)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    rows.append(["file": url.lastPathComponent, "error": "image unavailable"]); continue
                }
                let detector = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
                try handler.perform([detector])
                let faces = detector.results ?? []
                guard faces.count == 1, let face = faces.first else {
                    rows.append(["file": url.lastPathComponent, "faceCount": faces.count, "error": "requires one clear face"]); continue
                }
                let landmarks = VNDetectFaceLandmarksRequest()
                landmarks.inputFaceObservations = [face]
                try handler.perform([landmarks])
                guard let detail = landmarks.results?.first?.landmarks else {
                    rows.append(["file": url.lastPathComponent, "error": "landmarks unavailable"]); continue
                }
                let box = face.boundingBox
                func region(_ r: VNFaceLandmarkRegion2D?) -> [Point] {
                    guard let r else { return [] }
                    return (0..<r.pointCount).map { let p = r.normalizedPoints[$0]
                        return Point(Double(box.minX + CGFloat(p.x) * box.width), Double(box.minY + CGFloat(p.y) * box.height))
                    }
                }
                guard let features = FacialGeometry.features(outer: region(detail.outerLips), inner: region(detail.innerLips),
                    leftEye: region(detail.leftEye), rightEye: region(detail.rightEye), nose: region(detail.nose),
                    image: ImageSize(Double(image.width), Double(image.height))) else {
                    rows.append(["file": url.lastPathComponent, "error": "mouth geometry unavailable"]); continue
                }
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(features))
                rows.append(["file": url.lastPathComponent, "features": object,
                             "yawDegrees": (face.yaw?.doubleValue ?? 0) * 180 / .pi,
                             "pitchDegrees": (face.pitch?.doubleValue ?? 0) * 180 / .pi])
            }
            let output: [String: Any] = ["localOnly": true, "imagesSaved": false, "landmarkCoordinatesSaved": false,
                "warning": "Screenshots contain painted landmark/skeleton overlays; these can bias re-detected features. Positive examples without comfortable negative samples cannot validate classification or hidden tooth contact.",
                "samples": rows]
            print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
            exit(0)
        } catch { fputs("Image sample check failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
