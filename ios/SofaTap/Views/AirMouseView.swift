import SwiftUI
import UIKit

/// Air-mouse card. The pebble is a catalog photo (`PebbleBasalt` and the other
/// four stones), lit amber while held, with a tilt highlight and a 2.4 s breath.
struct AirMouseView: View {
    @ObservedObject var model: ControllerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var song = KareSong.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            AirMouseTouchLayer(onDown: { model.airMouseFingerDown(x: Double($0.x), y: Double($0.y)) },
                               onMove: { model.airMouseFingerMove(x: Double($0.x), y: Double($0.y)) },
                               onUp: { model.airMouseFingerUp() },
                               onTwoBegan: { model.airMouseTwoFingerBegan(x: Double($0.x), y: Double($0.y)) },
                               onTwoMoved: { model.airMouseTwoFingerMoved(x: Double($0.x), y: Double($0.y), rebase: $1) },
                               onTwoEnded: { model.airMouseTwoFingerEnded() },
                               onCancel: { model.airMouseCancelTouches() })
            controls
        }
        .onAppear { pushGestureSettings() }
        .onChangeCompat(of: flickRightClick) { _, _ in pushGestureSettings() }
        .onChangeCompat(of: rightHold) { _, _ in pushGestureSettings() }
        .onChangeCompat(of: storedSweep) { _, value in model.setAirMouseSweepDegrees(value) }
    }

    @AppStorage("sofatap.airMouse.flickRightClick") private var flickRightClick = false
    @AppStorage("sofatap.airMouse.rightHold") private var rightHold = 0.6
    @AppStorage(ControllerModel.airMouseSweepKey) private var storedSweep = AirMouseGain.defaultSweepDegrees
    @AppStorage("sofatap.airMouse.hintSeen") private var hintSeen = false
    @State private var showHint = false
    /// Two-finger scroll hint: the first three visits after this update, plus one
    /// recovery per visit after a vertical one-finger slide. Retired by a real
    /// two-finger scroll on this page.
    @AppStorage("sofatap.airMouse.scrollHintVisits") private var scrollHintVisits = 0
    @AppStorage("sofatap.airMouse.twoFingerScrollDone") private var twoFingerScrollDone = false
    @State private var scrollHintOpacity = 0.0
    @State private var scrollHintGeneration = 0
    @State private var scrollHintRecoveryUsed = false
    /// Survives view rebuilds within the launch that first showed the hint.
    private static var hintShownThisLaunch = false

    private func pushGestureSettings() {
        model.setAirMouseCard(flickRightClick: flickRightClick, rightHold: rightHold)
    }

    /// The page is the toggle and one stone. Display, recenter and
    /// sensitivity live in the device menu and settings.
    private var controls: some View {
        // The stone sits on the ring centre of the static sand bitmap, which is
        // laid out in screen coordinates; the label sits under it on one line.
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let screen = UIScreen.main.bounds.size
            let center = KareSandBackground.stoneCenter(screen: screen)
            let local = CGPoint(x: center.x - frame.minX, y: center.y - frame.minY)
            let small = Kare.isSmallScreen
            ZStack {
                pebble.position(local)
                stoneLabel
                    .overlay(alignment: .bottom) { scrollHint(width: max(0, geo.size.width - 44)) }
                    .position(x: local.x, y: local.y + (small ? 202 : 238) + 10)
                VStack(spacing: 6) {
                    if showHint {
                        Text(airMouseHint)
                            .font(Kare.song(15)).tracking(1)
                            .foregroundStyle(Kare.ink2)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                    if model.connected && !model.receiverState.supportsDisplayCentering {
                        Text(verbatim: ControllerModel.recenterUnsupportedNotice)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Kare.accent)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("airMouseRecenterNotice")
                    }
                }
                .padding(.horizontal, 22)
                .position(x: local.x, y: local.y - (small ? 132 : 162))
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // The hint shows only on the first visit.
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--demo-hint-seen") { hintSeen = true }
#endif
            if !hintSeen { hintSeen = true; Self.hintShownThisLaunch = true }
            showHint = Self.hintShownThisLaunch
            beginScrollHintVisit()
        }
        .onDisappear { hideScrollHint(animated: false) }
        .onChangeCompat(of: model.airMouseTwoFingerScrolls) { old, new in
            guard new > old else { return }
            twoFingerScrollDone = true
            hideScrollHint(animated: !reduceMotion)
        }
        .onChangeCompat(of: model.airMouseVerticalSlides) { old, new in
            guard new > old, !twoFingerScrollDone, !scrollHintRecoveryUsed else { return }
            scrollHintRecoveryUsed = true
            flashScrollHint()
        }
        .onAppear { if scenePhase == .active { model.startAirMouseSession() } }
        .onDisappear { model.stopAirMouse() }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .active { model.startAirMouseSession() }
            else { model.airMouseFingerUp(); model.stopAirMouse() }
        }
        .onChangeCompat(of: model.connected) { _, _ in
            if scenePhase == .active { model.startAirMouseSession() }
        }
    }

    private var airMouseHint: String { String(localized: "按住移动 · 轻点单击") }

    /// 13 pt PingFang for Chinese, the system face elsewhere; one line, down to 12 pt.
    private func scrollHint(width: CGFloat) -> some View {
        let chinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? false
        return Text(String(localized: "两指上下滑 · 滚动"))
            .font(chinese ? .custom("PingFang SC", size: 13) : .system(size: 13))
            .foregroundStyle(Kare.mute)
            .lineLimit(1)
            .minimumScaleFactor(12.0 / 13.0)
            .multilineTextAlignment(.center)
            .frame(width: width)
            .opacity(scrollHintOpacity)
            .accessibilityHidden(scrollHintOpacity == 0)
            .accessibilityIdentifier("airMouseScrollHint")
            // Hint top sits 12 pt under the stone name.
            .alignmentGuide(.bottom) { $0[.top] - 12 }
    }

    private func beginScrollHintVisit() {
        scrollHintRecoveryUsed = false
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--demo-scroll-hint") {
            scrollHintGeneration += 1
            scrollHintOpacity = 1
            return
        }
