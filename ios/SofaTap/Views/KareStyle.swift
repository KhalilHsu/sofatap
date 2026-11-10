import SwiftUI
import UIKit

/// 枯山水 (raked sand) palette and drawing helpers. Only the stone gets light;
/// everything else is flat warm hairlines on dark sand, one ember accent.
enum Kare {
    static let sand = Color(red: 0x14 / 255.0, green: 0x12 / 255.0, blue: 0x10 / 255.0)
    static let surface = Color(red: 0x1e / 255.0, green: 0x1b / 255.0, blue: 0x17 / 255.0)
    static let ink = Color(red: 0xe9 / 255.0, green: 0xe2 / 255.0, blue: 0xd4 / 255.0)
    static let inkSoft = Color(red: 0xb8 / 255.0, green: 0xae / 255.0, blue: 0x9b / 255.0)
    static let stone = Color(red: 0x8c / 255.0, green: 0x84 / 255.0, blue: 0x76 / 255.0)
    static let faint = Color(red: 0x7a / 255.0, green: 0x73 / 255.0, blue: 0x66 / 255.0)
    static let dim = Color(red: 0x6f / 255.0, green: 0x68 / 255.0, blue: 0x5c / 255.0)
    static let ember = Color(red: 0xd4 / 255.0, green: 0x87 / 255.0, blue: 0x4a / 255.0)
    static let emberLight = Color(red: 0xe3 / 255.0, green: 0xa0 / 255.0, blue: 0x6b / 255.0)
    static let lamp = Color(red: 0xc9 / 255.0, green: 0xb4 / 255.0, blue: 0x8a / 255.0)
    static let thumb = Color(red: 0xf3 / 255.0, green: 0xed / 255.0, blue: 0xe2 / 255.0)
    static let hairline = ink.opacity(0.07)

    /// Serif for titles and device names. iOS ships no Simplified Chinese serif,
    /// so Latin uses New York and Han characters fall back to the system face.
    static func serif(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// Thin-line glyphs from the 枯山水 mockup, drawn on a 24 pt grid.
struct KareGlyph: Shape {
    enum Kind { case keyboard, mic, volume, chevron, check, plus, sliders, help, stop }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * s, oy = rect.midY - 12 * s
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        var path = Path()
        switch kind {
        case .keyboard:
            path.addRoundedRect(in: CGRect(origin: p(2.5, 6), size: CGSize(width: 19 * s, height: 12 * s)),
                                cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s))
            for x in [6.0, 9.5, 13, 16.5] as [CGFloat] { path.move(to: p(x, 10)); path.addLine(to: p(x + 0.01, 10)) }
            path.move(to: p(8, 14)); path.addLine(to: p(16, 14))
        case .mic:
            path.addRoundedRect(in: CGRect(origin: p(9, 3), size: CGSize(width: 6 * s, height: 11 * s)),
                                cornerSize: CGSize(width: 3 * s, height: 3 * s))
            path.move(to: p(5.5, 11))
            path.addArc(center: p(12, 11), radius: 6.5 * s, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            path.move(to: p(12, 17.5)); path.addLine(to: p(12, 21))
        case .volume:
            path.move(to: p(4, 9.5)); path.addLine(to: p(7.5, 9.5)); path.addLine(to: p(12, 5.5))
            path.addLine(to: p(12, 18.5)); path.addLine(to: p(7.5, 14.5)); path.addLine(to: p(4, 14.5)); path.closeSubpath()
            path.move(to: p(15.5, 9)); path.addQuadCurve(to: p(15.5, 15), control: p(18.0, 12))
            path.move(to: p(18, 6.5)); path.addQuadCurve(to: p(18, 17.5), control: p(22.5, 12))
        case .chevron:
            path.move(to: p(6, 9)); path.addLine(to: p(12, 15)); path.addLine(to: p(18, 9))
        case .check:
            path.move(to: p(5, 12.5)); path.addLine(to: p(9.5, 17)); path.addLine(to: p(19, 7.5))
        case .plus:
            path.move(to: p(12, 5)); path.addLine(to: p(12, 19)); path.move(to: p(5, 12)); path.addLine(to: p(19, 12))
        case .sliders:
            path.move(to: p(4, 8)); path.addLine(to: p(13.5, 8)); path.move(to: p(18.5, 8)); path.addLine(to: p(20, 8))
            path.addEllipse(in: CGRect(origin: p(13.5, 5.5), size: CGSize(width: 5 * s, height: 5 * s)))
            path.move(to: p(4, 16)); path.addLine(to: p(5.5, 16)); path.move(to: p(10.5, 16)); path.addLine(to: p(20, 16))
            path.addEllipse(in: CGRect(origin: p(5.5, 13.5), size: CGSize(width: 5 * s, height: 5 * s)))
        case .help:
            path.addEllipse(in: CGRect(origin: p(3, 3), size: CGSize(width: 18 * s, height: 18 * s)))
            path.move(to: p(9.6, 9.6))
            path.addQuadCurve(to: p(12, 7.5), control: p(10, 7.5))
            path.addQuadCurve(to: p(14.4, 9.8), control: p(14.4, 7.6))
            path.addQuadCurve(to: p(12, 12.6), control: p(14.4, 11.6))
            path.addLine(to: p(12, 13.8))
            path.move(to: p(12, 16.6)); path.addLine(to: p(12.01, 16.6))
        case .stop:
            path.addRoundedRect(in: CGRect(origin: p(7.5, 7.5), size: CGSize(width: 9 * s, height: 9 * s)),
                                cornerSize: CGSize(width: 1.5 * s, height: 1.5 * s))
        }
        return path
    }
}

extension KareGlyph {
    func line(_ width: CGFloat = 1.5) -> some View {
        stroke(style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}

/// Fine grain over the dark sand, plus horizontal rake lines on the trackpad.
struct KareSandBackground: View {
    var raked: Bool

    var body: some View {
        ZStack {
            Kare.sand
            Image("SandGrain").resizable(resizingMode: .tile).opacity(0.9)
            if raked {
                GeometryReader { geo in
                    Canvas { context, size in
                        var path = Path()
                        var y: CGFloat = 10.5
                        while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += 11 }
                        context.stroke(path, with: .color(Kare.ink.opacity(0.04)), lineWidth: 1)
                    }
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0.14), .init(color: .black, location: 0.24),
                        .init(color: .black, location: 0.80), .init(color: .clear, location: 0.88)
                    ], startPoint: .top, endPoint: .bottom))
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Static concentric rake rings around the stone (the animated version waits
/// for iPhone 7 measurements). Rings are 11 pt apart horizontally.
struct KareRipples: View {
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let aspect: CGFloat = 1.6
            var path = Path()
            var rx: CGFloat = 11
            while rx * aspect < size.height / 2 {
                path.addEllipse(in: CGRect(x: center.x - rx, y: center.y - rx * aspect, width: rx * 2, height: rx * aspect * 2))
                rx += 11
            }
            context.stroke(path, with: .color(Kare.ink.opacity(0.06)), lineWidth: 1)
        }
        .mask(EllipticalGradient(stops: [
            .init(color: .black, location: 0.40), .init(color: .clear, location: 0.75)
        ], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Text-only surface tabs with a thin ember underline on the selected one.
struct KareTabs: View {
    let titles: [String]
    let selected: Int
    var enabled = true
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 30) {
            ForEach(titles.indices, id: \.self) { index in
                Button { onSelect(index) } label: {
                    VStack(spacing: 6) {
                        Text(titles[index]).font(.system(size: 13)).tracking(3)
                            .foregroundStyle(index == selected ? Kare.ink : Kare.dim)
                        Rectangle().fill(index == selected ? Kare.ember : .clear).frame(height: 1)
                    }
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == selected ? .isSelected : [])
            }
        }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }
}

/// Hairline slider: 2 pt track, ember fill, warm-white thumb.
struct KareSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let label: String

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = CGFloat(fraction) * width
            ZStack(alignment: .leading) {
                Capsule().fill(Kare.ink.opacity(0.15)).frame(height: 2)
                Capsule().fill(Kare.ember).frame(width: max(0, x), height: 2)
                Circle().fill(Kare.thumb).frame(width: 20, height: 20).offset(x: min(max(0, x - 10), width - 20))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = min(1, max(0, drag.location.x / max(1, width)))
                var next = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                next = (next / step).rounded() * step
                next = min(range.upperBound, max(range.lowerBound, next))
                if next != value { value = next }
            })
        }
        .frame(height: 36)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            let delta = (range.upperBound - range.lowerBound) / 10
            switch direction {
            case .increment: value = min(range.upperBound, value + delta)
            case .decrement: value = max(range.lowerBound, value - delta)
            @unknown default: break
            }
        }
    }
}

