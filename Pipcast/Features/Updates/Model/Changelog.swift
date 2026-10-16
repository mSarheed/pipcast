import Foundation

/// `CHANGELOG.md` as the app reads it: one entry per `## <version>` heading, newest first.
struct Changelog: Sendable {
    struct Entry: Identifiable, Hashable, Sendable {
        let version: AppVersion
        /// The heading's `YYYY-MM-DD`, written when the release is cut; nil until then.
        let date: DateComponents?
        /// Markdown in the block shapes `ReleaseNotes.blocks` reads.
        let notes: String
        /// The summary a section opens with, as one plain line; nil when it opens on a list.
        let headline: String?

        var id: AppVersion { version }

        init(version: AppVersion, date: DateComponents?, notes: String) {
            self.version = version
            self.date = date
            self.notes = notes
            headline = Self.headline(of: notes)
        }

        /// Read once here, never per render, and never linkified: the card is a target of its own.
        private static func headline(of notes: String) -> String? {
            let opening = notes.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .prefix { !$0.isEmpty }
            guard let first = opening.first, !first.hasPrefix("#"),
                !["- ", "* ", "+ "].contains(where: first.hasPrefix)
            else { return nil }
            return opening.joined(separator: " ")
        }
    }

    let entries: [Entry]

    init(entries: [Entry]) {
        self.entries = entries.sorted { $0.version > $1.version }
    }

    /// Anything above the first version heading is the file's own preamble, and is dropped.
    init(markdown: String) {
        var entries: [Entry] = []
        var current: (version: AppVersion, date: DateComponents?)?
        var body: [Substring] = []

        func flush() {
            guard let current else { return }
            let notes = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(Entry(version: current.version, date: current.date, notes: notes))
        }

        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false)
        {
            if let heading = Self.versionHeading(line) {
                flush()
                current = heading
                body.removeAll()
            } else if current != nil {
                body.append(line)
            }
        }
        flush()
        // `changelog-notes.py` refuses a repeated version, so a release never ships one.
        var versions = Set<AppVersion>()
        self.init(entries: entries.filter { versions.insert($0.version).inserted })
    }

    /// A beta reads the notes of the release it leads to, so it never shows an empty screen.
    func entry(for running: AppVersion) -> Entry? {
        entries.first { $0.version == running.release }
    }

    /// Notes written ahead of a version this build has not reached are not this build's history.
    func entries(upTo running: AppVersion) -> [Entry] {
        entries.filter { $0.version <= running.release }
    }

    /// A fresh install has nothing to catch up on; a copy that predates the record has updated.
    func hasNews(for running: AppVersion, lastSeen: AppVersion?, isFirstLaunch: Bool) -> Bool {
        guard entry(for: running) != nil else { return false }
        guard let lastSeen else { return !isFirstLaunch }
        return lastSeen < running.release
    }

    /// `## 0.4.0` or `## 0.4.0 — 2026-10-16`; matches `HEADING` in `Scripts/changelog-notes.py`.
    private static func versionHeading(_ line: Substring) -> (AppVersion, DateComponents?)? {
        guard line.hasPrefix("## ") else { return nil }
        let words = line.dropFirst(3).split(whereSeparator: \.isWhitespace)
            .filter { !["—", "–", "-"].contains($0) }
        // `AppVersion` takes a tag's `v`, which a heading never carries; a prerelease has none.
        guard let first = words.first, first.first?.isNumber == true,
            let version = AppVersion(String(first)), !version.isPrerelease
        else { return nil }
        return (version, words.dropFirst().first.flatMap(date))
    }

    private static func date(_ text: Substring) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
            let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }
}
