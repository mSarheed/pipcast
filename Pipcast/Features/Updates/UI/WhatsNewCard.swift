import SwiftUI

/// The launcher's lead card after an update, shaped like the meeting card it shares the slot with.
struct WhatsNewCard: View {
    @Environment(\.metrics) private var metrics
    let entry: Changelog.Entry
    let selected: Bool

    var body: some View {
        let subtitle = subtitle
        return HStack(spacing: metrics.spacing.xl) {
            SymbolImage(name: CommandID.whatsNew.sfSymbol, size: metrics.size.headerIconSlot)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: metrics.spacing.xs) {
                Text(title)
                    .font(metrics.typography.calcResult.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(subtitle)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.md)
            Text("New")
                .font(metrics.typography.rowTitle.weight(.medium))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .padding(.horizontal, metrics.spacing.md)
                .padding(.vertical, metrics.spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: metrics.radius.keyCap, style: .continuous)
                        .fill(Theme.Colors.brandAction)
                )
        }
        .padding(.horizontal, metrics.spacing.xl)
        .padding(.vertical, metrics.spacing.xxl)
        .leadCard(selected: selected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(String(subtitle.characters)), new")
        .accessibilityAddTraits(.isButton)
    }

    private var title: String {
        "What's New in \(Bundle.main.appDisplayName) \(entry.version.description)"
    }

    /// The release's own headline, styled as written; without one, what the card leads to.
    private var subtitle: AttributedString {
        guard let headline = entry.headline else { return "See what changed in this update" }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: headline, options: options)) ?? AttributedString(headline)
    }
}

/// The card's actions; ↵ opens the notes, and Dismiss reads them without opening.
@MainActor
enum WhatsNewActionsMenu {
    static func content(entry: Changelog.Entry, core: AppCore) -> PopoverMenuContent {
        PopoverMenuContent(
            header: "What's New",
            items: [
                PopoverMenuItem(
                    title: "Open What's New", systemImage: CommandID.whatsNew.sfSymbol, shortcut: "↵"
                ) {
                    core.changelogCoordinator.showChangelog()
                },
                PopoverMenuItem(title: "View on GitHub", systemImage: "arrow.up.right.square") {
                    core.changelogCoordinator.dismissNews()
                    core.changelogCoordinator.openRelease(entry)
                },
                PopoverMenuItem(title: "Dismiss", systemImage: "xmark", startsSection: true) {
                    core.changelogCoordinator.dismissNews()
                }
            ])
    }
}
