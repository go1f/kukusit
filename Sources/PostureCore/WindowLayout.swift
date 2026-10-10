import Foundation

public enum WindowLayout {
    public static func pipHeight(width: Double, visual: Bool, demo: Bool = false) -> Double {
        let picture = visual ? max(0, width - 20) * 9 / 16 : 0
        return picture + (visual ? 108 : 100) + (demo ? 20 : 0)
    }
}
