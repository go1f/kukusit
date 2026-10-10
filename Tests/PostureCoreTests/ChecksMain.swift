import Foundation

private func failure(_ message: String, file: StaticString, line: UInt) -> Never {
    fputs("FAIL: \(file):\(line): \(message)\n", stderr)
    exit(1)
}
func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { failure("expected true", file: file, line: line) }
}
func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if value { failure("expected false", file: file, line: line) }
}
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    if actual != expected { failure("\(actual) != \(expected)", file: file, line: line) }
}
func expectEqual(_ actual: Double, _ expected: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    if !actual.isFinite || abs(actual - expected) > accuracy { failure("\(actual) != \(expected) ± \(accuracy)", file: file, line: line) }
}
func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { failure("expected nil", file: file, line: line) }
}
func expectNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value == nil { failure("expected non-nil", file: file, line: line) }
}
func expectLessThan(_ actual: Double, _ limit: Double, file: StaticString = #filePath, line: UInt = #line) {
    if !(actual < limit) { failure("\(actual) is not less than \(limit)", file: file, line: line) }
}
func expectThrowsError<T>(_ expression: @autoclosure () throws -> T, _ verify: (Error) -> Void,
                          file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() }
    catch { verify(error); return }
    failure("expected error", file: file, line: line)
}

