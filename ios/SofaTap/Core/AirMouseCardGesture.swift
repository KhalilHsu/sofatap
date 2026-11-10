import Foundation

/// Thumb gestures on the air-mouse card. Pointer math stays in `AirMouseTracker`;
/// this type only decides which of those deltas, clicks, drags and scrolls to emit.
/// One thumb: gyro coarse move plus thumb fine move. Two fingers: vertical scroll.
/// No protocol types are invented here.
struct AirMouseCardGesture {
    struct Point: Equatable {
        var x: Double
        var y: Double
        func distance(to other: Self) -> Double { hypot(x - other.x, y - other.y) }
    }

    struct Config: Equatable {
        /// Swallow pointer motion at touch-down so a tap cannot kick the cursor.
        var tapFreeze = 0.10
        var scrollTravel = 10.0
        var flickTravel = 40.0
        /// The flick must cover `flickTravel` this soon after touch-down.
        var flickWindow = 0.15
        /// Backup right click. Off unless the user enables 「横划右键」.
        var flickRightClickEnabled = false
        var doubleTapInterval = 0.30
        var tapMaxDuration = 0.28
        var tapSlop = 14.0
        /// How long the second press must stay down before it becomes a drag.
        var dragArmDelay = 0.20
        /// Press-and-hold-still right click. Tunable from 0.5 to 0.8 seconds.
        var rightHold = 0.60
        /// Gyro motion larger than this, from the touch-down pose, is not "still".
        var tremor = 0.02
        var inertiaSteps = 3
        /// Thumb fine move as a fraction of the trackpad's base gain. The trackpad
        /// sends finger points × `pointerSpeed` (× 1.0 at precise speeds), so the
        /// stone sends finger points × 0.4 × `pointerSpeed`, added to the gyro.
        static let fineMoveTrackpadFraction = 0.4
        var fineMoveGain = Config.fineMoveTrackpadFraction
        /// The trackpad pointer speed setting (GestureConfiguration.pointerSpeed).
        var pointerSpeed = 1.0  // GestureConfiguration.defaultPointerSpeed
        /// One-finger fine moves this vertical (travel > 2× horizontal and > 30 pt)
        /// look like an attempted scroll; the page may re-show the two-finger hint.
        var verticalSlideTravel = 30.0
    }

    enum Haptic: Equatable {
        case light
        case medium
        /// Two medium impacts, 60 ms apart. Played only when a right click fires.
        case mediumTwice
    }

    enum Action: Equatable {
        case pointer(Double, Double)
        case leftClick
        case rightClick
        case drag(Bool)
        case scroll(Double)
        case haptic(Haptic)
    }

    var config = Config()
    private enum Phase { case idle, tracking, rightReady, dragging, flicked, twoFinger, scrolling }
    private var phase = Phase.idle
    private var downTime = 0.0
    private var origin = Point(x: 0, y: 0)
    private var last = Point(x: 0, y: 0)
    private var pitch0 = 0.0
    private var yaw0 = 0.0
    private var cursorMoved = false
    private var fineMoving = false
    private var tremorBroken = false
    private var rightDisqualified = false
    private var secondTap = false
    private var verticalNoted = false
    private var scrollOrigin = 0.0
    private var scrollLast = 0.0
    private var scrollAlong = 0.0
    private var pendingTap: (point: Point, deadline: Double)?
    private var inertiaLeft = 0
    private var inertiaStep = 0.0
    private(set) var needsTick = false
    /// Two-finger scrolls started on the card. The page uses it to retire its hint.
    private(set) var twoFingerScrolls = 0
    /// One-finger touches whose fine move looked like a vertical scroll attempt.
    private(set) var verticalFineSlides = 0

    mutating func touchDown(at point: Point, time: Double, pitch: Double, yaw: Double) -> [Action] {
        inertiaLeft = 0
        let second = pendingTap.map { time <= $0.deadline && $0.point.distance(to: point) <= config.tapSlop } ?? false
        var actions: [Action] = []
        if !second, let pendingTap, time >= pendingTap.deadline {
            actions.append(.leftClick)
            actions.append(.haptic(.light))
        }
        pendingTap = nil
        secondTap = second
        phase = .tracking
        downTime = time
        origin = point
        last = point
        pitch0 = pitch
        yaw0 = yaw
        cursorMoved = false
        fineMoving = false
        tremorBroken = false
        rightDisqualified = second
        verticalNoted = false
        needsTick = true
        return actions
    }

