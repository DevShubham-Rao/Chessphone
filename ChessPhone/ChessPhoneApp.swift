import SwiftUI

@main
struct ChessPhoneApp: App {
    init() {
        GlassesSetup.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    GlassesSetup.handle(url: url)
                }
        }
    }
}
