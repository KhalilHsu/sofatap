import SwiftUI
import UIKit
import CoreText

/// 枯山水 (raked sand) tokens from handoff-m2/CHECKLIST.md. Every colour follows
/// the system light/dark appearance. Only the stone gets light or shadow.
enum Kare {
    static func ui(dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> UIColor {
        UIColor { traits in
            let isLight = traits.userInterfaceStyle == .light
            let hex = isLight ? light : dark
            return UIColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: isLight ? lightAlpha : darkAlpha)
        }
    }
    static let sand = Color(ui(dark: 0x141210, light: 0xE6E0D3))
    static let surface = Color(ui(dark: 0x1E1B17, light: 0xDCD5C6))
    static let ink = Color(ui(dark: 0xE9E2D4, light: 0x211E1A))
    static let ink2 = Color(ui(dark: 0xC2B8A5, light: 0x3F3A33))
    static let mute = Color(ui(dark: 0x9A9283, light: 0x5A544A))
    static let accentUI = ui(dark: 0xE39A5E, light: 0x8A4416)
    static let accent = Color(accentUI)
    static let line = Color(ui(dark: 0xE9E2D4, light: 0x211E1A, darkAlpha: 0.08, lightAlpha: 0.12))
    static let line2 = Color(ui(dark: 0xE9E2D4, light: 0x211E1A, darkAlpha: 0.16, lightAlpha: 0.22))
    static let rule = Color(ui(dark: 0xE9E2D4, light: 0x211E1A, darkAlpha: 0.14, lightAlpha: 0.14))
    static let scrim = Color(ui(dark: 0x0A0908, light: 0x211E1A, darkAlpha: 0.6, lightAlpha: 0.35))
    static let stoneLit = Color(ui(dark: 0xE39A5E, light: 0xA0501E, darkAlpha: 0.38, lightAlpha: 0.35))
    static let stoneShadow = Color(ui(dark: 0x000000, light: 0x000000, darkAlpha: 0.45, lightAlpha: 0.28))
    /// Disabled: mute at 50 %.
    static let disabled = Color(ui(dark: 0x9A9283, light: 0x5A544A, darkAlpha: 0.5, lightAlpha: 0.5))

    static var isSmallScreen: Bool { UIScreen.main.bounds.height <= 700 }

    /// Song for device names and titles. Uses the Apple downloadable Songti SC
    /// when present, PingFang SC Medium until then. No CJK font is bundled.
    static func song(_ size: CGFloat) -> Font {
        if let name = KareSong.shared.fontName { return .custom(name, fixedSize: size) }
        return .custom("PingFangSC-Medium", fixedSize: size)
    }
    static let instrumentSerifItalic = "InstrumentSerif-Italic"
    /// Bundled Instrument Serif Italic (OFL) for English stone names; New York
    /// italic if the font failed to register.
    static let instrumentSerifLoaded: Bool = {
        let ok = UIFont(name: instrumentSerifItalic, size: 15) != nil
        NSLog("KareFont InstrumentSerif-Italic loaded=%@", ok ? "YES" : "NO")
        return ok
    }()
    static func latinItalic(_ size: CGFloat) -> Font {
        if instrumentSerifLoaded { return .custom(instrumentSerifItalic, fixedSize: size) }
        return .system(size: size, weight: .regular, design: .serif).italic()
    }
}

/// Loads STSongti-SC-Regular, downloading it from Apple on first use.
final class KareSong: ObservableObject {
    static let shared = KareSong()
    static let postScriptName = "STSongti-SC-Regular"
    @Published private(set) var fontName: String?
    private var requested = false

    private init() {
        if UIFont(name: Self.postScriptName, size: 17) != nil { fontName = Self.postScriptName }
    }

    /// Called on every launch: an already downloaded font still has to be
    /// matched once per process before `UIFont(name:)` can see it.
    func prepare() {
        guard fontName == nil, !requested else { return }
        requested = true
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: Self.postScriptName] as CFDictionary)
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler([descriptor] as CFArray, nil) { state, _ in
            if state == .didFinish {
                DispatchQueue.main.async {
                    let ok = UIFont(name: KareSong.postScriptName, size: 17) != nil
                    NSLog("KareSong download finished, available=%@", ok ? "YES" : "NO")
                    if ok { KareSong.shared.fontName = KareSong.postScriptName }
                }
            }
            return true
        }
    }
}