#endif
        guard !twoFingerScrollDone, scrollHintVisits < 3 else { return }
        scrollHintVisits += 1
        flashScrollHint()
    }

    /// Fade in 300 ms, hold 3 s, fade out 600 ms. Reduce Motion shows and hides plainly.
    private func flashScrollHint() {
        scrollHintGeneration += 1
        let generation = scrollHintGeneration
        let plain = reduceMotion
        if plain { scrollHintOpacity = 1 } else { withAnimation(.easeIn(duration: 0.3)) { scrollHintOpacity = 1 } }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: plain ? 3_000_000_000 : 3_300_000_000)
            guard generation == scrollHintGeneration else { return }
            hideScrollHint(animated: !plain)
        }
    }

    private func hideScrollHint(animated: Bool) {
        scrollHintGeneration += 1
        if animated { withAnimation(.easeOut(duration: 0.6)) { scrollHintOpacity = 0 } } else { scrollHintOpacity = 0 }
    }

    /// 玄武岩 Basalt — Song in ink2, then the Latin name in italic mute.
    private var stoneLabel: some View {
        let names = Self.stoneNames(model.airMouseAppearance.stone.assetName)
        return HStack(spacing: 6) {
            Text(names.local).font(Kare.song(17)).foregroundStyle(Kare.ink)
            if names.local != names.latin {
                Text(verbatim: names.latin).font(Kare.latinItalic(17)).foregroundStyle(Kare.ink2)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityIdentifier("airMouseStoneName")
    }

    static func stoneNames(_ asset: String) -> (local: String, latin: String) {
        switch asset {
        case "PebbleBasalt": return (String(localized: "玄武岩"), "Basalt")
        case "PebbleGranite": return (String(localized: "花岗岩"), "Granite")
        case "PebbleSlate": return (String(localized: "辉长岩"), "Gabbro")
        case "PebbleSandstone": return (String(localized: "板岩"), "Slate")
        default: return (String(localized: "绿岩"), "Greenstone")
        }
    }

    private var pebble: some View {
        let choice = model.airMouseAppearance
        // Re-exported pebbles carry a 4% transparent margin (stone = 92% of the
        // image width), so a 326/260pt image keeps the stone itself at 300/240pt.
        let longEdge: CGFloat = Kare.isSmallScreen ? 260 : 326
        let lit = model.airMoving
        let motion = reduceMotion ? Animation.easeOut(duration: 0.1) : (lit ? .easeOut(duration: 0.14) : .easeOut(duration: 0.2))
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let wave = reduceMotion ? 0.0 : 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate / 2.4 * 2 * Double.pi)
            let breathScale = reduceMotion ? 1.0 : 0.98 + 0.05 * wave
            // Breathing stays subtle so a dark stone never fades into the sand.
            let breathOpacity = reduceMotion ? 1.0 : 0.9 + 0.1 * wave
            stoneImage(longEdge: longEdge)
                .opacity(breathOpacity)
                .scaleEffect(x: (choice.mirrored ? -1 : 1) * choice.scale * breathScale, y: choice.scale * breathScale)
                .rotationEffect(.degrees(choice.rotationDegrees))
                .animation(motion, value: lit)
        }
        // Tall enough for a rotated, breathing stone so nothing above covers it.
        .frame(width: longEdge, height: longEdge * 0.86)
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .accessibilityIdentifier("airMousePebble")
    }

    private func stoneImage(longEdge: CGFloat) -> some View {
        let name = model.airMouseAppearance.stone.assetName
        let highlight = tiltHighlight
        return Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: longEdge)
            .overlay {
                if model.airMoving {
                    Image(name)
                        .resizable()
                        .scaledToFit()
                        .colorMultiply(Kare.accent)
                        .opacity(0.22)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // Soft radial highlight: 0.55 at the center, gone by 40% of the
                // radius, masked by the stone's alpha so it sits in the texture.
                GeometryReader { geo in
                    let radius = max(geo.size.width, geo.size.height) / 2
                    // A small, faint sheen at the upper left, nudged by tilt;
                    // the stone's own texture carries the look.
                    Rectangle()
                        .fill(RadialGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0)],
                                             center: UnitPoint(x: highlight.x, y: highlight.y),
                                             startRadius: 0, endRadius: radius * 0.22))
                        .allowsHitTesting(false)
                }
                .mask(Image(name).resizable().scaledToFit())
            }
            // Dark sand: lift the stone and add a faint rim so even Gabbro
            // stands clearly above the sand in peripheral vision.
            .brightness(colorScheme == .dark ? 0.10 : 0)
            .contrast(colorScheme == .dark ? 1.08 : 1)
            .shadow(color: colorScheme == .dark ? Kare.ink.opacity(0.16) : .clear, radius: 10)
            .shadow(color: Kare.stoneShadow, radius: 12, y: 26)
            .shadow(color: model.airMoving ? Kare.stoneLit : .clear, radius: model.airMoving ? 8 : 0)
    }

    /// Highlight center as a fraction of the stone. Pitch and roll are radians.
    private var tiltHighlight: (x: Double, y: Double) {
        let pitch = min(30, max(-30, model.airMousePitch * 180 / .pi))
        let roll = min(30, max(-30, model.airMouseRoll * 180 / .pi))
        return (0.32 + roll * 0.004, 0.28 - pitch * 0.004)
    }

    static func displayLabel(_ display: RemoteDisplay) -> String {
        let scale = display.scale == display.scale.rounded() ? "\(Int(display.scale))x" : String(format: "%.1fx", display.scale)
        let size = "\(display.width)×\(display.height) · \(scale)"
        guard display.isMain else { return size }
        return size + " · " + String(localized: "主屏幕")
    }
}

