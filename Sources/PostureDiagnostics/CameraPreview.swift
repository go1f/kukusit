import AppKit
import SwiftUI
import AVFoundation

// AVFoundation presents camera buffers directly. Model initialization and Vision requests
// cannot block this path; no CGImage is copied into the SwiftUI observation model.
private final class CameraPreviewNSView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds }
}
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    let enabled: Bool
    func makeNSView(context: Context) -> NSView {
        let view = CameraPreviewNSView(frame: .zero)
        view.preview.session = session
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CameraPreviewNSView else { return }
        if view.preview.session !== session { view.preview.session = session }
        if let connection = view.preview.connection {
            connection.isEnabled = enabled
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? CameraPreviewNSView)?.preview.session = nil
    }
}
