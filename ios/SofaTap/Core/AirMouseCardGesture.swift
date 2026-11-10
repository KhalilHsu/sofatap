import Foundation

/// One-thumb gestures on the air-mouse card. Pointer math stays in `AirMouseTracker`;
/// this type only decides which of those deltas, clicks, drags and scrolls to emit.
/// A second finger cancels the press. No protocol types are invented here.
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
    private enum Phase { case idle, tracking, rightReady, scrolling, dragging, flicked, inertia }
    private var phase = Phase.idle
    private var downTime = 0.0
    private var origin = Point(x: 0, y: 0)
    private var last = Point(x: 0, y: 0)
    private var pitch0 = 0.0
    private var yaw0 = 0.0
    private var sentX = 0.0
    private var sentY = 0.0
    private var cursorMoved = false
    private var tremorBroken = false
    private var rightDisqualified = false
    private var secondTap = false
    private var scrollAlong = 0.0
    private var pendingTap: (point: Point, deadline: Double)?
    private var inertiaLeft = 0
    private var inertiaStep = 0.0
    private(set) var needsTick = false

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
        sentX = 0
        sentY = 0
        cursorMoved = false
        tremorBroken = false
        rightDisqualified = second
        scrollAlong = 0
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

    mutating func touchMove(to point: Point, time: Double) -> [Action] {
        guard phase == .tracking || phase == .rightReady else {
            guard phase == .scrolling else { last = point; return [] }
            let delta = (point.y - origin.y) - scrollAlong
            scrollAlong = point.y - origin.y
            last = point
            return abs(delta) > 0.4 ? [.scroll(delta)] : []
        }
        last = point
        let travelX = point.x - origin.x
        let travelY = point.y - origin.y
        if secondTap && time - downTime >= config.dragArmDelay && hypot(travelX, travelY) <= config.tapSlop {
            phase = .dragging
            rightDisqualified = true
            return [.drag(true), .haptic(.medium)]
        }
        if abs(travelY) >= config.scrollTravel && abs(travelY) > abs(travelX) * 1.15 {
            phase = .scrolling
            rightDisqualified = true
            scrollAlong = travelY
            var actions: [Action] = []
            if abs(sentX) + abs(sentY) > 0.4 {
                actions.append(.pointer(-sentX, -sentY))
                sentX = 0
                sentY = 0
            }
            actions.append(.haptic(.light))
            actions.append(.scroll(travelY))
            return actions
        }
        if config.flickRightClickEnabled && abs(travelX) >= config.flickTravel && abs(travelX) > abs(travelY) * 1.15 {
            phase = .flicked
            rightDisqualified = true
            return [.rightClick, .haptic(.medium)]
        }
        if hypot(travelX, travelY) > config.tapSlop { rightDisqualified = true }
        return []
    }

    mutating func touchUp(time: Double) -> [Action] {
        let ended = phase
        let travel = origin.distance(to: last)
        let duration = time - downTime
        phase = .idle
        needsTick = pendingTap != nil || inertiaLeft > 0
        switch ended {
        case .scrolling:
            inertiaLeft = config.inertiaSteps
            inertiaStep = (last.y - origin.y) / Double(max(config.inertiaSteps, 1)) * 0.45
            needsTick = true
            return []
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

    mutating func extraFinger() -> [Action] {
        let wasDragging = phase == .dragging
        phase = .idle
        pendingTap = nil
        inertiaLeft = 0
        secondTap = false
        needsTick = false
        return wasDragging ? [.drag(false)] : []
    }

    mutating func cancel() -> [Action] { extraFinger() }

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

    private mutating func forward(_ dx: Double, _ dy: Double, time: Double, always: Bool = false) -> [Action] {
        if !always && time < downTime + config.tapFreeze { return [] }
        guard abs(dx) + abs(dy) > 0.4 else { return [] }
        cursorMoved = true
        rightDisqualified = true
        sentX += dx
        sentY += dy
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
