import SwiftUI

@main
struct PumpTallyApp: App {
    @StateObject private var loader = ApplicationEnvironmentLoader {
        try AppBootstrap.makeEnvironment()
    }

    var body: some Scene {
        WindowGroup {
            ApplicationRootView(loader: loader)
        }
    }
}
