import Foundation
import CoreGraphics
import PostureCore

struct SessionChecks {
    func overlappingInterruptions() {
        var s = MonitoringInterruptionState()
        expectTrue(s.requestStart())
        s.suspend(.screenLocked); s.suspend(.displaySleep); s.suspend(.systemSleep)
        s.suspend(.screenLocked)
        expectFalse(s.canResume)
        s.resume(.systemSleep); expectFalse(s.canResume)
        s.resume(.displaySleep); expectFalse(s.canResume)
        s.resume(.screenLocked); expectTrue(s.canResume)
    }
    func manualPause() {
        var s = MonitoringInterruptionState()
        _ = s.requestStart(); s.suspend(.screenLocked)
        s.requestPause(); s.unlocked(); expectFalse(s.canResume)
        s.suspend(.displaySleep); expectFalse(s.requestStart())
        s.requestPause(); s.resume(.displaySleep); expectFalse(s.canResume)
    }
    func unlockAndInitialPause() {
        var s = MonitoringInterruptionState()
        s.suspend(.screenLocked); s.unlocked(); expectFalse(s.canResume)
        _ = s.requestStart()
        s.suspend(.systemSleep); s.suspend(.sessionInactive); s.suspend(.displaySleep)
        s.unlocked(); expectTrue(s.canResume)
        s.resume(.displaySleep); expectTrue(s.canResume)
    }
    func placementRoundtrip() throws {
        let area = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let frame = CGRect(x: -1250, y: 420, width: 440, height: 360)
        let p = FloatingWindowPlacement(displayID: "external", frame: frame, visibleFrame: area, contentWidth: 440)
        let copy = try JSONDecoder().decode(FloatingWindowPlacement.self, from: JSONEncoder().encode(p))
        expectEqual(p, copy); expectTrue(p.isValid)
        let resized = p.changingWidth(560)
        expectEqual(resized.contentWidth, 560)
        expectEqual(resized.xFraction, p.xFraction); expectEqual(resized.displayID, p.displayID)
        let origin = p.origin(visibleFrame: area, windowSize: frame.size)
        expectEqual(origin.x, frame.minX, accuracy: 0.001)
        expectEqual(origin.y, frame.minY, accuracy: 0.001)
    }
    func placementBounds() {
        let p = FloatingWindowPlacement(displayID: "external", frame: CGRect(x: 2300, y: 1200, width: 500, height: 300),
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), contentWidth: 500)
        let smaller = CGRect(x: -800, y: -400, width: 900, height: 600)
        let point = p.origin(visibleFrame: smaller, windowSize: CGSize(width: 500, height: 300))
        expectTrue(point.x >= smaller.minX+18 && point.x+500 <= smaller.maxX-18)
        expectTrue(point.y >= smaller.minY+18 && point.y+300 <= smaller.maxY-18)
    }
}
