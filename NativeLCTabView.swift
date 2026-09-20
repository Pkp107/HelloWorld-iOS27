import SwiftUI

struct LCTabView: View {
    @StateObject private var store = WorkspaceStore()

    var body: some View {
        ContentView(store: store)
            // The workspace shell owns the visible launcher, while the
            // native LiveContainer views still read their shared model from
            // the environment when a guest-app surface is opened.
            .environmentObject(DataManager.shared.model)
            .environmentObject(LCAppSortManager.shared)
    }
}