/// Text-only 触控 / 空鼠 tabs under the device name.
struct RemoteSurfaceToggle: View {
    @Binding var airMouse: Bool
    var enabled: Bool

    var body: some View {
        KareTabs(titles: [String(localized: "触控"), String(localized: "空鼠")], selected: airMouse ? 1 : 0, enabled: enabled) { index in
            let air = index == 1
            guard air != airMouse else { return }
            airMouse = air
            UISelectionFeedbackGenerator().selectionChanged()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remoteSurfaceToggle")
    }
}

private struct AirMouseTouchLayer: UIViewRepresentable {
    var onDown: (CGPoint) -> Void
    var onMove: (CGPoint) -> Void
    var onUp: () -> Void
    var onTwoBegan: (CGPoint) -> Void
    var onTwoMoved: (CGPoint, Bool) -> Void
    var onTwoEnded: () -> Void
    var onCancel: () -> Void

    func makeUIView(context: Context) -> AirMouseTouchView {
        let view = AirMouseTouchView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: AirMouseTouchView, context: Context) {
        uiView.onDown = onDown
        uiView.onMove = onMove
        uiView.onUp = onUp
        uiView.onTwoBegan = onTwoBegan
        uiView.onTwoMoved = onTwoMoved
        uiView.onTwoEnded = onTwoEnded
        uiView.onCancel = onCancel
    }
}

/// One thumb drives the gyro card gesture. As soon as a second finger lands the
/// touch becomes a two-finger scroll, reported as the centroid of the fingers
/// still down, until every finger has lifted.
final class AirMouseTouchView: UIView {
    var onDown: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onUp: (() -> Void)?
    var onTwoBegan: ((CGPoint) -> Void)?
    /// The flag is true when the finger count changed, so the centroid jump is not travel.
    var onTwoMoved: ((CGPoint, Bool) -> Void)?
    var onTwoEnded: (() -> Void)?
    var onCancel: (() -> Void)?
    private var touching: [UITouch] = []
    private var multi = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { return nil }

    private var centroid: CGPoint {
        let points = touching.map { $0.location(in: self) }
        guard !points.isEmpty else { return .zero }
        let count = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / count, y: points.map(\.y).reduce(0, +) / count)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasEmpty = touching.isEmpty
        touching.append(contentsOf: touches.filter { !touching.contains($0) })
        if multi {
            onTwoMoved?(centroid, true)
        } else if touching.count > 1 {
            multi = true
            onTwoBegan?(centroid)
        } else if wasEmpty, let touch = touching.first {
            onDown?(touch.location(in: self))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !touching.isEmpty else { return }
        if multi {
            if touching.count > 1 { onTwoMoved?(centroid, false) }
        } else if let touch = touching.first, touches.contains(touch) {
            onMove?(touch.location(in: self))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let before = touching.count
        touching.removeAll { touches.contains($0) }
        guard before > 0, touching.count != before else { return }
        if touching.isEmpty {
            if multi { multi = false; onTwoEnded?() } else { onUp?() }
        } else if multi {
            onTwoMoved?(centroid, true)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let before = touching.count
        touching.removeAll { touches.contains($0) }
        guard before > 0, touching.count != before else { return }
        if touching.isEmpty {
            multi = false
            onCancel?()
        } else if multi {
            onTwoMoved?(centroid, true)
        }
    }
}
