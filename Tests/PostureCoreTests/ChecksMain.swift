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
        let habits = TuningHabitChecks()
        let updates = UpdateChecks()
        let sessions = SessionChecks()
        let banners = BannerChecks()
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
            ("head and shoulders overlap", reminders.testWholeBodyLeanDoesNotInventIndependentNeckTilt),
            ("head and shoulders independent timers", reminders.testHeadAndShouldersAccumulateIndependently),
            ("one recovery preserves other channel", reminders.testRecoveringOneChannelKeepsTheOtherUnresolved),
            ("crossing channels survive short return", reminders.testShortReturnDoesNotResetCrossingChannels),
            ("head direction switch preserves timer", reminders.testHeadDirectionSwitchKeepsItsTimer),
            ("brief shoulder loss preserves channels", reminders.testBriefShoulderLossPreservesBothIndependentTimers),
            ("shoulder direction switch preserves timer", reminders.testShoulderDirectionSwitchKeepsItsTimer),
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
            ("small shoulder shift never invents head tilt", reminders.testSmallShoulderShiftDoesNotInventHeadTilt),
            ("tuning defaults and bounds", habits.testTuningDefaultsAndBounds),
            ("partial tuning and roundtrip", habits.testPartialTuningDecodeAndRoundtrip),
            ("custom tuning drives reminder", habits.testCustomSensitivityControlsRealReminderEngine),
            ("facial geometry rotation and aspect", habits.testFacialGeometryCorrectsImageAspectAndHeadRotation),
            ("hand mouth persistence and cooldown", habits.testHandMouthSustainedAndCooldown),
            ("unreliable oral targets stay quiet", habits.testLowConfidenceAndMultipleTargetsStayQuiet),
            ("personal asymmetry baseline", habits.testPersonalAsymmetryIsNotAutomaticAbnormality),
            ("lip reference and talking", habits.testLipChangesNeedReferenceAndExcludeTalking),
            ("blink versus sustained eye change", habits.testShortBlinkAndLongEyeChangeAreSeparated),
            ("head reference survives shoulder switch", habits.testFaceReferenceSurvivesShoulderBackendSwitch),
            ("open mouth and parallel habit timers", habits.testOpenMouthShiftAndParallelHabitTimers),
            ("oral short recovery preserves evidence", habits.testHabitShortRecoveryRetainsCountAndConfirmation),
            ("oral dropout is not recovery", habits.testHabitDropoutFreezesAndNeverConfirmsRecovery),
            ("legacy facial feature compatibility", habits.testLegacyFacialFeaturesDecodeAndNewGeometryRoundTrip),
            ("personal examples require neutral and margin", habits.testPersonalPrototypeRequiresNeutralDistanceAndMargin),
            ("examples independent from lip experiment", habits.testPersonalPrototypeRunsWithoutGenericLipExperiment),
            ("two Hz oral analysis and gaps", habits.testTwoHertzMouthAndExamplesReachThreshold),
            ("update signed manifest and OS", updates.validSignature),
            ("update tampering and wrong signing key", updates.tampering),
            ("update download and size constraints", updates.constraints),
            ("update atomic replacement", updates.success),
            ("update failed relaunch rollback", updates.launchRollback),
            ("update post-swap verification rollback", updates.verificationRollback),
            ("update stage failure and parent wait", updates.failedStageOrParent),
            ("update path restrictions and lock", updates.pathAndLock),
            ("recovery animation uses evidence", reminders.testRecoverySnapshotProgressUsesRealEvidence),
            ("overlapping system interruption", sessions.overlappingInterruptions),
            ("manual pause cancels automatic resume", sessions.manualPause),
            ("unlock clears coalesced sleep signals", sessions.unlockAndInitialPause),
            ("PiP negative-coordinate placement", sessions.placementRoundtrip),
            ("PiP changed resolution stays on screen", sessions.placementBounds),
            ("dismissed reminder survives tracking dropout", banners.trackingDropout),
            ("new anomalies respect 30-second global mute", banners.independentAnomaly),
            ("recovery cannot reset click quiet period", banners.recoveryAndReset),
            ("single-screen island respects cutout", banners.notchedPlacement),
            ("non-notched single screen moves above old banner", banners.flatPlacement),
            ("multi-screen reminder stays below menu", banners.multiScreenPlacement)
        ]
        for (name, check) in checks { try check(); print("PASS: \(name)") }
        print("\(checks.count) / \(checks.count) core checks passed")
    }
}
