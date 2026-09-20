import SwiftUI

@main
@MainActor
struct HelloWorldApp: App {
    @StateObject private var store = WorkspaceStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
