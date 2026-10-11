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
}
