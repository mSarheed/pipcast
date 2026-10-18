import AppKit
import SwiftUI

@main
@MainActor
struct QuicklinkCoordinatorTests {
    static var failures = 0
    static var passes = 0

    static func main() async throws {
        try await missingSelection()
        try await missingSelectionWithoutAccessibility()
        try await readableSelection()
        try await copiedSelection()
        try await argumentsBeforeSelection()
        try await defaultAppOverride()
        try await hotKeySelectedText()
        try await hotKeySelectedTextTargets()
        try await hotKeyCopiesOnce()
        try await plainLink()
        try copying()
        try editing()
        try await deleting()
        try revealing()
        try await websiteIcons()
        try await websiteIconRefresh()
        try await websiteIconsInFlight()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func missingSelection() async throws {
        for token in ["selection", "selectedText"] {
            let fixture = try Fixture(link: "https://de.wikipedia.org/w/index.php?search={\(token)}")
            defer { fixture.cleanUp() }
            fixture.coordinator.openQuicklinkFromHotKey(id: fixture.link.id)
            try await Task.sleep(for: .milliseconds(1))
            expect(QuicklinkLauncher.opened.isEmpty, "an empty \(token) never opens an empty search")
            expect(fixture.palette.shows == 0, "an empty \(token) asks for nothing")
            expect(
                fixture.core.messages == ["Couldn’t get the selected text"],
                "an empty \(token) reports the failure")
            expect(fixture.injector.copies == 1, "an unreadable \(token) is tried once with ⌘C")
        }
    }

    static func missingSelectionWithoutAccessibility() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        Permissions.isTrusted = false
        defer { Permissions.isTrusted = true }
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(
            fixture.core.messages == ["Allow Pipcast to use Accessibility in System Settings"],
            "without Accessibility the failure names the permission")
    }

    static func readableSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.injector.selection = "selected text"
        expect(fixture.accessory() == nil, "{selection} adds no field to the header")
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        await waitForOpen()
        expect(
            QuicklinkLauncher.opened.first?.link == "https://example.com/?q=selected%20text",
            "a readable selection opens immediately")
        expect(fixture.palette.shows == 0, "a readable selection needs no prompt")
        expect(QuicklinkLauncher.opened.first?.app == "com.example.browser", "the saved handler is used")
        expect(fixture.injector.copies == 0, "a readable selection never sends ⌘C")

