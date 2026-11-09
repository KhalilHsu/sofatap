import Foundation

/// One Euro filter (Casiez, Roussel, Vogel). The cutoff rises with speed so a
/// slow wrist stays smooth and a flick is not left behind. Timestamps are the
/// caller's monotonic clock, in seconds.
struct OneEuroFilter {
    var minimumCutoff: Double
    var beta: Double
    var derivativeCutoff: Double
    private var previous: Double?
    private var previousDerivative = 0.0
    private var previousTime: Double?

    init(minimumCutoff: Double = 1.5, beta: Double = 0.8, derivativeCutoff: Double = 1.0) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func reset() {
        previous = nil
        previousDerivative = 0
        previousTime = nil
    }

    /// Nil rejects a non-finite sample and leaves the previous output in place.
    mutating func filter(_ value: Double, time: Double) -> Double? {
        guard value.isFinite, time.isFinite, minimumCutoff > 0, derivativeCutoff > 0, beta.isFinite else { return nil }
        guard let previous, let previousTime else {
            self.previous = value
            self.previousTime = time
            previousDerivative = 0
            return value
        }
        let dt = time - previousTime
        if dt < 0 { return previous }
        if dt == 0 { return previous }
        // A stalled sensor must not be treated as a huge derivative.
        if dt > 1 {
            self.previous = value
            self.previousTime = time
            previousDerivative = 0
            return value
        }
        let derivative = (value - previous) / dt
        let smoothedDerivative = lowpass(derivative, alpha: alpha(dt: dt, cutoff: derivativeCutoff), previous: previousDerivative)
        let cutoff = minimumCutoff + beta * abs(smoothedDerivative)
        let smoothed = lowpass(value, alpha: alpha(dt: dt, cutoff: max(cutoff, 0.0001)), previous: previous)
        self.previous = smoothed
        self.previousDerivative = smoothedDerivative
        self.previousTime = time
        return smoothed
    }

    private func alpha(dt: Double, cutoff: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    private func lowpass(_ value: Double, alpha: Double, previous: Double) -> Double {
        alpha * value + (1 - alpha) * previous
    }
}

struct Vec3: Equatable {
    var x: Double
    var y: Double
    var z: Double
    static let zero = Vec3(x: 0, y: 0, z: 0)
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    func dot(_ other: Vec3) -> Double { x * other.x + y * other.y + z * other.z }
    func scaled(_ value: Double) -> Vec3 { Vec3(x: x * value, y: y * value, z: z * value) }
    func normalized() -> Vec3? {
        let length = (x * x + y * y + z * z).squareRoot()
        guard length.isFinite, length > 0.2 else { return nil }
        return scaled(1 / length)
    }
}

struct AirMouseSample: Equatable {
    var time: Double
    var gravity: Vec3
    var rotationRate: Vec3
}

/// Degrees of wrist rotation that should carry the pointer across the selected
/// display. The gain uses that display's logical width, so the same slider
/// covers a 1080-point TV and a wider one. Vertical travel uses the same
/// points-per-radian, so a degree of pitch matches a degree of yaw.
enum AirMouseGain {
    static let nominalLogicalWidth = 1920.0
    static let minimumSweepDegrees = 15.0
    static let maximumSweepDegrees = 120.0
    static let defaultSweepDegrees = 45.0

    static func clampSweep(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSweepDegrees }
        return min(maximumSweepDegrees, max(minimumSweepDegrees, value))
    }

    static func clampWidth(_ value: Double) -> Double {
        guard value.isFinite, value >= 1 else { return nominalLogicalWidth }
        return min(16_384, value)
    }

    static func pointsPerRadian(logicalWidth: Double, sweepDegrees: Double) -> Double {
        let width = clampWidth(logicalWidth)
        let degrees = clampSweep(sweepDegrees)
        return width / (degrees * Double.pi / 180)
    }

    static func points(radians: Double, logicalWidth: Double, sweepDegrees: Double) -> Double {
        guard radians.isFinite else { return 0 }
        return radians * pointsPerRadian(logicalWidth: logicalWidth, sweepDegrees: sweepDegrees)
    }
}

enum AirMouseAttitude {
    /// Below this, yaw is treated as still so bias does not walk the pointer.
    static let yawDeadZone = 0.015

