import SwiftUI

@main
struct FilmStripApp: App {
    @State private var viewModel = ContentViewModel()

    init() {
        Task {
            await checkForUpdates(silent: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .frame(minWidth: 800, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("FilmStrip Help") {
                    viewModel.showHelp = true
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Check for Updates…") {
                    Task { await checkForUpdates() }
                }

                Divider()

                Button("Send Feedback…") {
                    if let url = URL(string: "https://sevmorris.github.io/FilmStrip/#feedback"),
                       !NSWorkspace.shared.open(url) {
                        viewModel.errorMessage = "Could not open the feedback page. Visit sevmorris.github.io/FilmStrip in your browser."
                    }
                }

                Button("Report an Issue…") {
                    if let url = URL(string: "https://github.com/sevmorris/FilmStrip/issues/new"),
                       !NSWorkspace.shared.open(url) {
                        viewModel.errorMessage = "Could not open the issue page. Visit github.com/sevmorris/FilmStrip/issues in your browser."
                    }
                }
            }
        }
    }
}
