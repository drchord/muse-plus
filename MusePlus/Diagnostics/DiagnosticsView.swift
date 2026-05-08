import SwiftUI
import OSLog

// MARK: - DiagnosticsView
//
// Reads the app's own OSLog entries (last 24 h) via OSLogStore and displays them
// as a scrollable monospaced list. A Share button exports the log as plain text.
// Accessible from SettingsSheet → "Diagnostics" section.
// iOS 15+ only — callers must guard with `if #available(iOS 15, *)`.

@available(iOS 15.0, *)
struct DiagnosticsView: View {
    @State private var entries: [String] = []
    @State private var isLoading = true
    @State private var shareText: String = ""
    @State private var showShare = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading diagnostics…")
            } else {
                List {
                    Section("Last 24h — \(entries.count) entries") {
                        ForEach(entries.indices, id: \.self) { i in
                            Text(entries[i])
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            Button {
                shareText = entries.joined(separator: "\n")
                showShare = true
            } label: { Image(systemName: "square.and.arrow.up") }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [shareText])
        }
        .task { await load() }
    }

    private func load() async {
        await Task.detached(priority: .userInitiated) {
            do {
                let store = try OSLogStore(scope: .currentProcessIdentifier)
                let cutoff = store.position(date: Date().addingTimeInterval(-24 * 3600))
                let predicate = NSPredicate(format: "subsystem == %@", "com.drchord.museplus")
                let allEntries = try store.getEntries(at: cutoff, matching: predicate)
                let fmt = ISO8601DateFormatter()
                let lines: [String] = allEntries.compactMap { entry -> String? in
                    guard let log = entry as? OSLogEntryLog else { return nil }
                    return "\(fmt.string(from: log.date)) [\(log.category)] \(log.composedMessage)"
                }
                await MainActor.run {
                    self.entries = lines
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.entries = ["Error loading OSLog: \(error.localizedDescription)"]
                    self.isLoading = false
                }
            }
        }.value
    }
}

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