    /// Signed portrait pitch in radians. Zero is upright. Positive means the top
    /// of the phone has come toward the user (aiming down). Gravity is absolute,
    /// so gyro bias cannot drift this axis. Roll is removed before the angle is
    /// measured. Nil when the phone is too close to flat for a stable sign.
    static func pitch(gravity: Vec3) -> Double? {
        guard gravity.isFinite else { return nil }
        let horizontal = hypot(gravity.x, gravity.z)
        guard hypot(gravity.y, horizontal) > 0.15 else { return nil }
        // Roll moves the lean between X and Z. The sign stays with Z so a twist
        // does not flip vertical aiming. A phone rolled fully onto its side has
        // no stable sign; the caller keeps the previous pitch.
        if abs(gravity.z) < 0.05 && abs(gravity.x) > 0.2 { return nil }
        return atan2(copysign(horizontal, gravity.z), -gravity.y)
    }

    /// Rotation about world up, in radians per second. Positive turns the phone
    /// toward the user's left while the screen faces them.
    static func yawRate(gravity: Vec3, rotation: Vec3) -> Double? {
        guard gravity.isFinite, rotation.isFinite, let up = gravity.scaled(-1).normalized() else { return nil }
        let rate = rotation.dot(up)
        return rate.isFinite ? rate : nil
    }

    static func roll(gravity: Vec3) -> Double {
        guard gravity.isFinite else { return 0 }
        return atan2(gravity.x, hypot(gravity.y, gravity.z))
    }
}

/// Specular offset in the pebble view. +x is toward the phone's right, +y is down.
struct AirMouseHighlight: Equatable {
    var x: Double
    var y: Double
    /// The reference stone's resting glint, used for Reduce Motion.
    static let reducedMotion = AirMouseHighlight(x: 0.42, y: -0.38)

    static func offset(pitch: Double, roll: Double, reduceMotion: Bool) -> AirMouseHighlight {
        guard !reduceMotion else { return reducedMotion }
        let safePitch = pitch.isFinite ? pitch : 0
        let safeRoll = roll.isFinite ? roll : 0
        return AirMouseHighlight(x: sin(safeRoll) * 0.75, y: sin(safePitch) * 0.75)
    }
}

/// Integrates yaw, reads pitch from gravity, and smooths both with a 1€ filter.
struct AirMouseTracker {
    private(set) var pitch = 0.0
    private(set) var yaw = 0.0
    private(set) var roll = 0.0
    private var integratedYaw = 0.0
    private var lastTime: Double?
    private var seeded = false
    private var holding = false
    private var frozen = false
    private var emittedPitch = 0.0
    private var emittedYaw = 0.0
    private var pitchFilter = OneEuroFilter()
    private var yawFilter = OneEuroFilter()
    private var sweepDegrees = AirMouseGain.defaultSweepDegrees
    private var logicalWidth = AirMouseGain.nominalLogicalWidth
    var logicalHeight = AirMouseGain.nominalLogicalWidth

    mutating func setMapping(sweepDegrees: Double, logicalWidth: Double, logicalHeight: Double) {
        self.sweepDegrees = AirMouseGain.clampSweep(sweepDegrees)
        self.logicalWidth = AirMouseGain.clampWidth(logicalWidth)
        self.logicalHeight = logicalHeight.isFinite && logicalHeight >= 1 ? min(16_384, logicalHeight) : AirMouseGain.nominalLogicalWidth
    }

    mutating func setFilter(minimumCutoff: Double, beta: Double) {
        pitchFilter.minimumCutoff = minimumCutoff
        pitchFilter.beta = beta
        yawFilter.minimumCutoff = minimumCutoff
        yawFilter.beta = beta
    }

    mutating func ingest(_ sample: AirMouseSample) -> Bool {
        guard sample.time.isFinite, sample.gravity.isFinite, sample.rotationRate.isFinite else { return false }
        if let lastTime {
            let dt = sample.time - lastTime
            if dt < 0 { return false }
            if dt == 0 { return true }
            if dt > 0.1 {
                pitchFilter.reset()
                yawFilter.reset()
                seeded = false
            } else if let rate = AirMouseAttitude.yawRate(gravity: sample.gravity, rotation: sample.rotationRate) {
                let usable = abs(rate) < AirMouseAttitude.yawDeadZone ? 0 : rate
                integratedYaw += usable * dt
            }
        }
        let absolutePitch = AirMouseAttitude.pitch(gravity: sample.gravity)
        if let absolutePitch, let filtered = pitchFilter.filter(absolutePitch, time: sample.time) {
            pitch = filtered
        }
        if let filteredYaw = yawFilter.filter(integratedYaw, time: sample.time) {
            yaw = filteredYaw
        }
        roll = AirMouseAttitude.roll(gravity: sample.gravity)
        lastTime = sample.time
        if !seeded, absolutePitch != nil {
            seeded = true
            emittedPitch = pitch
            emittedYaw = yaw
        }
        return true
    }

