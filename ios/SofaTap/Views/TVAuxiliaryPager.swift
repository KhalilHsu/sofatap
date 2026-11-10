import SwiftUI
import UIKit

/// Owns every touch in its bounds, including touches over disabled controls.
/// Its local swipe recognizer never forwards input to the underlying touchpad.
struct TVAuxiliaryPager: UIViewRepresentable {
    struct Action {
        let symbol: String
        let label: String
        let identifier: String
        var value: String = ""
        var enabled = true
        let perform: () -> Void
    }
    final class Control {
        fileprivate weak var view: PagerView?
        func cancel() { view?.cancelContact() }
    }
    let pages: [[Action]]
    let identity: String
    let layout: TVAuxiliaryLayout
    let interactionEnabled: Bool
    let control: Control
    let onInteractionBegan: () -> Void
    func makeUIView(context: Context) -> PagerView { let view = PagerView(); view.configure(self); return view }
    func updateUIView(_ view: PagerView, context: Context) { view.configure(self) }
    static func dismantleUIView(_ view: PagerView, coordinator: Void) { view.cancelContact() }

    final class PagerView: UIView {
        private var config: TVAuxiliaryPager?
        private var page = 0
        private var accessibilityGeneration: UInt64 = 0
        private var gesture = TVAuxiliaryGesture()
        private weak var trackedTouch: UITouch?
        private let symbols = [UIImageView(), UIImageView()]
        private let selection = [UIView(), UIView()]
        private var dots: [UIView] = []
        private let mint = UIColor(red: 0.831, green: 0.529, blue: 0.290, alpha: 1)
        private var actions: [Action] { guard let config, config.pages.indices.contains(page) else { return [] }; return config.pages[page] }
        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true; clipsToBounds = true
            backgroundColor = UIColor(red: 0.118, green: 0.106, blue: 0.090, alpha: 0.92)
            layer.cornerRadius = 22; layer.borderColor = mint.withAlphaComponent(0.16).cgColor; layer.borderWidth = 1
            accessibilityIdentifier = "tvAuxiliaryPager"
            for index in symbols.indices {
                selection[index].backgroundColor = mint.withAlphaComponent(0.12)
                selection[index].layer.cornerRadius = 18; selection[index].alpha = 0
                selection[index].isUserInteractionEnabled = false
                symbols[index].contentMode = .center; symbols[index].isUserInteractionEnabled = false
                addSubview(selection[index]); addSubview(symbols[index])
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
        func configure(_ next: TVAuxiliaryPager) {
            if config?.identity != next.identity {
                cancelContact(); page = 0; accessibilityGeneration &+= 1
            } else if config?.pages.map({ $0.map(\.identifier) }) != next.pages.map({ $0.map(\.identifier) }) {
                cancelContact(); accessibilityGeneration &+= 1
            }
            if config?.layout.vertical != next.layout.vertical { cancelContact() }
            if !next.interactionEnabled { cancelContact() }
            config = next; next.control.view = self
            page = TVAuxiliaryGesture.page(page, delta: 0, count: next.pages.count)
            render(); setNeedsLayout()
        }
        private func render() {
            for index in symbols.indices {
                guard actions.indices.contains(index) else { symbols[index].image = nil; continue }
                let action = actions[index]
                symbols[index].image = UIImage(systemName: action.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
                symbols[index].tintColor = mint.withAlphaComponent(action.enabled && config?.interactionEnabled == true ? 1 : 0.35)
            }
            let count = config?.pages.count ?? 0
            if dots.count != count {
                dots.forEach { $0.removeFromSuperview() }; dots = (0..<count).map { _ in
                    let dot = UIView(); dot.isUserInteractionEnabled = false; dot.layer.cornerRadius = 2
                    addSubview(dot); return dot
                }
            }
            for (index, dot) in dots.enumerated() {
                dot.isHidden = count < 2; dot.backgroundColor = mint.withAlphaComponent(index == page ? 0.9 : 0.25)
            }
            rebuildAccessibility()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let config else { return }
            for index in symbols.indices {
                let frame = config.layout.buttonFrame(index)
                symbols[index].frame = frame; selection[index].frame = frame.insetBy(dx: 2, dy: 2)
            }
            for (index, dot) in dots.enumerated() {
                dot.frame = CGRect(x: bounds.midX + CGFloat(index) * 8 - CGFloat(dots.count - 1) * 4 - 2, y: bounds.height - 8, width: 4, height: 4)
            }
            rebuildAccessibility()
        }
        private func button(at point: CGPoint) -> Int? {
            guard let config else { return nil }
            return actions.indices.first { config.layout.buttonFrame($0).contains(point) }
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Cancel the main surface before tracking this contact, even if the
            // touched button is unavailable or this becomes a local page swipe.
            config?.onInteractionBegan()
            guard config?.interactionEnabled == true, trackedTouch == nil, event?.allTouches?.count == 1, let touch = touches.first else { cancelContact(); return }
            trackedTouch = touch
            let point = touch.location(in: self), index = button(at: point)
            gesture.begin(x: point.x, y: point.y, time: touch.timestamp, button: index)
            if let index, actions[index].enabled { selection[index].alpha = 1 }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard event?.allTouches?.count == 1, let touch = trackedTouch, touches.contains(touch) else { cancelContact(); return }
            let point = touch.location(in: self); gesture.move(x: point.x, y: point.y)
            if gesture.moved { selection.forEach { $0.alpha = 0 } }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard event?.allTouches?.count == 1, let touch = trackedTouch, touches.contains(touch) else { cancelContact(); return }
            let point = touch.location(in: self)
            let outcome = gesture.end(x: point.x, y: point.y, time: touch.timestamp, button: button(at: point))
            cancelContact()
            switch outcome {
            case .activate(let index): _ = activate(index)
            case .page(let delta): _ = changePage(delta)
            case nil: break
            }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelContact() }
        fileprivate func cancelContact() { trackedTouch = nil; gesture.cancel(); selection.forEach { $0.alpha = 0 } }
        private func token(for identifier: String) -> TVAuxiliaryActionToken? {
            guard let config else { return nil }
            return TVAuxiliaryActionToken(identity: config.identity, page: page, actionIdentifier: identifier, generation: accessibilityGeneration)
        }
        private func activate(_ index: Int, expected: TVAuxiliaryActionToken? = nil) -> Bool {
            if let expected {
                guard actions.indices.contains(index), token(for: actions[index].identifier) == expected else { return false }
            }
            config?.onInteractionBegan()
            guard config?.interactionEnabled == true, actions.indices.contains(index), actions[index].enabled else { return false }
            actions[index].perform(); return true
        }
        private func changePage(_ delta: Int) -> Bool {
            config?.onInteractionBegan()
            guard let config, config.interactionEnabled else { return false }
            let next = TVAuxiliaryGesture.page(page, delta: delta, count: config.pages.count)
            guard next != page else { return false }
            page = next; accessibilityGeneration &+= 1
            UIView.transition(with: self, duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.16, options: .transitionCrossDissolve) { self.render() }
            UISelectionFeedbackGenerator().selectionChanged()
            UIAccessibility.post(notification: .pageScrolled, argument: pageLabel)
            return true
        }
        private var pageLabel: String { String(format: String(localized: "操作页 %1$d，共 %2$d 页"), page + 1, config?.pages.count ?? 1) }
        override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
            switch direction { case .left: return changePage(1); case .right: return changePage(-1); default: return false }
        }
        private func rebuildAccessibility() {
            guard let config else { return }
            var elements: [UIAccessibilityElement] = []
            for (index, action) in actions.enumerated() {
                let element = ActionElement(accessibilityContainer: self)
                let expected = token(for: action.identifier)
                element.activate = { [weak self] in
                    guard let expected else { return false }
                    return self?.activate(index, expected: expected) ?? false
                }
                element.accessibilityLabel = action.label; element.accessibilityValue = action.value
                element.accessibilityIdentifier = action.identifier
                element.accessibilityTraits = action.enabled && config.interactionEnabled ? .button : [.button, .notEnabled]
                element.accessibilityFrameInContainerSpace = config.layout.buttonFrame(index)
                elements.append(element)
            }
            if config.pages.count > 1 {
                let element = PageElement(accessibilityContainer: self)
                let expectedIdentity = config.identity
                element.change = { [weak self] delta in
                    guard let self, self.config?.identity == expectedIdentity else { return }
                    _ = self.changePage(delta)
                }
                element.accessibilityLabel = String(localized: "电视快捷操作")
                element.accessibilityHint = String(localized: "左右滑动切换操作")
                element.accessibilityValue = pageLabel; element.accessibilityTraits = .adjustable
                element.accessibilityIdentifier = "tvAuxiliaryPage"
                element.accessibilityFrameInContainerSpace = CGRect(x: 0, y: bounds.height - 12, width: bounds.width, height: 12)
                elements.append(element)
            }
            accessibilityElements = elements
        }
    }
    private final class ActionElement: UIAccessibilityElement {
        var activate: (() -> Bool)?
        override func accessibilityActivate() -> Bool { activate?() ?? false }
    }
    private final class PageElement: UIAccessibilityElement {
        var change: ((Int) -> Void)?
        override func accessibilityIncrement() { change?(1) }
        override func accessibilityDecrement() { change?(-1) }
    }
}