        QuicklinkLauncher.opened = []
        fixture.window.isVisible = true
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        await waitForOpen()
        expect(fixture.injector.target == .previous, "palette activation reads the previous app")
    }

    static func copiedSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.injector.copied = "Swift & macOS"
        fixture.window.isVisible = true
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        await waitForOpen()
        expect(
            QuicklinkLauncher.opened.first?.link == "https://example.com/?q=Swift%20%26%20macOS",
            "a selection only ⌘C can read still opens the link")
        expect(!fixture.window.isVisible, "the palette steps aside so the ⌘C reaches the app")
    }

    static let selectionAndSite = "https://example.com/?q={selection}&site={argument name=\"Site\"}"

    static func argumentsBeforeSelection() async throws {
        let fixture = try Fixture(link: selectionAndSite)
        defer { fixture.cleanUp() }
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(
            fixture.accessory()?.firstIncompleteField == "Site" && fixture.core.messages.isEmpty,
            "a missing argument is asked for before the selection is judged")
        expect(fixture.injector.copies == 0, "no ⌘C is sent while arguments are still owed")

        fixture.coordinator.openQuicklink(id: fixture.link.id, values: ["Site": "swift.org"])
        try await Task.sleep(for: .milliseconds(1))
        expect(
            QuicklinkLauncher.opened.isEmpty
                && fixture.core.messages == ["Couldn’t get the selected text"],
            "filled arguments cannot bypass a missing selection")

        fixture.injector.selection = "Swift"
        fixture.coordinator.openQuicklink(id: fixture.link.id, values: ["Site": "swift.org"])
        await waitForOpen()
        expect(
            QuicklinkLauncher.opened.first?.link == "https://example.com/?q=Swift&site=swift.org",
            "selection and declared arguments resolve together")
    }

    static func defaultAppOverride() async throws {
        let fixture = try Fixture(link: selectionAndSite)
        defer { fixture.cleanUp() }
        fixture.injector.selection = "Swift"
        fixture.coordinator.openQuicklink(id: fixture.link.id, forcingDefaultApp: true)
        try await Task.sleep(for: .milliseconds(1))
        fixture.coordinator.openQuicklink(id: fixture.link.id, values: ["Site": "swift.org"])
        await waitForOpen()
        expect(
            QuicklinkLauncher.opened.first?.app == nil,
            "the default-app override survives the argument prompt")
    }

    static func hotKeySelectedText() async throws {
        let fixture = try Fixture(link: "https://example.com/?q={argument name=\"Query\"}")
        defer { fixture.cleanUp() }
        fixture.injector.selection = "  Swift & macOS\n"
        fixture.coordinator.openQuicklinkFromHotKey(id: fixture.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(QuicklinkLauncher.opened.isEmpty, "off by default, a shortcut still asks for the argument")

        fixture.settings.quicklinkPassesSelectedText = true
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(QuicklinkLauncher.opened.isEmpty, "only a shortcut passes the selected text")

        fixture.coordinator.openQuicklinkFromHotKey(id: fixture.link.id)
        await waitForOpen()
        expect(
            QuicklinkLauncher.opened.first?.link == "https://example.com/?q=Swift%20%26%20macOS",
            "a shortcut passes the trimmed selected text as the argument")

        QuicklinkLauncher.opened = []
        fixture.injector.selection = " \n"
        fixture.coordinator.openQuicklinkFromHotKey(id: fixture.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(QuicklinkLauncher.opened.isEmpty, "blank selected text leaves the argument to be asked for")
    }

    static func hotKeySelectedTextTargets() async throws {
        let twoFields = try Fixture(
            link: "https://example.com/?a={argument name=\"A\"}&b={argument name=\"B\"}")
        defer { twoFields.cleanUp() }
        twoFields.settings.quicklinkPassesSelectedText = true
        twoFields.injector.selection = "Swift"
        twoFields.coordinator.openQuicklinkFromHotKey(id: twoFields.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(
            twoFields.core.palette.commandArguments[PaletteState.argumentKey(twoFields.link.entryID, "A")]
                == "Swift" && twoFields.accessory()?.firstIncompleteField == "B",
            "only the first argument takes the selected text")

        let dropdownFirst = try Fixture(
            link: "https://example.com/?e={argument name=\"Engine\" options=\"web, news\"}&q={argument}")
        defer { dropdownFirst.cleanUp() }
        dropdownFirst.settings.quicklinkPassesSelectedText = true
        dropdownFirst.injector.selection = "Swift"
        dropdownFirst.coordinator.openQuicklinkFromHotKey(id: dropdownFirst.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(
            dropdownFirst.core.palette.commandArguments.isEmpty,
            "a first argument with options is never filled from the selection")
    }

    static func hotKeyCopiesOnce() async throws {
        let fixture = try Fixture(link: "https://example.com/?q={argument name=\"Query\"}")
        defer { fixture.cleanUp() }
        fixture.settings.quicklinkPassesSelectedText = true
        fixture.injector.copied = "Swift"
        fixture.coordinator.openQuicklinkFromHotKey(id: fixture.link.id)
        await waitForOpen()
        expect(
            QuicklinkLauncher.opened.first?.link == "https://example.com/?q=Swift",
            "a shortcut passes a selection only ⌘C can read")

        let both = try Fixture(
            link: "https://example.com/?q={argument name=\"Query\" default=\"swift\"}&t={selection}")
        defer { both.cleanUp() }
        both.settings.quicklinkPassesSelectedText = true
        both.coordinator.openQuicklinkFromHotKey(id: both.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(
            both.injector.copies == 1 && both.core.messages == ["Couldn’t get the selected text"],
            "one shortcut press sends at most one ⌘C")
    }

    static func plainLink() async throws {
        let fixture = try Fixture(link: "https://example.com/")
        defer { fixture.cleanUp() }
        fixture.settings.quicklinksEnabled = false
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        try await Task.sleep(for: .milliseconds(1))
        expect(
            QuicklinkLauncher.opened.isEmpty && fixture.palette.shows == 0, "disabled quicklinks remain inert"
        )
        fixture.settings.quicklinksEnabled = true
        fixture.coordinator.openQuicklink(id: fixture.link.id)
        await waitForOpen()
        expect(
            QuicklinkLauncher.opened.first?.link == fixture.link.link,
            "a plain link opens without selection input")
        expect(fixture.injector.copies == 0, "a link that reads no selection never sends ⌘C")
    }

    static func copying() throws {
        for succeeds in [true, false] {
            let fixture = try Fixture(link: "https://example.com/?q={argument}&selection={selection}")
            defer { fixture.cleanUp() }
            Paster.copies = []
            Paster.succeeds = succeeds
            fixture.window.isVisible = true
            fixture.coordinator.copyQuicklink(id: fixture.link.id)
            expect(Paster.copies == [fixture.link.link], "copying writes the saved template literally")
            expect(!fixture.window.isVisible, "copying dismisses the palette")
            expect(QuicklinkLauncher.opened.isEmpty, "copying never opens the destination")
            expect(
                fixture.core.messages == [succeeds ? "Link copied" : "Couldn’t copy link"],
                "copy feedback reflects whether the clipboard write succeeded")
        }
        Paster.succeeds = true
    }

    static func editing() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.window.isVisible = true
        fixture.coordinator.editQuicklink(fixture.link)
        expect(
            fixture.window.isVisible && fixture.core.palette.mode == .quicklinkEditor,
            "editing opens the launcher form")
        expect(
            fixture.coordinator.editor?.original == fixture.link,
            "the editor opens on the chosen quicklink")
        fixture.coordinator.editor?.name = "Updated name"
        fixture.coordinator.setQuicklinkEnabled(false, id: fixture.link.id)
        fixture.coordinator.saveQuicklink()
        expect(
            fixture.store.quicklink(id: fixture.link.id)?.name == "Updated name"
                && fixture.store.quicklink(id: fixture.link.id)?.isEnabled == false,
            "saving an edit preserves the current enabled state from Settings")
        expect(
            fixture.coordinator.editor == nil && !fixture.window.isVisible,
            "saving closes a directly summoned editor")

        fixture.settings.quicklinksEnabled = false
        fixture.coordinator.editQuicklink(nil)
        expect(fixture.coordinator.editor == nil, "a disabled feature cannot open an editor")
        fixture.settings.quicklinksEnabled = true
        fixture.coordinator.editQuicklink(nil)
        fixture.coordinator.editor?.name = "New link"
        fixture.coordinator.editor?.link = "https://example.com/new"
        fixture.settings.quicklinksEnabled = false
        fixture.coordinator.saveQuicklink()
        expect(fixture.store.quicklinks.count == 2, "disabling the feature prevents saving a draft")
        fixture.settings.quicklinksEnabled = true
        fixture.coordinator.saveQuicklink()
        expect(fixture.store.quicklinks.count == 3, "creation resumes after re-enabling the feature")

        fixture.coordinator.editQuicklink(fixture.link)
        try fixture.store.remove(id: fixture.link.id)
        fixture.coordinator.saveQuicklink()
        expect(
            fixture.coordinator.editor?.errorMessage != nil
                && fixture.coordinator.editor?.original == fixture.link
                && fixture.store.quicklink(id: fixture.link.id) == nil,
            "saving a removed item reports the failure without losing the draft or recreating it")
    }

    static func deleting() async throws {
        for confirmsInSettings in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            fixture.settings.quicklinkConfirmsBeforeDelete = confirmsInSettings
            await fixture.coordinator.deleteQuicklink(id: fixture.link.id, alwaysConfirm: true)
            expect(
                fixture.core.confirmations == 1 && fixture.store.quicklink(id: fixture.link.id) != nil,
                "Settings deletion always confirms and cancellation preserves the item")
            fixture.core.confirmations = 0
            await fixture.coordinator.deleteQuicklink(id: fixture.link.id)
            expect(
                fixture.core.confirmations == (confirmsInSettings ? 1 : 0)
                    && (fixture.store.quicklink(id: fixture.link.id) != nil) == confirmsInSettings,
                "launcher deletion still follows its confirmation setting")
        }
    }

    static func revealing() throws {
        let folder = try Fixture(link: "/Applications")
        defer { folder.cleanUp() }
        AppLauncher.revealed = []
        folder.window.isVisible = true
        expect(folder.coordinator.showQuicklinkInFinder(folder.link), "a folder link is revealed")
        expect(
            AppLauncher.revealed == [URL(fileURLWithPath: "/Applications")],
            "Finder is shown the folder itself")
        expect(!folder.window.isVisible, "revealing leaves the palette")

        for link in ["https://example.com/", "~/Notes/{date}.md"] {
            let fixture = try Fixture(link: link)
            defer { fixture.cleanUp() }
            fixture.window.isVisible = true
            expect(!fixture.coordinator.showQuicklinkInFinder(fixture.link), "\(link) has nothing to reveal")
            expect(fixture.window.isVisible, "\(link) leaves the palette open")
        }
        expect(AppLauncher.revealed.count == 1, "only the folder link reached Finder")
    }

    static func waitForOpen() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while QuicklinkLauncher.opened.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        expect(QuicklinkLauncher.opened.count == 1, "one destination opens")
    }

    static func websiteIcons() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        fixture.store.onChange = { _ in coordinator.applyQuicklinksPresence() }
        coordinator.applyWebsiteIcons()
        coordinator.addImportedQuicklinks([
            Quicklink(name: "GitHub", link: "github.com/search?q={argument}")
        ])
        try await drain()
        expect(fixture.google.requests.isEmpty, "off, quicklinks make no network request")
        expect(coordinator.websiteIcon(for: fixture.link) == nil, "off, every icon stays automatic")

        fixture.settings.quicklinkFetchesWebsiteIcons = true
        coordinator.applyWebsiteIcons()
        try await settle { fixture.websiteIcons.files.count == 2 }
        expect(
            fixture.google.requests.sorted() == ["example.com", "github.com"],
            "turning it on fetches once per distinct web host")
        expect(coordinator.websiteIcon(for: fixture.link) != nil, "a stored icon replaces the automatic one")
        coordinator.applyWebsiteIcons()
        try await drain()
        expect(fixture.google.requests.count == 2, "re-applying an unchanged setting fetches nothing")

        var chosen = fixture.link
        chosen.iconSymbol = "star"
        expect(coordinator.websiteIcon(for: chosen) == nil, "a chosen symbol wins over the website icon")

        fixture.google.unknown = ["unknown.example"]
        coordinator.addImportedQuicklinks([
            Quicklink(name: "Unknown", link: "https://unknown.example/"),
            Quicklink(name: "Templated host", link: "https://{argument}.example.org/x"),
            Quicklink(name: "Deeplink", link: "spotify://track/1"),
            Quicklink(name: "Folder", link: "~/Documents")
        ])
        try await settle { fixture.google.requests.count == 3 }
        try await drain()
        expect(fixture.google.requests.count == 3, "only the new web host is fetched")
        expect(
            fixture.websiteIcons.files["unknown.example"] == nil,
            "a site Google doesn't know stores nothing")

        coordinator.editQuicklink(nil)
        coordinator.editor?.name = "Swift"
        coordinator.editor?.link = "https://swift.org"
        coordinator.saveQuicklink()
        try await settle { fixture.websiteIcons.files["swift.org"] != nil }
        expect(fixture.google.requests.last == "swift.org", "saving a new web host fetches it")

        guard let github = fixture.store.quicklinks.first(where: { $0.name == "GitHub" }) else {
            return expect(false, "the imported quicklink is stored")
        }
        await coordinator.deleteQuicklink(id: github.id)
        expect(
            fixture.websiteIcons.files["github.com"] == nil,
            "deleting the last quicklink for a host removes its icon")

        fixture.settings.quicklinkFetchesWebsiteIcons = false
        coordinator.applyWebsiteIcons()
        expect(
            fixture.websiteIcons.files.isEmpty
                && !FileManager.default.fileExists(atPath: fixture.iconFolder.path),
            "turning it off removes every stored icon")
        expect(coordinator.websiteIcon(for: fixture.link) == nil, "off brings the automatic icon back")
    }

    static func websiteIconRefresh() async throws {
        let fixture = try Fixture(link: "https://unknown.example/")
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        fixture.settings.quicklinkFetchesWebsiteIcons = true
        coordinator.applyWebsiteIcons()
        expect(fixture.google.requests.isEmpty, "launch with the setting on fetches nothing")
        guard let known = fixture.store.quicklinks.first(where: { $0.id != fixture.link.id }) else {
            return expect(false, "the fixture holds a second quicklink")
        }
        coordinator.refreshWebsiteIcon(id: known.id)
        try await settle { fixture.websiteIcons.files["example.com"] != nil }
        let first = fixture.websiteIcons.files["example.com"]
        coordinator.refreshWebsiteIcon(id: known.id)
        try await settle { fixture.websiteIcons.files["example.com"] != first }
        let second = fixture.websiteIcons.files["example.com"]
        expect(
            fixture.google.requests == ["example.com", "example.com"],
            "refresh fetches a host again even when it is stored")
        expect(
            first != nil && second != nil && first != second
                && !FileManager.default.fileExists(atPath: first?.path ?? ""),
            "refresh replaces the stored icon under a new name")
        expect(fixture.core.messages.isEmpty, "a successful refresh shows nothing")

        fixture.google.unknown = ["unknown.example"]
        expect(coordinator.canRefreshWebsiteIcon(fixture.link), "a web quicklink offers a refresh")
        coordinator.refreshWebsiteIcon(id: fixture.link.id)
        try await settle { !fixture.core.messages.isEmpty }
        expect(fixture.core.messages == ["Couldn’t fetch website icon"], "a failed refresh is reported")
        fixture.settings.quicklinkFetchesWebsiteIcons = false
        expect(!coordinator.canRefreshWebsiteIcon(fixture.link), "off, no refresh is offered")
    }

    static func websiteIconsInFlight() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let coordinator = fixture.coordinator
        let google = fixture.google
        fixture.store.onChange = { _ in coordinator.applyQuicklinksPresence() }
        fixture.settings.quicklinkFetchesWebsiteIcons = true
        coordinator.applyWebsiteIcons()

        google.holding = true
        coordinator.refreshWebsiteIcon(id: fixture.link.id)
        try await settle { google.requests.count == 1 }
        fixture.settings.quicklinkFetchesWebsiteIcons = false
        coordinator.applyWebsiteIcons()
        google.release()
        try await drain()
        expect(
            fixture.websiteIcons.files.isEmpty
                && !FileManager.default.fileExists(atPath: fixture.iconFolder.path),
            "a fetch that outlives turning it off writes nothing")
        expect(fixture.core.messages.isEmpty, "switching off mid-refresh is not reported as a failure")

        google.holding = true
        fixture.settings.quicklinkFetchesWebsiteIcons = true
        coordinator.applyWebsiteIcons()
        try await settle { google.requests.count == 2 }
        fixture.settings.quicklinkFetchesWebsiteIcons = false
        coordinator.applyWebsiteIcons()
        fixture.settings.quicklinkFetchesWebsiteIcons = true
        coordinator.applyWebsiteIcons()
        try await settle { google.requests.count == 3 }
        google.release()
        try await settle { fixture.websiteIcons.files["example.com"] != nil }
        let folder = fixture.iconFolder.path
        let stored = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        expect(stored.count == 1, "off then on keeps only the second fetch's icon")

        coordinator.addImportedQuicklinks([Quicklink(name: "Queued", link: "https://queued.example/")])
        fixture.settings.quicklinkFetchesWebsiteIcons = false
        coordinator.applyWebsiteIcons()
        try await drain()
        expect(
            !google.requests.contains("queued.example"),
            "a fetch queued just before turning it off never contacts Google")
        fixture.settings.quicklinkFetchesWebsiteIcons = true
        coordinator.applyWebsiteIcons()
        try await settle { google.requests.count == 5 }

        google.holding = true
        coordinator.refreshWebsiteIcon(id: fixture.link.id)
        try await settle { google.requests.count == 6 }
        for quicklink in fixture.store.quicklinks {
            await coordinator.deleteQuicklink(id: quicklink.id)
        }
        google.release()
        try await drain()
        expect(
            fixture.websiteIcons.files["example.com"] == nil,
            "a fetch for a host no quicklink uses any more writes nothing")
    }

    /// Polls rather than sleeping a fixed time, so a loaded runner can't outrun the fetch.
    static func settle(until done: @MainActor () -> Bool) async throws {
        for _ in 0..<400 where !done() { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// Asserting that nothing happens can only wait; the fake answers within a few main-actor turns.
    static func drain() async throws { try await Task.sleep(for: .milliseconds(20)) }

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    @MainActor
    final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: QuicklinkStore
        let link: Quicklink
        let settings = AppSettings()
        let injector = TextInjector()
        let window = PaletteWindowController()
        let core = AppCore()
        let palette: PaletteCoordinator
        let coordinator: QuicklinkCoordinator
        let google = FakeFaviconService()
        let websiteIcons: QuicklinkFaviconStore
        var iconFolder: URL { directory.appendingPathComponent("Icons") }

        init(link: String = "https://example.com/?q={selection}") throws {
            QuicklinkLauncher.opened = []
            store = QuicklinkStore(directory: directory)
            try store.add(Quicklink(name: "A different quicklink", link: "https://example.com/"))
            self.link = try store.add(
                Quicklink(name: "Wikipedia", link: link, openWithBundleID: "com.example.browser"))
            palette = PaletteCoordinator(window: window, state: core.palette)
            let google = google
            websiteIcons = QuicklinkFaviconStore(
                folder: directory.appendingPathComponent("Icons"),
                download: { await google.answer($0) })
            coordinator = QuicklinkCoordinator(
                store: store, websiteIcons: websiteIcons, settings: settings, appIndex: AppIndex(),
                injector: injector,
                hotKeys: HotKeyManager(), favorites: FavoritesStore(), visibility: VisibilityStore(),
                ranking: LauncherRankingStore(), aliases: AliasStore(), windowController: window,
                paletteCoordinator: palette,
                clipboardHistory: { ["clipboard text"] }, core: core)
            core.quicklinkCoordinator = coordinator
        }

        func accessory() -> PaletteHeaderAccessory? {
            QuicklinkArgumentsAccessory.make(
                quicklink: link, core: core, vm: core.palette,
                focus: FocusState<String?>().projectedValue, placement: .besideSearchField,
                onOpenOptions: { _ in }, onSubmit: {})
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}

/// Answers like Google: image bytes for a known host, nothing for one it has no icon for.
@MainActor
final class FakeFaviconService {
    var requests: [String] = []
    var unknown: Set<String> = []
    /// Parks every answer until `release`, so a test can change things while a fetch is out.
    var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func answer(_ url: URL) async -> Data? {
        let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "domain" }?.value ?? ""
        requests.append(host)
        if holding { await withCheckedContinuation { held.append($0) } }
        return unknown.contains(host) ? nil : Data(host.utf8)
    }

    func release() {
        let parked = held
        held = []
        holding = false
        for continuation in parked { continuation.resume() }
    }
}

// Platform collaborators are inert so the shipped coordinator never opens apps or reads selections.
@MainActor
final class AppSettings {
    var quicklinksEnabled = true
    var quicklinksShowInLauncher = true
    var quicklinkPassesSelectedText = false
    var quicklinkOpensNewWindow = false
    var quicklinkConfirmsBeforeDelete = false
    var quicklinkFetchesWebsiteIcons = false
    var interfaceSize = InterfaceSize()
}

struct InterfaceSize { var metrics: Int { 0 } }
enum CommandID { case createQuicklink, searchQuicklinks, importQuicklinks, exportQuicklinks }

@MainActor
final class AppIndex {
    func setQuicklinks(_ links: [Quicklink], websiteIcon: (Quicklink) -> URL?) {}
    func setCommandsVisible(_ commands: Set<CommandID>, _ visible: Bool) {}
    func setCommandsListed(_ commands: Set<CommandID>, _ listed: Bool) {}
}

enum InjectionTarget: Equatable {
    case frontmost, previous
    static func current() -> Self? { .frontmost }
    var externalApp: NSRunningApplication? { .current }
}

@MainActor
final class TextInjector {
    var selection = ""
    var copied: String?
    var copies = 0
    var target: InjectionTarget?
    func copySelection(from app: NSRunningApplication?) async -> String? {
        copies += 1
        return copied
    }
    func captureExpansionContext(
        target: InjectionTarget?, clipboardHistory: [String]
    ) -> SnippetTemplateEngine.ExpansionContext {
        self.target = target
        return .init(
            clipboardHistory: clipboardHistory, selection: selection, now: .distantPast,
            calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US_POSIX"),
            timeZone: TimeZone(secondsFromGMT: 0)!)
    }
}

enum HotKeyAction: Equatable { case quicklink(id: UUID) }
@MainActor
final class HotKeyManager {
    var recordingAction: HotKeyAction?
    func setBinding(_ binding: String?, for action: HotKeyAction) {}
}
final class FavoritesStore { func remove(keys: Set<String>) {} }
final class VisibilityStore { func removeItemKeys(_ keys: Set<String>) {} }
final class LauncherRankingStore { func reset(itemKey: String) {} }
final class AliasStore { func removeKeys(_ keys: Set<String>) {} }

@MainActor
final class PaletteWindowController {
    var isVisible = false
    var previousTarget: InjectionTarget? = .previous
}

enum PaletteMode { case launcher, quicklinks, quicklinkEditor }
@MainActor
final class PaletteState {
    var mode = PaletteMode.launcher
    var selection = 0
    var commandArguments: [String: String] = [:]
    var pendingArgumentEntryID: String?
    func prepare(mode: PaletteMode) { self.mode = mode }
    func pop(preservingSelection: Bool) -> Bool { false }
    static func argumentKey(_ entryID: String, _ name: String) -> String { entryID + "\u{1}" + name }
}

@MainActor
final class PaletteCoordinator {
    let window: PaletteWindowController
    let state: PaletteState
    var shows = 0
    init(window: PaletteWindowController, state: PaletteState) { self.window = window; self.state = state }
    func showPalette(mode: PaletteMode) {
        state.prepare(mode: mode)
        shows += 1
        window.isVisible = true
        state.selection = 0
        state.commandArguments = [:]
        state.pendingArgumentEntryID = nil
    }
    var isVisible: Bool { window.isVisible }
    func hidePalette(restoreFocus: Bool = true) { window.isVisible = false }
}

@MainActor
enum Paster {
    static var copies: [String] = []
    static var succeeds = true
    static func copyPlainText(_ text: String) -> Bool {
        copies.append(text)
        return succeeds
    }
}

@MainActor
enum AppLauncher {
    static var revealed: [URL] = []
    static func showInFinder(_ url: URL) { revealed.append(url) }
}

enum DialogTone { case danger, neutral, success }
@MainActor
final class AppCore {
    let palette = PaletteState()
    let settings = AppSettings()
    lazy var quicklinkCoordinator: QuicklinkCoordinator = {
        fatalError("The fixture must wire the coordinator")
    }()
    var messages: [String] = []
    var confirmations = 0
    func showNotice(title: String, message: String, symbol: String, tone: DialogTone) async {}
    func reportFailure(title: String, message: String, symbol: String, recovery: String) async -> Bool {
        false
    }
    func confirm(title: String, message: String, symbol: String, confirmTitle: String) async -> Bool {
        confirmations += 1
        return false
    }
    func showMessage(_ message: String, tone: DialogTone = .success) { messages.append(message) }
}

@MainActor
enum Permissions {
    static var isTrusted = true
    static func isAccessibilityTrusted() -> Bool { isTrusted }
}

enum BackupActions {
    static func chooseSaveLocation(named: String) -> URL? { nil }
    static func chooseJSONFile() -> URL? { nil }
}

@MainActor
enum QuicklinkLauncher {
    struct Opened { let link: String; let app: String? }
    static var opened: [Opened] = []
    enum Failure: LocalizedError {
        case refused
        var missingApplicationBundleID: String? { nil }
    }
    static func open(_ link: String, openWithBundleID: String?, inNewWindow: Bool) async throws(Failure) {
        opened.append(Opened(link: link, app: openWithBundleID))
    }
}

struct InlineArgument { let id: String; let title: String; let options: [String]; let isOptional: Bool }
@MainActor
enum QuicklinkGlyph {
    static func rowIcon(symbol: String, websiteIcon: URL?) -> NSImage { NSImage() }
}

struct InlineArgumentFields: View {
    let arguments: [InlineArgument]
    let icon: NSImage?
    let value: (String) -> Binding<String>
    let focused: FocusState<String?>.Binding
    let openOptions: (String) -> Void
    let onSubmit: () -> Void
    var body: some View { EmptyView() }
    static func totalWidth(for arguments: [InlineArgument], hasIcon: Bool, metrics: Int) -> CGFloat { 0 }
}

struct PaletteHeaderAccessory {
    enum Placement { case afterQuery, besideSearchField }
    let width: CGFloat
    let fieldNames: [String]
    let firstIncompleteField: String?
    let optionsMenu: (String) -> PopoverMenuContent?
    let placement: Placement
    let view: AnyView
}

struct PopoverMenuContent { let header: String; let items: [PopoverMenuItem] }
struct PopoverMenuItem {
    enum Icon { case symbol(String), blank }
    let title: String
    let icon: Icon
    let action: () -> Void
}
