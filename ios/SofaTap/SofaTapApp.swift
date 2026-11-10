import SwiftUI

@main
struct SofaTapApp: App {
    @StateObject private var controller = ControllerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RemoteView(model: controller)
                .preferredColorScheme(.dark)
                .tint(Palette.mint)
                .onChangeCompat(of: scenePhase) { _, phase in
                    if phase == .active { controller.becameActive() }
                    else if phase == .background { controller.becameInactive() }
                    else { controller.pauseInput() }
                }
        }
    }
}

enum Palette {
    // 枯山水: dark warm sand. `mint` keeps its name but is now the single
    // ember accent, so older screens follow the new palette.
    static let background = Color(red: 0.078, green: 0.071, blue: 0.063)
    static let panel = Color(red: 0.118, green: 0.106, blue: 0.090)
    static let elevated = Color(red: 0.161, green: 0.145, blue: 0.122)
    static let mint = Color(red: 0.831, green: 0.529, blue: 0.290)
    static let muted = Color(red: 0.549, green: 0.518, blue: 0.463)
}
