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
    static let background = Color(red: 0.039, green: 0.051, blue: 0.067)
    static let panel = Color(red: 0.079, green: 0.098, blue: 0.122)
    static let elevated = Color(red: 0.110, green: 0.137, blue: 0.165)
    static let mint = Color(red: 0.722, green: 0.953, blue: 0.816)
    static let muted = Color(red: 0.60, green: 0.65, blue: 0.69)
}
