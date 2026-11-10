import Foundation

@main
struct AirMouseCardGestureTests {
    static func main() {
        var passed = 0
        func check(_ name: String, _ value: Bool) {
            if !value { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }

        var tap = AirMouseCardGesture()
        _ = tap.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        let frozen = tap.pose(pitch: 0.2, yaw: 0, dx: 30, dy: 0, time: 0.05)
        check("the first 100 ms of a touch sends no pointer", frozen.isEmpty)
        let lifted = tap.touchUp(time: 0.15)
        check("a short press waits out the double-tap window", lifted.isEmpty)
        let single = tap.tick(0.50)
        check("one tap is a left click", single.contains(.leftClick) && !single.contains(.rightClick))

        var twice = AirMouseCardGesture()
        _ = twice.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = twice.touchUp(time: 0.1)
        _ = twice.touchDown(at: .init(x: 4, y: 2), time: 0.2, pitch: 0, yaw: 0)
        let doubled = twice.touchUp(time: 0.28)
        check("a second tap is two left clicks", doubled.filter { $0 == .leftClick }.count == 2)

        var drag = AirMouseCardGesture()
        _ = drag.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = drag.touchUp(time: 0.1)
        _ = drag.touchDown(at: .init(x: 2, y: 1), time: 0.18, pitch: 0, yaw: 0)
        let armed = drag.touchMove(to: .init(x: 3, y: 1), time: 0.40)
        check("tap then hold presses the mouse button", armed.contains(.drag(true)))
        let released = drag.touchUp(time: 0.7)
        check("releasing a drag lets the button up", released.contains(.drag(false)) && !released.contains(.leftClick))

        var scroll = AirMouseCardGesture()
        _ = scroll.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = scroll.pose(pitch: 0, yaw: 0, dx: 0, dy: 8, time: 0.2)
        let slid = scroll.touchMove(to: .init(x: 1, y: 18), time: 0.22)
        check("a vertical thumb slide rolls the pointer back and scrolls",
              slid.contains(.pointer(0, -8)) && slid.contains(.scroll(18)))
        _ = scroll.touchUp(time: 0.3)
        let coast = scroll.tick(0.32)
        check("scroll release keeps a short decaying inertia", coast.contains { if case .scroll = $0 { return true }; return false })

        var flickOff = AirMouseCardGesture()
        _ = flickOff.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        let ignored = flickOff.touchMove(to: .init(x: 55, y: 2), time: 0.12)
        check("a horizontal flick does nothing while the backup is off", !ignored.contains(.rightClick))

        var flickOn = AirMouseCardGesture()
        flickOn.config.flickRightClickEnabled = true
        _ = flickOn.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        let flicked = flickOn.touchMove(to: .init(x: 48, y: 3), time: 0.12)
        check("the backup flick sends one right click", flicked.contains(.rightClick) && flicked.contains(.haptic(.medium)))

        var hold = AirMouseCardGesture()
        _ = hold.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        let early = hold.tick(0.4)
        check("holding still before the threshold does not cue", !early.contains(.haptic(.medium)))
        let ready = hold.tick(0.6)
        check("a still hold cues with one medium tap", ready == [.haptic(.medium)])
        let fired = hold.touchUp(time: 0.75)
        check("releasing after the cue is a right click with a double medium tap",
              fired.contains(.rightClick) && fired.contains(.haptic(.mediumTwice)) && !fired.contains(.leftClick))

        var tilt = AirMouseCardGesture()
        _ = tilt.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = tilt.tick(0.6)
        let cancelled = tilt.pose(pitch: 0.08, yaw: 0, dx: 4, dy: 0, time: 0.7)
        check("tilting after the cue sends no extra haptic", !cancelled.contains { if case .haptic = $0 { return true }; return false })
        check("tilting after the cue becomes pointer motion", cancelled.contains(.pointer(4, 0)))
        let afterTilt = tilt.touchUp(time: 0.9)
        check("a cancelled hold does not right-click", !afterTilt.contains(.rightClick) && !afterTilt.contains(.haptic(.mediumTwice)))

        var moved = AirMouseCardGesture()
        _ = moved.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = moved.pose(pitch: 0, yaw: 0, dx: 6, dy: 0, time: 0.2)
        let noCue = moved.tick(0.7)
        check("cursor travel disables the still right click", !noCue.contains(.haptic(.medium)) && !moved.touchUp(time: 0.8).contains(.rightClick))

        var shaky = AirMouseCardGesture()
        _ = shaky.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = shaky.pose(pitch: 0.05, yaw: 0, dx: 0, dy: 0, time: 0.2)
        check("gyro tremor before the cue disables the still right click", !shaky.tick(0.7).contains(.haptic(.medium)))

        var fingers = AirMouseCardGesture()
        _ = fingers.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = fingers.touchUp(time: 0.1)
        _ = fingers.touchDown(at: .init(x: 1, y: 1), time: 0.2, pitch: 0, yaw: 0)
        _ = fingers.touchMove(to: .init(x: 1, y: 1), time: 0.45)
        let dropped = fingers.extraFinger()
        check("a second finger releases a drag and does not click", dropped == [.drag(false)])

        let again = AirMouseStones.choose(previous: .basalt, unit: 0)
        check("a new stone does not repeat the previous one", again != .basalt)
        let allDifferent = AirMouseStone.allCases.allSatisfy { previous in
            (0..<20).allSatisfy { step in
                AirMouseStones.choose(previous: previous, unit: Double(step) / 20) != previous
            }
        }
        check("every previous stone is excluded across the unit interval", allDifferent)
        let look = AirMouseStones.appearance(previous: .slate, units: (0, 0.25, 0.8, 0.5))
        check("appearance draws rotation, mirror and scale without repeating",
              look.stone != .slate && abs(look.rotationDegrees - 90) < 0.001 && look.mirrored && abs(look.scale - 1.0) < 0.001)

        print("PASS \(passed) air-mouse card gesture checks (no device input)")
    }
}
