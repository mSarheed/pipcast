import Foundation

/// Stands in for Shortcuts Events and the Caches folder, recording every effect the store asks for.
@MainActor
final class FakeIcons {
    var onDisk: [UUID: AppleShortcutIconFile] = [:]
    var access: AppleShortcutIconProvider.Access = .granted
    var icons: [UUID: AppleShortcutIconFile] = [:]
    var failing: Set<UUID> = []
    var scans = 0
    var accessAsks: [Bool] = []
    var fetches: [[UUID]] = []
    var removed: [AppleShortcutIconFile] = []
    /// What the store published by the time each removal ran.
    var publishedAtRemoval: [[UUID: AppleShortcutIconFile]?] = []
    var holdFetch = false
    private var held: CheckedContinuation<Void, Never>?
    weak var store: AppleShortcutIconStore?

    func release() {
        holdFetch = false
        held?.resume()
        held = nil
    }

    var isHolding: Bool { held != nil }

    func fetch(_ ids: [UUID], _ cached: [UUID: AppleShortcutIconFile]) async -> AppleShortcutIconCache.Fetch {
        fetches.append(ids)
        if holdFetch { await withCheckedContinuation { held = $0 } }
        var fetch = AppleShortcutIconCache.Fetch()
        for id in ids {
            if failing.contains(id) {
                fetch.failed.insert(id)
            } else if let icon = icons[id], icon != cached[id] {
                fetch.files[id] = icon
            }
        }
        return fetch
    }

    var effects: AppleShortcutIconStore.Effects {
        AppleShortcutIconStore.Effects(
            scan: { _ in await MainActor.run { self.scans += 1; return self.onDisk } },
            access: { prompting in
                await MainActor.run {
                    self.accessAsks.append(prompting)
                    return self.access
                }
            },
            fetch: { await self.fetch($0, $1) },
            remove: { files in
                await MainActor.run {
                    self.removed += files
                    self.publishedAtRemoval.append(self.store?.files)
                }
            })
    }
}

@main
struct AppleShortcutIconTest {
    @MainActor static var failures = 0

    @MainActor static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    static let a = UUID(uuidString: "97A1DDFA-76F3-4872-A672-25D5F35B7882")!
    static let b = UUID(uuidString: "B63D79CE-D540-4E8C-B5E4-B3BF5FDD1897")!
    static let library = [AppleShortcut(id: a, name: "A"), AppleShortcut(id: b, name: "B")]

    static func file(_ id: UUID, _ digest: String) -> AppleShortcutIconFile {
        AppleShortcutIconFile(id: id, digest: String(repeating: digest, count: 16))
    }

    @MainActor static func make(_ fake: FakeIcons) -> AppleShortcutIconStore {
        let folder = FileManager.default.temporaryDirectory.appending(path: "asi-test-\(UUID())")
        let store = AppleShortcutIconStore(
            cache: AppleShortcutIconCache(folder: folder), effects: fake.effects)
        fake.store = store
        return store
    }

    @MainActor static func settle(_ store: AppleShortcutIconStore) async {
        for _ in 0..<1000 where store.isReading { try? await Task.sleep(for: .milliseconds(1)) }
    }

    @MainActor static func waitForHold(_ fake: FakeIcons) async {
        for _ in 0..<1000 where !fake.isHolding { try? await Task.sleep(for: .milliseconds(1)) }
    }

    static func main() async {
        await launchWithoutPermission()
        await promptQueuedMidRead()
        await failedIconsWaitForSweep()
        await unavailableIsNotRefusal()
        await cancelPublishesNothing()
        await supersededRemovedAfterPublish()
        await cachedLibraryCostsNothing()
        let failed = await MainActor.run { failures }
        print(failed == 0 ? "\nALL PASSED" : "\n\(failed) failed")
        if failed > 0 { exit(1) }
    }

