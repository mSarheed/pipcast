import Foundation

struct NumberSlots {
    let hasMeetingCard: Bool

    private var firstRow: Int { hasMeetingCard ? 1 : 0 }
    static let digits: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]

    private static let numberRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]

    static func index(for digit: Character) -> Int? { digits.firstIndex(of: digit) }

    static func index(forKeyCode keyCode: UInt16) -> Int? {
        numberRowKeyCodes.firstIndex(of: keyCode)
    }

    func selection(at index: Int, rowCount: Int) -> Int? {
        guard Self.digits.indices.contains(index) else { return nil }
        let row = index + firstRow
        return row < rowCount ? row : nil
    }

    func digit(forRow row: Int) -> Character? {
        guard row >= firstRow else { return nil }
        return Self.digit(at: row - firstRow)
    }

    static func digit(at index: Int) -> Character? {
        digits.indices.contains(index) ? digits[index] : nil
    }
}
