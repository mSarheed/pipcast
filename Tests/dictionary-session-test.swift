import Foundation

@MainActor
private final class LookupProbe {
    var calls: [String] = []
    var pending: CheckedContinuation<DictionaryEntry?, Never>?

    func entry(_ term: String) async -> DictionaryEntry? {
        calls.append(term)
        if term == "slow" {
            return await withCheckedContinuation { pending = $0 }
        }
        return term == "mango" ? DictionaryEntry(term: term, plainText: "a fruit") : nil
    }
}

@main
@MainActor
struct DictionarySessionTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; print("FAIL: \(message)") }
    }

    static func wait(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        expect(condition(), "asynchronous operation finishes")
    }

    static func main() async {
        expect(!DictionarySuggestions.accepts("a"), "single letters do not request predictions")
        expect(!DictionarySuggestions.accepts(String(repeating: "a", count: 129)), "bounded request")
        expect(!DictionarySuggestions.accepts("two words"), "phrases still get definitions, not predictions")
        expect(!DictionarySuggestions.accepts("123"), "numbers do not request predictions")
        expect(DictionarySuggestions.accepts("café"), "Unicode words are supported")
        expect(DictionarySuggestions.accepts("can't"), "apostrophes are supported")
        expect(
            DictionarySuggestions.words(
                from: [" Reconize ", " Recognize \n", "recognize", "", "recognise", "two words"],
                for: "reconize") == ["Recognize", "recognise"],
            "remove echoed query, duplicates, whitespace and phrases while preserving server order")
        expect(DictionarySuggestions.words(from: (0..<20).map { "word\($0)" }, for: "query").count == 8,
               "candidate list is bounded")

        let probe = LookupProbe()
        var suggestionQueries: [String] = []
        let session = DictionarySession(
            findEntry: { await probe.entry($0) },
            findSuggestions: { term in
                suggestionQueries.append(term)
                return ["recognize", "recognise"]
            })
        session.lookUp("r")
        session.lookUp("reco")
        session.lookUp(" reconize \n")
        await wait { session.lookup?.term == "reconize" }
        expect(probe.calls == ["reconize"], "typing is debounced and trimmed")
        expect(session.lookup?.suggestions == ["recognize", "recognise"], "missing definition publishes candidates")
        session.lookUp("mango")
        expect(session.lookup?.term == "reconize", "visible result survives the next debounce")
        await wait { session.lookup?.term == "mango" }
        expect(session.lookup?.entry?.term == "mango", "exact definition wins")
        expect(session.lookup?.suggestions == [], "exact definitions have no predictions")
        expect(suggestionQueries == ["reconize"], "exact lookup does not initialize spelling")
        session.lookUp("mango")
        try? await Task.sleep(for: .milliseconds(120))
        expect(probe.calls == ["reconize", "mango"], "identical query does no work")

        session.lookUp("slow")
        await wait { probe.pending != nil }
        session.lookUp("mango")
        await wait { probe.calls.count == 4 }
        probe.pending?.resume(returning: DictionaryEntry(term: "slow", plainText: "obsolete"))
        probe.pending = nil
        try? await Task.sleep(for: .milliseconds(20))
        expect(session.lookup?.term == "mango", "late definition cannot replace current result")
        expect(!suggestionQueries.contains("slow"), "cancelled lookup cannot request suggestions")

        session.lookUp("slow")
        await wait { probe.pending != nil }
        session.reset()
        probe.pending?.resume(returning: DictionaryEntry(term: "slow", plainText: "obsolete"))
        probe.pending = nil
        try? await Task.sleep(for: .milliseconds(20))
        expect(session.lookup == nil, "reset prevents late publication")
        session.lookUp("mango")
        await wait { session.lookup?.term == "mango" }
        session.lookUp(" \n")
        expect(session.lookup == nil, "empty query clears synchronously")

        var started = false
        var cancelled = false
        let cancelling = DictionarySession(findEntry: { _ in nil }, findSuggestions: { _ in
            started = true
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled = Task.isCancelled
            }
            return ["obsolete"]
        })
        cancelling.lookUp("reconize")
        await wait { started }
        cancelling.reset()
        await wait { cancelled }
        expect(cancelling.lookup == nil, "cancellation reaches suggestion work without publishing")

        var delayed: CheckedContinuation<[String], Never>?
        var suggestionCall = 0
        let delayedSession = DictionarySession(findEntry: { _ in nil }, findSuggestions: { _ in
            suggestionCall += 1
            if suggestionCall == 1 {
                return await withCheckedContinuation { delayed = $0 }
            }
            return ["current"]
        })
        delayedSession.lookUp("same")
        await wait { delayed != nil }
        delayedSession.reset()
        delayedSession.lookUp("same")
        await wait { delayedSession.lookup?.suggestions == ["current"] }
        delayed?.resume(returning: ["obsolete"])
        delayed = nil
        try? await Task.sleep(for: .milliseconds(20))
        expect(delayedSession.lookup?.suggestions == ["current"],
               "operation identity survives resetting and reopening the identical query")

        let empty = DictionarySession(findEntry: { _ in nil }, findSuggestions: { _ in [] })
        empty.lookUp("zzzxqv")
        await wait { empty.lookup?.term == "zzzxqv" }
        expect(empty.lookup?.entry == nil && empty.lookup?.suggestions == [],
               "missing dictionaries and candidates leave a completed empty result")

        if ProcessInfo.processInfo.environment["PIPCAST_TEST_DICTIONARY_SYSTEM"] == "1" {
            let words = await DictionarySuggestionService.words(for: "reconize")
            expect(words.contains { $0.lowercased() == "recognize" || $0.lowercased() == "recognise" },
                   "system spelling corrects the upstream reproduction")
            let completions = await DictionarySuggestionService.words(for: "recogni")
            expect(completions.contains { $0.lowercased().hasPrefix("recogni") && $0.count > 7 },
                   "system spelling completes partial words")
            let task = Task { await DictionarySuggestionService.words(for: "reconize") }
            task.cancel()
            expect(await task.value == [], "cancelled system request returns no candidates")
        }
        print("Dictionary session tests: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