    @MainActor static func launchWithoutPermission() async {
        let fake = FakeIcons()
        fake.access = .refused
        fake.icons = [a: file(a, "1"), b: file(b, "2")]
        let store = make(fake)
        store.read(library, .init(sweep: true))
        await settle(store)
        check("the launch read asks without prompting", fake.accessAsks == [false])
        check("a refusal reads nothing", fake.fetches.isEmpty && store.files == [:])
        store.read(library, .init())
        await settle(store)
        check("a launcher read after a refusal doesn't ask again", fake.accessAsks == [false])
        fake.access = .granted
        store.queue(.prompt)
        store.read(library, .init())
        await settle(store)
        check("the pane's read prompts", fake.accessAsks == [false, true])
        check("an allowed prompt reads every icon", store.files == fake.icons)
    }

    @MainActor static func promptQueuedMidRead() async {
        let fake = FakeIcons()
        fake.access = .refused
        let store = make(fake)
        // The switch's own read is in flight when the pane asks to prompt.
        store.read(library, .init(sweep: true))
        store.queue(.prompt)
        store.read(library, .init())
        await settle(store)
        check("a prompt asked for mid-read still prompts", fake.accessAsks == [false, true])
    }

    @MainActor static func failedIconsWaitForSweep() async {
        let fake = FakeIcons()
        fake.icons = [a: file(a, "1")]
        fake.failing = [b]
        let store = make(fake)
        store.read(library, .init(sweep: true))
        await settle(store)
        check("a readable icon is published beside a failed one", store.files == [a: file(a, "1")])
        store.read(library, .init())
        await settle(store)
        check("a launcher read doesn't retry a failed icon", fake.fetches == [[a, b]])
        fake.failing = []
        fake.icons[b] = file(b, "2")
        store.read(library, .init(sweep: true))
        await settle(store)
        check("a sweep retries it", fake.fetches.last == [a, b] && store.files?[b] == file(b, "2"))
    }

    @MainActor static func unavailableIsNotRefusal() async {
        let fake = FakeIcons()
        fake.access = .unavailable
        let store = make(fake)
        store.read(library, .init(sweep: true))
        await settle(store)
        store.read(library, .init())
        await settle(store)
        check("Shortcuts Events not answering is asked again, unprompted", fake.accessAsks == [false, false])
    }

    @MainActor static func cancelPublishesNothing() async {
        let fake = FakeIcons()
        fake.icons = [a: file(a, "1"), b: file(b, "2")]
        fake.holdFetch = true
        let store = make(fake)
        var changes = 0
        store.onChange = { changes += 1 }
        store.read(library, .init(sweep: true))
        await waitForHold(fake)
        let before = (changes, store.files)
        store.cancel()
        fake.release()
        await settle(store)
        check("switching off mid-read publishes nothing", changes == before.0 && store.files == before.1)
        store.read(library, .init(sweep: true))
        await settle(store)
        check("switching back on reads again", store.files == fake.icons)
    }

    @MainActor static func supersededRemovedAfterPublish() async {
        let fake = FakeIcons()
        fake.onDisk = [a: file(a, "1"), b: file(b, "2")]
        fake.icons = [a: file(a, "3"), b: file(b, "2")]
        let store = make(fake)
        var published: [[UUID: AppleShortcutIconFile]?] = []
        store.onChange = { published.append(store.files) }
        store.read(library, .init(sweep: true))
        await settle(store)
        check("cached icons are published before any Apple event", published.first == fake.onDisk)
        check("only the changed icon's old file is removed", fake.removed == [file(a, "1")])
        check(
            "it is removed only once rows point at its successor",
            fake.publishedAtRemoval.first??[a] == file(a, "3"))
    }

    @MainActor static func cachedLibraryCostsNothing() async {
        let fake = FakeIcons()
        fake.onDisk = [a: file(a, "1"), b: file(b, "2")]
        let store = make(fake)
        store.read(library, .init())
        await settle(store)
        store.read(library, .init())
        await settle(store)
        check("the folder is scanned once", fake.scans == 1)
        check("a fully cached library sends no Apple event", fake.accessAsks.isEmpty && fake.fetches.isEmpty)
    }
}
