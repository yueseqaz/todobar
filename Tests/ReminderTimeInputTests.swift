@MainActor
enum ReminderTimeInputTests {
    static func run() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 140, height: 70), styleMask: .titled, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let input = ReminderTimeControl(frame: NSRect(x: 10, y: 10, width: 72, height: 26))
        panel.contentView!.addSubview(input)
        input.update(minuteOfDay: 1260, isEnabled: true)
        var saved: [Int] = []
        input.onChange = { value in saved.append(value); return true }

        func type(_ text: String, into field: NSTextField) {
            let editor = field.currentEditor() as! NSTextView
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        func blur() {
            panel.makeFirstResponder(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        input.hourField.selectText(nil)
        type("1", into: input.hourField)
        precondition(input.hourField.stringValue == "1" && input.hourField.currentEditor() != nil)
        // SwiftUI may re-render while the hour is only half entered.
        input.update(minuteOfDay: 1260, isEnabled: true)
        precondition(input.hourField.stringValue == "1")
        type("5", into: input.hourField)
        precondition(saved.isEmpty, "Advancing to minutes must not submit an intermediate time")
        precondition(input.minuteField.currentEditor() != nil, "Two hour digits must automatically focus minutes")
        precondition((input.minuteField.currentEditor() as! NSTextView).selectedRange().length == 2,
                     "Existing minutes must be selected so typing replaces them")
        type("3", into: input.minuteField)
        type("0", into: input.minuteField)
        precondition(input.minuteOfDay == 930 && saved.last == 930, "Typing 1530 must save 15:30")
        blur()

        input.hourField.selectText(nil)
        type("0", into: input.hourField)
        type("9", into: input.hourField)
        type("0", into: input.minuteField)
        type("5", into: input.minuteField)
        precondition(input.minuteOfDay == 545, "Leading zeroes must work for both segments")
        blur()

        input.hourField.selectText(nil)
        type("2", into: input.hourField)
        type("4", into: input.hourField)
        precondition(input.hourField.currentEditor() != nil, "Invalid hours must not advance")
        blur()
        precondition(input.minuteOfDay == 545 && input.hourField.stringValue == "09", "Invalid input must restore the saved time")

        input.minuteField.selectText(nil)
        type("7", into: input.minuteField)
        blur()
        precondition(input.minuteOfDay == 547 && input.minuteField.stringValue == "07", "Clicking away must commit and pad a single digit")

        input.onChange = { _ in false }
        input.minuteField.selectText(nil)
        type("3", into: input.minuteField)
        type("0", into: input.minuteField)
        precondition(input.minuteOfDay == 547 && input.minuteField.stringValue == "07", "Rejected duplicate times must restore the prior value")
        blur()
        input.update(minuteOfDay: 540, isEnabled: true)
        input.onChange = { $0 != 1260 }
        input.hourField.selectText(nil)
        type("2", into: input.hourField)
        type("1", into: input.hourField)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(input.hourField.stringValue == "21" && input.minuteField.currentEditor() != nil)
        type("3", into: input.minuteField)
        type("0", into: input.minuteField)
        precondition(input.minuteOfDay == 1290, "A duplicate intermediate hour must not block entering a distinct final time")
        blur()
        input.update(minuteOfDay: 0, isEnabled: false)
        precondition(!input.hourField.isEnabled && !input.minuteField.isEnabled)
        precondition(input.hourField.stringValue == "00" && input.minuteField.stringValue == "00")
        print("PASS: real time-field typing, automatic hour-to-minute focus, replacement selection, leading zeroes, outside commit, invalid/duplicate rejection, disabled fields")
    }
}
