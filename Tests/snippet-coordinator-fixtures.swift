import AppKit

@MainActor
final class AppCore {
    var isShowingDialog = false
    var confirmationCount = 0
    func confirm(
        title: String, message: String, symbol: String, confirmTitle: String,
        tone: DialogTone = .neutral, confirmRole: DialogRole = .standard
    ) async -> Bool {
        confirmationCount += 1
        return false
    }
    func showNotice(title: String, message: String, symbol: String, tone: DialogTone) async {}
    func fillSnippetArguments(
        snippetName: String, arguments: [SnippetTemplateEngine.MissingArgument]
    ) async -> [String: String]? { nil }
}

enum DialogTone { case neutral, success, danger }
enum DialogRole { case standard }
enum CommandID { case searchSnippets, createSnippet }

@MainActor
final class AppIndex {
    func setCommandsVisible(_ commands: Set<CommandID>, _ visible: Bool) {}
    func setCommandsListed(_ commands: Set<CommandID>, _ visible: Bool) {}
    func updateSnippets(_ snippets: [StoredSnippet]) {}
}

@MainActor
final class PaletteWindowController {
    var isVisible = true
    var previousTarget: InjectionTarget? { nil }
}

@MainActor
final class PaletteState {
    enum Mode { case launcher, clipboard, snippets, snippetEditor }
    var mode = Mode.clipboard
    var menuPresentationToken = UUID()
    func notePointerMoved(to: CGPoint) {}
    func disarmHoverHighlight(pointerAt: CGPoint) {}
    func noteCommandHeld(_ held: Bool) {}
    var isComposing = false
    var query = ""
    var clipboardFilter = ClipboardFilter.all
    var selection = 0
    var restoredSelection: Int?
    func restoreSelection(_ index: Int) {
        selection = index
        restoredSelection = index
    }
    func pop(preservingSelection: Bool) -> Bool {
        mode = .clipboard
        restoredSelection = preservingSelection ? selection : nil
        return true
    }
    func prepare(mode: Mode) { self.mode = mode }
}

@MainActor
final class PaletteCoordinator {
    let state: PaletteState
    init(state: PaletteState) { self.state = state }
    func togglePalette(mode: PaletteState.Mode) { state.mode = mode }
    func showPalette(mode: PaletteState.Mode) { state.mode = mode }
    func hidePalette(restoreFocus: Bool = true) {}
}

@MainActor
enum FolderPicker {
    static func choose(message: String, startingAt: URL) -> URL? { nil }
}

@MainActor
enum AppLauncher {
    static func showInFinder(_ url: URL) {}
}
