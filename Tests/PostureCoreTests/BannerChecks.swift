import Foundation
import CoreGraphics
import PostureCore

struct BannerChecks {
    func trackingDropout() {
        var s = ReminderDismissal(); s.dismiss(["head"])
        s.reconcile(ongoingIDs: ["head"])
        expectFalse(s.allows("head"))
        // Observable alert rows can disappear, while the episode remains unresolved.
        s.reconcile(ongoingIDs: ["head"]); expectFalse(s.allows("head"))
    }
    func independentAnomaly() {
        var s = ReminderDismissal(); s.dismiss(["head"])
        s.reconcile(ongoingIDs: ["head", "shoulders"])
        expectTrue(s.allows("shoulders")); expectFalse(s.allows("head"))
        s.dismiss(["shoulders"]); expectFalse(s.allows("shoulders"))
    }
    func recoveryAndReset() {
        var s = ReminderDismissal(); s.dismiss(["head", "shoulders"])
        s.reconcile(ongoingIDs: ["shoulders"])
        expectTrue(s.allows("head")); expectFalse(s.allows("shoulders"))
        s.reconcile(ongoingIDs: []); expectTrue(s.acknowledged.isEmpty)
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