@main
struct ChecksMain {
    static func main() throws {
        let suite = PostureCoreTests()
        let reminders = ReminderChecks()
        let checks: [(String, () throws -> Void)] = [
            ("pixel angle and endpoint order", suite.testNonSquareImageShoulderAngleAndEndpointOrder),
            ("shoulder angle wrap", suite.testShoulderDeviationWrapsAcrossNinetyDegrees),
            ("preview mirror and letterboxing", suite.testPreviewMirrorAndLetterboxUseSameFitTransform),
            ("missing roll stays unknown", suite.testMissingFaceRollNeverBecomesZero),
            ("missing pitch stays unknown", suite.testMissingPitchDoesNotInventPitchOrBlockRoll),
            ("multiple targets", suite.testMultipleTargetsPauseAllMetrics),
            ("clipped shoulder", suite.testClippedShoulderDoesNotBlockFace),
            ("face/body association", suite.testUnassociatedBodyDoesNotProduceShoulderMetric),
            ("large yaw shoulder gate", suite.testLargeYawSuspendsShoulderMetric),
            ("valid single target", suite.testValidSingleTargetProducesIndependentMetrics),
            ("stable calibration", suite.testCalibrationAcceptsStableHeadAndShoulders),
            ("head-only calibration", suite.testCalibrationCanSaveHeadOnlyWithoutInventedShoulders),
            ("unstable calibration rejected", suite.testCalibrationRejectsUnstableHead),
            ("missing time not counted", suite.testCalibrationRejectsMissingCoverageAndDoesNotCountGaps),
            ("duplicate/backward timestamps", suite.testCalibrationIgnoresDuplicateAndBackwardTimestamps),
            ("configuration changes", suite.testCalibrationRejectsConfigurationChange),
            ("premature finish rejected", suite.testCalibrationCannotFinishEarly),
            ("circular reference", suite.testCircularReferenceDoesNotAverageAcrossDiscontinuity),
            ("15 FPS to 6 Hz sampling", suite.testSamplingFifteenFPSMaintainsSixHz),
            ("sampling gaps and epochs", suite.testSamplingDoesNotBurstAfterLongGapAndCanResetEpoch),
            ("calibration archive roundtrip", suite.testCalibrationArchiveRoundTrip),
            ("MediaPipe coordinate origin and anatomical sides", suite.testMediaPipeAdapterFlipsOriginAndPreservesAnatomicalSides),
            ("MediaPipe incomplete points", suite.testMediaPipeAdapterRejectsPartialLandmarkList),
            ("MediaPipe visibility gate", suite.testMediaPipeLowVisibilityIsNotInventedAsReliable),
            ("body worker failure preserves head", suite.testBodyWorkerFailurePreservesHeadAndBlocksShoulders),
            ("short deviation stays quiet", reminders.testShortDeviationDoesNotRemind),
            ("head correction direction", reminders.testSustainedHeadTiltUsesPhysicalCorrectionDirection),
            ("three-minute repeat cooldown", reminders.testPersistentDeviationRepeatsOnlyAfterThreeMinutes),
            ("unreliable interval resets persistence", reminders.testUnreliableIntervalBreaksPersistence),
            ("missing time not counted for reminders", reminders.testTimeGapDoesNotContributeToPersistence),
            ("turned head stays quiet", reminders.testTurningAwayStaysQuiet),
            ("jitter stays quiet", reminders.testJitterStaysQuiet),
            ("viewing context resets persistence", reminders.testSwitchingReferencesBreaksPersistence),
            ("shoulder changes do not invent head direction", reminders.testShoulderShiftDoesNotInventHeadDirection),
            ("whole-body lean classified separately", reminders.testWholeBodyLeanDoesNotInventIndependentNeckTilt),
            ("recovery once; unknown not recovery", reminders.testRecoveryHappensOnceAndUnknownIsNotRecovery),
            ("pause preserves cooldown", reminders.testPauseResetKeepsCooldown),
            ("hysteresis preserves episode", reminders.testHysteresisKeepsEpisodeWithoutRepeatedAlerts),
            ("subsecond recovery preserves accumulated time", reminders.testSubsecondRecoveryRetainsAccumulation),
            ("two-second recovery clears pending time", reminders.testTwoSecondRecoveryClearsPendingAccumulation),
            ("short recovery never emits recovered", reminders.testBriefRecoveryDoesNotEmitRecovered),
            ("compact PiP sizing", reminders.testCompactPiPHeightScalesWithVideoWidth),
            ("eye anchor without nose", suite.testEyeAnchorAssociatesShouldersWithoutNose),
            ("head-only reminder input and lost shoulders", suite.testReminderFactorySupportsHeadOnlyBaselineAndLostShoulders),
            ("missing direction never invented", suite.testReminderFactoryDoesNotInventMissingOrientation),
            ("multiple targets bypass loss grace", suite.testMultipleTargetsCannotUseLossGrace),
            ("head-only reminder", reminders.testHeadOnlyCanRemindWithoutShoulders),
            ("brief loss pauses and preserves time", reminders.testBriefRecognitionLossRetainsTimeButDoesNotCountLoss),
            ("long loss clears time", reminders.testLongRecognitionLossClearsPendingTime),
            ("repeated single-frame losses", reminders.testRepeatedSingleFrameLossDoesNotPreventReminder),
            ("shoulder dropout preserves head timer", reminders.testMissingShoulderFrameDoesNotResetHeadTimer),
            ("missing shoulders never confirm recovery", reminders.testMissingShouldersCannotConfirmShoulderRecovery),
            ("shoulder jitter leaves head usable", reminders.testShoulderJitterDoesNotBlockClearHead),
            ("slow tilt accumulates", reminders.testSlowTiltStillAccumulates),
            ("isolated angle outlier", reminders.testOneAngleOutlierDoesNotResetPersistence),
            ("upper display viewing pitch", reminders.testUpperScreenPitchDifferenceCanBeJudged),
            ("looking away clears persistence", reminders.testDirectionChangeClearsEarlierTimer),
            ("brief pipeline stall", reminders.testBriefPipelineStallDoesNotCountMissingTime),
            ("specific state reason", reminders.testSpecificReasonIsVisibleInStateLabel),
            ("absolute side turn blocks head-only fallback", suite.testAbsoluteSideTurnCannotUseHeadOnlyFallback),
            ("two Hz still reaches decision", reminders.testTwoHzObservationsStillReachDecision),
            ("confidence and cropping reasons differ", suite.testQualityReasonsSeparateConfidenceAndCropping),
            ("reference loss and boundary noise", suite.testReferenceLossAndBoundaryNoiseKeepCurrentContext),
            ("4–6 degree head tilt starts timer", reminders.testFourToSixDegreesStartHeadTimer),
            ("intermediate band is not normal", reminders.testIntermediateBandIsNotNormal),
            ("3 degrees cannot confirm recovery", reminders.testThreeDegreesCannotConfirmRecovery),
            ("shoulders never cancel visible head tilt", reminders.testShouldersDoNotCancelVisibleHeadDeviation),
            ("small shoulder shift never invents head tilt", reminders.testSmallShoulderShiftDoesNotInventHeadTilt)
        ]
        for (name, check) in checks { try check(); print("PASS: \(name)") }
        print("\(checks.count) / \(checks.count) core checks passed")
    }
}
