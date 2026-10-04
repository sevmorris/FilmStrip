import Testing
import Foundation
@testable import FilmStrip

// MARK: - UpdateChecker: minimum macOS

/// `minimumMacOS(inReleaseNotes:)` and its helpers decide whether the update
/// check offers a release, from the marker release.sh writes into its notes.
/// A missing or malformed marker sets no minimum, so the release is offered as
/// it always was.
@Suite("UpdateChecker minimum macOS")
struct UpdateCheckerMinimumMacOSTests {

    private func version(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    private func fields(_ version: OperatingSystemVersion?) -> [Int]? {
        version.map { [$0.majorVersion, $0.minorVersion, $0.patchVersion] }
    }

    @Test("Reads the marker release.sh writes")
    func readsTheMarker() {
        #expect(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "**Fixed**\n- Something.\n\n---\nRequires macOS 15.0 or later.\n<!-- minimum-macos: 15.0 -->")) == [15, 0, 0])
        #expect(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15.2.1 -->")) == [15, 2, 1])
        #expect(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 26 -->")) == [26, 0, 0])
    }

    @Test("Notes without a marker set no minimum")
    func noMarker() {
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: nil) == nil)
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "**Fixed**\n- Something.") == nil)
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "Requires macOS 15.0 or later.") == nil)
    }

    @Test("A malformed marker sets no minimum")
    func malformedMarker() {
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: fifteen -->") == nil)
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15.0") == nil)
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15..0 -->") == nil)
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 1.2.3.4 -->") == nil)
    }

    @Test("Compares major, then minor, then patch")
    func comparison() {
        #expect(!UpdateChecker.runs(on: version(14, 6), given: version(15)))
        #expect(UpdateChecker.runs(on: version(15), given: version(15)))
        #expect(UpdateChecker.runs(on: version(26, 7, 1), given: version(15)))
        #expect(!UpdateChecker.runs(on: version(15), given: version(15, 1)))
        #expect(UpdateChecker.runs(on: version(15, 1), given: version(15, 0, 1)))
    }

    @Test("Describes a version the way macOS does")
    func description() {
        #expect(UpdateChecker.describe(version(15)) == "15.0")
        #expect(UpdateChecker.describe(version(15, 2, 1)) == "15.2.1")
    }
}
