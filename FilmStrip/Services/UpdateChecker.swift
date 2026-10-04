import AppKit

actor UpdateChecker {

    enum Result {
        case upToDate(version: String)
        case available(version: String, downloadURL: URL, releaseURL: URL)
        /// Newer than this build, but it needs a newer macOS than this Mac has.
        case needsNewerMacOS(version: String, minimum: String, installed: String)
        case error(String)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
        let assets: [Asset]
        /// The release notes, which carry the minimum-macos marker.
        let body: String?

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadUrl = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
            case assets
            case body
        }
    }

    /// The macOS a release says it needs. release.sh ends every release's notes
    /// with `<!-- minimum-macos: 15.0 -->`, read from the built app's
    /// LSMinimumSystemVersion; GitHub does not render the comment. nil when there
    /// is no marker: a release from before it existed, which runs on every macOS
    /// this build does.
    nonisolated static func minimumMacOS(inReleaseNotes notes: String?) -> OperatingSystemVersion? {
        guard let notes,
              let start = notes.range(of: "<!-- minimum-macos:"),
              let end = notes[start.upperBound...].range(of: "-->") else { return nil }
        return macOSVersion(String(notes[start.upperBound..<end.lowerBound]))
    }

    /// "15", "15.0" or "15.2.1" as a version; nil for anything else.
    nonisolated static func macOSVersion(_ string: String) -> OperatingSystemVersion? {
        let fields = string.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        guard (1...3).contains(fields.count), numbers.count == fields.count else { return nil }
        return OperatingSystemVersion(majorVersion: numbers[0],
                                      minorVersion: numbers.count > 1 ? numbers[1] : 0,
                                      patchVersion: numbers.count > 2 ? numbers[2] : 0)
    }

    /// True when a Mac running `os` meets `minimum`.
    nonisolated static func runs(on os: OperatingSystemVersion, given minimum: OperatingSystemVersion) -> Bool {
        (os.majorVersion, os.minorVersion, os.patchVersion)
            >= (minimum.majorVersion, minimum.minorVersion, minimum.patchVersion)
    }

    /// "15.0", or "15.2.1" when there is a patch number.
    nonisolated static func describe(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    func check() async -> Result {
        guard let apiURL = URL(string: "https://api.github.com/repos/sevmorris/FilmStrip/releases/latest") else {
            return .error("Invalid update URL.")
        }

        do {
            var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .error("Could not reach GitHub. Check your internet connection.")
            }

            let release = try JSONDecoder().decode(Release.self, from: data)

            let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            guard let releaseURL = URL(string: release.htmlUrl)
                ?? URL(string: "https://github.com/sevmorris/FilmStrip/releases") else {
                return .error("Invalid release URL.")
            }
            let downloadURL = release.assets.first(where: { $0.name.hasSuffix(".dmg") })
                .flatMap { URL(string: $0.browserDownloadUrl) }
                ?? releaseURL

            if latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending {
                // A release this Mac cannot run is not an update for it: its DMG
                // would replace a working app with one that will not open.
                if let minimum = Self.minimumMacOS(inReleaseNotes: release.body),
                   !Self.runs(on: ProcessInfo.processInfo.operatingSystemVersion, given: minimum) {
                    return .needsNewerMacOS(version: latestVersion, minimum: Self.describe(minimum),
                                            installed: currentVersion)
                }
                return .available(version: latestVersion, downloadURL: downloadURL, releaseURL: releaseURL)
            } else {
                return .upToDate(version: currentVersion)
            }

        } catch {
            return .error(error.localizedDescription)
        }
    }
}

/// Show an update dialog. When `silent` is true (launch check), only prompt if
/// an update is actually available — don't bother the user with "you're up to date".
@MainActor
func checkForUpdates(silent: Bool = false) async {
    let result = await UpdateChecker().check()

    switch result {
    case .upToDate(let version):
        guard !silent else { return }
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "FilmStrip \(version) is the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()

    case .available(let version, let downloadURL, let releaseURL):
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "FilmStrip \(version) is available."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(downloadURL)
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.open(releaseURL)
        }

    case .needsNewerMacOS(let version, let minimum, let installed):
        // Nothing this Mac can install, so the check at launch says nothing.
        guard !silent else { return }
        let alert = NSAlert()
        alert.messageText = "FilmStrip \(version) needs macOS \(minimum)"
        alert.informativeText = "This Mac has macOS \(UpdateChecker.describe(ProcessInfo.processInfo.operatingSystemVersion)), "
            + "so FilmStrip \(installed) is the newest version it can run."
        alert.addButton(withTitle: "OK")
        alert.runModal()

    case .error(let message):
        guard !silent else { return }
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
