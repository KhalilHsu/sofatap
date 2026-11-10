import SwiftUI
import UIKit

/// Temporary gyro entry. The pebble is a stand-in for the later visual design:
/// a dark stone at rest, amber while the finger is down, with a highlight that
/// follows pitch and roll. Reduce Motion keeps the highlight in one place.
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
        .onChange(of: flickRightClick) { _, _ in pushGestureSettings() }
        .onChange(of: rightHold) { _, _ in pushGestureSettings() }
    }

    @AppStorage("sofatap.airMouse.flickRightClick") private var flickRightClick = false
    @AppStorage("sofatap.airMouse.rightHold") private var rightHold = 0.6

    private func pushGestureSettings() {
        model.setAirMouseCard(flickRightClick: flickRightClick, rightHold: rightHold)
    }

    private var controls: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text(String(localized: "陀螺空鼠"))
                    .font(.system(size: 22, weight: .semibold))
                Text(String(localized: "暂时入口"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.elevated, in: Capsule())
            }
            .padding(.top, 8)
            HStack(alignment: .center, spacing: 22) {
                pebble
                Button(action: model.recenterAirMouse) {
                    VStack(spacing: 6) {
                        Image(systemName: "scope")
                            .font(.system(size: 22, weight: .semibold))
                        Text(String(localized: "回中"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(width: 76, height: 76)
                    .foregroundStyle(model.airMouseCanRecenter ? Palette.background : Palette.muted)
                    .background(model.airMouseCanRecenter ? Palette.mint : Palette.elevated, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!model.airMouseCanRecenter)
                .accessibilityIdentifier("airMouseRecenter")
            }
            Text(String(localized: "按住石子移动光标，松手立刻停止。轻点单击。"))
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            if model.connected && !model.receiverState.supportsDisplayCentering {
                Text(verbatim: ControllerModel.recenterUnsupportedNotice)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("airMouseRecenterNotice")
            }
            displayPicker
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "灵敏度"))
                    .font(.subheadline.weight(.semibold))
                Slider(value: Binding(
                    get: { AirMouseGain.sensitivitySliderPosition(sweepDegrees: model.airMouseSweepDegrees) },
                    set: { model.setAirMouseSweepDegrees(AirMouseGain.sweepDegrees(sensitivitySliderPosition: $0)) }
                ), in: AirMouseGain.minimumSweepDegrees...AirMouseGain.maximumSweepDegrees, step: 1)
                .tint(Palette.mint)
                .accessibilityLabel(String(localized: "灵敏度"))
                .accessibilityHint(String(localized: "手腕转一点，光标走多远"))
                HStack {
                    Text(String(localized: "慢"))
                    Spacer()
                    Text(String(localized: "快"))
                }
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
                Text(String(localized: "手腕转一点，光标走多远"))
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            .padding(16)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(String(localized: "右键按住时长")).font(.caption.weight(.semibold))
                    Spacer()
                    Text(verbatim: String(format: "%.1f s", rightHold))
                        .font(.caption.monospacedDigit()).foregroundStyle(Palette.mint)
                }
                Slider(value: $rightHold, in: 0.5...0.8, step: 0.1)
                    .tint(Palette.mint)
                    .accessibilityLabel(String(localized: "右键按住时长"))
                Toggle(isOn: $flickRightClick) {
                    Text(String(localized: "横划右键")).font(.caption.weight(.semibold))
                }
                .tint(Palette.mint)
            }
            .padding(16)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
        .onAppear { if scenePhase == .active { model.startAirMouseSession() } }
        .onDisappear { model.stopAirMouse() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.startAirMouseSession() }
            else { model.airMouseFingerUp(); model.stopAirMouse() }
        }
        .onChange(of: model.connected) { _, _ in
            if scenePhase == .active { model.startAirMouseSession() }
        }
    }

    private var pebble: some View {
        let highlight = AirMouseHighlight.offset(pitch: model.airMousePitch, roll: model.airMouseRoll, reduceMotion: reduceMotion)
        return ZStack {
            PebbleShape()
                .fill(model.airMoving ? AnyShapeStyle(activeFill) : AnyShapeStyle(idleFill))
                .overlay {
                    PebbleShape().stroke(model.airMoving ? Color.orange.opacity(0.85) : Color.white.opacity(0.14), lineWidth: model.airMoving ? 3 : 1)
                }
                .shadow(color: model.airMoving ? Color.orange.opacity(0.55) : .black.opacity(0.45), radius: model.airMoving ? 28 : 16, y: 10)
            if !model.airMoving {
                PebbleVeins()
                    .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .padding(34)
                    .allowsHitTesting(false)
            }
            Ellipse()
                .fill(RadialGradient(colors: [Color.white.opacity(model.airMoving ? 0.95 : 0.35), .clear],
                                     center: .center, startRadius: 0, endRadius: 28))
                .frame(width: 64, height: 40)
                .offset(x: highlight.x * 34, y: highlight.y * 26)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        }
        .frame(width: 210, height: 168)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "按住石子移动光标，松手立刻停止。轻点单击。"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("airMousePebble")
    }

    private var idleFill: LinearGradient {
        LinearGradient(colors: [Color(white: 0.46), Color(white: 0.24), Color(white: 0.16)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var activeFill: RadialGradient {
        RadialGradient(colors: [Color(red: 1, green: 0.78, blue: 0.32), Color(red: 0.93, green: 0.45, blue: 0.05), Color(red: 0.55, green: 0.18, blue: 0.02)],
                       center: .center, startRadius: 8, endRadius: 120)
    }

    @ViewBuilder private var displayPicker: some View {
        if model.receiverState.displays.isEmpty {
            Text(String(localized: "选择电视屏幕"))
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker(String(localized: "选择电视屏幕"), selection: Binding(
                get: { model.selectedRemoteDisplayID ?? "" },
                set: { model.selectRemoteDisplay($0) }
            )) {
                ForEach(model.receiverState.displays) { display in
                    Text(verbatim: displayLabel(display)).tag(display.id)
                }
            }
            .pickerStyle(.menu)
            .tint(Palette.mint)
            .accessibilityIdentifier("airMouseDisplayPicker")
        }
    }

    private func displayLabel(_ display: RemoteDisplay) -> String {
        let scale = display.scale == display.scale.rounded() ? "\(Int(display.scale))x" : String(format: "%.1fx", display.scale)
        let size = "\(display.width)×\(display.height) · \(scale)"
        guard display.isMain else { return size }
        return size + " · " + String(localized: "主屏幕")
    }
}

private struct PebbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.06))
        path.addCurve(to: CGPoint(x: w * 0.90, y: h * 0.34),
                      control1: CGPoint(x: w * 0.70, y: h * 0.02), control2: CGPoint(x: w * 0.92, y: h * 0.14))
        path.addCurve(to: CGPoint(x: w * 0.84, y: h * 0.78),
                      control1: CGPoint(x: w * 0.98, y: h * 0.52), control2: CGPoint(x: w * 0.96, y: h * 0.68))
        path.addCurve(to: CGPoint(x: w * 0.46, y: h * 0.96),
                      control1: CGPoint(x: w * 0.74, y: h * 0.94), control2: CGPoint(x: w * 0.60, y: h * 0.99))
        path.addCurve(to: CGPoint(x: w * 0.10, y: h * 0.62),
                      control1: CGPoint(x: w * 0.26, y: h * 0.94), control2: CGPoint(x: w * 0.08, y: h * 0.80))
        path.addCurve(to: CGPoint(x: w * 0.22, y: h * 0.20),
                      control1: CGPoint(x: w * 0.04, y: h * 0.44), control2: CGPoint(x: w * 0.08, y: h * 0.28))
        path.addCurve(to: CGPoint(x: w * 0.50, y: h * 0.06),
                      control1: CGPoint(x: w * 0.30, y: h * 0.08), control2: CGPoint(x: w * 0.38, y: h * 0.04))
        path.closeSubpath()
        return path
    }
}

/// Dark two-segment control for the remote card. Stock UISegmentedControl
/// stays light and does not sit cleanly beside the television note.
struct RemoteSurfaceToggle: View {
    @Binding var airMouse: Bool
    var enabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            segment(String(localized: "触控板"), selected: !airMouse) { airMouse = false }
            segment(String(localized: "陀螺空鼠"), selected: airMouse) { airMouse = true }
        }
        .padding(4)
        .background(Palette.elevated, in: Capsule())
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remoteSurfaceToggle")
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .foregroundStyle(selected ? Palette.background : Palette.muted)
                .background(selected ? Palette.mint : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PebbleVeins: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX * 0.92, y: rect.minY + 8),
                          control: CGPoint(x: rect.midX, y: rect.midY - 10))
        path.move(to: CGPoint(x: rect.minX + 6, y: rect.maxY * 0.72))
        path.addQuadCurve(to: CGPoint(x: rect.maxX * 0.8, y: rect.maxY * 0.55),
                          control: CGPoint(x: rect.midX, y: rect.maxY * 0.9))
        return path
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
