import SwiftUI
import UIKit

/// The whole dot surface is a remote touchpad. Hints appear only for the current
/// contact; direction events never move a pointer or silently turn into a click.
struct AndroidTVNavigationPad: UIViewRepresentable {
    var enabled: Bool
    var control: Control
    final class Control {
        fileprivate weak var view: Pad?
        func cancel() { view?.cancelContact() }
    }
    var onInteractionBegan: () -> Void = {}
    let onKey: (AndroidTVKey) -> Void
    func makeUIView(context: Context) -> Pad { let pad = Pad(); pad.onKey = onKey; pad.onInteractionBegan = onInteractionBegan; control.view = pad; return pad }
    func updateUIView(_ view: Pad, context: Context) { control.view = view; view.onKey = onKey; view.onInteractionBegan = onInteractionBegan; view.inputEnabled = enabled }
    static func dismantleUIView(_ view: Pad, coordinator: Void) { view.inputEnabled = false }

    final class Pad: UIView {
        var onKey: ((AndroidTVKey) -> Void)?
        var onInteractionBegan: () -> Void = {}
        var inputEnabled = false { didSet { if !inputEnabled { cancelContact() } } }
        private var contact = AndroidTVNavigationContact()
        private weak var trackedTouch: UITouch?
        private let hints = UIView()
        private let centerDot = UIView()
        private var arrows: [AndroidTVKey: UIImageView] = [:]
        private let mint = UIColor(red: 0.831, green: 0.529, blue: 0.290, alpha: 1)
        private var lastBounds = CGRect.zero
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear; isMultipleTouchEnabled = true
            hints.isUserInteractionEnabled = false; hints.alpha = 0
            addSubview(hints)
            centerDot.backgroundColor = mint.withAlphaComponent(0.65)
            centerDot.layer.cornerRadius = 6
            centerDot.layer.shadowColor = mint.cgColor
            centerDot.layer.shadowRadius = 18; centerDot.layer.shadowOpacity = 0.6
            centerDot.layer.shadowOffset = .zero
            hints.addSubview(centerDot)
            for (key, symbol) in [(AndroidTVKey.up, "chevron.up"), (.left, "chevron.left"), (.right, "chevron.right"), (.down, "chevron.down")] {
                let arrow = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)))
                arrow.tintColor = mint; arrow.contentMode = .center
                hints.addSubview(arrow); arrows[key] = arrow
            }
            isAccessibilityElement = true
            accessibilityIdentifier = "tvNavigationSurface"
            accessibilityLabel = String(localized: "电视遥控")
            accessibilityTraits = .button
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "向上"), actionHandler: { [weak self] _ in self?.emit(.up) ?? false }),
                UIAccessibilityCustomAction(name: String(localized: "向下"), actionHandler: { [weak self] _ in self?.emit(.down) ?? false }),
                UIAccessibilityCustomAction(name: String(localized: "向左"), actionHandler: { [weak self] _ in self?.emit(.left) ?? false }),
                UIAccessibilityCustomAction(name: String(localized: "向右"), actionHandler: { [weak self] _ in self?.emit(.right) ?? false })
            ]
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
        override func accessibilityActivate() -> Bool { emit(.confirm) }
        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds != lastBounds { cancelContact(); lastBounds = bounds }
            hints.bounds = CGRect(x: 0, y: 0, width: 96, height: 96)
            centerDot.frame = CGRect(x: 42, y: 42, width: 12, height: 12)
            arrows[.up]?.frame = CGRect(x: 32, y: 0, width: 32, height: 32)
            arrows[.left]?.frame = CGRect(x: 0, y: 32, width: 32, height: 32)
            arrows[.right]?.frame = CGRect(x: 64, y: 32, width: 32, height: 32)
            arrows[.down]?.frame = CGRect(x: 32, y: 64, width: 32, height: 32)
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            onInteractionBegan()
            guard inputEnabled, trackedTouch == nil, event?.allTouches?.count == 1, let touch = touches.first else {
                cancelContact(); return
            }
            trackedTouch = touch
            let point = touch.location(in: self)
            contact.begin(x: point.x, y: point.y, time: touch.timestamp)
            placeHints(at: point, direction: nil)
            hints.layer.removeAllAnimations()
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.1) { self.hints.alpha = 1 }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard inputEnabled, event?.allTouches?.count == 1, let touch = trackedTouch, touches.contains(touch) else {
                cancelContact(); return
            }
            let point = touch.location(in: self)
            let key = contact.move(x: point.x, y: point.y, time: touch.timestamp)
            placeHints(at: point, direction: key)
            if let key { _ = emit(key) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard event?.allTouches?.count == 1, let touch = trackedTouch, touches.contains(touch) else { cancelContact(); return }
            let point = touch.location(in: self)
            let key = contact.end(x: point.x, y: point.y, time: touch.timestamp)
            if let key { _ = emit(key) }
            cancelContact()
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelContact() }
        private func placeHints(at point: CGPoint, direction: AndroidTVKey?) {
            hints.center = CGPoint(x: min(max(point.x, 52), max(52, bounds.width - 52)),
                                   y: min(max(point.y, 52), max(52, bounds.height - 52)))
            for (key, arrow) in arrows { arrow.alpha = direction == nil ? 0.55 : key == direction ? 1 : 0.25 }
        }
        fileprivate func cancelContact() {
            trackedTouch = nil; contact.cancel()
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) { self.hints.alpha = 0 }
        }
        private func emit(_ key: AndroidTVKey) -> Bool {
            guard inputEnabled else { return false }
            onKey?(key); return true
        }
    }
}