    /// `dx`/`dy` are the pointer deltas the tracker would send for this pose.
    mutating func pose(pitch: Double, yaw: Double, dx: Double, dy: Double, time: Double) -> [Action] {
        guard phase == .tracking || phase == .rightReady || phase == .dragging else { return tick(time) }
        let angle = hypot(pitch - pitch0, yaw - yaw0)
        if angle > config.tremor { tremorBroken = true }
        let proposal = abs(dx) + abs(dy) > 0.4
        if phase == .rightReady && (tremorBroken || proposal) {
            phase = .tracking
            rightDisqualified = true
            cursorMoved = cursorMoved || proposal
            return forward(dx, dy, time: time)
        }
        if phase == .dragging { return forward(dx, dy, time: time, always: true) }
        if tremorBroken { rightDisqualified = true }
        if !rightDisqualified && !secondTap && time - downTime >= config.rightHold {
            phase = .rightReady
            return [.haptic(.medium)]
        }
        // Holding still keeps the cursor put. Any real tilt after the tap
        // freeze is ordinary pointer motion and cannot also be a right click.
        return forward(dx, dy, time: time)
    }

    /// One thumb moved. Past `tapSlop` it becomes fine pointer motion on top of the gyro.
    mutating func touchMove(to point: Point, time: Double) -> [Action] {
        guard phase == .tracking || phase == .rightReady || phase == .dragging else {
            if phase != .twoFinger && phase != .scrolling { last = point }
            return []
        }
        let previous = last
        last = point
        let travelX = point.x - origin.x
        let travelY = point.y - origin.y
        let travel = hypot(travelX, travelY)
        if phase == .dragging { return fine(from: previous, to: point, time: time) }
        if secondTap && !fineMoving && time - downTime >= config.dragArmDelay && travel <= config.tapSlop {
            phase = .dragging
            rightDisqualified = true
            return [.drag(true), .haptic(.medium)]
        }
        if config.flickRightClickEnabled && !fineMoving && time - downTime <= config.flickWindow
            && abs(travelX) >= config.flickTravel && abs(travelX) > abs(travelY) * 1.15 {
            phase = .flicked
            rightDisqualified = true
            return [.rightClick, .haptic(.medium)]
        }
        if travel > config.tapSlop { rightDisqualified = true }
        if !fineMoving {
            guard travel > config.tapSlop, time >= downTime + config.tapFreeze else { return [] }
            // A fast sideways flick keeps its window when the backup is on.
            if config.flickRightClickEnabled && time - downTime <= config.flickWindow
                && abs(travelX) > abs(travelY) * 1.15 { return [] }
            // The first event past the slop only arms fine move, so nothing jumps.
            fineMoving = true
            cursorMoved = true
            if phase == .rightReady { phase = .tracking }
            return []
        }
        if !verticalNoted && abs(travelY) > config.verticalSlideTravel && abs(travelY) > abs(travelX) * 2 {
            verticalNoted = true
            verticalFineSlides += 1
        }
        return fine(from: previous, to: point, time: time)
    }

    mutating func touchUp(time: Double) -> [Action] {
        let ended = phase
        let travel = origin.distance(to: last)
        let duration = time - downTime
        if ended == .twoFinger || ended == .scrolling { return [] }
        phase = .idle
        needsTick = pendingTap != nil || inertiaLeft > 0
        switch ended {
        case .dragging:
            return [.drag(false), .haptic(.light)]
        case .flicked:
            return []
        case .rightReady:
            pendingTap = nil
            return [.rightClick, .haptic(.mediumTwice)]
        case .tracking:
            // A tap may twitch the gyro; the cursor freeze absorbs that. Thumb
            // travel or a pointer delta that was actually sent is not a tap.
            guard travel <= config.tapSlop, duration <= config.tapMaxDuration, !cursorMoved else { return [] }
            if secondTap { return [.leftClick, .leftClick, .haptic(.light)] }
            pendingTap = (origin, time + config.doubleTapInterval)
            needsTick = true
            return []
        default:
            return []
        }
    }

    /// A second finger landed (or two landed together). Ends the one-thumb phase
    /// without clicking; a held drag button is released. Nothing else is undone.
    mutating func twoFingerBegan(centroid: Point, time: Double) -> [Action] {
        let wasDragging = phase == .dragging
        phase = .twoFinger
        pendingTap = nil
        secondTap = false
        inertiaLeft = 0
        needsTick = false
        scrollOrigin = centroid.y
        scrollLast = centroid.y
        scrollAlong = 0
        return wasDragging ? [.drag(false)] : []
    }

    /// The centroid of the fingers on the card moved. `rebase` is true when the
    /// finger count changed, so the centroid jump is not read as travel.
    mutating func twoFingerMoved(centroid: Point, rebase: Bool = false) -> [Action] {
        guard phase == .twoFinger || phase == .scrolling else { return [] }
        if rebase {
            scrollOrigin += centroid.y - scrollLast
            scrollLast = centroid.y
            return []
        }
        scrollLast = centroid.y
        let travelY = centroid.y - scrollOrigin
        if phase == .twoFinger {
            guard abs(travelY) >= config.scrollTravel else { return [] }
            phase = .scrolling
            scrollAlong = travelY
            twoFingerScrolls += 1
            return [.haptic(.light), .scroll(travelY)]
        }
        let delta = travelY - scrollAlong
        scrollAlong = travelY
        return abs(delta) > 0.4 ? [.scroll(delta)] : []
    }

