private final class InlineFocusTestPanel: NSPanel {
    var simulatedKey = false
    var simulatedVisible = false
    override var isKeyWindow: Bool { simulatedKey }
    override var isVisible: Bool { simulatedVisible }
}

@MainActor
enum InlineTaskEditingTests {
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = ComposerTestFileManager(root: directory)
        let store = TaskStore(fileManager: manager)
        store.add(title: "Original", priority: .medium, dueDate: Date())
        store.toggle(store.tasks[0])
        let original = store.tasks[0]
        store.inlineDraft.title = "Unsent new task"
        var edit = InlineTaskDraft(item: original)
        precondition(edit.title == original.title && edit.priority == original.priority)
        precondition(edit.schedule == .custom(original.dueDate!))
        edit.title = "  Edited inline  "
        edit.priority = .high
        edit.schedule = .unscheduled
        precondition(store.tasks[0] == original, "Typing must not change the saved task before finishing")
        precondition(store.saveInlineEdit(id: original.id, draft: edit))
        let changed = store.tasks[0]
        precondition(changed.title == "Edited inline" && changed.priority == .high && changed.dueDate == nil)
        precondition(changed.id == original.id && changed.createdAt == original.createdAt)
        precondition(changed.isCompleted && changed.completedAt == original.completedAt, "Editing must preserve completion status")
        precondition(store.inlineDraft.title == "Unsent new task", "Editing must not overwrite the new-task draft")
        let restored = TaskStore(fileManager: manager).tasks[0]
        precondition(restored.title == changed.title && restored.priority == .high && restored.dueDate == nil && restored.isCompleted)

        edit.title = " \n\t "
        edit.priority = .low
        precondition(!store.saveInlineEdit(id: original.id, draft: edit))
        precondition(store.tasks[0] == changed, "An empty title must leave the original task intact")
        var saveCount = 0
        store.onTasksChanged = { _ in saveCount += 1 }
        precondition(store.saveInlineEdit(id: changed.id, draft: InlineTaskDraft(item: changed)))
        precondition(saveCount == 0, "Finishing unchanged edits must not cause redundant saves")
        store.delete(changed)
        precondition(!store.saveInlineEdit(id: changed.id, draft: InlineTaskDraft(item: changed)))
        precondition(store.tasks.isEmpty, "A disappearing editor must not recreate a deleted task")
        print("PASS: inline edit, save, empty-title protection, status preservation, draft isolation, deletion")

        _ = NSApplication.shared
        let window = InlineFocusTestPanel(contentRect: NSRect(x: 100, y: 100, width: 360, height: 460), styleMask: .borderless, backing: .buffered, defer: false)
        let popup = InlineFocusTestPanel(contentRect: NSRect(x: 500, y: 100, width: 150, height: 140), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        popup.isReleasedWhenClosed = false
        let region = NSView(frame: NSRect(x: 12, y: 300, width: 334, height: 80))
        window.contentView = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        window.contentView!.addSubview(region)
        let popupRegion = NSView(frame: NSRect(origin: .zero, size: popup.frame.size))
        popup.contentView = popupRegion
        let session = InlineInteractionSession()
        session.register(region)
        session.register(popupRegion)
        func event(in panel: NSPanel, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let inside = event(in: window, at: NSPoint(x: 30, y: 330))
        let inPopup = event(in: popup, at: NSPoint(x: 20, y: 20))
        let outside = event(in: window, at: NSPoint(x: 30, y: 30))
        precondition(session.contains(inside) && session.contains(inPopup))
        precondition(!session.contains(outside), "Blank panel space must count as an outside click")
        var finishes = 0
        var focusRequests = 0
        session.start { finishes += 1 }
        popup.simulatedVisible = true
        let popupPoint = NSPoint(x: popup.frame.midX, y: popup.frame.midY)
        precondition(InlineInteractionSession.containsPopupClick(for: window, at: popupPoint), "Picking metadata must not close the menu-bar panel")
        session.handlePointerDown(inside)
        session.handlePointerDown(inPopup)
        precondition(session.isActive && finishes == 0, "Own controls and popovers must not end editing")
        session.requestFocus { focusRequests += 1 }
        session.handlePointerDown(outside)
        precondition(!session.isActive, "An outside click must immediately invalidate pending focus")
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        precondition(finishes == 1 && focusRequests == 0, "Focus must not be pulled back after clicking elsewhere")
        session.dismiss()
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        precondition(finishes == 1, "Multiple outside notifications must finish only once")
        precondition(!InlineInteractionSession.containsPopupClick(for: window, at: popupPoint))

        session.start { finishes += 1 }
        window.simulatedKey = true
        session.requestFocus { focusRequests += 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(focusRequests == 1, "An active form must accept its own focus requests")
        window.simulatedKey = false
        session.requestFocus { focusRequests += 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(focusRequests == 1, "Focus requests must not reactivate a window after it loses key status")
        session.stop()

        session.start { finishes += 1 }
        session.dismiss()
        session.start { finishes += 10 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(finishes == 1 && session.isActive, "A stale callback must not close a newer editing session")
        session.stop()
        session.unregister(region)
        session.unregister(popupRegion)
        window.close()
        popup.close()
        print("PASS: outside clicks, popup boundaries, focus cancellation, single finish, stale-session protection")
    }
}
