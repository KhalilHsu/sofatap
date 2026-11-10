import UIKit

/// Local touch feedback for the 枯山水 trackpad. This round is static: a soft
/// ember glow follows the finger and a click shows a brief ring. No display
/// link, no animated sand. It has no knowledge of the computer's cursor.
final class TouchParticleRenderer: NSObject {
    private let surface = CALayer()
    private let halo = CAShapeLayer()
    private let core = CAShapeLayer()
    private let pulse = CAShapeLayer()
    private let ember = UIColor(red: 0xd4 / 255.0, green: 0x87 / 255.0, blue: 0x4a / 255.0, alpha: 1)
    private let emberLight = UIColor(red: 0xe3 / 255.0, green: 0xa0 / 255.0, blue: 0x6b / 255.0, alpha: 1)
    private var renderingActive = false
    private var hasContact = false
    private var dragging = false
    private var contactPoint = CGPoint.zero
    private var pulseClear: DispatchWorkItem?
    private var canvasBounds = CGRect.zero

    init(in layer: CALayer) {
        super.init()
        surface.masksToBounds = true
        layer.addSublayer(surface)
        halo.fillColor = ember.withAlphaComponent(0.18).cgColor
        core.fillColor = emberLight.cgColor
        pulse.fillColor = UIColor.clear.cgColor
        pulse.strokeColor = ember.withAlphaComponent(0.7).cgColor
        pulse.lineWidth = 1
        for shape in [halo, core, pulse] { shape.opacity = 0; surface.addSublayer(shape) }
        setRadius(halo: 26)
        core.path = UIBezierPath(ovalIn: CGRect(x: -5, y: -5, width: 10, height: 10)).cgPath
    }

    deinit { pulseClear?.cancel() }

    func layout(in bounds: CGRect) {
        guard bounds != canvasBounds else { return }
        canvasBounds = bounds
        withoutAnimations { surface.frame = bounds }
    }

    func setActive(_ active: Bool) {
        guard renderingActive != active else { return }
        renderingActive = active
        if !active { clear() }
    }

    func beginContact(at point: CGPoint) {
        guard renderingActive else { return }
        hasContact = true
        show(at: point)
    }

    func updateContact(at point: CGPoint) {
        contactPoint = point
        guard hasContact else { return }
        withoutAnimations { halo.position = point; core.position = point }
    }

    func moveTrail(to point: CGPoint, scrolling: Bool = false) {}

    func endContact() {
        hasContact = false
        if !dragging { withoutAnimations { halo.opacity = 0; core.opacity = 0 } }
    }

    func click(at point: CGPoint, double: Bool) {
        guard renderingActive else { return }
        pulseClear?.cancel()
        withoutAnimations {
            let radius: CGFloat = double ? 24 : 17
            pulse.position = point
            pulse.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)).cgPath
            pulse.opacity = 1
        }
        let work = DispatchWorkItem { [weak self] in self?.withoutAnimations { self?.pulse.opacity = 0 } }
        pulseClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    func setDragging(_ down: Bool, at point: CGPoint) {
        guard dragging != down else { return }
        dragging = down
        contactPoint = point
        guard renderingActive else { return }
        withoutAnimations { setRadius(halo: down ? 34 : 26) }
        if !down && !hasContact { withoutAnimations { halo.opacity = 0; core.opacity = 0 } }
    }

    func clear() {
        pulseClear?.cancel()
        pulseClear = nil
        hasContact = false
        dragging = false
        withoutAnimations {
            setRadius(halo: 26)
            halo.opacity = 0; core.opacity = 0; pulse.opacity = 0
        }
    }

    func setInteractionFrameRate(_ maximum: Int) {}

    private func show(at point: CGPoint) {
        contactPoint = point
        withoutAnimations {
            halo.position = point; core.position = point
            halo.opacity = 1; core.opacity = 1
        }
    }

    private func setRadius(halo radius: CGFloat) {
        halo.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)).cgPath
    }

    private func withoutAnimations(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updates()
        CATransaction.commit()
    }

#if targetEnvironment(simulator)
    /// Simulator-only visual QA: `--demo --demo-touch 0.72,0.38` pins the glow
    /// at a fraction of the pad. No touch, gesture or desktop input is involved.
    func startPreviewIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard renderingActive, canvasBounds.width > 0, arguments.contains("--demo"),
              let index = arguments.firstIndex(of: "--demo-touch"), index + 1 < arguments.count else { return }
        let parts = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        show(at: CGPoint(x: canvasBounds.width * CGFloat(parts[0]), y: canvasBounds.height * CGFloat(parts[1])))
    }
#endif
}