    /// Every finger has left the card after a two-finger phase.
    mutating func allFingersUp(time: Double) -> [Action] {
        let ended = phase
        guard ended == .twoFinger || ended == .scrolling else { return touchUp(time: time) }
        phase = .idle
        needsTick = false
        if ended == .scrolling {
            inertiaLeft = config.inertiaSteps
            inertiaStep = scrollAlong / Double(max(config.inertiaSteps, 1)) * 0.45
            needsTick = true
        }
        return []
    }

    /// The system cancelled the touches. Releases a drag; nothing clicks.
    mutating func cancel() -> [Action] {
        let wasDragging = phase == .dragging
        phase = .idle
        pendingTap = nil
        inertiaLeft = 0
        secondTap = false
        needsTick = false
        return wasDragging ? [.drag(false)] : []
    }

    mutating func tick(_ time: Double) -> [Action] {
        var actions: [Action] = []
        if phase == .tracking && !secondTap && !rightDisqualified && !tremorBroken && !cursorMoved
            && time - downTime >= config.rightHold {
            phase = .rightReady
            actions.append(.haptic(.medium))
        }
        if phase == .idle, let pendingTap, time >= pendingTap.deadline {
            self.pendingTap = nil
            actions.append(.leftClick)
            actions.append(.haptic(.light))
        }
        if inertiaLeft > 0 {
            actions.append(.scroll(inertiaStep))
            inertiaStep *= 0.5
            inertiaLeft -= 1
        }
        needsTick = pendingTap != nil || inertiaLeft > 0 || phase == .tracking || phase == .rightReady
        return actions
    }

    private mutating func fine(from previous: Point, to point: Point, time: Double) -> [Action] {
        guard phase == .dragging || time >= downTime + config.tapFreeze else { return [] }
        let scale = config.fineMoveGain * config.pointerSpeed
        let dx = (point.x - previous.x) * scale
        let dy = (point.y - previous.y) * scale
        guard dx.isFinite, dy.isFinite, abs(dx) + abs(dy) > 0.01 else { return [] }
        cursorMoved = true
        rightDisqualified = true
        return [.pointer(dx, dy)]
    }

    private mutating func forward(_ dx: Double, _ dy: Double, time: Double, always: Bool = false) -> [Action] {
        if !always && time < downTime + config.tapFreeze { return [] }
        guard abs(dx) + abs(dy) > 0.4 else { return [] }
        cursorMoved = true
        rightDisqualified = true
        return [.pointer(dx, dy)]
    }
}

enum AirMouseStone: String, CaseIterable, Equatable {
    case basalt, granite, slate, sandstone, greenstone
    var assetName: String {
        switch self {
        case .basalt: return "PebbleBasalt"
        case .granite: return "PebbleGranite"
        case .slate: return "PebbleSlate"
        case .sandstone: return "PebbleSandstone"
        case .greenstone: return "PebbleGreenstone"
        }
    }
}

struct AirMouseStoneChoice: Equatable {
    var stone: AirMouseStone
    var rotationDegrees: Double
    var mirrored: Bool
    /// Visual scale around 1. Kept inside the card.
    var scale: Double
}

enum AirMouseStones {
    /// Stone used before the first pick and whenever a saved stone is no longer offered.
    static let defaultStone: AirMouseStone = .basalt

    static let pool: [AirMouseStone] = AirMouseStone.allCases

    /// Maps a saved stone onto the current pool; unknown stones fall back to the default.
    static func resolve(_ stone: AirMouseStone?) -> AirMouseStone? {
        guard let stone else { return nil }
        return pool.contains(stone) ? stone : defaultStone
    }

    /// `unit` is in 0..<1. The previous stone is removed from the pool so a new
    /// session or connection cannot repeat it. A nil previous may return any stone.
    static func choose(previous: AirMouseStone?, unit: Double) -> AirMouseStone {
        let previous = resolve(previous)
        let remaining = pool.filter { $0 != previous }
        let options = remaining.isEmpty ? pool : remaining
        let clamped = unit.isFinite ? min(0.999999, max(0, unit)) : 0
        let index = min(options.count - 1, Int(clamped * Double(options.count)))
        return options[index]
    }

    /// `units` are four independent 0..<1 draws: stone, rotation, mirror, scale.
    static func appearance(previous: AirMouseStone?, units: (Double, Double, Double, Double)) -> AirMouseStoneChoice {
        let rotation = (units.1.isFinite ? min(0.999999, max(0, units.1)) : 0) * 360
        let scale = 0.92 + (units.3.isFinite ? min(1, max(0, units.3)) : 0) * 0.16
        return AirMouseStoneChoice(stone: choose(previous: previous, unit: units.0),
                                   rotationDegrees: rotation,
                                   mirrored: units.2 >= 0.5,
                                   scale: scale)
    }
}
