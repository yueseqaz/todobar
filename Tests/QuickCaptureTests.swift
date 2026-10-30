private final class CaptureTestPanel: NSPanel {
    var shown = false
    override var isVisible: Bool { shown }
    override func center() {}
    override func makeKeyAndOrderFront(_ sender: Any?) { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
}

@MainActor
enum QuickCaptureTests {
    static func run() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(fileManager: ComposerTestFileManager(root: directory))
        let panel = CaptureTestPanel(contentRect: NSRect(x: 0, y: 0, width: 388, height: 194), styleMask: .titled, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var activations = 0
        let controller = QuickCaptureController(panel: panel, activateApp: { activations += 1 })
        controller.configure(with: store)
        let session = controller.session
        controller.toggle()
        precondition(panel.isVisible && session.isPresented && activations == 1)
        let firstGeneration = session.generation
        session.draft = InlineTaskDraft(title: "Unsent capture", priority: .high, schedule: .tomorrow)
        controller.toggle()
        precondition(!panel.isVisible && !session.isPresented && activations == 1,
                     "Pressing the shortcut again must close without activating the app")
        precondition(session.draft.title == "Unsent capture" && session.draft.priority == .high && session.draft.schedule == .tomorrow)
        precondition(session.takeSubmission(generation: firstGeneration) == nil, "A hidden capture must not submit")
        controller.toggle()
        precondition(panel.isVisible && session.isPresented && activations == 2)
        precondition(session.draft.title == "Unsent capture")
        precondition(!session.dismiss(generation: firstGeneration) && session.isPresented,
                     "A queued dismissal from the prior opening must not close the new one")
        precondition(session.takeSubmission(generation: firstGeneration) == nil)
        session.draft.title = " \n\t "
        precondition(session.takeSubmission(generation: session.generation) == nil && session.isPresented,
                     "Blank submission must leave the input open without success feedback")
        session.draft.title = "  Captured task  "
        let generation = session.generation
        let submitted = session.takeSubmission(generation: generation)!
        store.add(title: submitted.trimmedTitle, priority: submitted.priority, dueDate: submitted.schedule.dueDate())
        precondition(store.tasks.count == 1 && store.tasks[0].title == "Captured task" && store.tasks[0].priority == .high)
        precondition(!session.isPresented && session.draft == InlineTaskDraft(), "A successful save must clear and close capture")
        precondition(session.takeSubmission(generation: generation) == nil, "Repeated save callbacks must not create duplicates")
        precondition(TaskStore(fileManager: ComposerTestFileManager(root: directory)).tasks.count == 1)
        panel.orderOut(nil)
        controller.toggle()
        precondition(session.isPresented && session.draft == InlineTaskDraft())
        for _ in 0..<10 { controller.toggle() }
        precondition(panel.isVisible && session.isPresented && store.tasks.count == 1)
        panel.orderOut(nil)
        controller.toggle()
        precondition(panel.isVisible && session.isPresented, "The shortcut must reopen a natively hidden panel")
        controller.toggle()

        let feedback = QuickCaptureFeedbackController()
        let feedbackPanel = feedback.makePanel(title: "Example task")
        precondition(!feedbackPanel.canBecomeKey && !feedbackPanel.canBecomeMain)
        precondition(feedbackPanel.ignoresMouseEvents && feedbackPanel.styleMask.contains(.nonactivatingPanel))
        precondition(feedbackPanel.contentView != nil && !feedbackPanel.isVisible)
        feedbackPanel.close()
        print("PASS: quick-capture toggle, retained draft, fresh focus generations, stale callback rejection, blank/double submission, saved task, nonactivating click-through feedback")
    }
}
