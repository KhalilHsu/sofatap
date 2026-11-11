import SwiftUI

@main
struct SofaTapApp: App {
    @StateObject private var controller = ControllerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RemoteView(model: controller)
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
    // 枯山水 tokens (light and dark). `mint` keeps its name but is the single
    // accent, so older screens follow the new palette.
    static let background = Kare.sand
    static let panel = Kare.surface
    static let elevated = Color(Kare.ui(dark: 0x29251F, light: 0xD2CABA))
    static let mint = Kare.accent
    static let muted = Kare.mute
}
