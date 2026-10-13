import Foundation
import PostureCore

final class TuningHabitChecks {
    func testTuningDefaultsAndBounds() {
        let defaults = MonitorTuning().reminderConfiguration
        expectEqual(defaults.sustainedSeconds, 5)
        expectEqual(defaults.headEnterDegrees, 3)
        var t = MonitorTuning()
        t.headEnterDegrees = 1; t.headExitDegrees = .nan; t.bodyHertz = 0; t.faceHertz = 2
        t.recoverySeconds = -20; t.cooldownSeconds = .infinity
        let n = t.normalized
        expectLessThan(n.headExitDegrees, n.headEnterDegrees)
        expectEqual(n.bodyHertz, 1)
        expectEqual(n.recoverySeconds, 0.5)
        expectEqual(n.cooldownSeconds, 60)
        expectEqual(n.reminderConfiguration.maximumGap, 0.75)
    }
    func testPartialTuningDecodeAndRoundtrip() throws {
        let data = Data(#"{"sustainedSeconds":1.5,"headEnterDegrees":2}"#.utf8)
        let t = try JSONDecoder().decode(MonitorTuning.self, from: data)
        expectEqual(t.sustainedSeconds, 1.5)
        expectEqual(t.headEnterDegrees, 2)
        expectEqual(t.bodyHertz, 3)
        expectEqual(t.computePreference, .automatic)
        expectEqual(try JSONDecoder().decode(MonitorTuning.self, from: JSONEncoder().encode(t)), t)
    }
    func testCustomSensitivityControlsRealReminderEngine() {
        var t = MonitorTuning(); t.sustainedSeconds = 2; t.headEnterDegrees = 2; t.headExitDegrees = 1
        var e = ReminderEngine(configuration: t.reminderConfiguration)
        let events = (0..<30).compactMap { e.observe(ReminderInput(timestamp: Double($0) / 6, contextID: "personal",
            reliable: true, rollDeviation: 2.5, shoulderDeviation: nil)).event }
        expectTrue(events.contains(.correction(.headTowardLeft)))
    }
    private let mouth = [Point(0.42, 0.4), Point(0.46, 0.42), Point(0.54, 0.42), Point(0.58, 0.4), Point(0.54, 0.38), Point(0.46, 0.38)]
    private let inner = [Point(0.46,0.4),Point(0.5,0.404),Point(0.54,0.4),Point(0.5,0.396)]
    private let left = [Point(0.34,0.6),Point(0.37,0.61),Point(0.40,0.6),Point(0.37,0.59)]
    private let right = [Point(0.60,0.6),Point(0.63,0.61),Point(0.66,0.6),Point(0.63,0.59)]
    func testFacialGeometryCorrectsImageAspectAndHeadRotation() {
        let size = ImageSize(1280,720)
        let f = FacialGeometry.features(outer: mouth, inner: inner, leftEye: left, rightEye: right, nose: [Point(0.5,0.55)], image:size)!
        expectEqual(f.outerLipAspect, 0.140625, accuracy: 0.00001)
        expectEqual(f.mouthShift, 0, accuracy: 0.00001)
        expectEqual(f.eyelidDifference!, 0, accuracy: 0.00001)
        func turn(_ p: Point) -> Point {
            let x=(p.x-0.5)*1280, y=(p.y-0.5)*720, angle=0.2
            return Point(0.5+(x*cos(angle)-y*sin(angle))*0.9/1280,0.5+(x*sin(angle)+y*cos(angle))*0.9/720)
        }
        let rotated = FacialGeometry.features(outer:mouth.map(turn),inner:inner.map(turn),leftEye:left.map(turn),
            rightEye:right.map(turn),nose:[turn(Point(0.5,0.55))],image:size)!
        expectEqual(rotated.outerLipAspect,f.outerLipAspect,accuracy:0.00001)
        expectEqual(rotated.mouthShift,f.mouthShift,accuracy:0.00001)
        expectEqual(rotated.cornerSlope,f.cornerSlope,accuracy:0.00001)
        expectEqual(rotated.mouthWidth!, f.mouthWidth!, accuracy:0.00001)
        expectEqual(rotated.upperLipThickness!, f.upperLipThickness!, accuracy:0.00001)
        expectEqual(rotated.lowerLipThickness!, f.lowerLipThickness!, accuracy:0.00001)
        expectEqual(rotated.innerMouthAsymmetry!, f.innerMouthAsymmetry!, accuracy:0.00001)
    }
    private func observation(_ time: Double, hand: Bool = false, confidence: Double = 0.95,
                             features: FacialFeatures = FacialFeatures(outerLipAspect:0.2,mouthOpening:0.02,mouthShift:0,cornerSlope:0),
                             faces: Int = 1, yaw: Double = 0) -> Observation {
        let oral = OralObservation(features:features,mouthOutline:mouth,
            fingerTips:hand ? [JointPoint(Point(0.5,0.42),confidence:confidence)] : [],handsObserved:true)
        return Observation(timestamp:time,imageSize:ImageSize(1280,720),cameraSignature:"personal",faceCount:faces,bodyCount:0,
            faceBox:FaceBox(x:0.3,y:0.3,width:0.4,height:0.5),faceConfidence:0.95,roll:0,yaw:yaw,pitch:-14,joints:[:],oral:oral)
    }
    private func feed(_ e: inout HabitEngine, start:Double, seconds:Double, reference:FacialReference? = nil,
                      hand:Bool = true, lips:Bool = false, face:Bool = false,
                      make:(Double)->Observation) -> [HabitKind] {
        (0..<Int(seconds*6)).compactMap { index in
            let o=make(start+Double(index)/6)
            return e.observe(o,metrics:QualityGate.evaluate(o),reference:reference,tuning:MonitorTuning(),hand:hand,lips:lips,face:face)
        }
    }
    func testHandMouthSustainedAndCooldown() {
        var e=HabitEngine()
        let short=feed(&e,start:0,seconds:1.5){ self.observation($0,hand:true) }
        expectTrue(short.isEmpty)
        let long=feed(&e,start:1.5,seconds:10){ self.observation($0,hand:true) }
        expectEqual(long,[.handMouth])
    }
    func testLowConfidenceAndMultipleTargetsStayQuiet() {
        var e=HabitEngine()
        expectTrue(feed(&e,start:0,seconds:6){self.observation($0,hand:true,confidence:0.2)}.isEmpty)
        expectTrue(feed(&e,start:6,seconds:6){self.observation($0,hand:true,faces:2)}.isEmpty)
        expectTrue(feed(&e,start:12,seconds:6){self.observation($0,hand:true,yaw:30)}.isEmpty)
    }
    func testPersonalAsymmetryIsNotAutomaticAbnormality() {
        var e=HabitEngine()
        let reference=FacialReference(outerLipAspect:0.2,mouthShift:0.15,cornerSlope:0.08,eyelidDifference:0.25)
        let features=FacialFeatures(outerLipAspect:0.2,mouthOpening:0.02,mouthShift:0.15,cornerSlope:0.08,eyelidDifference:0.25)
        let events=feed(&e,start:0,seconds:10,reference:reference,lips:true,face:true){self.observation($0,features:features)}
        expectTrue(events.isEmpty)
    }
    func testLipChangesNeedReferenceAndExcludeTalking() {
        var e=HabitEngine()
        let reference=FacialReference(outerLipAspect:0.3,mouthShift:0,cornerSlope:0)
        let squeezed=FacialFeatures(outerLipAspect:0.1,mouthOpening:0.02,mouthShift:0,cornerSlope:0)
        expectTrue(feed(&e,start:0,seconds:6,lips:true){self.observation($0,features:squeezed)}.isEmpty)
        e=HabitEngine()
        let talking=FacialFeatures(outerLipAspect:0.1,mouthOpening:0.3,mouthShift:0,cornerSlope:0)
        expectTrue(feed(&e,start:0,seconds:6,reference:reference,lips:true){self.observation($0,features:talking)}.isEmpty)
        let events=feed(&e,start:6,seconds:6,reference:reference,lips:true){self.observation($0,features:squeezed)}
        expectEqual(events,[.lipChange])
    }
    func testShortBlinkAndLongEyeChangeAreSeparated() {
        var e=HabitEngine()
        let reference=FacialReference(outerLipAspect:0.2,mouthShift:0,cornerSlope:0,eyelidDifference:0)
        let wink=FacialFeatures(outerLipAspect:0.2,mouthOpening:0.02,mouthShift:0,cornerSlope:0,eyelidDifference:0.4)
        expectTrue(feed(&e,start:0,seconds:0.5,reference:reference,face:true){self.observation($0,features:wink)}.isEmpty)
        expectTrue(feed(&e,start:0.5,seconds:2,reference:reference,face:true){self.observation($0)}.isEmpty)
        expectEqual(feed(&e,start:2.5,seconds:5,reference:reference,face:true){self.observation($0,features:wink)},[.eyelidChange])
    }
    func testFaceReferenceSurvivesShoulderBackendSwitch() throws {
        var collector=CalibrationCollector(context:.upperMonitor,startedAt:0,signature:"camera|1280x720|up|face3|old-body")
        for index in 0...120 {
            var o=observation(Double(index)/6,features:FacialFeatures(outerLipAspect:0.2,mouthOpening:0.02,mouthShift:0.1,cornerSlope:0,eyelidDifference:0.2))
            o.cameraSignature="camera|1280x720|up|face3|old-body"
            collector.consume(o,metrics:QualityGate.evaluate(o))
        }
        let baseline=try collector.finish(at:20)
        expectEqual(baseline.facialReference!.mouthShift,0.1,accuracy:0.000001)
        expectEqual(baseline.facialReference!.eyelidDifference!,0.2,accuracy:0.000001)
        var changed=observation(30)
        changed.cameraSignature="camera|1280x720|up|face3|new-body"
        expectTrue(baseline.matchesFace(changed.cameraSignature))
        let selected=CalibrationReferenceSelector.choose(profiles:[baseline],cameraSignature:changed.cameraSignature,
            yaw:0,pitch:-14,previousID:nil,preferredContext:.upperMonitor)
        expectEqual(selected?.id,baseline.id)
        let input=ReminderInput.make(observation:changed,metrics:QualityGate.evaluate(changed),baseline:baseline)
        expectTrue(input.reliable); expectNil(input.shoulderDeviation)
    }
    func testOpenMouthShiftAndParallelHabitTimers() {
        var e = HabitEngine(), t = MonitorTuning()
        t.handMouthSeconds = 1; t.lipChangeSeconds = 1
        let reference = FacialReference(outerLipAspect: 0.3, mouthShift: 0, cornerSlope: 0, mouthWidth: 1.0)
        let together = FacialFeatures(outerLipAspect: 0.1, mouthOpening: 0.02, mouthShift: 0.2, cornerSlope: 0.15)
        var result = e.result
        for i in 0...12 {
            let o = observation(Double(i)/6, hand: true, features: together)
            result = e.observeDetailed(o, metrics: QualityGate.evaluate(o), reference: reference, tuning: t, hand: true, lips: true, face: false, mouthShift: true)
        }
        expectEqual(Set(result.confirmedStates.map(\.kind)), Set([.handMouth, .lipChange, .facialShift]))
        let openShift = FacialFeatures(outerLipAspect: 0.5, mouthOpening: 0.2, mouthShift: 0, cornerSlope: 0, mouthWidth: 0.8)
        for i in 13...30 {
            let o = observation(Double(i)/6, features: openShift)
            result = e.observeDetailed(o, metrics: QualityGate.evaluate(o), reference: reference, tuning: t, hand: true, lips: true, face: false, mouthShift: true)
        }
        expectEqual(result.confirmedStates.map(\.kind), [.facialShift])
        expectTrue(result.confirmedStates[0].elapsedSeconds >= 4.0)
    }
    func testHabitShortRecoveryRetainsCountAndConfirmation() {
        var e = HabitEngine(), t = MonitorTuning(); t.lipChangeSeconds = 2
        let reference = FacialReference(outerLipAspect: 0.3, mouthShift: 0, cornerSlope: 0)
        let shifted = FacialFeatures(outerLipAspect: 0.3, mouthOpening: 0.2, mouthShift: 0.2, cornerSlope: 0)
        var before = 0.0, result = e.result
        for i in 0...30 {
            let active = i < 12 || i >= 18
            let o = observation(Double(i)/6, features: active ? shifted : FacialFeatures(outerLipAspect: 0.3, mouthOpening: 0.02, mouthShift: 0, cornerSlope: 0))
            result = e.observeDetailed(o, metrics: QualityGate.evaluate(o), reference: reference, tuning: t, hand: false, lips: false, face: true)
            if i == 11 { before = result.states[0].elapsedSeconds }
            if i == 17 { expectEqual(result.states[0].elapsedSeconds, before); expectTrue(result.states[0].recovering); expectTrue(result.states[0].recoverySeconds > 0) }
        }
        expectEqual(result.confirmedStates.map(\.kind), [.facialShift])
        for i in 31...36 {
            let o = observation(Double(i)/6)
            result = e.observeDetailed(o, metrics: QualityGate.evaluate(o), reference: reference, tuning: t, hand: false, lips: false, face: true)
        }
        expectEqual(result.confirmedStates.map(\.kind), [.facialShift])
        expectTrue(result.confirmedStates[0].recovering)
        for i in 37...45 {
            let o = observation(Double(i)/6)
            result = e.observeDetailed(o, metrics: QualityGate.evaluate(o), reference: reference, tuning: t, hand: false, lips: false, face: true)
        }
        expectTrue(result.confirmedStates.isEmpty)
    }
    func testHabitDropoutFreezesAndNeverConfirmsRecovery() {
        var e = HabitEngine(), t = MonitorTuning(); t.handMouthSeconds = 1
        var result = e.result
        for i in 0...8 {
            let o = observation(Double(i)/6, hand: true)
            result = e.observeDetailed(o, metrics: QualityGate.evaluate(o), reference: nil, tuning: t, hand: true, lips: false, face: false)
        }
        let count = result.confirmedStates[0].elapsedSeconds
        var lost = observation(1.5, hand: true); lost.oral = nil
        result = e.observeDetailed(lost, metrics: QualityGate.evaluate(lost), reference: nil, tuning: t, hand: true, lips: false, face: false)
        expectFalse(result.reliable); expectTrue(result.confirmedStates.isEmpty)
        expectEqual(result.states.map(\.kind), [.handMouth])
        expectEqual(result.states[0].elapsedSeconds, count)
        let back = observation(1.7, hand: true)
        result = e.observeDetailed(back, metrics: QualityGate.evaluate(back), reference: nil, tuning: t, hand: true, lips: false, face: false)
        expectEqual(result.confirmedStates[0].elapsedSeconds, count)
    }
    func testLegacyFacialFeaturesDecodeAndNewGeometryRoundTrip() throws {
        let old = Data(#"{"outerLipAspect":0.2,"mouthOpening":0.02,"mouthShift":0,"cornerSlope":0}"#.utf8)
        let f = try JSONDecoder().decode(FacialFeatures.self, from: old)
        expectNil(f.upperLipThickness); expectTrue(f.isFinite)
        let legacyReference = try JSONDecoder().decode(FacialReference.self, from: Data(#"{"outerLipAspect":0.2,"mouthShift":0,"cornerSlope":0}"#.utf8))
        expectNil(legacyReference.upperLipAsymmetry)
        let derived = FacialGeometry.features(outer: mouth, inner: inner, leftEye: left, rightEye: right, nose: [Point(0.5,0.55)], image: ImageSize(1280,720))!
        expectNotNil(derived.upperLipThickness); expectNotNil(derived.innerMouthAsymmetry)
        expectEqual(try JSONDecoder().decode(FacialFeatures.self, from: JSONEncoder().encode(derived)), derived)
    }
    func testPersonalPrototypeRequiresNeutralDistanceAndMargin() throws {
        let relaxed = FacialFeatures(outerLipAspect: 0.2, mouthOpening: 0.02, mouthShift: 0, cornerSlope: 0)
        let strained = FacialFeatures(outerLipAspect: 0.4, mouthOpening: 0.2, mouthShift: 0.1, cornerSlope: 0.05)
        let example = OralPoseExample(action: .upperLip, label: "我的上唇动作", samples: Array(repeating: strained, count: 6))
        var library = OralPoseExamples(cameraSignature: "personal", examples: [example])
        expectNil(library.match(strained))
        library.neutral = Array(repeating: relaxed, count: 6)
        expectEqual(library.reference?.outerLipAspect, relaxed.outerLipAspect)
        expectEqual(library.match(strained)?.action, .upperLip)
        expectNil(library.match(relaxed))
        let unmatched = FacialFeatures(outerLipAspect: 0.9, mouthOpening: 0.01, mouthShift: -0.2, cornerSlope: -0.3)
        expectNil(library.match(unmatched))
        let duplicate = OralPoseExample(action: .tongueSide, label: "无法区分的示范", samples: Array(repeating: strained, count: 6))
        library.examples.append(duplicate)
        expectNil(library.match(strained))
        library.examples = [OralPoseExample(action: .upperLip, label: "与放松相同", samples: Array(repeating: relaxed, count: 6))]
        expectNil(library.match(relaxed))
        expectEqual(try JSONDecoder().decode(OralPoseExamples.self, from: JSONEncoder().encode(library)), library)
    }
    func testPersonalPrototypeRunsWithoutGenericLipExperiment() {
        let relaxed = FacialFeatures(outerLipAspect: 0.2, mouthOpening: 0.02, mouthShift: 0, cornerSlope: 0)
        let upperLip = FacialFeatures(outerLipAspect: 0.4, mouthOpening: 0.2, mouthShift: 0.1, cornerSlope: 0.05)
        let library = OralPoseExamples(cameraSignature: "personal", neutral: Array(repeating: relaxed, count: 6),
            examples: [OralPoseExample(action: .upperLip, label: "上唇示范", samples: Array(repeating: upperLip, count: 6))])
        var e = HabitEngine(), t = MonitorTuning(); t.lipChangeSeconds = 1
        var result = e.result
        for i in 0...12 {
            let o = observation(Double(i)/6, features: upperLip)
            result = e.observeDetailed(o, metrics: QualityGate.evaluate(o), reference: nil, tuning: t,
                hand: false, lips: false, face: false, examples: library)
        }
        expectEqual(result.confirmedStates.map(\.kind), [.upperLipAppearance])
        expectEqual(result.matchedExample?.label, "上唇示范")
    }

    func testTwoHertzMouthAndExamplesReachThreshold() {
        let relaxed = FacialFeatures(outerLipAspect: 0.2, mouthOpening: 0.02, mouthShift: 0, cornerSlope: 0)
        let upperLip = FacialFeatures(outerLipAspect: 0.4, mouthOpening: 0.2, mouthShift: 0.1, cornerSlope: 0.05)
        let library = OralPoseExamples(cameraSignature: "personal", neutral: Array(repeating: relaxed, count: 6),
            examples: [OralPoseExample(action: .upperLip, label: "上唇示范", samples: Array(repeating: upperLip, count: 6))])
        var e = HabitEngine(), t = MonitorTuning(); t.faceHertz = 2; t.lipChangeSeconds = 1
        var result = e.result
        for i in 0...6 {
            let o = observation(Double(i)/2, features: upperLip)
            result = e.observeDetailed(o, metrics: QualityGate.evaluate(o), reference: library.reference, tuning: t,
                hand: false, lips: false, face: false, examples: library, mouthShift: true)
        }
        expectEqual(Set(result.confirmedStates.map(\.kind)), Set([.facialShift, .upperLipAppearance]))
        let frozenCounts = Dictionary(uniqueKeysWithValues: result.states.map { ($0.kind, $0.elapsedSeconds) })
        var missing = observation(3.5, features: upperLip); missing.oral = nil
        result = e.observeDetailed(missing, metrics: QualityGate.evaluate(missing), reference: library.reference, tuning: t,
            hand: false, lips: false, face: false, examples: library, mouthShift: true)
        expectFalse(result.reliable); expectTrue(result.confirmedStates.isEmpty)
        expectEqual(Dictionary(uniqueKeysWithValues: result.states.map { ($0.kind, $0.elapsedSeconds) }), frozenCounts)
        let restored = observation(4, features: upperLip)
        result = e.observeDetailed(restored, metrics: QualityGate.evaluate(restored), reference: library.reference, tuning: t,
            hand: false, lips: false, face: false, examples: library, mouthShift: true)
        expectEqual(Dictionary(uniqueKeysWithValues: result.states.map { ($0.kind, $0.elapsedSeconds) }), frozenCounts)
        // A gap longer than a sampling interval is unknown, not another counted second.
        let stalled = observation(5, features: upperLip)
        result = e.observeDetailed(stalled, metrics: QualityGate.evaluate(stalled), reference: library.reference, tuning: t,
            hand: false, lips: false, face: false, examples: library, mouthShift: true)
        expectFalse(result.reliable)
        expectEqual(Dictionary(uniqueKeysWithValues: result.states.map { ($0.kind, $0.elapsedSeconds) }), frozenCounts)
        let resumed = observation(5.5, features: upperLip)
        result = e.observeDetailed(resumed, metrics: QualityGate.evaluate(resumed), reference: library.reference, tuning: t,
            hand: false, lips: false, face: false, examples: library, mouthShift: true)
        expectEqual(Dictionary(uniqueKeysWithValues: result.states.map { ($0.kind, $0.elapsedSeconds) }), frozenCounts)
    }

}
