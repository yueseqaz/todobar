@main
struct WidgetEdgeTabTests {
    @MainActor
    static func main() {
        try! InlineTaskComposerTests.run()
        try! InlineTaskEditingTests.run()
        try! ReminderSettingsTests.run()
        ReminderTimeInputTests.run()
        let screen = NSRect(x: -1440, y: -200, width: 1440, height: 1000)
        let visible = NSRect(x: -1380, y: -150, width: 1380, height: 920)
        let left = DesktopWidgetController.collapsedFrame(side: .left, y: 100, screenFrame: screen, visibleFrame: visible)
        let right = DesktopWidgetController.collapsedFrame(side: .right, y: 100, screenFrame: screen, visibleFrame: visible)
        precondition(left.minX == screen.minX, "Left tab must touch the physical edge, even with a side Dock")
        precondition(right.maxX == screen.maxX, "Right tab must touch the physical edge")
        precondition(left.size == DesktopWidgetController.collapsedSize)

        let top = DesktopWidgetController.collapsedFrame(side: .right, y: 10_000, screenFrame: screen, visibleFrame: visible)
        let bottom = DesktopWidgetController.collapsedFrame(side: .right, y: -10_000, screenFrame: screen, visibleFrame: visible)
        precondition(top.maxY == visible.maxY - 14, "Dragging must stay below the menu bar")
        precondition(bottom.minY == visible.minY + 14, "Dragging must stay above the bottom Dock")
        let fraction = DesktopWidgetController.fraction(of: right.minY, height: right.height, in: visible)
        let restoredY = visible.minY + CGFloat(fraction) * (visible.height - right.height)
        precondition(abs(restoredY - right.minY) < 0.001, "Restoring position must not move the tab")

        let bounds = CGRect(origin: .zero, size: DesktopWidgetController.collapsedSize)
        let leftPath = WidgetEdgeTabShape(side: .left).path(in: bounds)
        let rightPath = WidgetEdgeTabShape(side: .right).path(in: bounds)
        precondition(leftPath.contains(CGPoint(x: 0.5, y: 0.5)), "Screen-facing left corners must be square")
        precondition(!leftPath.contains(CGPoint(x: 29.5, y: 0.5)), "Inward right corners must be rounded")
        precondition(rightPath.contains(CGPoint(x: 29.5, y: 0.5)), "Screen-facing right corners must be square")
        precondition(!rightPath.contains(CGPoint(x: 0.5, y: 0.5)), "Inward left corners must be rounded")

        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 200, width: 30, height: 64), styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = WidgetEdgeTabMouseView(frame: NSRect(origin: .zero, size: panel.frame.size))
        panel.contentView = view
        var clicks = 0
        var starts: [NSPoint] = []
        var changes: [NSPoint] = []
        var ends = 0
        view.onClick = { clicks += 1 }
        view.onDragBegan = { starts.append($0) }
        view.onDragChanged = { point in
            changes.append(point)
            // Reproduce a window following the pointer during event delivery.
            panel.setFrameOrigin(NSPoint(x: 100, y: point.y - 20))
        }
        view.onDragEnded = { ends += 1 }

        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = NSPoint(x: 115, y: 220)
        view.mouseDown(with: event(.leftMouseDown, at: start))
        view.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: 116, y: 221)))
        view.mouseUp(with: event(.leftMouseUp, at: start))
        precondition(clicks == 1 && starts.isEmpty, "Small pointer jitter must remain a click")

        view.mouseDown(with: event(.leftMouseDown, at: start))
        let first = NSPoint(x: 115, y: 260)
        let second = NSPoint(x: 115, y: 300)
        view.mouseDragged(with: event(.leftMouseDragged, at: first))
        view.mouseDragged(with: event(.leftMouseDragged, at: second))
        view.mouseUp(with: event(.leftMouseUp, at: second))
        precondition(starts == [start] && ends == 1, "Drag must begin and end exactly once")
        precondition(changes == [first, second, second], "Moving the window must not change screen-space drag coordinates")
        precondition(clicks == 1, "Releasing after a drag must not expand the panel")

        view.mouseDown(with: event(.leftMouseDown, at: second))
        view.mouseUp(with: event(.leftMouseUp, at: second))
        precondition(clicks == 2, "Clicking after a drag must still work")
        panel.close()
        print("PASS: edge placement, vertical bounds, saved position, mirrored corners, click/drag separation, moving-window coordinates")
    }
}
