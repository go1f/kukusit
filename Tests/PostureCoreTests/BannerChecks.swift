import Foundation
import CoreGraphics
import PostureCore

struct BannerChecks {
    func trackingDropout() {
        var s = ReminderDismissal(); s.dismiss(["head"], at: 0)
        s.reconcile(ongoingIDs: ["head"], at: 1)
        expectFalse(s.allows("head", at: 1))
        // Observable alert rows can disappear, while the episode remains unresolved.
        s.reconcile(ongoingIDs: ["head"], at: 2); expectFalse(s.allows("head", at: 2))
    }
    func independentAnomaly() {
        var s = ReminderDismissal(); s.dismiss(["head"], at: 10)
        s.reconcile(ongoingIDs: ["head", "shoulders"], at: 11)
        expectFalse(s.allows("shoulders", at: 11)); expectFalse(s.allows("head", at: 39.999))
        s.reconcile(ongoingIDs: ["head", "shoulders"], at: 40)
        expectTrue(s.allows("head", at: 40)); expectTrue(s.allows("shoulders", at: 40))
    }
    func recoveryAndReset() {
        var s = ReminderDismissal(); s.dismiss(["head", "shoulders"], at: 10)
        s.reconcile(ongoingIDs: [], at: 11)
        expectTrue(s.acknowledged.isEmpty); expectFalse(s.allows("head", at: 39))
        s.dismiss([], at: 20)
        expectFalse(s.allows("nudge", at: 49.999)); expectTrue(s.allows("head", at: 50))
    }
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 40, width: 1440, height: 828)
    func notchedPlacement() {
        let f = ReminderPlacement.frame(screen: screen, visible: visible, singleScreen: true, safeTop: 32, size: CGSize(width: 210,height:38))
        expectTrue(f.maxY < screen.maxY-32)
        expectTrue(f.maxY > visible.maxY-12)
        expectEqual(f.midX, screen.midX, accuracy: 0.001)
    }
    func flatPlacement() {
        let f = ReminderPlacement.frame(screen: screen, visible: visible, singleScreen: true, safeTop: 0, size: CGSize(width:160,height:38))
        expectTrue(f.maxY > visible.maxY)
        expectTrue(screen.contains(f))
    }
    func multiScreenPlacement() {
        let f = ReminderPlacement.frame(screen: screen, visible: visible, singleScreen: false, safeTop:32, size:CGSize(width:210,height:60))
        expectTrue(visible.contains(f)); expectTrue(f.maxY < visible.maxY)
    }
}
