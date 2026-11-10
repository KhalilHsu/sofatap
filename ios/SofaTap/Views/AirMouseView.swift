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
        let choice = model.airMouseAppearance
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let breath = reduceMotion ? 1.0 : 1 + 0.035 * sin(timeline.date.timeIntervalSinceReferenceDate / 2.4 * 2 * Double.pi)
            stoneImage
                .scaleEffect(x: (choice.mirrored ? -1 : 1) * choice.scale * breath, y: choice.scale * breath)
                .rotationEffect(.degrees(choice.rotationDegrees))
                .overlay {
                    Ellipse()
                        .fill(RadialGradient(colors: [Color.white.opacity(model.airMoving ? 0.9 : 0.28), .clear],
                                             center: .center, startRadius: 0, endRadius: 22))
                        .frame(width: 52, height: 32)
                        .offset(x: highlight.x * 28, y: highlight.y * 22)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
                .frame(width: 168, height: 132)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("airMousePebble")
    }

    private var stoneImage: some View {
        let name = model.airMouseAppearance.stone.assetName
        return Image(name)
            .resizable()
            .scaledToFit()
            .overlay {
                if model.airMoving {
                    Image(name).resizable().scaledToFit()
                        .colorMultiply(Color(red: 1, green: 0.55, blue: 0.12))
                        .opacity(0.85)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: model.airMoving ? Color.orange.opacity(0.55) : .black.opacity(0.35),
                    radius: model.airMoving ? 18 : 10, y: 8)
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
