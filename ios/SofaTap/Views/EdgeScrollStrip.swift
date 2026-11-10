import SwiftUI
import UIKit

/// Reserve at least 44 points inside the touch surface, clear of its other controls.
/// The visual thumb tracks the finger only and never represents the remote document position.
struct EdgeScrollStrip: UIViewRepresentable {
    static let minimumHitWidth: CGFloat = 44

    let enabled: Bool
    var control: Control? = nil
    var interactionID = ""
    var onInteractionBegan: () -> Void = {}
    let onScroll: (Double) -> Void

    final class Control {
        fileprivate weak var view: ScrollInputView?
        func cancel() { view?.cancelInput() }
    }

    func makeUIView(context: Context) -> ScrollInputView {
        let view = ScrollInputView()
        view.configure(self)
        return view
    }

    func updateUIView(_ view: ScrollInputView, context: Context) { view.configure(self) }
    static func dismantleUIView(_ view: ScrollInputView, coordinator: ()) { view.detach() }

    @available(iOS 16, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ScrollInputView, context: Context) -> CGSize? {
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 200
        return CGSize(width: Self.minimumHitWidth, height: max(Self.minimumHitWidth, height))
    }

    final class ScrollInputView: UIView {
        private var parent: EdgeScrollStrip?
        private var gesture = EdgeScrollGesture()
        private var contacts: [ObjectIdentifier: CGPoint] = [:]
        private var active = true
        private var fingerY: CGFloat?
        private var accessibilityFeedback = false
        private var feedbackReset: DispatchWorkItem?
        private let mint = UIColor(red: 0.655, green: 0.929, blue: 0.796, alpha: 1)

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isMultipleTouchEnabled = true
            isAccessibilityElement = true
            accessibilityIdentifier = "edgeScrollStrip"
            contentMode = .redraw
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(applicationInactive), name: UIApplication.willResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(applicationActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(sceneInactive(_:)), name: UIScene.willDeactivateNotification, object: nil)
            center.addObserver(self, selector: #selector(sceneActive(_:)), name: UIScene.didActivateNotification, object: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { feedbackReset?.cancel(); NotificationCenter.default.removeObserver(self) }

        override var intrinsicContentSize: CGSize {
            CGSize(width: EdgeScrollStrip.minimumHitWidth, height: UIView.noIntrinsicMetric)
        }

        func configure(_ parent: EdgeScrollStrip) {
            if self.parent?.interactionID != parent.interactionID || (!parent.enabled && self.parent?.enabled == true) {
                cancelInput()
            }
            if self.parent?.control !== parent.control, self.parent?.control?.view === self {
                self.parent?.control?.view = nil
            }
            self.parent = parent
            parent.control?.view = self
            accessibilityLabel = String(localized: "侧边滚动条")
            accessibilityHint = String(localized: "单指上下滑动，滚动当前设备上的页面")
            accessibilityValue = parent.enabled ? nil : String(localized: "滚动不可用")
            accessibilityTraits = parent.enabled ? [.adjustable] : [.adjustable, .notEnabled]
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "向上滚动"), target: self, selector: #selector(accessibleUp)),
                UIAccessibilityCustomAction(name: String(localized: "向下滚动"), target: self, selector: #selector(accessibleDown))
            ]
            updateAvailability()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancelInput() }
            updateAvailability()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            setNeedsDisplay()
        }

        func detach() {
            cancelInput()
            if parent?.control?.view === self { parent?.control?.view = nil }
            parent = nil
        }

        func cancelInput() {
            contacts.removeAll()
            gesture.cancel()
            fingerY = nil
            feedbackReset?.cancel()
            feedbackReset = nil
            accessibilityFeedback = false
            setNeedsDisplay()
        }

        private var canInput: Bool { parent?.enabled == true && active && window != nil }

        private func updateAvailability() {
            active = UIApplication.shared.applicationState == .active
                && (window?.windowScene?.activationState == .foregroundActive)
            // This view overlays the pointer pad. Consume disabled scroll touches
            // so they cannot fall through as pointer movement or clicks.
            // canInput still rejects every scroll when the capability is disabled.
            isUserInteractionEnabled = active
            if !active { cancelInput() }
            setNeedsDisplay()
        }

        @objc private func applicationInactive() {
            active = false
            cancelInput()
            isUserInteractionEnabled = false
        }

        @objc private func applicationActive() { updateAvailability() }

        @objc private func sceneInactive(_ notification: Notification) {
            guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
            applicationInactive()
        }

