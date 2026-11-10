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

        func pointers(_ actions: [AirMouseCardGesture.Action]) -> [(Double, Double)] {
            actions.compactMap { if case .pointer(let x, let y) = $0 { return (x, y) }; return nil }
        }
        func scrolls(_ actions: [AirMouseCardGesture.Action]) -> [Double] {
            actions.compactMap { if case .scroll(let dy) = $0 { return dy }; return nil }
        }
        let gain = AirMouseCardGesture.Config.fineMoveTrackpadFraction
        check("fine move is 0.4 of the trackpad gain", abs(gain - 0.4) < 1e-9 && AirMouseCardGesture.Config().fineMoveGain == gain)

        var fine = AirMouseCardGesture()
        _ = fine.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        check("thumb travel inside the slop sends nothing", fine.touchMove(to: .init(x: 10, y: 0), time: 0.2).isEmpty)
        check("crossing the slop only arms fine move", fine.touchMove(to: .init(x: 15, y: 0), time: 0.22).isEmpty)
        let fineStep = pointers(fine.touchMove(to: .init(x: 25, y: 5), time: 0.25))
        check("fine move sends finger points × 0.4", fineStep.count == 1 && abs(fineStep[0].0 - 4) < 1e-9 && abs(fineStep[0].1 - 2) < 1e-9)
        check("fine move adds to the gyro instead of replacing it", fine.pose(pitch: 0.1, yaw: 0, dx: 3, dy: 0, time: 0.3).contains(.pointer(3, 0)))
        check("fine move never scrolls with one finger", scrolls(fine.touchMove(to: .init(x: 25, y: 60), time: 0.35)).isEmpty)
        let fineUp = fine.touchUp(time: 0.4)
        check("a fine move is not a click", !fineUp.contains(.leftClick) && fine.tick(1.0).isEmpty)

        var speedy = AirMouseCardGesture()
        speedy.config.pointerSpeed = 2
        _ = speedy.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = speedy.touchMove(to: .init(x: 0, y: 20), time: 0.2)
        check("fine move follows the trackpad pointer speed", speedy.touchMove(to: .init(x: 0, y: 30), time: 0.25) == [.pointer(0, 8)])

        var frozenThumb = AirMouseCardGesture()
        _ = frozenThumb.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        let earlyMoves = frozenThumb.touchMove(to: .init(x: 20, y: 0), time: 0.03) + frozenThumb.touchMove(to: .init(x: 40, y: 0), time: 0.06)
            + frozenThumb.pose(pitch: 0.2, yaw: 0, dx: 9, dy: 0, time: 0.08)
        check("nothing moves the pointer in the first 100 ms", pointers(earlyMoves).isEmpty)
        _ = frozenThumb.touchMove(to: .init(x: 42, y: 0), time: 0.12)
        check("after the freeze the thumb fine-moves from where it is", frozenThumb.touchMove(to: .init(x: 47, y: 0), time: 0.14) == [.pointer(2, 0)])

        var fineHold = AirMouseCardGesture()
        _ = fineHold.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = fineHold.tick(0.6)
        _ = fineHold.touchMove(to: .init(x: 0, y: 18), time: 0.65)
        let fineHoldUp = fineHold.touchUp(time: 0.8)
        check("fine move after the cue cancels the right click", !fineHoldUp.contains(.rightClick) && !fineHoldUp.contains(.haptic(.mediumTwice)))

        var fineFirst = AirMouseCardGesture()
        _ = fineFirst.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = fineFirst.touchMove(to: .init(x: 16, y: 0), time: 0.2)
        check("fine move before the hold time prevents the cue", !fineFirst.tick(0.7).contains(.haptic(.medium)))

        var vertical = AirMouseCardGesture()
        _ = vertical.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = vertical.touchMove(to: .init(x: 2, y: 16), time: 0.2)
        _ = vertical.touchMove(to: .init(x: 4, y: 40), time: 0.3)
        _ = vertical.touchMove(to: .init(x: 4, y: 70), time: 0.4)
        check("a vertical one-finger fine move is noted once for the hint", vertical.verticalFineSlides == 1)
        var sideways = AirMouseCardGesture()
        _ = sideways.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = sideways.touchMove(to: .init(x: 20, y: 16), time: 0.2)
        _ = sideways.touchMove(to: .init(x: 30, y: 40), time: 0.3)
        check("a diagonal fine move is not a scroll attempt", sideways.verticalFineSlides == 0)

        var scroll = AirMouseCardGesture()
        _ = scroll.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = scroll.pose(pitch: 0, yaw: 0, dx: 0, dy: 8, time: 0.2)
        let joined = scroll.twoFingerBegan(centroid: .init(x: 10, y: 100), time: 0.25)
        check("a second finger ends the thumb phase without clicks or pointer rollback", joined.isEmpty)
        check("two fingers inside the scroll threshold do nothing", scroll.twoFingerMoved(centroid: .init(x: 10, y: 106)).isEmpty)
        let started = scroll.twoFingerMoved(centroid: .init(x: 10, y: 118))
        check("two-finger travel scrolls with a light tap", started == [.haptic(.light), .scroll(18)] && scroll.twoFingerScrolls == 1)
        check("two-finger scroll keeps following the centroid", scroll.twoFingerMoved(centroid: .init(x: 10, y: 128)) == [.scroll(10)])
        check("a finger count change rebases without a jump", scroll.twoFingerMoved(centroid: .init(x: 30, y: 160), rebase: true).isEmpty
              && scroll.twoFingerMoved(centroid: .init(x: 30, y: 164)) == [.scroll(4)])
        check("lifting one of two fingers is not a thumb release", scroll.touchUp(time: 0.4).isEmpty)
        check("the gyro is ignored during a two-finger scroll", pointers(scroll.pose(pitch: 0.3, yaw: 0, dx: 9, dy: 9, time: 0.42)).isEmpty)
        check("the scroll ends quietly when every finger lifts", scroll.allFingersUp(time: 0.45).isEmpty)
        let coast = scrolls(scroll.tick(0.47))
        check("two-finger release keeps the short decaying inertia", coast.count == 1 && abs(coast[0] - 32.0 / 3 * 0.45) < 1e-9)
        check("inertia halves each tick", scrolls(scroll.tick(0.49)).first.map { abs($0 - 32.0 / 3 * 0.45 / 2) < 1e-9 } ?? false)
        _ = scroll.tick(0.51)
        check("inertia stops after three steps", scroll.tick(0.53).isEmpty && !scroll.needsTick)

        var together = AirMouseCardGesture()
        _ = together.twoFingerBegan(centroid: .init(x: 0, y: 50), time: 0)
        check("two fingers landing together scroll too", scrolls(together.twoFingerMoved(centroid: .init(x: 0, y: 30))) == [-20])
        _ = together.allFingersUp(time: 0.2)
        _ = together.touchDown(at: .init(x: 0, y: 0), time: 1, pitch: 0, yaw: 0)
        _ = together.touchUp(time: 1.1)
        check("after a scroll the next tap still clicks", together.tick(1.5).contains(.leftClick))

        var shortTwo = AirMouseCardGesture()
        _ = shortTwo.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = shortTwo.twoFingerBegan(centroid: .init(x: 0, y: 0), time: 0.05)
        let shortUp = shortTwo.allFingersUp(time: 0.12)
        check("a two-finger touch without travel neither clicks nor scrolls", shortUp.isEmpty && shortTwo.tick(0.6).isEmpty)

        var flickOff = AirMouseCardGesture()
        _ = flickOff.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        let ignored = flickOff.touchMove(to: .init(x: 55, y: 2), time: 0.12)
        check("a horizontal flick does nothing while the backup is off", !ignored.contains(.rightClick))

        var flickOn = AirMouseCardGesture()
        flickOn.config.flickRightClickEnabled = true
        _ = flickOn.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        check("a quick sideways flick waits for its window", flickOn.touchMove(to: .init(x: 20, y: 1), time: 0.11).isEmpty)
        let flicked = flickOn.touchMove(to: .init(x: 48, y: 3), time: 0.12)
        check("the backup flick sends one right click", flicked.contains(.rightClick) && flicked.contains(.haptic(.medium)))

        var slowFlick = AirMouseCardGesture()
        slowFlick.config.flickRightClickEnabled = true
        _ = slowFlick.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = slowFlick.touchMove(to: .init(x: 20, y: 1), time: 0.12)
        let late = slowFlick.touchMove(to: .init(x: 30, y: 1), time: 0.18) + slowFlick.touchMove(to: .init(x: 50, y: 1), time: 0.22)
        check("horizontal travel after 0.15 s is fine move, not a flick", !late.contains(.rightClick) && !pointers(late).isEmpty)

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

        var dragMove = AirMouseCardGesture()
        _ = dragMove.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = dragMove.touchUp(time: 0.1)
        _ = dragMove.touchDown(at: .init(x: 2, y: 1), time: 0.18, pitch: 0, yaw: 0)
        check("drag still arms on tap then hold", dragMove.touchMove(to: .init(x: 3, y: 1), time: 0.40).contains(.drag(true)))
        check("a drag moves with the gyro", dragMove.pose(pitch: 0.2, yaw: 0, dx: 5, dy: 0, time: 0.45) == [.pointer(5, 0)])
        check("a drag moves with the thumb at fine gain", dragMove.touchMove(to: .init(x: 13, y: 6), time: 0.5) == [.pointer(4, 2)])
        let dragUp = dragMove.touchUp(time: 0.7)
        check("a fine-moved drag releases the button without clicking", dragUp.contains(.drag(false)) && !dragUp.contains(.leftClick))

        var secondMoves = AirMouseCardGesture()
        _ = secondMoves.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = secondMoves.touchUp(time: 0.1)
        _ = secondMoves.touchDown(at: .init(x: 1, y: 1), time: 0.18, pitch: 0, yaw: 0)
        _ = secondMoves.touchMove(to: .init(x: 20, y: 1), time: 0.3)
        let noDrag = secondMoves.touchMove(to: .init(x: 22, y: 1), time: 0.45) + secondMoves.touchUp(time: 0.5)
        check("a second press that slides is fine move, not a drag or click",
              !noDrag.contains(.drag(true)) && !noDrag.contains(.leftClick))

        var fingers = AirMouseCardGesture()
        _ = fingers.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = fingers.touchUp(time: 0.1)
        _ = fingers.touchDown(at: .init(x: 1, y: 1), time: 0.2, pitch: 0, yaw: 0)
        _ = fingers.touchMove(to: .init(x: 1, y: 1), time: 0.45)
        let dropped = fingers.twoFingerBegan(centroid: .init(x: 20, y: 1), time: 0.5)
        check("a second finger releases a drag and does not click", dropped == [.drag(false)])
        _ = fingers.twoFingerMoved(centroid: .init(x: 20, y: 30))
        check("a released drag then scrolls with two fingers", fingers.twoFingerScrolls == 1 && fingers.allFingersUp(time: 0.7).isEmpty)

        var systemCancel = AirMouseCardGesture()
        _ = systemCancel.touchDown(at: .init(x: 0, y: 0), time: 0, pitch: 0, yaw: 0)
        _ = systemCancel.touchUp(time: 0.1)
        _ = systemCancel.touchDown(at: .init(x: 1, y: 1), time: 0.2, pitch: 0, yaw: 0)
        _ = systemCancel.touchMove(to: .init(x: 1, y: 1), time: 0.45)
        check("a system cancel releases a drag", systemCancel.cancel() == [.drag(false)])

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
