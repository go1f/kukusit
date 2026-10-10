import Foundation

public struct AnalysisScheduler: Sendable {
    public let interval: Double
    private var deadline: Double?
    public init(hertz: Double = 6) { interval = 1 / hertz }
    public mutating func reset() { deadline = nil }
    public mutating func shouldProcess(at timestamp: Double) -> Bool {
        guard timestamp.isFinite else { return false }
        guard let due = deadline else { deadline = timestamp + interval; return true }
        guard timestamp + 0.000001 >= due else { return false }
        // Preserve phase when sampling 15 FPS at 6 Hz, rather than drifting to 5 Hz.
        deadline = timestamp - due > interval ? timestamp + interval : due + interval
        return true
    }
}
