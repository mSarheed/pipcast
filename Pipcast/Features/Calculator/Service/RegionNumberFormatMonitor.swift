import Foundation

/// Follows Language & Region's number format, so a change there applies without a relaunch.
@MainActor
@Observable
final class RegionNumberFormatMonitor {
    private(set) var system = CalcNumberFormat.english
    @ObservationIgnored private var token: NotificationCenter.ObservationToken?
    /// Replaced by each re-read, so an older answer landing late never wins.
    @ObservationIgnored private var reading: Task<Void, Never>?

    init() {
        token = NotificationCenter.default.addObserver(of: Locale.self, for: .currentLocaleDidChange) {
            [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    func format(for style: CalcNumberStyle) -> CalcNumberFormat {
        style == .system ? system : .english
    }

    /// The first separator lookup loads ICU's number data, ~6 ms that launch spends off main.
    private func refresh() {
        reading?.cancel()
        reading = Task { [weak self] in
            let format = await Self.read()
            guard !Task.isCancelled else { return }
            self?.system = format
        }
    }

    /// Separators the parser can't take, such as the Arabic `٫`, fall back to English.
    @concurrent private static func read() async -> CalcNumberFormat {
        let locale = Locale.autoupdatingCurrent
        return CalcNumberFormat(
            decimalSeparator: locale.decimalSeparator ?? ".", groupingSeparator: locale.groupingSeparator)
            ?? .english
    }
}
