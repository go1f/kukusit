import Foundation
import PostureCore

final class PostureCoreTests {
    private func frame(_ time: Double = 0, signature: String = "camera-a", shoulders: Bool = true) -> Observation {
        var points: [Joint: JointPoint] = [.nose: JointPoint(Point(0.5, 0.75), confidence: 0.95)]
        if shoulders {
            points[.leftShoulder] = JointPoint(Point(0.7, 0.4), confidence: 0.9)
            points[.rightShoulder] = JointPoint(Point(0.3, 0.4), confidence: 0.9)
        }
        return Observation(timestamp: time, imageSize: ImageSize(1280, 720), cameraSignature: signature,
                           faceCount: 1, bodyCount: shoulders ? 1 : 0,
                           faceBox: FaceBox(x: 0.4, y: 0.6, width: 0.2, height: 0.3), faceConfidence: 0.95,
                           roll: 2, yaw: 1, pitch: -15, joints: points)
    }
    func testNonSquareImageShoulderAngleAndEndpointOrder() {
        let a = Point(0.2, 0.4), b = Point(0.2 + 360 / 1280.0, 0.4 + 36 / 720.0)
        let forward = Geometry.lineAngle(from: a, to: b, imageSize: ImageSize(1280, 720))
        let reverse = Geometry.lineAngle(from: b, to: a, imageSize: ImageSize(1280, 720))
        expectEqual(forward, 5.710593, accuracy: 0.00001)
        expectEqual(reverse, forward, accuracy: 0.00001)
    }
    func testShoulderDeviationWrapsAcrossNinetyDegrees() {
        expectEqual(Geometry.wrapDegrees(-89 - 89, period: 180), 2, accuracy: 0.001)
    }
    func testPreviewMirrorAndLetterboxUseSameFitTransform() {
        let source = ImageSize(1280, 720), viewport = ImageSize(1000, 800)
        let regular = Geometry.previewPoint(Point(0.2, 0.8), source: source, viewport: viewport, mirrored: false)
        let mirror = Geometry.previewPoint(Point(0.2, 0.8), source: source, viewport: viewport, mirrored: true)
        expectEqual(regular.x, 200, accuracy: 0.00001)
        expectEqual(mirror.x, 800, accuracy: 0.00001)
        expectEqual(regular.y, 231.25, accuracy: 0.00001)
        expectEqual(mirror.y, regular.y, accuracy: 0.00001)
    }
    func testMissingFaceRollNeverBecomesZero() {
        var observation = frame(); observation.roll = nil
        let metrics = QualityGate.evaluate(observation)
        expectFalse(metrics.faceUsable)
        expectNil(metrics.roll)
        expectFalse(metrics.shouldersUsable)
    }
    func testMissingPitchDoesNotInventPitchOrBlockRoll() {
        var observation = frame(); observation.pitch = nil
        let metrics = QualityGate.evaluate(observation)
        expectTrue(metrics.faceUsable)
        expectNil(metrics.pitch)
    }
    func testMultipleTargetsPauseAllMetrics() {
        var observation = frame(); observation.faceCount = 2
        let metrics = QualityGate.evaluate(observation)
        expectFalse(metrics.faceUsable)
        expectFalse(metrics.shouldersUsable)
    }
    func testClippedShoulderDoesNotBlockFace() {
        var observation = frame()
        observation.joints[.leftShoulder] = JointPoint(Point(1.02, 0.4), confidence: 0.99)
        let metrics = QualityGate.evaluate(observation)
        expectTrue(metrics.faceUsable)
        expectFalse(metrics.shouldersUsable)
    }
    func testUnassociatedBodyDoesNotProduceShoulderMetric() {
        var observation = frame()
        observation.joints[.nose] = JointPoint(Point(0.85, 0.3), confidence: 0.99)
        let metrics = QualityGate.evaluate(observation)
        expectTrue(metrics.faceUsable)
        expectFalse(metrics.shouldersUsable)
    }
    func testLargeYawSuspendsShoulderMetric() {
        var observation = frame(); observation.yaw = 45
        expectFalse(QualityGate.evaluate(observation).shouldersUsable)
    }
    func testValidSingleTargetProducesIndependentMetrics() {
        let metrics = QualityGate.evaluate(frame())
        expectEqual(metrics.roll, 2)
        expectEqual(metrics.shoulderAngle, 0)
    }
    private func completeCollector(shoulders: Bool = true, change: ((inout Observation, Int) -> Void)? = nil) -> CalibrationCollector {
        var collector = CalibrationCollector(context: .upperMonitor, startedAt: 0, signature: "camera-a")
        for index in 0...120 {
            var observation = frame(Double(index) / 6, shoulders: shoulders)
            change?(&observation, index)
            collector.consume(observation, metrics: QualityGate.evaluate(observation))
        }
        return collector
    }
    func testCalibrationAcceptsStableHeadAndShoulders() throws {
        let baseline = try completeCollector().finish(at: 20)
        expectEqual(baseline.roll.median, 2)
        expectEqual(baseline.pitch?.median, -15)
        expectEqual(baseline.shoulder?.median, 0)
        expectEqual(baseline.faceValidSeconds, 20, accuracy: 0.001)
    }
    func testCalibrationCanSaveHeadOnlyWithoutInventedShoulders() throws {
        let baseline = try completeCollector(shoulders: false).finish(at: 20)
        expectNotNil(baseline.roll)
        expectNil(baseline.shoulder)
        expectEqual(baseline.shoulderValidSeconds, 0)
    }
    func testCalibrationRejectsUnstableHead() {
        let collector = completeCollector { observation, index in observation.roll = index % 2 == 0 ? -8 : 8 }
        expectThrowsError(try collector.finish(at: 20)) { expectEqual($0 as? CalibrationError, .unstableFace) }
    }
    func testCalibrationRejectsMissingCoverageAndDoesNotCountGaps() {
        var collector = CalibrationCollector(context: .upperMonitor, startedAt: 0, signature: "camera-a")
        for index in 0...5 {
            let observation = frame(Double(index) * 4)
            collector.consume(observation, metrics: QualityGate.evaluate(observation))
        }
        expectEqual(collector.faceValidSeconds, 0)
        expectThrowsError(try collector.finish(at: 20)) { expectEqual($0 as? CalibrationError, .insufficientFaceCoverage) }
    }
    func testCalibrationIgnoresDuplicateAndBackwardTimestamps() {
        var collector = CalibrationCollector(context: .upperMonitor, startedAt: 0, signature: "camera-a")
        for timestamp in [0.0, 0.2, 0.2, 0.1, 0.4] {
            let observation = frame(timestamp)
            collector.consume(observation, metrics: QualityGate.evaluate(observation))
        }
        expectEqual(collector.sampleCount, 3)
        expectEqual(collector.faceValidSeconds, 0.4, accuracy: 0.001)
    }
    func testCalibrationRejectsConfigurationChange() {
        var collector = completeCollector()
        let different = frame(20, signature: "camera-b")
        // Same timestamp is ignored, so introduce an in-window change earlier instead.
        collector = completeCollector { observation, index in if index == 60 { observation.cameraSignature = different.cameraSignature } }
        expectThrowsError(try collector.finish(at: 20)) { expectEqual($0 as? CalibrationError, .cameraChanged) }
    }
    func testCalibrationCannotFinishEarly() {
        expectThrowsError(try completeCollector().finish(at: 10)) { expectEqual($0 as? CalibrationError, .notFinished) }
    }
    func testCircularReferenceDoesNotAverageAcrossDiscontinuity() {
        let metric = BaselineMetric.from([179, -179, 178, -178])!
        expectEqual(abs(metric.median), 180, accuracy: 0.001)
        expectLessThan(metric.mad, 3)
    }
    func testSamplingFifteenFPSMaintainsSixHz() {
        var scheduler = AnalysisScheduler()
        let accepted = (0..<150).filter { scheduler.shouldProcess(at: Double($0) / 15) }
        expectEqual(accepted.count, 60)
    }
    func testSamplingDoesNotBurstAfterLongGapAndCanResetEpoch() {
        var scheduler = AnalysisScheduler()
        expectTrue(scheduler.shouldProcess(at: 0))
        expectFalse(scheduler.shouldProcess(at: 0.01))
        expectTrue(scheduler.shouldProcess(at: 100))
        expectFalse(scheduler.shouldProcess(at: 100.01))
        scheduler.reset()
        expectTrue(scheduler.shouldProcess(at: 0))
    }
    func testCalibrationArchiveRoundTrip() throws {
        let baseline = try completeCollector().finish(at: 20)
        let archive = CalibrationArchive(profiles: [baseline.context.rawValue: baseline])
        let data = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(CalibrationArchive.self, from: data)
        expectEqual(decoded.schemaVersion, 1)
        expectEqual(decoded.profiles[baseline.context.rawValue], baseline)
    }
    func testMediaPipeAdapterFlipsOriginAndPreservesAnatomicalSides() {
        var landmarks = Array(repeating: PoseLandmark(x: 0.5, y: 0.5, confidence: 0.95), count: 33)
        landmarks[11] = PoseLandmark(x: 0.7, y: 0.6, confidence: 0.9)
        landmarks[12] = PoseLandmark(x: 0.3, y: 0.6, confidence: 0.8)
        let joints = PoseAdapter.joints(from: landmarks)
        expectEqual(joints[.leftShoulder]?.location, Point(0.7, 0.4))
        expectEqual(joints[.rightShoulder]?.location, Point(0.3, 0.4))
        expectEqual(joints[.rightShoulder]?.confidence, 0.8)
        expectNil(joints[.neck])
    }
    func testMediaPipeAdapterRejectsPartialLandmarkList() {
        expectTrue(PoseAdapter.joints(from: [PoseLandmark(x: 0.5, y: 0.5, confidence: 0.95)]).isEmpty)
    }
    func testMediaPipeLowVisibilityIsNotInventedAsReliable() {
        var landmarks = Array(repeating: PoseLandmark(x: 0.5, y: 0.5, confidence: 0.95), count: 33)
        landmarks[11] = PoseLandmark(x: 0.7, y: 0.6, confidence: 0.1)
        expectFalse(PoseAdapter.joints(from: landmarks)[.leftShoulder]!.isReliable)
    }
    func testBodyWorkerFailurePreservesHeadAndBlocksShoulders() {
        var observation = frame(); observation.bodyFailureReason = "测试：肩部分析不可用"
        let metrics = QualityGate.evaluate(observation)
        expectTrue(metrics.faceUsable)
        expectFalse(metrics.shouldersUsable)
        expectEqual(metrics.shoulderReason, "测试：肩部分析不可用")
    }
}
