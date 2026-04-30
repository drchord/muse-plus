import SwiftUI

@main
struct MusePlusApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack {
            Text("Muse Plus")
                .font(.largeTitle)
            Text("Skeleton — Gate 0")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
