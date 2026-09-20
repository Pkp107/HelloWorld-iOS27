import SwiftUI

struct ContentView: View {
    @State private var didTap = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 56, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Hello, world!")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(didTap ? "Thanks for saying hello." : "A tiny app built for iOS 27.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                didTap = true
            } label: {
                Text("Say hello")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 140, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Shows a confirmation message")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .tint(.blue)
    }
}

#Preview {
    ContentView()
}
