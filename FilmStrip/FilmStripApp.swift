import SwiftUI

/// Decides, before anything else runs, whether this launch is the app or only
/// the host for the unit tests.
///
/// Xcode runs the tests inside this app, so a test run used to launch all of
/// it: the view model built the settings, which read the output choices from
/// the app's defaults and re-saved the output folder's bookmark — or dropped
/// it, if it no longer resolved — the launch checked for updates, and SwiftUI
/// recorded the window's frame. Hosting tests, the app now starts with no
/// window, no view model and no update check.
///
/// Until now it was the sandbox that kept this away from the real settings,
/// and only by accident: the Debug build the tests run in is sandboxed, so its
/// defaults are the container's, while release.sh signs the shipped app with
/// entitlements that leave the sandbox out, so its defaults are in
/// ~/Library/Preferences. Change either and a test run would reach them.
@main
enum AppLauncher {
    static func main() {
        if isHostingTests {
            TestHostApp.main()
        } else {
            FilmStripApp.main()
        }
    }

    /// XCTest is already loaded when main() runs in a test host — Swift
    /// Testing's included — and is never linked into the app itself. The
    /// session identifier is Xcode's own mark of a test launch, checked as
    /// well in case XCTest ever loads later.
    nonisolated static let isHostingTests =
        NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
}

/// A scene with no window: while the app hosts the tests, nothing of the real
/// app is built.
private struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

extension UserDefaults {
    /// Where the app keeps what it stores in defaults. It is the app's own
    /// domain — except in a test run, where `.standard` is that same domain,
    /// the developer's real settings, because the tests run inside the app.
    /// A test run gets a scratch suite in its place, so a test that forgets
    /// to pass a store of its own still cannot reach the real one. Nothing in
    /// the app names `.standard`; it goes through here.
    ///
    /// The scratch suite is named by a path in the temporary folder, which
    /// keeps its file out of ~/Library/Preferences, where the App Preferences
    /// source's io.github.sevmorris.* pattern would back it up.
    nonisolated static let app: UserDefaults = AppLauncher.isHostingTests
        ? UserDefaults(suiteName: FileManager.default.temporaryDirectory
            .appendingPathComponent("io.github.sevmorris.FilmStrip.tests").path)!
        : .standard
}

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