/// Custom bottom sheet (iOS 15 has no detents): dim backdrop, grabber,
/// warm surface sized to its content and scrollable on small screens.
struct KareSheet<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let bottomInset = geo.safeAreaInsets.bottom
            ZStack(alignment: .bottom) {
                Color(red: 8 / 255, green: 7 / 255, blue: 6 / 255).opacity(0.6)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    Capsule().fill(Kare.ink.opacity(0.2)).frame(width: 38, height: 5)
                        .frame(maxWidth: .infinity, minHeight: 27, alignment: .top)
                        .padding(.top, 14)
                        .contentShape(Rectangle())
                        .accessibilityHidden(true)
                    ScrollView(showsIndicators: false) {
                        content()
                            .padding(.horizontal, 26)
                            .padding(.bottom, bottomInset > 0 ? 30 : 18)
                            .background(GeometryReader { inner in
                                Color.clear.preference(key: KareSheetHeightKey.self, value: inner.size.height)
                            })
                    }
                    .frame(height: min(contentHeight, geo.size.height + geo.safeAreaInsets.top - 110))
                }
                .background(
                    RoundedRectangle(cornerRadius: bottomInset > 0 ? 40 : 22, style: .continuous).fill(Kare.surface)
                        .overlay(RoundedRectangle(cornerRadius: bottomInset > 0 ? 40 : 22, style: .continuous)
                            .strokeBorder(Kare.ink.opacity(0.07), lineWidth: 1))
                )
                .padding(8)
                .offset(y: max(0, drag))
                .gesture(DragGesture().onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        if value.translation.height > 90 { onDismiss() }
                        drag = 0
                    })
                .accessibilityAddTraits(.isModal)
            }
            .ignoresSafeArea(edges: .bottom)
            .onPreferenceChange(KareSheetHeightKey.self) { contentHeight = $0 }
        }
    }
}

private struct KareSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One hairline-separated row of the device sheet.
struct KareSheetRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var dimmed = false
    var separator = true
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(dimmed ? Kare.dim : Kare.ink).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(dimmed ? Kare.dim : Kare.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { if separator { Rectangle().fill(Kare.hairline).frame(height: 1) } }
        .contentShape(Rectangle())
    }
}
