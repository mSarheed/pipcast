import Foundation

@main
struct FavoritesTest {
    static func main() {
        var failures = 0

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        // Ten digit keys is the ceiling: there is no ⌘10, so the eleventh favorite gets no chord.
        check("ten slots", NumberSlots.digits.count == 10)
        check("no digit repeats", Set(NumberSlots.digits).count == NumberSlots.digits.count)

        check("⌘1 is the first favorite", NumberSlots.index(for: "1") == 0)
        check("⌘9 is the ninth", NumberSlots.index(for: "9") == 8)
        check("⌘0 is the tenth, not the first", NumberSlots.index(for: "0") == 9)
        check("a letter is not a slot", NumberSlots.index(for: "a") == nil)

        let numberRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for (index, keyCode) in numberRowKeyCodes.enumerated() {
            check(
                "physical number-row keycode \(keyCode) maps to slot \(index)",
                NumberSlots.index(forKeyCode: keyCode) == index)
        }
        check("unknown keycode is not a slot", NumberSlots.index(forKeyCode: 0) == nil)

        check("the first row shows 1", NumberSlots.digit(at: 0) == "1")
        check("the tenth row shows 0", NumberSlots.digit(at: 9) == "0")
        check("the eleventh row shows nothing", NumberSlots.digit(at: 10) == nil)
        check("a negative index shows nothing", NumberSlots.digit(at: -1) == nil)

        // The row overlay and the key handler must agree, or a row advertises another's chord.
        for index in NumberSlots.digits.indices {
            guard let digit = NumberSlots.digit(at: index) else {
                check("slot \(index) has a digit", false)
                continue
            }
            check("slot \(index) round-trips", NumberSlots.index(for: digit) == index)
        }

        for hasMeetingCard in [false, true] {
            let slots = NumberSlots(hasMeetingCard: hasMeetingCard)
            let firstRow = hasMeetingCard ? 1 : 0
            for slot in 0..<10 {
                let row = slot + firstRow
                check("activation skips only the meeting card: slot \(slot), meeting \(hasMeetingCard)",
                      slots.selection(at: slot, rowCount: 11) == row)
                check("displayed chord matches activation: row \(row), meeting \(hasMeetingCard)",
                      slots.digit(forRow: row) == NumberSlots.digits[slot])
            }
            check("no eleventh chord", slots.digit(forRow: firstRow + 10) == nil)
            check("missing result is not clamped", slots.selection(at: 8, rowCount: 2) == nil)
            check("empty list has no action", slots.selection(at: 0, rowCount: 0) == nil)
            check("eleventh slot cannot activate", slots.selection(at: 10, rowCount: 20) == nil)
            check("negative slot cannot activate", slots.selection(at: -1, rowCount: 20) == nil)
        }
        let meetingSlots = NumberSlots(hasMeetingCard: true)
        check("a timed meeting never advertises a numbered chord", meetingSlots.digit(forRow: 0) == nil)
        check("a meeting alone cannot take the first favorite chord",
              meetingSlots.selection(at: 0, rowCount: 1) == nil)
        check("the tenth favorite keeps Cmd0 below a meeting",
              meetingSlots.selection(at: 9, rowCount: 11) == 10)
        let querySlots = NumberSlots(hasMeetingCard: false)
        check("typed calculator and color cards keep Cmd1", querySlots.digit(forRow: 0) == "1")
        check("typed card activation keeps flat row zero", querySlots.selection(at: 0, rowCount: 3) == 0)

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) failed")
        if failures > 0 { exit(1) }
    }
}
