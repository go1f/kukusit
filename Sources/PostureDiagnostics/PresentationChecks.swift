import AppKit
import SwiftUI
import AVFoundation
import PostureCore

@MainActor enum PresentationChecks {
    static func run(directory: String) {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            let model = DiagnosticModel(demo: true)
            let desktop = DesktopCoordinator(model: model)
            do {
                recoveryTransitions()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                model.setRendering(image: true, skeleton: true)
                try await Task.sleep(nanoseconds: 250_000_000)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 690),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: MonitorWindowView(model: model, desktop: desktop))
                host.sizingOptions = []; window.contentView = host
                let original = window.frame
                var menuSizes: [String] = []
                for index in 0..<12 {
                    model.monitorState = index.isMultiple(of: 2) ? .normal : .unknown(String(repeating: "正在等待清晰姿态，暂不提醒。", count: 8))
                    model.settings.dualPreview = index.isMultiple(of: 3)
                    model.mirrored = index.isMultiple(of: 2)
                    try await Task.sleep(nanoseconds: 40_000_000)
                    host.layoutSubtreeIfNeeded()
                    precondition(window.frame == original, "Status text resized the application window")
                    let snapshot = desktop.presentationSnapshot["statusPanel"] as! [String:Any]
                    let titles = snapshot["itemTitles"] as! [String]
                    precondition(titles.contains("镜像预览") && !titles.contains(where: { $0.contains("更新") }))
                    precondition(snapshot["headerHeight"] as? CGFloat == 112)
                    menuSizes.append("\(snapshot["width"]!)x\(snapshot["height"]!)")
                }
                precondition(Set(menuSizes).count == 1, "Status changes resized the menu")
                model.settings.dualPreview = true
                model.setRendering(image: true, skeleton: true)
                try await Task.sleep(nanoseconds: 200_000_000)
                try NativeViewRender.png(MonitorWindowView(model: model, desktop: desktop), size: CGSize(width: 940, height: 690), to: folder.appendingPathComponent("dual-preview.png"))
                model.settings.dualPreview = false
                model.setRendering(image: true, skeleton: true)
                try await Task.sleep(nanoseconds: 200_000_000)
                try NativeViewRender.png(MonitorWindowView(model: model, desktop: desktop), size: CGSize(width: 940, height: 690), to: folder.appendingPathComponent("single-preview.png"))