/// Optional explicit keys, outside the normal touch surface. Also useful for
/// Switch Control, VoiceOver and people who prefer a traditional remote.
struct AndroidTVDirectionButtons: View {
    @ObservedObject var tv: AndroidTVController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SofaNavigationStack {
            VStack(spacing: 8) {
                key(.up, "chevron.up", String(localized: "向上"))
                HStack(spacing: 8) {
                    key(.left, "chevron.left", String(localized: "向左"))
                    key(.confirm, "checkmark", String(localized: "确认当前高亮项"))
                    key(.right, "chevron.right", String(localized: "向右"))
                }
                key(.down, "chevron.down", String(localized: "向下"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
            .navigationTitle(String(localized: "方向键与确认"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { dismiss() } } }
        }
        .tint(Palette.mint).preferredColorScheme(.dark)
    }
    private func key(_ key: AndroidTVKey, _ symbol: String, _ label: String) -> some View {
        Button { _ = tv.remoteKey(key) } label: {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
                .frame(width: 60, height: 52)
                .background(Palette.mint.opacity(key == .confirm ? 0.18 : 0.07), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(RemoteIconButtonStyle()).disabled(!tv.canNavigate)
        .accessibilityLabel(label).accessibilityIdentifier("tvDirection_" + key.rawValue)
    }
}

struct AndroidTVRemoteSetupView: View {
    @ObservedObject var tv: AndroidTVController
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var submitted = false
    private var navigation: AndroidTVControls.NavigationStatus? { tv.status?.tvControls?.navigationStatus }
    private var validCode: Bool { code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }
    var body: some View {
        SofaNavigationStack {
            Form {
                Section {
                    Text(String(localized: "连接后，方向键和确认键会像电视遥控器一样工作。光标模式仍可单独使用。"))
                    if navigation == .pairing {
                        Text(String(localized: "输入电视画面上显示的 6 位配对码。"))
                        TextField(String(localized: "电视配对码"), text: $code)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .keyboardType(.asciiCapable).privacySensitive()
                            .accessibilityIdentifier("tvRemotePairingCode")
                        Button(String(localized: "确认配对")) { submitted = tv.submitRemotePairingCode(code) }
                            .disabled(!validCode || submitted || !tv.connectionReady)
                            .accessibilityIdentifier("tvRemotePairingSubmit")
                    } else if navigation == .ready {
                        Label(String(localized: "已连接"), systemImage: "checkmark.circle")
                    } else {
                        Button(String(localized: "在电视上显示配对码")) { code = ""; submitted = false; _ = tv.startRemotePairing() }
                            .disabled(!tv.connectionReady || navigation == nil || navigation == .unsupported)
                            .accessibilityIdentifier("tvRemotePairingStart")
                    }
                    if let feedback = tv.inputFeedback { Text(feedback).foregroundStyle(.orange) }
                    if navigation == nil || navigation == .unsupported {
                        Text(String(localized: "此接收器暂不提供系统遥控，请更新接收器或使用光标模式。"))
                    }
                }
            }
            .navigationTitle(String(localized: "连接电视遥控"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "完成")) { dismiss() } } }
            .onChangeCompat(of: tv.inputFeedback) { _, _ in submitted = false }
            .onChangeCompat(of: navigation) { _, state in
                submitted = false
                if state == .ready { code = ""; dismiss() }
            }
        }
        .tint(Palette.mint).preferredColorScheme(.dark)
        .onDisappear { code = "" }
    }
}