    /// Point deltas since the last emitted pose. Zero unless a hold is active
    /// and the pointer is not frozen for a tap. +x is right, +y is down.
    mutating func consume() -> (dx: Double, dy: Double) {
        guard holding, !frozen, seeded else { return (0, 0) }
        let gain = AirMouseGain.pointsPerRadian(logicalWidth: logicalWidth, sweepDegrees: sweepDegrees)
        let dx = -(yaw - emittedYaw) * gain
        let dy = (pitch - emittedPitch) * gain
        emittedYaw = yaw
        emittedPitch = pitch
        guard dx.isFinite, dy.isFinite else { return (0, 0) }
        return (dx, dy)
    }

    mutating func setHolding(_ value: Bool) { holding = value }
    mutating func setFrozen(_ value: Bool) { frozen = value }

    /// Current pose becomes the baseline. Used for recenter and for discarding
    /// the tilt that a finger press or release adds.
    mutating func rebase() {
        emittedPitch = pitch
        emittedYaw = yaw
    }
}

/// Hold-to-move contact. A short, small press is a click and contributes no
/// pointer travel. A longer press discards the initial contact tilt, then
/// tracks until release, which stops on that sample.
struct AirMouseContact {
    enum Output: Equatable {
        case move(dx: Double, dy: Double)
        case click
        case pose(pitch: Double, roll: Double)
    }

    static let clickMaxDuration = 0.18
    static let clickMaxRadians = 0.035

    private var tracker = AirMouseTracker()
    private enum Phase { case idle, pressed, moving }
    private var phase = Phase.idle
    private var pressTime = 0.0
    private var pressPitch = 0.0
    private var pressYaw = 0.0
    var isIdle: Bool { phase == .idle }
    var isMoving: Bool { phase == .moving }
    var pitch: Double { tracker.pitch }
    var roll: Double { tracker.roll }

    mutating func setMapping(sweepDegrees: Double, logicalWidth: Double, logicalHeight: Double) {
        tracker.setMapping(sweepDegrees: sweepDegrees, logicalWidth: logicalWidth, logicalHeight: logicalHeight)
    }

    mutating func setFilter(minimumCutoff: Double, beta: Double) {
        tracker.setFilter(minimumCutoff: minimumCutoff, beta: beta)
    }

    mutating func begin(_ sample: AirMouseSample) -> [Output] {
        guard phase == .idle else { return [] }
        _ = tracker.ingest(sample)
        tracker.setFrozen(true)
        tracker.rebase()
        phase = .pressed
        pressTime = sample.time
        pressPitch = tracker.pitch
        pressYaw = tracker.yaw
        return pose()
    }

    mutating func update(_ sample: AirMouseSample) -> [Output] {
        guard tracker.ingest(sample) else { return phase == .idle ? [] : pose() }
        if phase == .pressed {
            let elapsed = sample.time - pressTime
            let angle = hypot(tracker.pitch - pressPitch, tracker.yaw - pressYaw)
            if elapsed >= Self.clickMaxDuration || (angle.isFinite && angle >= Self.clickMaxRadians) {
                tracker.rebase()
                tracker.setFrozen(false)
                tracker.setHolding(true)
                phase = .moving
            }
        }
        return motion() + pose()
    }

    mutating func end(_ sample: AirMouseSample) -> [Output] {
        guard phase != .idle else { return [] }
        _ = tracker.ingest(sample)
        let click = phase == .pressed
        tracker.rebase()
        tracker.setFrozen(false)
        tracker.setHolding(false)
        phase = .idle
        return (click ? [Output.click] : []) + pose()
    }

    mutating func cancel() {
        tracker.rebase()
        tracker.setFrozen(false)
        tracker.setHolding(false)
        phase = .idle
    }

    /// The current pose becomes the display center. The receiver still has to
    /// warp the cursor; this only stops the next sample from repeating the jump.
    mutating func recenter() {
        tracker.rebase()
    }

    private mutating func motion() -> [Output] {
        let delta = tracker.consume()
        guard delta.dx != 0 || delta.dy != 0 else { return [] }
        return [.move(dx: delta.dx, dy: delta.dy)]
    }

    private func pose() -> [Output] {
        [.pose(pitch: tracker.pitch, roll: tracker.roll)]
    }
}
