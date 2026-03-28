import SwiftUI

@main
struct FilmStripApp: App {
    @State private var viewModel = ContentViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .frame(minWidth: 780, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("FilmStrip Help") {
                    viewModel.showHelp = true
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}
