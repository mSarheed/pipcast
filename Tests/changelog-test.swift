import Foundation

@main
@MainActor
struct ChangelogTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        splitsIntoVersions()
        readsTheHeadingDate()
        mapsABetaToItsRelease()
        hidesVersionsNotYetReached()
        decidesWhenThereIsNews()
        keepsAWrappedBulletWhole()
        shipsAnEntryForTheBuiltVersion()
        agreesWithTheReleaseScript()
        announcesOncePerVersion()
        parsesQuickly()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    private static func version(_ text: String) -> AppVersion { AppVersion(text)! }

    private static let sample = """
        # Changelog

        Preamble that belongs to no version.

        ## 0.2.0 — 2026-11-20

        A headline.

        ### New

        - **Thing** — it does a thing.

        ## 0.1.0

        - First.
        """

    static func splitsIntoVersions() {
        let changelog = Changelog(markdown: sample)
        expect(changelog.entries.map(\.version) == [version("0.2.0"), version("0.1.0")], "newest first")
        expect(changelog.entries.first?.notes.hasPrefix("A headline.") == true, "notes start after the heading")
        expect(changelog.entries.first?.notes.contains("### New") == true, "subheadings stay in the notes")
        expect(changelog.entries.last?.notes == "- First.", "the last entry runs to the end of the file")
        expect(!changelog.entries.contains { $0.notes.contains("Preamble") }, "the preamble is dropped")

        let unordered = Changelog(markdown: "## 0.1.0\nOld.\n## 0.3.0\nNew.")
        expect(unordered.entries.first?.version == version("0.3.0"), "entries sort regardless of file order")
        expect(Changelog(markdown: "## Unreleased\n- x").entries.isEmpty, "a non-version heading starts nothing")
        expect(Changelog(markdown: "## 0.2.0-beta.3\n- x").entries.isEmpty, "a beta never has its own entry")
        expect(Changelog(markdown: "").entries.isEmpty, "an empty file has no entries")
        expect(
            Changelog(markdown: "## 0.4.0\t— 2026-01-01\n- x").entries.first?.version == version("0.4.0"),
            "a tab separates the heading's words like a space")
        expect(Changelog(markdown: "## v0.4.0\n- x").entries.isEmpty, "a heading never takes a tag's v")
        let repeated = Changelog(markdown: "## 0.4.0\n- first\n## 0.4.0\n- second")
        expect(
            repeated.entries.map(\.notes) == ["- first"],
            "a repeated version keeps its first section, so ids stay unique")
    }

    static func readsTheHeadingDate() {
        let changelog = Changelog(markdown: sample)
        expect(
            changelog.entries.first?.date == DateComponents(year: 2026, month: 11, day: 20),
            "a heading's date is read")
        expect(changelog.entries.last?.date == nil, "a heading without a date has none")
        expect(
            Changelog(markdown: "## 0.1.0 - 2026-01-02").entries.first?.date
                == DateComponents(year: 2026, month: 1, day: 2),
            "a hyphen separates the date too")
        expect(
            Changelog(markdown: "## 0.1.0 — 2026-13-02").entries.first?.date == nil,
            "an impossible month is no date")
    }

    static func mapsABetaToItsRelease() {
        expect(version("0.2.0-beta.4").release == version("0.2.0"), "a beta leads to its release")
        expect(version("0.2.0").release == version("0.2.0"), "a release is its own")
        let changelog = Changelog(markdown: sample)
        expect(
            changelog.entry(for: version("0.2.0-beta.4"))?.version == version("0.2.0"),
            "a beta reads the notes of the release it leads to")
        expect(changelog.entry(for: version("0.1.1")) == nil, "a version without notes has no entry")
    }

    static func hidesVersionsNotYetReached() {
        let changelog = Changelog(markdown: sample)
        expect(
            changelog.entries(upTo: version("0.1.0")).map(\.version) == [version("0.1.0")],
            "notes for a later version are not this build's history")
        expect(
            changelog.entries(upTo: version("0.2.0-beta.1")).count == 2,
            "a beta sees the release it leads to")
    }

    static func decidesWhenThereIsNews() {
        let changelog = Changelog(markdown: sample)
        let running = version("0.2.0")
        expect(
            !changelog.hasNews(for: running, lastSeen: nil, isFirstLaunch: true),
            "a fresh install has nothing to catch up on")
        expect(
            changelog.hasNews(for: running, lastSeen: nil, isFirstLaunch: false),
            "a copy that predates the record has updated")
        expect(
            changelog.hasNews(for: running, lastSeen: version("0.1.0"), isFirstLaunch: false),
            "an update past the last read version is news")
        expect(
            !changelog.hasNews(for: running, lastSeen: running, isFirstLaunch: false),
            "a read version is not news again")
        expect(
            !changelog.hasNews(for: version("0.1.0"), lastSeen: running, isFirstLaunch: false),
            "a downgrade is not news")
        expect(
            !changelog.hasNews(for: version("0.3.0"), lastSeen: running, isFirstLaunch: false),
            "a version without notes has nothing to announce")
        expect(
            !changelog.hasNews(for: version("0.2.0-beta.2"), lastSeen: running, isFirstLaunch: false),
            "a later beta of a release already read is not news")
    }

    static func keepsAWrappedBulletWhole() {
        expect(
            ReleaseNotes.blocks(from: "- **Launcher** — open apps\n  and commands.\n- Next.")
                == [.bullet("**Launcher** — open apps and commands."), .bullet("Next.")],
            "a wrapped line continues its bullet")
        expect(
            ReleaseNotes.blocks(from: "- Item.\n\nAfter.") == [.bullet("Item."), .paragraph("After.")],
            "a blank line ends the bullet")
    }

    /// The repo's own file: a version cannot be built without notes for it.
    static func shipsAnEntryForTheBuiltVersion() {
        guard let markdown = try? String(contentsOfFile: "CHANGELOG.md", encoding: .utf8),
            let project = try? String(contentsOfFile: "project.yml", encoding: .utf8),
            let line = project.split(separator: "\n").first(where: { $0.contains("MARKETING_VERSION:") }),
            let built = AppVersion(String(line.split(separator: "\"")[1]))
        else {
            expect(false, "CHANGELOG.md and project.yml's MARKETING_VERSION are readable")
            return
        }
        let changelog = Changelog(markdown: markdown)
        expect(changelog.entry(for: built) != nil, "CHANGELOG.md has an entry for \(built)")
        expect(
            changelog.entries.allSatisfy { !ReleaseNotes.blocks(from: $0.notes).isEmpty },
            "every entry has notes")
    }

    /// The script publishes what the app shows, so both must cut the same section.
    static func agreesWithTheReleaseScript() {
        guard let markdown = try? String(contentsOfFile: "CHANGELOG.md", encoding: .utf8) else {
            expect(false, "CHANGELOG.md is readable")
            return
        }
        for entry in Changelog(markdown: markdown).entries {
            let script = Process()
            let output = Pipe()
            script.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            script.arguments = ["python3", "Scripts/changelog-notes.py", entry.version.description]
            script.standardOutput = output
            guard (try? script.run()) != nil else {
                expect(false, "Scripts/changelog-notes.py runs")
                return
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            script.waitUntilExit()
            let published = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            expect(
                script.terminationStatus == 0 && published == entry.notes,
                "the release script publishes the notes the app shows for \(entry.version)")
        }
    }

    static func announcesOncePerVersion() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("changelog-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // A path per version: Foundation caches a bundle, Info.plist and all, by its path.
        func install(version: String) -> Bundle? {
            let bundleURL = root.appendingPathComponent("\(version).bundle")
            try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            let plist = ["CFBundleShortVersionString": version, "CFBundleIdentifier": "test.\(UUID())"]
            (plist as NSDictionary).write(to: bundleURL.appendingPathComponent("Info.plist"), atomically: true)
            try? sample.write(
                to: bundleURL.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
            return Bundle(url: bundleURL)
        }
        guard let first = install(version: "0.1.0"), let updated = install(version: "0.2.0") else {
            expect(false, "a fake bundle loads")
            return
        }

        let fresh = ChangelogStore(bundle: first, isFirstLaunch: true, directory: root)
        expect(!fresh.hasNews && !fresh.isAnnouncementDue, "a fresh install is told nothing")

        let afterUpdate = ChangelogStore(bundle: updated, isFirstLaunch: false, directory: root)
        expect(afterUpdate.hasNews && afterUpdate.isAnnouncementDue, "an update is news and owed a HUD")
        afterUpdate.markAnnounced()

        let relaunch = ChangelogStore(bundle: updated, isFirstLaunch: false, directory: root)
        expect(relaunch.hasNews, "the dot outlives the HUD")
        expect(!relaunch.isAnnouncementDue, "the HUD is said once per version, not once per launch")
        relaunch.markSeen()

        let read = ChangelogStore(bundle: updated, isFirstLaunch: false, directory: root)
        expect(!read.hasNews && !read.isAnnouncementDue, "opening What's New clears the dot for good")
    }

    /// Parsed once at launch, so even a long history must cost next to nothing.
    static func parsesQuickly() {
        let entry = """
            ## %@ — 2026-01-01

            A headline for this release.

            ### New

            - **Feature** — something that changed, wrapped across
              a second line.
            - **Another** — one more thing.

            ### Fixed

            - A fix.

            """
        let markdown = (0..<200).map { String(format: entry, "1.\($0).0") }.joined()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<10 { _ = Changelog(markdown: markdown) }
        }
        let perParse = elapsed / 10
        print("parse of 200 releases (\(markdown.utf8.count) bytes): \(perParse)")
        expect(perParse < .milliseconds(20), "a 200-release changelog parses in under 20 ms")
    }
}