                var time = 0.0
                let banner = ReminderPanelController(router: DisplayRouter(), now: { time }, presentsOnScreen: false)
                let head = MonitoringAlert(id: "head", title: "歪头", message: "头向左扶正", seconds: 8, recovering: false)
                banner.synchronize(ReminderPresentationUpdate(alerts: [head], ongoingIDs: [head.id]))
                try banner.renderReview(to: folder.appendingPathComponent("reminder-active.png"))
                var recovering = head; recovering.recovering = true; recovering.recoveryProgress = 0.6
                time = 1; banner.synchronize(ReminderPresentationUpdate(alerts: [recovering], ongoingIDs: [head.id]))
                try banner.renderReview(to: folder.appendingPathComponent("reminder-recovering.png"))
                time = 2; banner.synchronize(ReminderPresentationUpdate(alerts: [], ongoingIDs: [], recoveredIDs: [head.id]))
                try banner.renderReview(to: folder.appendingPathComponent("reminder-complete.png"))
                time = 2.5; banner.synchronize(ReminderPresentationUpdate(alerts: [], ongoingIDs: []))
                try banner.renderReview(to: folder.appendingPathComponent("reminder-checkmark.png"))
                banner.synchronize(ReminderPresentationUpdate(alerts: [], ongoingIDs: [], enabled: false))
                for name in ["reminder-active.png", "reminder-recovering.png", "reminder-complete.png", "reminder-checkmark.png"] {
                    let image = NSBitmapImageRep(data: try Data(contentsOf: folder.appendingPathComponent(name)))!
                    precondition(image.colorAt(x: 0, y: 0)!.alphaComponent < 0.01, "Reminder corner became square")
                    precondition(image.colorAt(x: image.pixelsWide/2, y: image.pixelsHigh/2)!.alphaComponent > 0.99)
                }
                let report: [String:Any] = ["passed":true, "input":"synthetic images and offscreen native views; no camera or desktop capture",
                    "windowFrameStableAcrossStatusAndPreviewChanges":true, "nativeMenuSizeStable":true,
                    "mirrorMenuPresent":true, "updateMenuAbsent":true, "menuSizes":menuSizes,
                    "roundedCornersPreservedAcrossRecovery":true,
                    "onlyVerifiedEpisodeTransitionsReportRecovery":true,
                    "renders":["dual-preview.png","single-preview.png","reminder-active.png","reminder-recovering.png","reminder-complete.png","reminder-checkmark.png"]]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                try data.write(to: folder.appendingPathComponent("checks.json"), options:.atomic)
                print(String(data:data,encoding:.utf8)!)
                desktop.shutdown(); model.shutdown(); window.close(); app.terminate(nil)
            } catch { desktop.shutdown(); model.shutdown(); fputs("Presentation checks failed: \(error)\n",stderr); exit(1) }
        }
        app.run()
    }
    private static func recoveryTransitions() {
        var configuration = ReminderConfiguration()
        configuration.sustainedSeconds = 0.5; configuration.recoverySeconds = 0.5; configuration.settleSeconds = 0.2
        configuration.cooldownSeconds = 0
        var engine = ReminderEngine(configuration: configuration)
        var previous: [ReminderChannelSnapshot] = []
        var events: Set<String> = []
        @MainActor func sample(_ time: Double, roll: Double, shoulder: Double, context: String = "a") {
            let result = engine.observe(ReminderInput(timestamp: time, contextID: context, reliable: true,
                rollDeviation: roll, shoulderDeviation: shoulder))
            events.formUnion(ReminderPresentationUpdate.recoveredPostureIDs(previous: previous, current: result.channels))
            previous = result.channels
        }
        for i in 0..<40 { sample(Double(i)/10, roll: 10, shoulder: 15) }
        precondition(previous.allSatisfy(\.hasReminded))
        for i in 40..<60 { sample(Double(i)/10, roll: 0, shoulder: 15) }
        precondition(events == ["posture.head"] && previous.last?.hasReminded == true)
        events = []
        for i in 60..<80 { sample(Double(i)/10, roll: 0, shoulder: 0, context: "b") }
        precondition(events.isEmpty, "Changing reference must not confirm the previous episode")
        for i in 80..<120 { sample(Double(i)/10, roll: 10, shoulder: 15, context: "b") }
        precondition(previous.allSatisfy(\.hasReminded))
        let reset = engine.reset()
        precondition(ReminderPresentationUpdate.recoveredPostureIDs(previous: previous, current: reset.channels).isEmpty)
        previous = reset.channels; events = []
        for i in 120..<140 { sample(Double(i)/10, roll: 0, shoulder: 0, context: "b") }
        precondition(events.isEmpty, "Pause/reset must not be presented as confirmed recovery")
    }
    static func cameraConnections() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            print("{\"skipped\":true,\"reason\":\"Existing camera permission required; none requested\"}"); return
        }
        do {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
                throw NSError(domain:"KukusitDualPreview",code:1,userInfo:[NSLocalizedDescriptionKey:"Built-in camera unavailable"])
            }
            let session = AVCaptureSession(); session.beginConfiguration(); session.sessionPreset = .high
            let input = try AVCaptureDeviceInput(device: device)
            precondition(session.canAddInput(input)); session.addInput(input)
            let original = AVCaptureVideoPreviewLayer(session: session)
            let mirrored = AVCaptureVideoPreviewLayer(session: session)
            session.commitConfiguration(); session.startRunning()
            defer { session.stopRunning(); original.session = nil; mirrored.session = nil }
            guard let a = original.connection, let b = mirrored.connection else {
                throw NSError(domain:"KukusitDualPreview",code:2,userInfo:[NSLocalizedDescriptionKey:"Two preview connections were not created"])
            }
            precondition(a !== b && a.isVideoMirroringSupported && b.isVideoMirroringSupported)
            a.automaticallyAdjustsVideoMirroring = false; a.isVideoMirrored = false
            b.automaticallyAdjustsVideoMirroring = false; b.isVideoMirrored = true
            precondition(session.isRunning && session.inputs.count == 1 && !a.isVideoMirrored && b.isVideoMirrored)
            print("{\"passed\":true,\"input\":\"brief built-in camera connection check; no images saved\",\"cameraInputs\":1,\"independentMirroredPreviewConnections\":2}")
        } catch { fputs("Dual preview check failed: \(error)\n",stderr); exit(1) }
    }
}
