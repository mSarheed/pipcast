import SwiftUI

/// ⌘K › Configure Command: the alias and hotkey Settings already offers a row, set in place.
@MainActor
enum CommandConfigurationMenu {
    /// Settings lists no alias for a snippet, and a query-driven row has no key to keep one under.
    static func supportsAlias(_ entry: AppEntry) -> Bool {
        switch entry.kind {
        case .snippet, .meeting: false
        default: !CommandCatalog.isQueryDriven(entry)
        }
    }

    /// The action Settings' recorder binds for the row; an extension command's is keyed by entry.
    static func hotKeyAction(for entry: AppEntry) -> HotKeyAction? {
        if entry.kind == .extensionCommand { return .extensionCommand(entryID: entry.id) }
        return entry.hotKeyAction
    }

    static func isConfigurable(_ entry: AppEntry) -> Bool {
        supportsAlias(entry) || hotKeyAction(for: entry) != nil
    }

    static func content(
        entry: AppEntry, core: AppCore, setHotkey: @escaping (HotKeyAction) -> Void,
        setAlias: @escaping () -> Void
    ) -> PopoverMenuContent {
        var items = [
            PopoverMenuItem(
                title: String(localized: "Open Command Settings"), systemImage: "gearshape"
            ) {
                showSettings(for: entry, core: core)
            }
        ]
        if let action = hotKeyAction(for: entry) {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Set Hotkey…"), icon: .symbol("command"),
                    detail: core.hotKeys.binding(for: action)?.keycaps.joined()
                ) {
                    setHotkey(action)
                })
        }
        if supportsAlias(entry) {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Set Alias…"), icon: .symbol("character.cursor.ibeam"),
                    detail: core.aliases.alias(for: entry.preferenceKey)
                ) {
                    setAlias()
                })
        }
        return PopoverMenuContent(header: String(localized: "Configure Command"), items: items)
    }

    /// The palette closes behind the pane, as every other route into Settings does.
    static func showSettings(for entry: AppEntry, core: AppCore) {
        if entry.kind == .extensionCommand {
            core.extensionCoordinator.showExtensionSettings(for: entry)
            return
        }
        guard let tab = entry.settingsTab else { return }
        core.paletteCoordinator.hidePalette(restoreFocus: false)
        core.settingsCoordinator.showSettings(tab: tab, revealing: entry.settingsTarget)
    }

    static func saveAlias(_ alias: String, for entry: AppEntry, core: AppCore) {
        let previous = core.aliases.alias(for: entry.preferenceKey)
        core.aliases.setAlias(
            alias.trimmingCharacters(in: .whitespacesAndNewlines), for: entry.preferenceKey)
        let saved = core.aliases.alias(for: entry.preferenceKey)
        guard saved != previous else { return }
        core.showMessage(
            saved == nil ? String(localized: "Alias removed") : String(localized: "Alias saved"))
    }

    /// Called once the recording ends; an unchanged binding means it was cancelled.
    static func confirmHotkey(_ action: HotKeyAction, previous: HotKeyBinding?, core: AppCore) {
        let binding = core.hotKeys.binding(for: action)
        guard binding != previous else { return }
        guard let binding else {
            core.showMessage(String(localized: "Hotkey removed"))
            return
        }
        // Settings warns beside the field; here the pill is the only place left to say it.
        if binding.usesModifierTapMonitor, !Permissions.isAccessibilityTrusted() {
            core.showMessage(
                String(localized: "Modifier-only hotkeys need Accessibility access. Click to grant it."),
                tone: .danger, onClick: Permissions.openAccessibilitySettings)
            return
        }
        core.showMessage(String(localized: "Hotkey saved"))
    }
}

extension AppEntry {
    /// The pane that draws this row's alias and hotkey controls.
    fileprivate var settingsTab: SettingsTab? {
        if let settingsOwner { return settingsOwner }
        switch kind {
        case .application: return .applications
        case .systemSettings: return .systemSettings
        case .systemAction: return .systemActions
        case .command, .customCommand: return .commands
        case .quickAction: return .quickActions
        case .snippet: return .snippets
        case .windowCommand, .windowLayout, .windowRoom: return .windowManagement
        case .quicklink: return .quicklinks
        case .appleShortcut: return .appleShortcuts
        case .extensionCommand: return .extensions
        case .meeting: return nil
        }
    }

    /// A filterable list is narrowed to the row's name; elsewhere the section listing it is shown.
    fileprivate var settingsTarget: SettingsTarget? {
        if let settingsOwner, kind == .command { return ownedCommandSection(in: settingsOwner) }
        switch kind {
        case .application: return .launcherItem(.applicationsApplications, name)
        case .systemSettings: return .launcherItem(.systemSettingsSystemSettings, name)
        case .systemAction: return .launcherItem(.systemActionsSystemActions, name)
        case .command: return .launcherItem(.commandsCommands, name)
        case .appleShortcut: return .launcherItem(.appleShortcutsShortcuts, name)
        case .quicklink: return .launcherItem(.quicklinksLibrary, name)
        case .customCommand: return .section(.commandsCustomCommands)
        case .quickAction: return .section(.quickActionsActions)
        case .snippet: return .section(.snippetsLibrary)
        case .windowLayout: return .section(.windowManagementLayouts)
        case .windowRoom: return .section(.windowManagementRooms)
        case .windowCommand:
            return CustomWindowSize.id(fromEntryID: id) == nil
                ? .row(.windowManagementCommands, name) : .section(.windowManagementCustomSizes)
        case .extensionCommand, .meeting: return nil
        }
    }

    /// Mirrors each pane's `FeatureCommandsSection` anchor; Search Menu Items sits apart.
    private func ownedCommandSection(in owner: SettingsTab) -> SettingsTarget? {
        let anchor: SettingsAnchor? =
            switch owner {
            case .commands: .commandsCustomCommands
            case .quicklinks: .quicklinksCommands
            case .ai: .aiCommands
            case .fileSearch: .fileSearchCommands
            case .notes: .notesCommands
            case .snippets: .snippetsCommands
            case .navigation:
                id == CommandID.searchMenuItems.rawValue ? .navigationMenuSearch : .navigationCommands
            case .windowManagement: .windowManagementLayoutCommands
            case .clipboard: .clipboardCommands
            case .emoji: .emojiCommands
            case .calendar: .calendarCommands
            default: nil
            }
        return anchor.map { .section($0) }
    }
}
