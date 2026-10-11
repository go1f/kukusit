import AppKit
import SwiftUI
import AVFoundation

// AVFoundation presents camera buffers directly. Model initialization and Vision requests
// cannot block this path; no CGImage is copied into the SwiftUI observation model.
private final class CameraPreviewNSView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    var mirrored = false
    var previewEnabled = false
    private var sessionObservers: [NSObjectProtocol] = []

    func configure(session: AVCaptureSession, mirrored: Bool, enabled: Bool) {
        self.mirrored = mirrored
        previewEnabled = enabled
        if preview.session !== session {
            sessionObservers.forEach(NotificationCenter.default.removeObserver)
            sessionObservers = [AVCaptureSession.didStartRunningNotification,
                                AVCaptureSession.didStopRunningNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: session, queue: .main) { [weak self] _ in
                    self?.applyPreferences()
                }
            }
            preview.session = session
        }
        applyPreferences()
    }

    // The capture session is configured asynchronously: the preview connection may
    // not exist when SwiftUI first sends its saved settings. Apply them again when
    // capture starts or the view is laid out, including after a camera restart.
    func applyPreferences() {
        guard let connection = preview.connection else { return }
        connection.isEnabled = previewEnabled
        if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    func detach() {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
        sessionObservers = []
        preview.session = nil
    }

    deinit { sessionObservers.forEach(NotificationCenter.default.removeObserver) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); preview.frame = bounds; applyPreferences() }
}
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    let enabled: Bool
    func makeNSView(context: Context) -> NSView {
        let view = CameraPreviewNSView(frame: .zero)
        view.configure(session: session, mirrored: mirrored, enabled: enabled)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CameraPreviewNSView else { return }
        view.configure(session: session, mirrored: mirrored, enabled: enabled)
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? CameraPreviewNSView)?.detach()
    }
}
