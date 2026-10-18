import SwiftUI

/// Set Alias…: a field in the Actions menu's corner. ↵ saves, and a blank field removes the alias.
struct CommandAliasPanel: View {
    let entry: AppEntry
    let attachment: PopoverMenu.Attachment
    let onSave: (String) -> Void
    let onClose: () -> Void

    @Environment(\.metrics) private var metrics
    @State private var draft: String
    @FocusState private var focused: Bool

    init(
        entry: AppEntry, alias: String?, attachment: PopoverMenu.Attachment,
        onSave: @escaping (String) -> Void, onClose: @escaping () -> Void
    ) {
        self.entry = entry
        self.attachment = attachment
        self.onSave = onSave
        self.onClose = onClose
        _draft = State(initialValue: alias ?? "")
    }

    var body: some View {
        CommandConfigurationSurface(
            title: String(localized: "Set Alias…"), entry: entry, attachment: attachment,
            onClose: onClose, onSave: { onSave(draft) }
        ) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(metrics.typography.menuRow)
                .foregroundStyle(Theme.Colors.textPrimary)
                .tint(Theme.Colors.textPrimary)
                .focused($focused)
                .lineLimit(1)
                .background(alignment: .leading) {
                    if draft.isEmpty {
                        Text("Enter Alias…")
                            .font(metrics.typography.menuRow)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: metrics.size.menuRowHeight)
                .onSubmit { onSave(draft) }
                .onAppear { focused = true }
                .accessibilityLabel("Alias for \(entry.name)")
        }
    }
}

/// Set Hotkey…: the Settings recorder's own capture session, narrated in the same corner.
struct CommandHotkeyPanel: View {
    let entry: AppEntry
    let attachment: PopoverMenu.Attachment
    let onClose: () -> Void

    @Environment(\.metrics) private var metrics

    var body: some View {
        CommandConfigurationSurface(
            title: String(localized: "Set Hotkey…"), entry: entry, attachment: attachment,
            onClose: onClose
        ) {
            ShortcutCaptureReadout()
                .frame(maxWidth: .infinity)
                .padding(.vertical, metrics.spacing.md)
        }
    }
}

/// The two panels' shared glass: a title, the control, then whose it is and how to leave.
private struct CommandConfigurationSurface<Content: View>: View {
    let title: String
    let entry: AppEntry
    let attachment: PopoverMenu.Attachment
    let onClose: () -> Void
    var onSave: (() -> Void)?
    @ViewBuilder let content: Content

    @Environment(\.metrics) private var metrics
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(metrics.typography.sectionHeader)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: metrics.size.menuSectionHeader, alignment: .leading)
                .padding(.top, metrics.spacing.md)
            content
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: 1 / displayScale)
                .padding(.horizontal, -metrics.spacing.lg)
                .accessibilityHidden(true)
            footer
        }
        .padding(.horizontal, metrics.spacing.lg)
        .frame(width: metrics.size.actionMenuWidth)
        .glassEffect(
            .regular,
            in: PopoverMenu.SurfaceShape(
                attachment: attachment, radius: metrics.radius.menuPanel,
                attachedRadius: metrics.size.menuButton / 2))
    }

    private var footer: some View {
        HStack(spacing: metrics.spacing.sm) {
            AppIconView(app: entry, pointSize: metrics.size.menuIcon)
                .frame(width: metrics.size.menuIcon, height: metrics.size.menuIcon)
            Text(entry.name)
                .font(metrics.typography.menuRow)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: metrics.spacing.sm)
            footerButton(String(localized: "Close"), key: String(localized: "esc"), action: onClose)
            if let onSave {
                footerButton(String(localized: "Save"), key: "↵", action: onSave)
            }
        }
        .frame(height: metrics.size.menuRowHeight)
        .padding(.vertical, metrics.spacing.xs)
    }

    private func footerButton(
        _ title: String, key: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: metrics.spacing.xs) {
                Text(title)
                    .font(metrics.typography.menuRow)
                    .foregroundStyle(Theme.Colors.textPrimary)
                KeyCapChip(text: key, style: .outline, scale: .compact)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
