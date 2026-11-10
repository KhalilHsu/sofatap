import Foundation

@main
struct AirMouseMotionTests {
    static func main() {
        var passed = 0
        func check(_ name: String, _ value: Bool) {
            if !value { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        filterChecks(check)
        gainChecks(check)
        attitudeChecks(check)
        contactChecks(check)
        highlightChecks(check)
        shakeChecks(check)
        print("PASS \(passed) air-mouse motion checks (no device motion)")
    }

    static func filterChecks(_ check: (String, Bool) -> Void) {
        var still = OneEuroFilter()
        var value = still.filter(1.25, time: 0)
        for step in 1...120 { value = still.filter(1.25, time: Double(step) / 60) }
        check("stationary signal does not drift", abs((value ?? 0) - 1.25) < 1e-9)
        check("non-finite samples are ignored", still.filter(.nan, time: 3) == nil && still.filter(1, time: .infinity) == nil)
        var order = OneEuroFilter()
        let first = order.filter(1, time: 1)
        let second = order.filter(4, time: 1.2)
        check("reversed or repeated timestamps do not spike",
              order.filter(100, time: 1.1) == second && order.filter(9, time: 1.2) == second && first == 1)

        func capturedFraction(step: Double) -> Double {
            var filter = OneEuroFilter(minimumCutoff: 1, beta: 0.5, derivativeCutoff: 1)
            _ = filter.filter(0, time: 0)
            let output = filter.filter(step, time: 1.0 / 60) ?? 0
            return output / step
        }
        check("a fast step is admitted more readily than a slow step",
              capturedFraction(step: 10) > capturedFraction(step: 0.01) + 0.2)

        var gap = OneEuroFilter()
        _ = gap.filter(0, time: 0)
        check("a long timestamp gap reseeds instead of differentiating", gap.filter(4, time: 2) == 4)
    }

    static func gainChecks(_ check: (String, Bool) -> Void) {
        let full = AirMouseGain.points(radians: 45 * .pi / 180, logicalWidth: 1920, sweepDegrees: 45)
        check("sweep angle maps onto the selected logical width", abs(full - 1920) < 0.001)
        let wider = AirMouseGain.points(radians: 0.2, logicalWidth: 3840, sweepDegrees: 45)
        let narrower = AirMouseGain.points(radians: 0.2, logicalWidth: 1920, sweepDegrees: 45)
        check("a wider display travels more points for the same angle", abs(wider - narrower * 2) < 0.001)
        let loose = AirMouseGain.points(radians: 0.2, logicalWidth: 1920, sweepDegrees: 90)
        check("doubling the sweep angle halves the pointer travel", abs(loose - narrower / 2) < 0.001)
        check("missing width uses the nominal 1920-point display",
              AirMouseGain.pointsPerRadian(logicalWidth: .nan, sweepDegrees: 45)
                == AirMouseGain.pointsPerRadian(logicalWidth: 1920, sweepDegrees: 45))
        check("sweep limits stay inside 15 to 120 degrees",
              AirMouseGain.clampSweep(1) == 15 && AirMouseGain.clampSweep(400) == 120 && AirMouseGain.clampSweep(.nan) == 45)
        let slow = AirMouseGain.minimumSweepDegrees
        let fast = AirMouseGain.maximumSweepDegrees
        check("the slow end of the slider needs the most wrist",
              AirMouseGain.sweepDegrees(sensitivitySliderPosition: slow) == fast)
        check("the fast end of the slider needs the least wrist",
              AirMouseGain.sweepDegrees(sensitivitySliderPosition: fast) == slow)
        check("moving the slider toward fast shortens the sweep",
              AirMouseGain.sweepDegrees(sensitivitySliderPosition: 90) < AirMouseGain.sweepDegrees(sensitivitySliderPosition: 40))
        check("sensitivity position round-trips the default sweep",
              AirMouseGain.sensitivitySliderPosition(sweepDegrees: 45) == 90
                && AirMouseGain.sweepDegrees(sensitivitySliderPosition: 90) == 45)
    }

    static func attitudeChecks(_ check: (String, Bool) -> Void) {
        check("upright portrait pitch is level", abs(AirMouseAttitude.pitch(gravity: Vec3(x: 0, y: -1, z: 0)) ?? 9) < 0.0001)
        let down = gravity(pitch: 0.3, roll: 0)
        check("aiming down is positive pitch", abs((AirMouseAttitude.pitch(gravity: down) ?? 0) - 0.3) < 0.0001)
        let up = gravity(pitch: -0.25, roll: 0)
        check("aiming up is negative pitch", abs((AirMouseAttitude.pitch(gravity: up) ?? 0) + 0.25) < 0.0001)
        for roll in [0.4, -0.7, 1.2] {
            let tilted = gravity(pitch: 0.3, roll: roll)
            let measured = AirMouseAttitude.pitch(gravity: tilted) ?? 9
            check("roll \(roll) does not change pitch", abs(measured - 0.3) < 0.0001)
        }
        let upright = Vec3(x: 0, y: -1, z: 0)
        let yaw = AirMouseAttitude.yawRate(gravity: upright, rotation: Vec3(x: 0.2, y: 0.4, z: -0.3)) ?? 0
        check("horizontal rate is the component about gravity, not device pitch", abs(yaw - 0.4) < 0.0001)
        let pitched = gravity(pitch: 0.5, roll: 0)
        let upVector = pitched.scaled(-1).normalized()!
        let aboutUp = AirMouseAttitude.yawRate(gravity: pitched, rotation: upVector) ?? 0
        check("yaw follows world up while the phone is tilted", abs(aboutUp - 1) < 0.0001)
        check("tiny yaw is inside the still dead zone", AirMouseAttitude.yawDeadZone == 0.015)
    }

    static func contactChecks(_ check: (String, Bool) -> Void) {
        var tap = prepared()
        _ = tap.begin(sample(time: 0, pitch: 0))
        var tapTravel = 0.0
        for step in 1...4 {
            tapTravel += travel(tap.update(sample(time: Double(step) / 60, pitch: 0.01)))
        }
        let ended = tap.end(sample(time: 0.1, pitch: 0.012))
        check("a short small press is a click", ended.contains(.click))
        check("a tap does not move the pointer", abs(tapTravel) < 0.01 && !ended.contains { if case .move = $0 { return true }; return false })

        var held = prepared()
        _ = held.begin(sample(time: 0, pitch: 0))
        var started: Double?
        var moved = 0.0
        var endPitch = 0.0
        for step in 1...18 {
            let pitch = min(0.4, 0.4 * Double(step) / 18)
            let outputs = held.update(sample(time: Double(step) / 60, pitch: pitch))
            let dy = travel(outputs)
            if held.isMoving, started == nil, let pose = posePitch(outputs) { started = pose + dy / gain }
            moved += dy
            if let pose = posePitch(outputs) { endPitch = pose }
        }
        let release = held.end(sample(time: 0.32, pitch: 0.4, yawRate: 2))
        check("release is not a click once the hold has started", !release.contains(.click))
        check("release does not add another jump", travel(release) == 0)
        if let started {
            check("travel after the press equals the negated post-compensation pitch",
                  abs(moved + (endPitch - started) * gain) < 1.5)
            check("the press tilt itself is removed", moved > -(0.4 * gain - 20) && moved < 0)
        } else {
            check("hold became active", false)
        }
        var after = 0.0
        for step in 1...10 {
            after += travel(held.update(sample(time: 0.4 + Double(step) / 60, pitch: 0.4, yawRate: 3)))
        }
        check("release stops motion immediately", after == 0)

        var drift = prepared()
        _ = drift.begin(sample(time: 0, pitch: 0))
        var vertical = 0.0
        for step in 1...180 {
            vertical += travel(drift.update(sample(time: Double(step) / 60, pitch: 0, pitchRate: 0.2)))
        }
        check("pitch-rate bias does not walk the vertical axis", abs(vertical) < 1)

        var yaw = prepared()
        _ = yaw.begin(sample(time: 0, pitch: 0))
        _ = yaw.update(sample(time: 0.2, pitch: 0))
        var horizontal = 0.0
        for step in 1...60 {
            horizontal += travelX(yaw.update(sample(time: 0.2 + Double(step) / 60, pitch: 0, yawRate: 1)))
        }
        for step in 1...30 {
            horizontal += travelX(yaw.update(sample(time: 1.2 + Double(step) / 60, pitch: 0)))
        }
        check("one radian of left yaw moves one sweep-scaled step left", abs(horizontal + gain) < 8)

        var stillYaw = prepared()
        _ = stillYaw.begin(sample(time: 0, pitch: 0))
        _ = stillYaw.update(sample(time: 0.2, pitch: 0))
        var creep = 0.0
        for step in 1...120 {
            creep += travelX(stillYaw.update(sample(time: 0.2 + Double(step) / 60, pitch: 0, yawRate: 0.01)))
        }
        check("yaw inside the dead zone does not creep", abs(creep) < 1)

        var aim = prepared()
        _ = aim.begin(sample(time: 0, pitch: 0))
        _ = aim.update(sample(time: 0.2, pitch: 0))
        // UIKit and Quartz global display Y both grow downward. An upward
        // trackpad swipe is negative dy, and MacInput adds dy to cursor Y, so
        // negative dy moves the pointer up. Raising the top of the phone
        // increases measured pitch; that delta is negated.
        let raised = travel(aim.update(sample(time: 0.25, pitch: 0.1)))
        check("raising the phone top sends negative dy, like an upward trackpad swipe", raised < -0.05 * gain)

        var center = prepared()
        _ = center.begin(sample(time: 0, pitch: 0))
        _ = center.update(sample(time: 0.2, pitch: 0))
        _ = center.update(sample(time: 0.25, pitch: 0.2))
        center.recenter()
        let same = travel(center.update(sample(time: 0.3, pitch: 0.2)))
        let next = travel(center.update(sample(time: 0.35, pitch: 0.3)))
        check("recenter makes the current pose the origin", abs(same) < 1 && abs(next + 0.1 * gain) < 3)

        var wide = prepared(width: 3840, height: 100)
        var tall = prepared(width: 1920, height: 4000)
        _ = wide.begin(sample(time: 0, pitch: 0))
        _ = tall.begin(sample(time: 0, pitch: 0))
        _ = wide.update(sample(time: 0.2, pitch: 0))
        _ = tall.update(sample(time: 0.2, pitch: 0))
        let wideTravel = travel(wide.update(sample(time: 0.25, pitch: 0.1)))
        let tallTravel = travel(tall.update(sample(time: 0.25, pitch: 0.1)))
        check("logical width changes the gain and height does not",
              abs(wideTravel - tallTravel * 2) < 3 && abs(tallTravel + 0.1 * AirMouseGain.pointsPerRadian(logicalWidth: 1920, sweepDegrees: 45)) < 3)

        var paused = prepared()
        _ = paused.begin(sample(time: 0, pitch: 0))
        _ = paused.update(sample(time: 0.2, pitch: 0))
        _ = paused.update(sample(time: 0.25, pitch: 0.2))
        let resumed = travel(paused.update(sample(time: 1.0, pitch: 0.8)))
        check("a sensing gap does not fling the pointer", abs(resumed) < 1)

        paused.cancel()
        let cancelled = travel(paused.update(sample(time: 1.1, pitch: 0, yawRate: 4)))
        check("cancel leaves no residual motion", cancelled == 0)
    }

    static func highlightChecks(_ check: (String, Bool) -> Void) {
        let level = AirMouseHighlight.offset(pitch: 0, roll: 0, reduceMotion: false)
        let tilted = AirMouseHighlight.offset(pitch: 0.4, roll: -0.5, reduceMotion: false)
        check("highlight follows pitch and roll", level == AirMouseHighlight(x: 0, y: 0) && tilted.x < 0 && tilted.y > 0)
        let reduced = AirMouseHighlight.offset(pitch: 0.4, roll: -0.5, reduceMotion: true)
        check("Reduce Motion keeps one static highlight",
              reduced == .reducedMotion && reduced == AirMouseHighlight.offset(pitch: -1, roll: 1, reduceMotion: true))
    }

    static func gravity(pitch: Double, roll: Double) -> Vec3 {
        let y = -cos(pitch)
        let z = sin(pitch)
        let cosine = cos(roll), sine = sin(roll)
        return Vec3(x: sine * z, y: y, z: cosine * z)
    }

    static func prepared(width: Double = 1920, height: Double = 1080) -> AirMouseContact {
        var contact = AirMouseContact()
        contact.setMapping(sweepDegrees: 45, logicalWidth: width, logicalHeight: height)
        contact.setFilter(minimumCutoff: 100_000, beta: 0)
        return contact
    }

    static var gain: Double { AirMouseGain.pointsPerRadian(logicalWidth: 1920, sweepDegrees: 45) }

    static func sample(time: Double, pitch: Double, yawRate: Double = 0, pitchRate: Double = 0) -> AirMouseSample {
        let g = gravity(pitch: pitch, roll: 0)
        let up = g.scaled(-1).normalized() ?? Vec3(x: 0, y: 1, z: 0)
        // Device x is the pitch axis while roll is zero. Add it without changing the vertical component.
        let rate = up.scaled(yawRate)
        return AirMouseSample(time: time, gravity: g, rotationRate: Vec3(x: rate.x + pitchRate, y: rate.y, z: rate.z))
    }

    static func shakeChecks(_ check: (String, Bool) -> Void) {
        func run(_ samples: [(Double, Double)]) -> Int {
            var detector = AirMouseShakeDetector()
            return samples.filter { detector.ingest(time: $0.0, acceleration: Vec3(x: $0.1, y: 0, z: 0)) }.count
        }
        check("a quick back-and-forth shake recenters once", run([(0, 2), (0.08, -2.2), (0.16, 2.1), (0.24, -2)]) == 1)
        check("one push, like picking the phone up, does not recenter", run([(0, 2), (0.05, 2.4), (0.1, 1.8), (0.2, 0.2)]) == 0)
        check("a push and a stop, like setting it down, does not recenter", run([(0, -1.8), (0.2, 1.9), (0.5, 0.1)]) == 0)
        check("gentle wobble below the threshold is ignored", run([(0, 0.9), (0.1, -1.0), (0.2, 1.1), (0.3, -0.9)]) == 0)
        check("slow reversals outside the window do not add up", run([(0, 2), (0.7, -2), (1.4, 2)]) == 0)
        check("a long shake fires once per cooldown",
              run([(0, 2), (0.08, -2), (0.16, 2), (0.24, -2), (0.32, 2), (0.4, -2), (0.48, 2)]) == 1)
        var odd = AirMouseShakeDetector()
        check("non-finite samples are ignored", !odd.ingest(time: .nan, acceleration: Vec3(x: 3, y: 0, z: 0)))
    }

    static func travel(_ outputs: [AirMouseContact.Output]) -> Double {
        outputs.reduce(0) { partial, output in
            if case .move(_, let dy) = output { return partial + dy }
            return partial
        }
    }

    static func travelX(_ outputs: [AirMouseContact.Output]) -> Double {
        outputs.reduce(0) { partial, output in
            if case .move(let dx, _) = output { return partial + dx }
            return partial
        }
    }

    static func posePitch(_ outputs: [AirMouseContact.Output]) -> Double? {
        for case .pose(let pitch, _) in outputs { return pitch }
        return nil
    }
}
