private final class ComposerTestFileManager: FileManager, @unchecked Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        [root]
    }
}

@MainActor
enum InlineTaskComposerTests {
    static func run() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59))!
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        precondition(InlineTaskSchedule.today.dueDate(relativeTo: now, calendar: calendar) == today)
        precondition(InlineTaskSchedule.tomorrow.dueDate(relativeTo: now, calendar: calendar) == tomorrow)
        precondition(InlineTaskSchedule.today.dueDate(relativeTo: tomorrow, calendar: calendar) == tomorrow,
                     "The default must follow the current day, not the app launch day")
        precondition(InlineTaskSchedule.custom(now).dueDate(calendar: calendar) == today)
        precondition(InlineTaskSchedule.unscheduled.dueDate() == nil)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ComposerTestFileManager(root: directory)
        let store = TaskStore(fileManager: manager)
        precondition(store.inlineDraft.priority == .medium && store.inlineDraft.schedule == .today)
        store.inlineDraft.title = "  \n\t "
        precondition(!store.submitInlineDraft() && store.tasks.isEmpty, "Whitespace must not create a task")
        precondition(store.inlineDraft.title == "  \n\t ", "Invalid submission must not discard the draft")

        store.inlineDraft = InlineTaskDraft(title: "  Inline task  ", priority: .high, schedule: .custom(now))
        let expectedDate = store.inlineDraft.schedule.dueDate()
        precondition(store.submitInlineDraft())
        precondition(store.tasks.count == 1 && store.tasks[0].title == "Inline task")
        precondition(store.tasks[0].priority == .high && store.tasks[0].dueDate == expectedDate)
        precondition(!store.tasks[0].isCompleted)
        precondition(store.inlineDraft == InlineTaskDraft(), "Each new task must start with the default settings")
        let saved = TaskStore(fileManager: manager).tasks
        precondition(saved.count == 1 && saved[0].id == store.tasks[0].id, "Inline additions must be persisted")
        precondition(saved[0].title == "Inline task" && saved[0].priority == .high && saved[0].dueDate == expectedDate)

        store.inlineDraft = InlineTaskDraft(title: "No date", priority: .low, schedule: .unscheduled)
        precondition(store.submitInlineDraft() && store.tasks[1].dueDate == nil)
        store.inlineDraft.title = "Default task"
        precondition(store.submitInlineDraft())
        precondition(store.tasks[2].priority == .medium)
        precondition(Calendar.current.isDateInToday(store.tasks[2].dueDate!))
        precondition(!store.submitInlineDraft() && store.tasks.count == 3, "Repeated Return must not create duplicates")

        store.inlineDraft.title = "Unsent draft"
        store.toggle(store.tasks[0])
        precondition(store.inlineDraft.title == "Unsent draft", "Other task actions must not clear the draft")
        print("PASS: inline defaults, validation, relative dates, custom/no date, submission, reset, persistence, draft retention")
    }
}
