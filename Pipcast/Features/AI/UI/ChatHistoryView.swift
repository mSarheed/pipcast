import SwiftUI

struct ChatHistoryList: View {

    @Environment(\.metrics) private var metrics
    let results: [ChatConversation]
    let selectedID: ChatConversation.ID?
    let scroll: ScrollIntent
    let onSelect: (ChatConversation) -> Void
    let onActivate: () -> Void
    let onActions: (ChatConversation) -> Void

    private enum Row: Identifiable {
        case header(String)
        case conversation(ChatConversation)

        var id: String {
            switch self {
            case .header(let title): return "header-" + title
            case .conversation(let conversation): return conversation.id.uuidString
            }
        }
    }

    private var firstRowSelected: Bool {
        selectedID != nil && selectedID == results.first?.id
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var currentBucket: DateBucket?
        let buckets = DateBucket.Boundaries()
        for conversation in results {
            let bucket = buckets.bucket(for: conversation.updatedAt)
            if bucket != currentBucket {
                rows.append(.header(bucket.title))
                currentBucket = bucket
            }
            rows.append(.conversation(conversation))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let title):
                            SectionHeader(title: title, isFirst: row.id == rows.first?.id)
                        case .conversation(let conversation):
                            ChatHistoryRow(
                                conversation: conversation,
                                selected: conversation.id == selectedID
                            )
                            .selectionFrame(conversation.id == selectedID)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(conversation) }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    onSelect(conversation)
                                    onActivate()
                                }
                            )
                            .onRightClick { onActions(conversation) }
                        }
                    }
                }
                .padding(.horizontal, metrics.spacing.md)
                .padding(.top, metrics.spacing.xs)
                .padding(.bottom, metrics.spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            // Snap to the origin on the first row so its section header shows too.
            .scrollFollowsSelection(
                scroll, row: selectedID?.uuidString, atOrigin: firstRowSelected, proxy: proxy)
        }
    }
}

private struct ChatHistoryRow: View {

    @Environment(\.metrics) private var metrics
    let conversation: ChatConversation
    let selected: Bool
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        IconCache.observeStyle()
        return HStack(spacing: metrics.spacing.lg) {
            Image(nsImage: IconCache.symbolIcon(named: "bubble.left")).resizable()
                .frame(width: metrics.size.resultRowIcon, height: metrics.size.resultRowIcon)
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(conversation.displayTitle)
                    .font(metrics.typography.rowTitle)
                    .lineLimit(1)
                if !conversation.preview.isEmpty {
                    Text(conversation.preview)
                        .font(metrics.typography.keyCap)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(conversation.updatedAt.formatted(date: .omitted, time: .shortened))
                .font(metrics.typography.keyCap)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous).fill(fill)
        )
        .armedHover($hovered)
    }
}

struct ChatHistoryPreview: View {
    let history: ChatHistoryStore
    let chat: AIChatState
    let conversationID: UUID?
    @State private var session: ChatSession?
    @State private var lastSelectionChange: ContinuousClock.Instant?
    @State private var hasOpened = false

    /// Selections closer together than this are stepping through the list, as a held arrow does.
    private static let steppingInterval: Duration = .milliseconds(300)
    /// Jitter in a fast key repeat must not land a step just after the wait has ended.
    private static let shortestSettle: Duration = .milliseconds(60)
    /// Deliberate presses near the stepping interval should barely feel the wait.
    private static let longestSettle: Duration = .milliseconds(150)

    var body: some View {
        Group {
            if conversationID == chat.session.id, !chat.session.messages.isEmpty {
                ChatTranscriptView(
                    messages: chat.session.messages, status: chat.liveStatus, usage: chat.usage,
                    surface: .palette)
            } else if let session {
                ChatTranscriptView(
                    messages: session.messages, status: nil, usage: nil,
                    surface: .palette)
            } else if conversationID != nil {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: conversationID) {
            session = nil
            let now = ContinuousClock.now
            let gap = lastSelectionChange.map { now - $0 }
            // Opening the screen is not a selection, so it starts no stepping run.
            if hasOpened { lastSelectionChange = now }
            hasOpened = true
            guard let conversationID else { return }
            guard conversationID != chat.session.id || chat.session.messages.isEmpty else { return }
            if let gap, gap < Self.steppingInterval {
                do { try await Task.sleep(for: Self.settle(after: gap)) } catch { return }
                // A newer selection cancels this task, so one still live owns `conversationID`.
                guard !Task.isCancelled else { return }
            }
            session = history.session(id: conversationID)
        }
    }

    /// Half again the stepping pace, so a held arrow's next step lands before a transcript draws.
    private static func settle(after gap: Duration) -> Duration {
        min(max(gap * 3 / 2, shortestSettle), longestSettle)
    }
}
