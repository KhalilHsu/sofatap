import SwiftUI
import UIKit

/// Air-mouse card. The pebble is a catalog photo (`PebbleBasalt` and the other
/// four stones), lit amber while held, with a tilt highlight and a 2.4 s breath.
struct AirMouseView: View {
    @ObservedObject var model: ControllerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            AirMouseTouchLayer(onDown: { model.airMouseFingerDown(x: Double($0.x), y: Double($0.y)) },
                               onMove: { model.airMouseFingerMove(x: Double($0.x), y: Double($0.y)) },
                               onUp: { model.airMouseFingerUp() },
                               onCancel: { model.airMouseExtraFinger() })
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
    /// Survives view rebuilds within the launch that first showed the hint.
    private static var hintShownThisLaunch = false

    private func pushGestureSettings() {
        model.setAirMouseCard(flickRightClick: flickRightClick, rightHold: rightHold)
    }

    /// The page is the toggle and one stone. Display, recenter and
    /// sensitivity live in the device menu and settings.
    private var controls: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            pebble
            if showHint {
                Text(airMouseHint)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            if model.connected && !model.receiverState.supportsDisplayCentering {
                Text(verbatim: ControllerModel.recenterUnsupportedNotice)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("airMouseRecenterNotice")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // The hint shows only on the first visit.
            if !hintSeen { hintSeen = true; Self.hintShownThisLaunch = true }
            showHint = Self.hintShownThisLaunch
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

    private var pebble: some View {
        let choice = model.airMouseAppearance
        let longEdge: CGFloat = UIScreen.main.bounds.height <= 700 ? 240 : 300
        let lit = model.airMoving
        let motion = reduceMotion ? Animation.easeOut(duration: 0.1) : (lit ? .easeOut(duration: 0.14) : .easeOut(duration: 0.2))
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let wave = reduceMotion ? 0.0 : 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate / 2.4 * 2 * Double.pi)
            let breathScale = reduceMotion ? 1.0 : 0.98 + 0.05 * wave
            let breathOpacity = reduceMotion ? 1.0 : 0.55 + 0.45 * wave
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
                        .colorMultiply(Color(red: 1, green: 159.0 / 255, blue: 67.0 / 255))
                        .opacity(0.35)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // Soft radial highlight: 0.55 at the center, gone by 40% of the
                // radius, masked by the stone's alpha so it sits in the texture.
                GeometryReader { geo in
                    let radius = max(geo.size.width, geo.size.height) / 2
                    Rectangle()
                        .fill(RadialGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0)],
                                             center: UnitPoint(x: highlight.x, y: highlight.y),
                                             startRadius: 0, endRadius: radius * 0.4))
                        .allowsHitTesting(false)
                }
                .mask(Image(name).resizable().scaledToFit())
            }
            .shadow(color: model.airMoving ? Color(red: 1, green: 140.0 / 255, blue: 40.0 / 255).opacity(0.45) : .clear,
                    radius: model.airMoving ? 24 : 0)
    }

    /// Highlight center as a fraction of the stone. Pitch and roll are radians.
    private var tiltHighlight: (x: Double, y: Double) {
        let pitch = min(30, max(-30, model.airMousePitch * 180 / .pi))
        let roll = min(30, max(-30, model.airMouseRoll * 180 / .pi))
        return (0.5 + roll * 0.007, 0.5 - pitch * 0.007)
    }

    static func displayLabel(_ display: RemoteDisplay) -> String {
        let scale = display.scale == display.scale.rounded() ? "\(Int(display.scale))x" : String(format: "%.1fx", display.scale)
        let size = "\(display.width)×\(display.height) · \(scale)"
        guard display.isMain else { return size }
        return size + " · " + String(localized: "主屏幕")
    }
}

/// Dark two-segment control for the remote card. Stock UISegmentedControl
/// stays light and does not sit cleanly beside the television note.
struct RemoteSurfaceToggle: View {
    @Binding var airMouse: Bool
    var enabled: Bool
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            segment(String(localized: "触控板"), symbol: "hand.point.up.left", selected: !airMouse) { select(false) }
            segment(String(localized: "陀螺空鼠"), symbol: "gyroscope", selected: airMouse) { select(true) }
        }
        .padding(3)
        .frame(width: 248, height: 36)
        .background(Palette.elevated, in: Capsule())
        .overlay(Capsule().stroke(Palette.mint.opacity(0.10), lineWidth: 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: airMouse)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remoteSurfaceToggle")
    }

    private func select(_ air: Bool) {
        guard air != airMouse else { return }
        airMouse = air
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func segment(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .medium))
            }
            .frame(width: 121, height: 30)
            .foregroundStyle(selected ? Palette.background : Palette.muted)
            .background {
                if selected {
                    Capsule().fill(Palette.mint).matchedGeometryEffect(id: "remoteSurface", in: selection)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AirMouseTouchLayer: UIViewRepresentable {
    var onDown: (CGPoint) -> Void
    var onMove: (CGPoint) -> Void
    var onUp: () -> Void
    var onCancel: () -> Void

    func makeUIView(context: Context) -> AirMouseTouchView {
        let view = AirMouseTouchView()
        view.onDown = onDown
        view.onMove = onMove
        view.onUp = onUp
        view.onCancel = onCancel
        return view
    }

    func updateUIView(_ uiView: AirMouseTouchView, context: Context) {
        uiView.onDown = onDown
        uiView.onMove = onMove
        uiView.onUp = onUp
        uiView.onCancel = onCancel
    }
}

final class AirMouseTouchView: UIView {
    var onDown: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onUp: (() -> Void)?
    var onCancel: (() -> Void)?
    private var active: UITouch?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { return nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if active != nil || touches.count > 1 || (event?.allTouches?.count ?? 1) > 1 {
            onCancel?()
            active = nil
            return
        }
        guard let touch = touches.first else { return }
        active = touch
        onDown?(touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active, touches.contains(active) else { return }
        if (event?.allTouches?.count ?? 1) > 1 {
            onCancel?()
            self.active = nil
            return
        }
        onMove?(active.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active, touches.contains(active) else { return }
        self.active = nil
        onUp?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active, touches.contains(active) else { return }
        self.active = nil
        onCancel?()
    }
}