/// The delivered thin-line icons (PDF vectors, template rendering).
struct KareIcon: View {
    let name: String
    var size: CGFloat = 24
    var body: some View {
        Image("KareIcon-" + name).renderingMode(.template).resizable().scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Pre-rendered static sand from handoff-m2/assets: rings (air mouse) or rake
/// (trackpad). Aspect-filled so the ring centre lands on the stone centre.
struct KareSandBackground: View {
    var rings: Bool

    var body: some View {
        let suffix = Kare.isSmallScreen ? "SE" : ""
        ZStack {
            Kare.sand
            Image("SandRake" + suffix).resizable().scaledToFill().opacity(rings ? 0 : 1)
            Image("SandRings" + suffix).resizable().scaledToFill().opacity(rings ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.24), value: rings)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Ring centre (= stone centre) in screen points for the aspect-filled bitmap.
    static func stoneCenter(screen: CGSize) -> CGPoint {
        let small = Kare.isSmallScreen
        let art = small ? CGSize(width: 375, height: 667) : CGSize(width: 390, height: 844)
        let center = small ? CGPoint(x: 187.5, y: 330) : CGPoint(x: 195, y: 420)
        let scale = max(screen.width / art.width, screen.height / art.height)
        return CGPoint(x: screen.width / 2 + (center.x - art.width / 2) * scale,
                       y: screen.height / 2 + (center.y - art.height / 2) * scale)
    }
}

/// Text-only tabs: selected word in ink with a 1 pt accent underline 6 pt below.
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
                        Text(titles[index]).font(.custom("PingFangSC-Medium", fixedSize: 15)).tracking(3)
                            .foregroundStyle(index == selected ? Kare.ink : Kare.ink2)
                        Rectangle().fill(index == selected ? Kare.accent : .clear).frame(height: 1)
                    }
                    .fixedSize()
                    .frame(minWidth: 64, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == selected ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.18), value: selected)
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
    }
}

/// Slider: 1 pt line2 track, 2 pt accent fill, 20 pt ink thumb, no shadow.
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
                Rectangle().fill(Kare.line2).frame(height: 1)
                Rectangle().fill(Kare.accent).frame(width: max(0, x), height: 2)
                Circle().fill(Kare.ink).frame(width: 20, height: 20).offset(x: min(max(0, x - 10), width - 20))
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

/// Bottom sheet (iOS 15 has no detents): scrim, 38×5 grabber, surface with a
/// 1 pt line border, 8 pt from the screen edges, radius 40.
struct KareSheet<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let bottomInset = geo.safeAreaInsets.bottom
            let radius: CGFloat = bottomInset > 0 ? 40 : 22
            ZStack(alignment: .bottom) {
                Kare.scrim
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
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Kare.surface)
                        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Kare.line, lineWidth: 1))
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

/// One 56 pt row of the device sheet with a 1 pt line separator.
struct KareSheetRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var dimmed = false
    var separator = true
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let icon { KareIcon(name: icon, size: 20).foregroundStyle(dimmed ? Kare.disabled : Kare.ink2) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(dimmed ? Kare.disabled : Kare.ink).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(dimmed ? Kare.disabled : Kare.mute).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { if separator { Rectangle().fill(Kare.line).frame(height: 1) } }
        .contentShape(Rectangle())
    }
}

/// Delivery hint under the composer: the message wraps to at most two lines and
/// truncates with an ellipsis; the accent text actions stay one line at full size.
struct DeliveryNoticeRow: View {
    struct Action { let title: String; let identifier: String; let run: () -> Void }
    let message: String
    let font: Font
    let actions: [Action]
    var disabled = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(message)
                .font(font)
                .foregroundStyle(Kare.mute)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("textDeliveryStatus")
            ForEach(actions, id: \.identifier) { action in
                Button(action.title, action: action.run)
                    .font(font.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                    .foregroundStyle(Kare.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(disabled)
                    .accessibilityIdentifier(action.identifier)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
    }
}