        @objc private func sceneActive(_ notification: Notification) {
            guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
            updateAvailability()
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard canInput else { return }
            let wasEmpty = contacts.isEmpty
            for touch in touches where touch.type == .direct { contacts[ObjectIdentifier(touch)] = touch.location(in: self) }
            guard !contacts.isEmpty else { return }
            // Cancel any other pad interaction before emitting even the first scroll delta.
            if wasEmpty {
                // A second finger outside this view may have lifted without delivering
                // its end here. This new contact still checks the current whole-window count.
                gesture.cancel()
                parent?.onInteractionBegan()
            }
            guard canInput, !contacts.isEmpty else { cancelInput(); return }
            gesture.begin(y: Double(contactY), count: activeTouchCount(event))
            fingerY = gesture.isContactActive ? contactY : nil
            setNeedsDisplay()
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard canInput else { cancelInput(); return }
            guard touches.contains(where: { contacts[ObjectIdentifier($0)] != nil }) else { return }
            for touch in touches where contacts[ObjectIdentifier(touch)] != nil {
                contacts[ObjectIdentifier(touch)] = touch.location(in: self)
            }
            let delta = gesture.move(y: Double(contactY), count: activeTouchCount(event))
            fingerY = gesture.isContactActive ? contactY : nil
            setNeedsDisplay()
            if let delta { parent?.onScroll(delta) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.contains(where: { contacts[ObjectIdentifier($0)] != nil }) else { return }
            for touch in touches { contacts.removeValue(forKey: ObjectIdentifier(touch)) }
            gesture.end(remainingCount: activeTouchCount(event))
            fingerY = nil
            setNeedsDisplay()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.contains(where: { contacts[ObjectIdentifier($0)] != nil }) else { return }
            cancelInput()
        }

        private var contactY: CGFloat { contacts.values.first?.y ?? 0 }

        private func activeTouchCount(_ event: UIEvent?) -> Int {
            // Another finger elsewhere in this app also suppresses the strip. Do not convert
            // a two-finger gesture into a fresh one-finger scroll when one contact is lifted.
            let live = window.flatMap { event?.touches(for: $0) }?.filter {
                $0.phase == .began || $0.phase == .moved || $0.phase == .stationary
            }.count ?? contacts.count
            return max(live, contacts.count)
        }

        override func accessibilityIncrement() { _ = accessibleDown() }
        override func accessibilityDecrement() { _ = accessibleUp() }

        @objc private func accessibleUp() -> Bool { accessibilityScroll(delta: EdgeScrollGesture.accessibilityStep) }
        @objc private func accessibleDown() -> Bool { accessibilityScroll(delta: -EdgeScrollGesture.accessibilityStep) }

        private func accessibilityScroll(delta: Double) -> Bool {
            guard canInput else { return false }
            cancelInput()
            parent?.onInteractionBegan()
            guard canInput else { return false }
            parent?.onScroll(delta)
            accessibilityFeedback = true
            setNeedsDisplay()
            let reset = DispatchWorkItem { [weak self] in
                self?.accessibilityFeedback = false
                self?.setNeedsDisplay()
            }
            feedbackReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: reset)
            return true
        }

        override func draw(_ rect: CGRect) {
            guard bounds.width > 0, bounds.height > 24, let context = UIGraphicsGetCurrentContext() else { return }
            let trackX = bounds.maxX - 12
            let top: CGFloat = 14, bottom = bounds.maxY - 14
            let engaged = gesture.isContactActive || accessibilityFeedback
            let available = parent?.enabled == true
            context.setLineCap(.round)
            context.setLineWidth(2)
            context.setStrokeColor(mint.withAlphaComponent(available ? 0.15 : 0.06).cgColor)
            context.move(to: CGPoint(x: trackX, y: top))
            context.addLine(to: CGPoint(x: trackX, y: bottom))
            context.strokePath()
            let thumbHeight = min(bottom - top, max(32, min(64, (bottom - top) * 0.15)))
            let center = max(top + thumbHeight / 2, min(bottom - thumbHeight / 2, fingerY ?? bounds.midY))
            context.setLineWidth(engaged ? 5 : 3)
            context.setStrokeColor(mint.withAlphaComponent(available ? (engaged ? 0.95 : 0.42) : 0.12).cgColor)
            if engaged { context.setShadow(offset: .zero, blur: 8, color: mint.withAlphaComponent(0.25).cgColor) }
            context.move(to: CGPoint(x: trackX, y: center - thumbHeight / 2))
            context.addLine(to: CGPoint(x: trackX, y: center + thumbHeight / 2))
            context.strokePath()
        }
    }
}
