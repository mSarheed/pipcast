import Foundation

/// ↑ in root search walks back through what ran, and never through what should not be kept.
@main
@MainActor
struct QueryHistoryTests {
    static var failures = 0
    static var passes = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        if actual == expected {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message) — got \(actual), want \(expected)")
        }
    }

    static func history(_ queries: [String], capacity: Int = LauncherQueryHistory.defaultCapacity)
        -> LauncherQueryHistory
    {
        var history = LauncherQueryHistory(capacity: capacity)
        for query in queries { history.record(query) }
        return history
    }

    static func main() {
        ordering()
        dedupe()
        bounds()
        exclusions()
        navigation()
        clearing()
        print("query-history-test: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func ordering() {
        let recorded = history(["safari", "12 * 4", "notes"])
        expect(recorded.entries, ["notes", "12 * 4", "safari"], "the newest search comes first")
        expect(history(["  mail \n"]).entries, ["mail"], "surrounding whitespace is not part of it")
    }

    static func dedupe() {
        let recorded = history(["safari", "notes", "safari"])
        expect(recorded.entries, ["safari", "notes"], "running a search again moves it to the front")
        expect(
            history(["Safari", "safari"]).entries, ["safari", "Safari"],
            "only an exact repeat collapses, as a shell's history does")
        expect(history(["notes", " notes "]).entries, ["notes"], "a padded repeat is still a repeat")
    }

    static func bounds() {
        let recorded = history((1...60).map { "query \($0)" })
        expect(recorded.entries.count, LauncherQueryHistory.defaultCapacity, "capped at the default")
        expect(recorded.entries.first, "query 60", "the cap keeps the newest")
        expect(recorded.entries.last, "query 11", "the cap drops the oldest")
        expect(history(["a", "b", "c"], capacity: 2).entries, ["c", "b"], "a custom cap holds")
        expect(history(["a"], capacity: 0).entries, [], "a zero cap keeps nothing")
        expect(history(["a"], capacity: -3).entries, [], "a negative cap reads as zero")
    }

    static func exclusions() {
        expect(history(["", "   ", "\n"]).entries, [], "nothing typed is never a search")
        let longest = String(repeating: "x", count: LauncherQueryHistory.maximumLength)
        expect(history([longest]).entries, [longest], "the length limit itself is kept")
        expect(history([longest + "x"]).entries, [], "a paste past the limit is content")
        expect(history(["first\nsecond"]).entries, [], "an inner line break is pasted content")

        let token = "sk9Fq2LmZx7RtY4pWv8NbC3dJh6KsA1e"
        expect(token.count, LauncherQueryHistory.credentialLength, "the fixture sits on the limit")
        expect(history([token]).entries, [], "a long mixed-case, digit-bearing token is a secret")
        expect(
            history([String(token.dropLast())]).entries, [String(token.dropLast())],
            "one character short of the limit is not judged")
        let lower = token.lowercased()
        expect(history([lower]).entries, [lower], "a single case is a hash or word, not a key")
        let spaced = "Sk9Fq2LmZx7RtY4p Wv8NbC3dJh6KsA1e"
        expect(history([spaced]).entries, [spaced], "a space makes it a phrase, not a token")
        let url = "https://example.com/Docs/Release2026/Notes"
        expect(history([url]).entries, [url], "an address is worth recalling")
        let sum = "1234567890 + 9876543210 * 1234567890"
        expect(history([sum]).entries, [sum], "a long calculation is kept")
    }

    static func navigation() {
        var recorded = history(["safari", "12 * 4", "notes"])
        expect(recorded.recallOlder(from: ""), "notes", "↑ on an empty field recalls the newest")
        expect(recorded.recallOlder(from: "notes"), "12 * 4", "↑ again steps older")
        expect(recorded.recallOlder(from: "12 * 4"), "safari", "and older again")
        expect(recorded.recallOlder(from: "safari"), nil, "the oldest has nothing behind it")
        expect(recorded.recalledIndex, 2, "and the walk stays on the oldest")
        expect(recorded.recallOlder(from: "safari"), nil, "pressing again stays put")

        var edited = history(["safari", "notes"])
        _ = edited.recallOlder(from: "")
        expect(edited.recallOlder(from: "notes app"), nil, "an edited recall is a new search")
        expect(edited.recalledIndex, nil, "editing ends the walk")
        expect(edited.recallOlder(from: ""), "notes", "clearing the field starts over at the newest")

        var typed = history(["safari"])
        expect(typed.recallOlder(from: "saf"), nil, "↑ never replaces something typed")
        expect(typed.recallOlder(from: "   "), "safari", "blank space counts as empty")

        var empty = LauncherQueryHistory()
        expect(empty.recallOlder(from: ""), nil, "nothing recorded recalls nothing")

        var rerun = history(["safari", "12 * 4", "notes"])
        _ = rerun.recallOlder(from: "")
        _ = rerun.recallOlder(from: "notes")
        rerun.record("12 * 4")
        expect(rerun.recalledIndex, nil, "running a search ends the walk")
        expect(rerun.entries, ["12 * 4", "notes", "safari"], "and the recalled search moves up")
        expect(rerun.recallOlder(from: ""), "12 * 4", "the next walk starts from the newest")

        var refused = history(["safari"])
        _ = refused.recallOlder(from: "")
        refused.record("")
        expect(refused.recalledIndex, nil, "an unrecorded run still ends the walk")

        var stale = history(["safari", "notes"])
        _ = stale.recallOlder(from: "")
        _ = stale.recallOlder(from: "notes")
        stale.record("mail")
        stale.record("maps")
        expect(stale.recallOlder(from: "safari"), nil, "a walk is never resumed past a new record")
    }

    static func clearing() {
        var recorded = history(["safari", "notes"])
        _ = recorded.recallOlder(from: "")
        recorded.clear()
        expect(recorded.entries, [], "clearing forgets every search")
        expect(recorded.recalledIndex, nil, "and the walk")
        expect(recorded.recallOlder(from: "notes"), nil, "a field left holding one recalls nothing")
    }
}
