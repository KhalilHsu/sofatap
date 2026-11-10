import SwiftUI

/// `NavigationStack` on iOS 16 and a stack-style `NavigationView` on iOS 15.
struct SofaNavigationStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 16, *) {
            NavigationStack(content: content)
        } else {
            NavigationView(content: content)
                .navigationViewStyle(.stack)
        }
    }
}

enum SofaSheetDetent {
    case mediumLarge
    case large
    case height300
}

extension View {
    /// iOS 14 `onChange` on iOS 15, and the two-value form on iOS 17.
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (_ oldValue: V, _ newValue: V) -> Void) -> some View {
        modifier(OnChangeCompat(value: value, action: action))
    }

    @ViewBuilder
    func sofaSheet(_ detent: SofaSheetDetent, indicator: Bool = true) -> some View {
        if #available(iOS 16, *) {
            sofaSheetIOS16(detent, indicator: indicator)
        } else {
            self
        }
    }

    @ViewBuilder
    func sofaHiddenScrollBackground() -> some View {
        if #available(iOS 16, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func sofaScrollDismissesKeyboard() -> some View {
        if #available(iOS 16, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    @ViewBuilder
    func sofaScrollDisabled(_ disabled: Bool) -> some View {
        if #available(iOS 16, *) {
            self.scrollDisabled(disabled)
        } else if disabled {
            self.highPriorityGesture(DragGesture(minimumDistance: 0))
        } else {
            self
        }
    }

    @ViewBuilder
    func sofaDestination<Destination: View>(isPresented: Binding<Bool>, @ViewBuilder destination: () -> Destination) -> some View {
        if #available(iOS 16, *) {
            self.navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            self.background(
                NavigationLink(isActive: isPresented, destination: destination) { EmptyView() }
                    .hidden()
            )
        }
    }

    @ViewBuilder
    func sofaSymbolReplace(reduceMotion: Bool) -> some View {
        if #available(iOS 17, *), !reduceMotion {
            self.contentTransition(.symbolEffect(.replace))
        } else if #available(iOS 16, *) {
            self.contentTransition(.opacity)
        } else {
            self
        }
    }

    @ViewBuilder
    func sofaNumericText() -> some View {
        if #available(iOS 17, *) {
            self.contentTransition(.numericText())
        } else if #available(iOS 16, *) {
            self.contentTransition(.opacity)
        } else {
            self
        }
    }

    /// Text-style weight. `Font.weight` is iOS 16; iOS 15 uses a fixed point size.
    @ViewBuilder
    func sofaTextStyle(_ style: Font.TextStyle, weight: Font.Weight) -> some View {
        if #available(iOS 16, *) {
            self.font(.system(style, design: .default, weight: weight))
        } else {
            self.font(.system(size: sofaPointSize(style), weight: weight))
        }
    }

    @ViewBuilder
    func sofaMonospacedCaption() -> some View {
        if #available(iOS 16, *) {
            self.font(.caption.monospaced())
        } else {
            self.font(.system(size: 12, weight: .regular, design: .monospaced))
        }
    }

    private func sofaPointSize(_ style: Font.TextStyle) -> CGFloat {
        if style == .largeTitle { return 34 }
        if style == .title { return 28 }
        if style == .title2 { return 22 }
        if style == .title3 { return 20 }
        if style == .headline || style == .body { return 17 }
        if style == .callout { return 16 }
        if style == .subheadline { return 15 }
        if style == .footnote { return 13 }
        if style == .caption { return 12 }
        if style == .caption2 { return 11 }
        return 17
    }
}

struct SofaVerticalTextField: View {
    var prompt: String
    @Binding var text: String
    var limit: Int = 6

    var body: some View {
        if #available(iOS 16, *) {
            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(1...limit)
        } else {
            TextField(prompt, text: $text)
                .lineLimit(limit)
        }
    }
}

@available(iOS 16, *)
private extension View {
    @ViewBuilder
    func sofaSheetIOS16(_ detent: SofaSheetDetent, indicator: Bool) -> some View {
        switch detent {
        case .mediumLarge:
            if indicator {
                self.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            } else {
                self.presentationDetents([.medium, .large])
            }
        case .large:
            if indicator {
                self.presentationDetents([.large]).presentationDragIndicator(.visible)
            } else {
                self.presentationDetents([.large])
            }
        case .height300:
            self.presentationDetents([.height(300)]).presentationDragIndicator(.visible)
        }
    }
}

private struct OnChangeCompat<V: Equatable>: ViewModifier {
    let value: V
    let action: (V, V) -> Void
    @State private var previous: V?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17, *) {
            content.onChange(of: value) { oldValue, newValue in
                action(oldValue, newValue)
            }
        } else {
            content
                .onAppear { previous = value }
                .onChange(of: value, perform: { newValue in
                    let oldValue = previous ?? newValue
                    previous = newValue
                    action(oldValue, newValue)
                })
        }
    }
}
