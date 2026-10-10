import SwiftUI
import PostureCore

private let diagnosticTeal = Color.accentColor

struct LandmarkOverlay: View {
    let observation: Observation
    let metrics: Metrics?
    let mirrored: Bool
    var body: some View {
        Canvas { context, size in
            func position(_ point: Point) -> CGPoint {
                let transformed = Geometry.previewPoint(point, source: observation.imageSize,
                                                        viewport: ImageSize(size.width, size.height), mirrored: mirrored)
                return CGPoint(x: transformed.x, y: transformed.y)
            }
            if let box = observation.faceBox {
                let a = position(Point(box.x, box.y)), b = position(Point(box.x + box.width, box.y + box.height))
                let rectangle = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                context.stroke(Path(roundedRect: rectangle, cornerRadius: 7), with: .color(metrics?.faceUsable == true ? diagnosticTeal : .orange), lineWidth: 1.5)
            }
            for point in observation.faceLandmarks where point.isInFrame {
                let location = position(point)
                context.fill(Path(ellipseIn: CGRect(x: location.x - 1.5, y: location.y - 1.5, width: 3, height: 3)), with: .color(.white.opacity(0.7)))
            }
            let connections: [(Joint, Joint)] = [(.leftShoulder, .rightShoulder), (.neck, .leftShoulder), (.neck, .rightShoulder),
                                                (.leftShoulder, .leftElbow), (.rightShoulder, .rightElbow),
                                                (.leftElbow, .leftWrist), (.rightElbow, .rightWrist)]
            for (first, second) in connections {
                guard let a = observation.joints[first], let b = observation.joints[second],
                      a.location.isInFrame, b.location.isInFrame else { continue }
                var path = Path(); path.move(to: position(a.location)); path.addLine(to: position(b.location))
                let valid = a.isReliable && b.isReliable && metrics?.shouldersUsable == true
                context.stroke(path, with: .color(valid ? diagnosticTeal.opacity(0.85) : .orange.opacity(0.7)), lineWidth: 2)
            }
            for joint in Joint.allCases {
                guard let point = observation.joints[joint], point.location.isInFrame else { continue }
                let location = position(point.location)
                context.fill(Path(ellipseIn: CGRect(x: location.x - 4, y: location.y - 4, width: 8, height: 8)),
                             with: .color(point.isReliable ? diagnosticTeal : .orange))
                if joint == .leftShoulder || joint == .rightShoulder {
                    context.draw(Text(joint.label).font(.system(size: 12, weight: .medium)).foregroundColor(.white),
                                 at: CGPoint(x: location.x, y: location.y + 17))
                }
            }
        }.allowsHitTesting(false)
    }
}
