@MainActor
enum ReminderSettingsTests {
    static func run() throws {
        let suite = "TodoBar.ReminderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReminderSettings(defaults: defaults)
        precondition(settings.isEnabled && settings.times.map(\.minuteOfDay) == [900, 1260])
        let firstID = settings.times[0].id
        precondition(!settings.update(id: firstID, minuteOfDay: 1260), "Duplicate times must not create two reminders")
        precondition(!settings.update(id: firstID, minuteOfDay: -1))
        precondition(!settings.update(id: firstID, minuteOfDay: 1440))
        precondition(settings.update(id: firstID, minuteOfDay: 600))
        precondition(settings.times[0].id == firstID, "Editing must retain row identity")
        settings.addTime()
        precondition(settings.times.map(\.minuteOfDay) == [600, 1260, 1320])
        settings.remove(id: firstID)
        settings.isEnabled = false
        let restored = ReminderSettings(defaults: defaults)
        precondition(!restored.isEnabled && restored.times == settings.times, "Times and enable state must survive restart")
        settings.remove(id: settings.times[0].id)
        settings.remove(id: settings.times[0].id)
        precondition(settings.times.count == 1, "Keep one saved time; switch off reminders to pause")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let times = [ReminderTime(minuteOfDay: 900), ReminderTime(minuteOfDay: 1260)]
        precondition(ReminderSchedule.nextDate(times, after: date(30, 14), calendar: calendar) == date(30, 15))
        precondition(ReminderSchedule.nextDate(times, after: date(30, 15), calendar: calendar) == date(30, 21))
        precondition(ReminderSchedule.nextDate(times, after: date(30, 22), calendar: calendar) == date(31, 15))
        precondition(ReminderSchedule.dueTimes(times, at: date(30, 14, 59), calendar: calendar).isEmpty)
        precondition(ReminderSchedule.dueTimes(times, at: date(30, 15), calendar: calendar) == [times[0]])
        let history = ReminderDeliveryHistory(defaults: defaults)
        precondition(!history.consumeLatest(times, at: date(30, 14), calendar: calendar))
        precondition(history.consumeLatest(times, at: date(30, 15), calendar: calendar))
        precondition(!history.consumeLatest(times, at: date(30, 16), calendar: calendar))
        let restarted = ReminderDeliveryHistory(defaults: defaults)
        precondition(!restarted.consumeLatest(times, at: date(30, 16), calendar: calendar))
        precondition(restarted.consumeLatest(times, at: date(30, 21), calendar: calendar), "Second daily reminder must still fire")
        precondition(!restarted.consumeLatest(times, at: date(30, 22), calendar: calendar))
        precondition(restarted.consumeLatest(times, at: date(31, 22), calendar: calendar), "After sleep, deliver latest missed reminder once")
        precondition(!restarted.consumeLatest(times, at: date(31, 22), calendar: calendar))
        precondition(ReminderSchedule.dayKey(at: date(30, 23), calendar: calendar) != ReminderSchedule.dayKey(at: date(31, 0), calendar: calendar),
                     "Deduplication must roll over at local midnight, not UTC midnight")
        let midnight = [ReminderTime(minuteOfDay: 0)]
        precondition(ReminderSchedule.nextDate(midnight, after: date(30, 23, 59), calendar: calendar) == date(31, 0))
        precondition(history.consumeLatest(midnight, at: date(31, 0), calendar: calendar))

        var dst = Calendar(identifier: .gregorian)
        dst.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let beforeDST = dst.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0))!
        let nextDST = ReminderSchedule.nextDate([ReminderTime(minuteOfDay: 150)], after: beforeDST, calendar: dst)!
        precondition(dst.isDate(nextDST, inSameDayAs: beforeDST) && nextDST > beforeDST,
                     "A nonexistent spring-forward time must still remind on that day")
        let autumn = dst.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0))!
        let repeated = [ReminderTime(minuteOfDay: 90)]
        let first = ReminderSchedule.nextDate(repeated, after: autumn, calendar: dst)!
        precondition(history.consumeLatest(repeated, at: first, calendar: dst))
        precondition(!history.consumeLatest(repeated, at: first.addingTimeInterval(3600), calendar: dst),
                     "Repeated autumn hour must not deliver the same slot twice")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(fileManager: ComposerTestFileManager(root: directory))
        let controller = EveningReminderController(settings: settings, defaults: defaults)
        controller.configure(with: store)
        precondition(controller.nextScheduledReminder == nil, "Disabled reminders must not schedule timers")
        settings.isEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(controller.nextScheduledReminder != nil)
        let newMinute = (settings.times[0].minuteOfDay + 17) % 1440
        settings.update(id: settings.times[0].id, minuteOfDay: newMinute)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let expected = ReminderSchedule.nextDate(settings.times, after: Date())!
        precondition(abs(controller.nextScheduledReminder!.timeIntervalSince(expected)) < 1, "Editing must reschedule immediately")
        settings.isEnabled = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(controller.nextScheduledReminder == nil)
        print("PASS: reminder defaults, edits, duplicates, persistence, daily frequency, local midnight, missed slots, DST, enable/disable, live rescheduling")
    }
}
