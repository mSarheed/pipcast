import SwiftUI

/// What's New inside the palette: versions on the left, the selected one's notes beside them.
struct ChangelogScreen: PaletteScreen {
    let store: ChangelogStore
    let core: AppCore
    let vm: PaletteState
    let metrics: InterfaceMetrics

    var rows: [Changelog.Entry] {
        let query = vm.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter {
            $0.version.description.hasPrefix(query) || $0.notes.localizedStandardContains(query)
        }
    }

    var primaryActionTitle: String { "View on GitHub" }

    func hasActions(at selection: Int) -> Bool { false }

    func activate(at selection: Int) {
        let rows = rows
        guard rows.indices.contains(selection) else { return }
        core.changelogCoordinator.openRelease(rows[selection])
    }

    func secondary(at selection: Int) -> Bool { false }

    /// A beta's entry is the release it is heading to, which is not installed yet.
    private var currentLabel: String {
        store.running?.isPrerelease == true ? "Beta" : "Installed"
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        let rows = rows
        guard !rows.isEmpty else {
            return AnyView(EmptyResults(text: store.entries.isEmpty ? "No release notes" : "No matches"))
        }
        let selected = rows[min(max(selection, 0), rows.count - 1)]
        return AnyView(
            HStack(spacing: 0) {
                ChangelogPaletteList(
                    entries: rows, current: store.current?.id, currentLabel: currentLabel,
                    selectedID: selected.id, scroll: scroll,
                    onSelect: { entry in vm.selection = rows.firstIndex(of: entry) ?? 0 },
                    onActivate: { activate(at: vm.selection) }
                )
                .frame(width: metrics.size.clipboardListWidth)
                Rectangle()
                    .fill(Theme.Colors.separator)
                    .frame(width: Theme.Size.hairline)
                ChangelogPaletteDetail(entry: selected)
            })
    }
}

private struct ChangelogPaletteList: View {
    let entries: [Changelog.Entry]
    let current: AppVersion?
    let currentLabel: String
    let selectedID: AppVersion
    let scroll: ScrollIntent
    let onSelect: (Changelog.Entry) -> Void
    let onActivate: () -> Void

    @Environment(\.metrics) private var metrics

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Keyed by the string `scrollFollowsSelection` addresses rows by.
                    ForEach(entries, id: \.version.description) { entry in
                        ChangelogPaletteRow(
                            entry: entry, label: entry.id == current ? currentLabel : nil,
                            selected: entry.id == selectedID
                        )
                        .selectionFrame(entry.id == selectedID)
                        .contentShape(Rectangle())
                        .onRowClick(
                            select: { onSelect(entry) },
                            activate: {
                                onSelect(entry)
                                onActivate()
                            })
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.vertical, metrics.spacing.xs)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID.description, atOrigin: selectedID == entries.first?.id,
                proxy: proxy)
        }
    }
}

private struct ChangelogPaletteRow: View {
    let entry: Changelog.Entry
    let label: String?
    let selected: Bool

    @Environment(\.metrics) private var metrics
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            Image(systemName: CommandID.whatsNew.sfSymbol)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            Text("\(Bundle.main.appDisplayName) \(entry.version.description)")
                .font(metrics.typography.menuRow)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let label {
                Text(label)
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill))
        .armedHover($hovered)
    }
}

private struct ChangelogPaletteDetail: View {
    let entry: Changelog.Entry

    @Environment(\.metrics) private var metrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.spacing.xl) {
                VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                    Text("What's New in \(Bundle.main.appDisplayName) \(entry.version.description)")
                        .font(metrics.typography.markdownHeading2)
                    if let date = entry.date.flatMap(Calendar.current.date(from:)) {
                        Text(date.formatted(date: .abbreviated, time: .omitted))
                            .font(Font(metrics.typography.textNSFont(.subheadline)))
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
                ReleaseNotesView(text: entry.notes)
                    .textSelection(.enabled)
            }
            .padding(metrics.spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hideNativeScrollers()
        }
        .edgeDissolve()
        .thinScrollbar()
        .id(entry.id)
    }
}
