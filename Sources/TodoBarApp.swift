import SwiftUI
import Foundation
import AppKit
import Combine
import Carbon
import UserNotifications

enum AppLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "English"
        }
    }

    var shortName: String {
        switch self {
        case .chinese: return "中"
        case .english: return "EN"
        }
    }

    var locale: Locale {
        switch self {
        case .chinese: return Locale(identifier: "zh_Hans_CN")
        case .english: return Locale(identifier: "en_US")
        }
    }
}

final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "TodoBar.language")
        }
    }

    private init() {
        let storedValue = UserDefaults.standard.string(forKey: "TodoBar.language")
        language = AppLanguage(rawValue: storedValue ?? "") ?? .chinese
    }

    func text(_ chinese: String, _ english: String) -> String {
        language == .english ? english : chinese
    }
}

// MARK: - 玻璃材质（macOS 亚克力/毛玻璃观感）

/// 桥接 NSVisualEffectView，对窗口背后的桌面内容做实时模糊采样
struct GlassEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        if cornerRadius > 0 {
            let layer = CALayer()
            layer.cornerRadius = cornerRadius
            layer.masksToBounds = true
            view.layer = layer
        }
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// 统一玻璃面板外观：实时模糊底 + 顶部高光渐变 + 玻璃描边
private struct GlassSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat
    var usesLiveBlur: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                ZStack(alignment: .top) {
                    if usesLiveBlur {
                        GlassEffectView()
                    } else {
                        Rectangle().fill(.ultraThinMaterial)
                    }
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 92)
                    .frame(maxWidth: .infinity)
                }
            }
            .clipShape(shape)
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.42), Color.white.opacity(0.07), Color.white.opacity(0.2)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat, usesLiveBlur: Bool = true) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, usesLiveBlur: usesLiveBlur))
    }
}

// MARK: - 桌面常驻小组件

enum WidgetSide: String {
    case left
    case right
}

/// 无边框、不抢焦点的玻璃面板；App 未激活时也能成为 key，面板内可以直接输入文字
final class WidgetPanel: NSPanel {
    /// The display this panel belongs to. Keeping this on the window avoids
    /// guessing from its frame while it is being moved between displays.
    var displayID: UInt32?

    override var canBecomeKey: Bool { true }
}

@MainActor
final class DesktopWidgetController: NSObject, ObservableObject {
    static let expandedSize = NSSize(width: 360, height: 460)
    static let collapsedSize = NSSize(width: 30, height: 64)

    private static let enabledKey = "TodoBar.widget.enabled"
    private static let expandedKey = "TodoBar.widget.expanded"
    private static let expandedDisplayKey = "TodoBar.widget.expandedDisplay"
    private static let displayModeKey = "TodoBar.widget.display"
    private static let sideKey = "TodoBar.widget.side"
    private static let yFractionKey = "TodoBar.widget.yFraction"
    private static let yFractionsKey = "TodoBar.widget.yFractions"
    private static let legacyFrameKey = "TodoBar.widget.frame"

    enum DisplayMode: String {
        case mainDisplay = "main"
        case allDisplays = "all"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isExpanded: Bool
    @Published private(set) var displayMode: DisplayMode

    var currentSide: WidgetSide { side }

    /// 每块屏幕一个面板，key 为显示器 ID。
    private var panels: [UInt32: WidgetPanel] = [:]
    /// 逻辑位置：贴靠的侧边由设置决定，垂直方向的位置按屏幕独立保存。
    @Published private var side: WidgetSide
    private var yFractions: [UInt32: Double]
    private var expandedPanelIDs: Set<UInt32> = []
    private var preferredExpandedDisplayID: UInt32?
    private var draggingPanelID: UInt32?
    private var dragStartMouseY: CGFloat = 0
    private var dragStartOriginY: CGFloat = 0
    private var isDragging = false
    private var mirrorTimer: Timer?
    private let taskStore: TaskStore

    init(taskStore: TaskStore) {
        self.taskStore = taskStore
        let defaults = UserDefaults.standard
        _isEnabled = Published(initialValue: defaults.bool(forKey: Self.enabledKey))
        _isExpanded = Published(initialValue: defaults.object(forKey: Self.expandedKey) as? Bool ?? true)
        _displayMode = Published(initialValue: DisplayMode(rawValue: defaults.string(forKey: Self.displayModeKey) ?? "") ?? .mainDisplay)
        preferredExpandedDisplayID = defaults.object(forKey: Self.expandedDisplayKey) as? UInt32

        // 迁移旧版单面板坐标；没有记录时默认右上角
        var parsedSide: WidgetSide?
        if let raw = defaults.string(forKey: Self.sideKey) {
            parsedSide = WidgetSide(rawValue: raw)
        }
        var parsedFraction: Double?
        if let value = defaults.object(forKey: Self.yFractionKey) as? Double {
            parsedFraction = value
        }
        if parsedSide == nil || parsedFraction == nil,
           let legacy = Self.legacySavedFrame(),
           let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(legacy) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if parsedSide == nil {
                parsedSide = Self.nearestSide(of: legacy, in: visible)
            }
            if parsedFraction == nil {
                parsedFraction = Self.fraction(of: legacy.origin.y, height: legacy.height, in: visible)
            }
        }
        side = parsedSide ?? .right
        if let saved = defaults.dictionary(forKey: Self.yFractionsKey) {
            yFractions = saved.reduce(into: [:]) { result, entry in
                if let id = UInt32(entry.key), let fraction = entry.value as? Double {
                    result[id] = fraction
                }
            }
        } else {
            yFractions = [:]
        }
        // Keep the old single-screen setting as a fallback for existing installs.
        if let parsedFraction, yFractions[0] == nil {
            // A zero key is a legacy fallback; real display IDs replace it as
            // soon as a panel is laid out or dragged.
            yFractions[0] = parsedFraction
        }

        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func restoreIfNeeded() {
        guard isEnabled else { return }
        rebuildPanels()
        applyLayout(animated: false)
        panels.values.forEach {
            $0.orderFrontRegardless()
            $0.invalidateShadow()
        }
    }

    func toggleEnabled() {
        setEnabled(!isEnabled)
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        finishDragging()
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            rebuildPanels()
            applyLayout(animated: false)
            panels.values.forEach {
                $0.orderFrontRegardless()
                $0.invalidateShadow()
            }
        } else {
            panels.values.forEach { $0.orderOut(nil) }
        }
    }

    /// 设置项：仅在主屏幕显示 / 每块屏幕都显示
    func setDisplayMode(_ mode: DisplayMode) {
        guard displayMode != mode else { return }
        finishDragging()
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.displayModeKey)
        guard isEnabled else { return }
        rebuildPanels()
        applyLayout(animated: false)
        panels.values.forEach { $0.orderFrontRegardless() }
    }

    func toggleExpanded() {
        let target = panelUnderMouse() ?? panels.values.first { $0.isVisible }
        if let target, let id = target.displayID {
            setExpanded(!isExpanded(for: id), for: id)
        } else {
            setExpanded(!isExpanded)
        }
    }

    func setExpanded(_ expanded: Bool) {
        let target = panelUnderMouse() ?? panels.values.first { $0.isVisible }
        if let target, let id = target.displayID {
            setExpanded(expanded, for: id)
            return
        }
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        UserDefaults.standard.set(expanded, forKey: Self.expandedKey)
        applyLayout(animated: true)
    }

    func isExpanded(for displayID: UInt32) -> Bool {
        expandedPanelIDs.contains(displayID)
    }

    func setExpanded(_ expanded: Bool, for displayID: UInt32) {
        if draggingPanelID == displayID { finishDragging() }
        if expanded {
            // Expand only the panel that was clicked. Other displays keep their
            // own state instead of being opened as a side effect.
            expandedPanelIDs.insert(displayID)
            preferredExpandedDisplayID = displayID
            UserDefaults.standard.set(displayID, forKey: Self.expandedDisplayKey)
        } else {
            expandedPanelIDs.remove(displayID)
        }
        isExpanded = !expandedPanelIDs.isEmpty
        UserDefaults.standard.set(isExpanded, forKey: Self.expandedKey)
        applyLayout(animated: true)
    }

    /// 让面板在 App 未激活时也能接收键盘输入（面板内新建/编辑待办）
    func focusPanel() {
        let target = panelUnderMouse() ?? panels.values.first { $0.isVisible }
        target?.makeKeyAndOrderFront(nil)
    }

    func focusPanel(on displayID: UInt32) {
        (panels[displayID] ?? panelUnderMouse())?.makeKeyAndOrderFront(nil)
    }

    /// 菜单栏「打开面板」：始终展开并显示
    func expandFromStatusBar() {
        guard isEnabled else { return }
        if panels.isEmpty {
            rebuildPanels()
        }
        let target = panelUnderMouse() ?? panels.values.first { $0.isVisible }
        if let target, let id = target.displayID {
            setExpanded(true, for: id)
            target.orderFrontRegardless()
        }
    }

    /// 菜单栏左键点按：展开 ⇄ 收纳成侧边标签
    func toggleFromStatusBar() {
        guard isEnabled else { return }
        let target = panelUnderMouse() ?? panels.values.first { $0.isVisible }
        guard let target, let id = target.displayID else { return }
        setExpanded(!isExpanded(for: id), for: id)
        target.orderFrontRegardless()
    }

    func snap(to side: WidgetSide) {
        finishDragging()
        self.side = side
        persistPosition()
        applyLayout(animated: true)
    }

    /// Use screen coordinates so moving the window cannot feed back into the gesture.
    func beginDragging(on displayID: UInt32, at mouse: NSPoint) {
        guard let target = panels[displayID], !isExpanded(for: displayID) else { return }
        mirrorTimer?.invalidate()
        draggingPanelID = displayID
        dragStartMouseY = mouse.y
        dragStartOriginY = target.frame.minY
        isDragging = true
    }

    func drag(to mouse: NSPoint) {
        guard isDragging,
              let target = draggingPanelID.flatMap({ panels[$0] }),
              let screen = screenForPanel(target) else { return }
        let y = dragStartOriginY + mouse.y - dragStartMouseY
        let frame = Self.collapsedFrame(side: side, y: y, screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        target.setFrameOrigin(frame.origin)
    }

    func finishDragging() {
        guard isDragging else { return }
        mirrorTimer?.invalidate()
        if let target = draggingPanelID.flatMap({ panels[$0] }) {
            recordPosition(from: target.frame, screen: screenForPanel(target))
            target.invalidateShadow()
        }
        isDragging = false
        draggingPanelID = nil
        persistPosition()
    }

    // MARK: Private

    private func rebuildPanels() {
        let desired = desiredDisplayIDs()
        for (id, panel) in panels where !desired.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for id in desired where panels[id] == nil {
            panels[id] = makePanel(displayID: id)
        }
        expandedPanelIDs.formIntersection(desired)
        if expandedPanelIDs.isEmpty, isExpanded, let preferredID = preferredDisplayID(in: desired) {
            expandedPanelIDs = [preferredID]
        }
        isExpanded = !expandedPanelIDs.isEmpty
    }

    private func desiredDisplayIDs() -> Set<UInt32> {
        let screens = displayMode == .allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        return Set(screens.compactMap(Self.displayID(of:)))
    }

    private func applyLayout(animated: Bool) {
        guard !isDragging else { return }
        for (_, panel) in panels {
            guard let screen = screenForPanel(panel) else { continue }
            let expanded = panel.displayID.map { isExpanded(for: $0) } ?? isExpanded
            let size = expanded ? Self.expandedSize : Self.collapsedSize
            let visible = screen.visibleFrame
            let fraction = yFractions[panel.displayID ?? 0] ?? yFractions[0] ?? 1
            let y = visible.minY + CGFloat(fraction) * max(visible.height - size.height, 0)
            let target = expanded
                ? Self.frame(size: size, side: side, y: y, in: visible)
                : Self.collapsedFrame(side: side, y: y, screenFrame: screen.frame, visibleFrame: visible)
            panel.hasShadow = expanded
            if abs(panel.frame.origin.x - target.origin.x) > 0.5
                || abs(panel.frame.origin.y - target.origin.y) > 0.5
                || abs(panel.frame.width - target.width) > 0.5
                || abs(panel.frame.height - target.height) > 0.5 {
                panel.setFrame(target, display: true, animate: animated)
            }
        }
        panels.values.forEach { $0.invalidateShadow() }
    }

    private func makePanel(displayID: UInt32) -> WidgetPanel {
        let panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.displayID = displayID
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Keep the expanded panel anchored to the configured edge. The
        // collapsed edge tab provides the dedicated vertical drag gesture.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let hosting = NSHostingView(rootView: WidgetHostRootView(store: taskStore, controller: self, panelID: displayID))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private func panelUnderMouse() -> WidgetPanel? {
        let mouse = NSEvent.mouseLocation
        if let panel = panels.values.first(where: { $0.isVisible && $0.frame.contains(mouse) }) {
            return panel
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
           let id = Self.displayID(of: screen),
           let panel = panels[id], panel.isVisible {
            return panel
        }
        return panels.values.first { $0.isVisible }
    }

    private func recordPosition(from frame: NSRect, screen: NSScreen?) {
        guard let screen else { return }
        let visible = screen.visibleFrame
        let id = Self.displayID(of: screen) ?? draggingPanelID ?? 0
        yFractions[id] = Self.fraction(of: frame.origin.y, height: frame.height, in: visible)
    }

    private func persistPosition() {
        UserDefaults.standard.set(side.rawValue, forKey: Self.sideKey)
        let encoded = yFractions.reduce(into: [String: Double]()) { result, entry in
            result[String(entry.key)] = entry.value
        }
        UserDefaults.standard.set(encoded, forKey: Self.yFractionsKey)
        // Keep this for older builds that only know one vertical position.
        UserDefaults.standard.set(yFractions.values.first ?? 1, forKey: Self.yFractionKey)
    }

    private static func legacySavedFrame() -> NSRect? {
        let raw = UserDefaults.standard.string(forKey: legacyFrameKey) ?? ""
        let rect = NSRectFromString(raw)
        return rect.isEmpty ? nil : rect
    }

    private static func displayID(of screen: NSScreen) -> UInt32? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }

    private func screenHosting(_ rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.intersects(rect) } ?? NSScreen.main
    }

    private func screenForPanel(_ panel: WidgetPanel) -> NSScreen? {
        if let id = panel.displayID,
           let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == id }) {
            return screen
        }
        return panel.screen ?? screenHosting(panel.frame)
    }

    private func preferredDisplayID(in ids: Set<UInt32>) -> UInt32? {
        if let preferredExpandedDisplayID, ids.contains(preferredExpandedDisplayID) {
            return preferredExpandedDisplayID
        }
        if let mainID = NSScreen.main.flatMap(Self.displayID(of:)), ids.contains(mainID) { return mainID }
        return ids.first
    }

    @objc private func screensChanged() {
        guard isEnabled else { return }
        finishDragging()
        rebuildPanels()
        applyLayout(animated: false)
        panels.values.forEach { $0.orderFrontRegardless() }
    }

    static func nearestSide(of frame: NSRect, in visible: NSRect) -> WidgetSide {
        frame.midX < visible.midX ? .left : .right
    }

    static func fraction(of y: CGFloat, height: CGFloat, in visible: NSRect) -> Double {
        let span = max(visible.height - height, 1)
        return Double(min(max((y - visible.minY) / span, 0), 1))
    }

    static func frame(size: NSSize, side: WidgetSide, y: CGFloat, in visible: NSRect, margin: CGFloat = 14) -> NSRect {
        let x = side == .left ? visible.minX + margin : visible.maxX - margin - size.width
        let clampedY = min(max(y, visible.minY + margin), visible.maxY - margin - size.height)
        return NSRect(origin: CGPoint(x: x, y: clampedY), size: size)
    }

    static func collapsedFrame(side: WidgetSide, y: CGFloat, screenFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        var result = frame(size: collapsedSize, side: side, y: y, in: visibleFrame)
        // Dock placement must not leave a gap between the tab and the physical screen edge.
        result.origin.x = side == .left ? screenFrame.minX : screenFrame.maxX - collapsedSize.width
        return result
    }
}

extension DesktopWidgetController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard !isDragging,
              let window = notification.object as? WidgetPanel,
              panels.contains(where: { $0.value === window }) else { return }
        recordPosition(from: window.frame, screen: screenForPanel(window))
        persistPosition()
        scheduleMirror()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        applyLayout(animated: false)
        persistPosition()
    }

    /// 拖动停止后把逻辑位置镜像到其余屏幕（用防抖避免拖动过程中反复同步）
    private func scheduleMirror() {
        mirrorTimer?.invalidate()
        mirrorTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyLayout(animated: false)
            }
        }
    }
}

/// 小组件的宿主视图，把 taskStore 注入 SwiftUI 环境
private struct WidgetHostRootView: View {
    let store: TaskStore
    let controller: DesktopWidgetController
    let panelID: UInt32

    var body: some View {
        DesktopWidgetRootView(controller: controller, panelID: panelID)
            .environmentObject(store)
    }
}

struct DesktopWidgetRootView: View {
    @ObservedObject var controller: DesktopWidgetController
    let panelID: UInt32
    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        Group {
            if controller.isExpanded(for: panelID) {
                TodoPanelView(widget: controller, panelID: panelID, showsWidgetControls: true)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                WidgetCollapsedBadge(controller: controller, panelID: panelID)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: controller.isExpanded(for: panelID))
        .contextMenu { widgetContextMenu }
    }

    @ViewBuilder
    private var widgetContextMenu: some View {
        Button(controller.isExpanded(for: panelID) ? t("收纳为侧边标签", "Collapse to edge tab") : t("展开面板", "Expand panel")) {
            controller.setExpanded(!controller.isExpanded(for: panelID), for: panelID)
        }

        Divider()

        Button(t("贴靠到屏幕左侧", "Snap to left edge")) { controller.snap(to: .left) }
        Button(t("贴靠到屏幕右侧", "Snap to right edge")) { controller.snap(to: .right) }

        Divider()

        Button(role: .destructive) {
            controller.setEnabled(false)
        } label: {
            Label(t("关闭桌面常驻", "Turn off desktop widget"), systemImage: "pin.slash")
        }
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}

/// 收纳后的贴边标签：点击展开，按住拖动换位置
struct WidgetCollapsedBadge: View {
    @ObservedObject var controller: DesktopWidgetController
    let panelID: UInt32
    @EnvironmentObject private var taskStore: TaskStore
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @State private var isHovering = false

    var body: some View {
        let shape = WidgetEdgeTabShape(side: controller.currentSide)
        ZStack {
            GlassEffectView()
            Color.primary.opacity(isHovering ? 0.08 : 0.025)

            if taskStore.remainingCount == 0 {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "checklist")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(taskStore.remainingCount > 99 ? "99+" : "\(taskStore.remainingCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.75))
                        .monospacedDigit()
                }
            }
        }
        .frame(width: DesktopWidgetController.collapsedSize.width, height: DesktopWidgetController.collapsedSize.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .overlay {
            WidgetEdgeTabInteraction(controller: controller, panelID: panelID)
                .clipShape(shape)
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .help(t("点击展开 TodoBar，上下拖动调整位置", "Click to expand TodoBar; drag vertically to reposition"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("TodoBar 侧边标签，\(taskStore.remainingCount) 项待办", "TodoBar edge tab, \(taskStore.remainingCount) tasks remaining"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { controller.setExpanded(true, for: panelID) }
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}

struct WidgetEdgeTabShape: InsettableShape {
    let side: WidgetSide
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = max(0, min(12 - insetAmount, rect.width / 2, rect.height / 2))
        let leftRadius: CGFloat = side == .right ? radius : 0
        let rightRadius: CGFloat = side == .left ? radius : 0
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + leftRadius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - rightRadius, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rightRadius), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rightRadius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - rightRadius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + leftRadius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - leftRadius), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + leftRadius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + leftRadius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
        }
    }

    func inset(by amount: CGFloat) -> WidgetEdgeTabShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

private struct WidgetEdgeTabInteraction: NSViewRepresentable {
    let controller: DesktopWidgetController
    let panelID: UInt32

    func makeNSView(context: Context) -> WidgetEdgeTabMouseView {
        let view = WidgetEdgeTabMouseView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WidgetEdgeTabMouseView, context: Context) {
        view.onDragBegan = { [weak controller] mouse in controller?.beginDragging(on: panelID, at: mouse) }
        view.onDragChanged = { [weak controller] mouse in controller?.drag(to: mouse) }
        view.onDragEnded = { [weak controller] in controller?.finishDragging() }
        view.onClick = { [weak controller] in controller?.setExpanded(true, for: panelID) }
    }
}

private final class WidgetEdgeTabMouseView: NSView {
    var onDragBegan: (NSPoint) -> Void = { _ in }
    var onDragChanged: (NSPoint) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onClick: () -> Void = {}
    private var mouseDownPoint: NSPoint?
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = screenLocation(for: event)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let mouse = screenLocation(for: event)
        if !isDragging {
            guard hypot(mouse.x - start.x, mouse.y - start.y) >= 3 else { return }
            isDragging = true
            onDragBegan(start)
        }
        onDragChanged(mouse)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        let wasDragging = isDragging
        mouseDownPoint = nil
        isDragging = false
        if wasDragging {
            onDragChanged(screenLocation(for: event))
            onDragEnded()
        } else {
            onClick()
        }
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }
}

@main
final class TodoBarMain: NSObject, NSApplicationDelegate {
    private var model: TodoBarModel?

    static func main() {
        let app = NSApplication.shared
        let delegate = TodoBarMain()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = TodoBarModel()
        self.model = model
        model.statusBarController.start()
    }
}

struct ReminderTime: Codable, Equatable, Identifiable {
    let id: UUID
    var minuteOfDay: Int

    init(id: UUID = UUID(), minuteOfDay: Int) {
        self.id = id
        self.minuteOfDay = minuteOfDay
    }

    func date(on day: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60, second: 0, of: day) ?? day
    }
}

final class ReminderSettings: ObservableObject {
    private let defaults: UserDefaults
    private static let timesKey = "TodoBar.reminders.times"
    private static let enabledKey = "TodoBar.reminders.enabled"

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var times: [ReminderTime]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        let saved = defaults.data(forKey: Self.timesKey)
            .flatMap { try? JSONDecoder().decode([ReminderTime].self, from: $0) } ?? []
        var minutes = Set<Int>()
        var ids = Set<UUID>()
        let valid = saved.filter {
            (0..<1440).contains($0.minuteOfDay) && minutes.insert($0.minuteOfDay).inserted && ids.insert($0.id).inserted
        }.sorted { $0.minuteOfDay < $1.minuteOfDay }
        times = valid.isEmpty ? [ReminderTime(minuteOfDay: 900), ReminderTime(minuteOfDay: 1260)] : valid
    }

    @discardableResult
    func update(id: UUID, minuteOfDay: Int) -> Bool {
        guard (0..<1440).contains(minuteOfDay),
              let index = times.firstIndex(where: { $0.id == id }),
              !times.contains(where: { $0.id != id && $0.minuteOfDay == minuteOfDay }) else { return false }
        var updated = times
        updated[index].minuteOfDay = minuteOfDay
        save(updated)
        return true
    }

    func addTime() {
        let used = Set(times.map(\.minuteOfDay))
        let start = ((times.last?.minuteOfDay ?? 840) + 60) % 1440
        guard let minute = (0..<1440).map({ (start + $0) % 1440 }).first(where: { !used.contains($0) }) else { return }
        save(times + [ReminderTime(minuteOfDay: minute)])
    }

    func remove(id: UUID) {
        guard times.count > 1 else { return }
        save(times.filter { $0.id != id })
    }

    private func save(_ updated: [ReminderTime]) {
        times = updated.sorted { $0.minuteOfDay < $1.minuteOfDay }
        if let data = try? JSONEncoder().encode(times) {
            defaults.set(data, forKey: Self.timesKey)
        }
    }
}

enum ReminderSchedule {
    static func dueTimes(_ times: [ReminderTime], at now: Date, calendar: Calendar = .current) -> [ReminderTime] {
        times.filter { $0.date(on: now, calendar: calendar) <= now }
            .sorted { $0.minuteOfDay < $1.minuteOfDay }
    }

    static func nextDate(_ times: [ReminderTime], after now: Date, calendar: Calendar = .current) -> Date? {
        times.compactMap { time in
            calendar.nextDate(
                after: now,
                matching: DateComponents(hour: time.minuteOfDay / 60, minute: time.minuteOfDay % 60, second: 0),
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first
            )
        }.min()
    }

    static func dayKey(at now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: now)
        return "\(parts.era ?? 0)-\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}

@MainActor
final class SettingsWindowController {
    private let widget: DesktopWidgetController
    private let reminders: ReminderSettings
    private var window: NSWindow?

    init(widget: DesktopWidgetController, reminders: ReminderSettings) {
        self.widget = widget
        self.reminders = reminders
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 700),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "TodoBar"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: TodoBarSettingsView(widget: widget, reminders: reminders))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct BlueSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack {
                Capsule().fill(configuration.isOn ? Color.blue : Color.primary.opacity(0.18))
                Circle().fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    .offset(x: configuration.isOn ? 8 : -8)
            }
            .frame(width: 36, height: 20)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

private final class ReminderTimeSegmentField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        selectText(nil)
    }
}

/// Separate editable segments give predictable HH -> mm keyboard navigation.
final class ReminderTimeControl: NSView, NSTextFieldDelegate {
    let hourField: NSTextField = ReminderTimeSegmentField()
    let minuteField: NSTextField = ReminderTimeSegmentField()
    private(set) var minuteOfDay = 0
    var onChange: (Int) -> Bool = { _ in true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for field in [hourField, minuteField] {
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.alignment = .center
            field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            field.delegate = self
            addSubview(field)
        }
        hourField.frame = NSRect(x: 7, y: 4, width: 25, height: 18)
        minuteField.frame = NSRect(x: 40, y: 4, width: 25, height: 18)
        hourField.nextKeyView = minuteField
        displayValue()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 72, height: 26) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        (":" as NSString).draw(at: NSPoint(x: 33, y: 5), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
        ])
    }

    func update(minuteOfDay: Int, isEnabled: Bool) {
        hourField.isEnabled = isEnabled
        minuteField.isEnabled = isEnabled
        // SwiftUI updates must not overwrite a partially entered segment.
        guard hourField.currentEditor() == nil && minuteField.currentEditor() == nil else { return }
        self.minuteOfDay = minuteOfDay
        displayValue()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        (notification.object as? NSTextField)?.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let digits = String(field.stringValue.filter { $0 >= "0" && $0 <= "9" }.prefix(2))
        if field.stringValue != digits { field.stringValue = digits }
        guard digits.count == 2, let number = Int(digits) else { return }
        if field === hourField && number < 24 {
            window?.makeFirstResponder(minuteField)
            minuteField.selectText(nil)
        } else if field === minuteField && number < 60 {
            commit()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Moving between segments is not a submission of the intermediate time.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hourField.currentEditor() == nil && self.minuteField.currentEditor() == nil else { return }
            self.commit()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commit()
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            displayValue()
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private func commit() {
        guard let hour = Int(hourField.stringValue), (0..<24).contains(hour),
              let minute = Int(minuteField.stringValue), (0..<60).contains(minute) else {
            displayValue()
            return
        }
        let value = hour * 60 + minute
        if value != minuteOfDay && onChange(value) { minuteOfDay = value }
        displayValue()
    }

    private func displayValue() {
        hourField.stringValue = String(format: "%02d", minuteOfDay / 60)
        minuteField.stringValue = String(format: "%02d", minuteOfDay % 60)
    }
}

struct ReminderTimeInput: NSViewRepresentable {
    let minuteOfDay: Int
    let onChange: (Int) -> Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> ReminderTimeControl { ReminderTimeControl(frame: .zero) }

    func updateNSView(_ view: ReminderTimeControl, context: Context) {
        view.onChange = onChange
        view.hourField.setAccessibilityLabel(LanguageSettings.shared.text("提醒小时，24 小时制", "Reminder hour, 24-hour time"))
        view.minuteField.setAccessibilityLabel(LanguageSettings.shared.text("提醒分钟", "Reminder minute"))
        view.update(minuteOfDay: minuteOfDay, isEnabled: isEnabled)
    }
}

struct TodoBarSettingsView: View {
    @ObservedObject var widget: DesktopWidgetController
    @ObservedObject var reminders: ReminderSettings
    @ObservedObject private var language = LanguageSettings.shared
    @State private var duplicateTime = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(t("设置", "Settings"))
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                    Text(t("按你的节奏，安排每一天。", "Make room for your daily rhythm."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                section(t("待办提醒", "Daily reminders")) {
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(t("今日待办清单", "Today's to-do list")).fontWeight(.medium)
                                Text(reminders.isEnabled
                                     ? t("每天提醒 \(reminders.times.count) 次", "\(reminders.times.count) reminders per day")
                                     : t("已暂停提醒，时间设置会保留", "Paused. Your times are saved."))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(t("开启提醒", "Enable reminders"), isOn: $reminders.isEnabled)
                                .labelsHidden().toggleStyle(BlueSwitchStyle())
                        }
                        .padding(14)
                        Divider().padding(.horizontal, 14)
                        VStack(spacing: 9) {
                            ForEach(Array(reminders.times.enumerated()), id: \.element.id) { index, time in
                                HStack {
                                    Text(t("第 \(index + 1) 次", "Reminder \(index + 1)"))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    ReminderTimeInput(minuteOfDay: time.minuteOfDay) { minute in
                                        let accepted = reminders.update(id: time.id, minuteOfDay: minute)
                                        duplicateTime = !accepted
                                        return accepted
                                    }
                                    .frame(width: 72, height: 26)
                                    Button { reminders.remove(id: time.id) } label: {
                                        Image(systemName: "minus").font(.system(size: 11, weight: .medium))
                                            .frame(width: 26, height: 26).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .disabled(reminders.times.count == 1)
                                    .help(t("移除此时间", "Remove this time"))
                                    .accessibilityLabel(t("移除此提醒时间", "Remove reminder time"))
                                }
                            }
                            HStack {
                                Button { reminders.addTime() } label: {
                                    Label(t("添加提醒时间", "Add reminder time"), systemImage: "plus")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain).disabled(reminders.times.count == 1440)
                                Spacer()
                            }
                            .padding(.top, 3)
                        }
                        .padding(14)
                        .disabled(!reminders.isEnabled)
                        .opacity(reminders.isEnabled ? 1 : 0.45)
                    }
                }
                Text(t("仅提醒今天到期且未完成的事项；没有待办时不打扰。请保持 TodoBar 运行。", "Only unfinished tasks due today appear. No tasks, no interruption. Keep TodoBar running."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.top, -14)

                section(t("桌面小组件", "Desktop widget")) {
                    VStack(spacing: 14) {
                        HStack {
                            Text(t("常驻桌面", "Pin to desktop"))
                            Spacer()
                            Toggle(t("常驻桌面", "Pin to desktop"), isOn: Binding(get: { widget.isEnabled }, set: { widget.setEnabled($0) }))
                                .labelsHidden().toggleStyle(BlueSwitchStyle())
                        }
                        Divider()
                        HStack {
                            Text(t("显示屏幕", "Displays"))
                            Spacer()
                            Picker(t("显示屏幕", "Displays"), selection: Binding(get: { widget.displayMode }, set: { widget.setDisplayMode($0) })) {
                                Text(t("仅主屏幕", "Main display")).tag(DesktopWidgetController.DisplayMode.mainDisplay)
                                Text(t("所有屏幕", "All displays")).tag(DesktopWidgetController.DisplayMode.allDisplays)
                            }
                            .labelsHidden().frame(width: 165)
                        }
                        .disabled(!widget.isEnabled)
                        HStack {
                            Text(t("停靠侧边", "Dock side"))
                            Spacer()
                            Picker(t("停靠侧边", "Dock side"), selection: Binding(get: { widget.currentSide }, set: { widget.snap(to: $0) })) {
                                Text(t("左侧", "Left")).tag(WidgetSide.left)
                                Text(t("右侧", "Right")).tag(WidgetSide.right)
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 165)
                        }
                        .disabled(!widget.isEnabled)
                    }
                    .padding(14)
                }

                section(t("通用", "General")) {
                    VStack(spacing: 14) {
                        HStack {
                            Text(t("界面语言", "Language"))
                            Spacer()
                            Picker(t("界面语言", "Language"), selection: $language.language) {
                                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden().frame(width: 165)
                        }
                        Divider()
                        HStack {
                            Text(t("快速新建", "Quick capture"))
                            Spacer()
                            Text("⌥ ⌘ T").foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                }
                Text(t("所有更改自动保存", "Changes are saved automatically"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(24)
        }
        .frame(width: 480, height: 700)
        .background { GlassEffectView(material: .sidebar) }
        .tint(.primary)
        .environment(\.locale, language.language.locale)
        .alert(t("这个时间已存在", "Time already added"), isPresented: $duplicateTime) {
            Button(t("知道了", "Got it"), role: .cancel) {}
        } message: {
            Text(t("请选择另一个时间，同一时间只提醒一次。", "Choose another time. Each time only needs one reminder."))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
                .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.03), lineWidth: 1) }
        }
    }

    private func t(_ chinese: String, _ english: String) -> String { language.text(chinese, english) }
}

@MainActor
final class TodoBarModel: ObservableObject {
    let taskStore: TaskStore
    let widgetController: DesktopWidgetController
    let statusBarController: StatusBarController
    private let services: TodoBarServices

    init() {
        let store = TaskStore()
        let reminders = ReminderSettings()
        self.taskStore = store
        self.widgetController = DesktopWidgetController(taskStore: store)
        self.statusBarController = StatusBarController(taskStore: store, widgetController: widgetController, reminders: reminders)
        self.services = TodoBarServices(reminders: reminders)
        self.services.configure(with: store)

        DispatchQueue.main.async { [weak self] in
            self?.widgetController.restoreIfNeeded()
        }
    }
}

// MARK: - 菜单栏状态图标（左键弹出面板，右键设置与退出）

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let taskStore: TaskStore
    private let widgetController: DesktopWidgetController
    private let settingsController: SettingsWindowController

    private var statusItem: NSStatusItem?
    private var panel: WidgetPanel?
    private var aboutPanel: WidgetPanel?
    private var eventMonitors: [Any] = []
    private var widgetSubscription: AnyCancellable?
    private let contextMenu = NSMenu()
    private var isShowingContextMenu = false

    init(taskStore: TaskStore, widgetController: DesktopWidgetController, reminders: ReminderSettings) {
        self.taskStore = taskStore
        self.widgetController = widgetController
        self.settingsController = SettingsWindowController(widget: widgetController, reminders: reminders)
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.action = #selector(handleStatusItemClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        contextMenu.delegate = self
        configureIcon()

        // 小组件开启时收起菜单面板，避免出现两个待办面板
        widgetSubscription = widgetController.$isEnabled.receive(on: DispatchQueue.main).sink { [weak self] enabled in
            if enabled {
                self?.hidePanel()
            }
        }
    }

    private func configureIcon() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "TodoBar")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        image?.isTemplate = true
        button.image = image
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = "TodoBar"
    }

    @objc private func handleStatusItemClick() {
        guard !isShowingContextMenu else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            openPanelAction()
        }
    }

    /// 左键：小组件开启时 展开⇄收纳，否则开合菜单面板
    private func openPanelAction() {
        if widgetController.isEnabled {
            widgetController.toggleFromStatusBar()
        } else {
            togglePanel()
        }
    }

    /// 右键「打开待办面板」：始终展开显示，避免出现两个待办面板
    private func revealPanelAction() {
        if widgetController.isEnabled {
            widgetController.expandFromStatusBar()
        } else {
            showPanel()
        }
    }

    private func togglePanel() {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
        installMonitorsIfNeeded()
    }

    private func showContextMenu() {
        hidePanel()
        guard let statusItem else { return }
        isShowingContextMenu = true
        defer { isShowingContextMenu = false }

        rebuildMenu()
        statusItem.menu = contextMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makePanel() -> WidgetPanel {
        let panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 360, height: 460)),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: MenuPanelHostView(store: taskStore, widgetController: widgetController))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private func makeAboutPanel() -> WidgetPanel {
        let panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 280, height: 244)),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: AboutView(onClose: { [weak panel] in
            panel?.orderOut(nil)
        }))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    /// 把面板放到状态图标正下方，越界时往屏幕内收
    private func positionPanel(_ panel: NSPanel) {        guard let button = statusItem?.button, let itemWindow = button.window else {
            panel.center()
            return
        }
        let itemFrame = itemWindow.convertToScreen(button.bounds)
        let size = panel.frame.size
        var origin = CGPoint(x: itemFrame.midX - size.width / 2, y: itemFrame.minY - 6 - size.height)
        if let screen = itemWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeMonitorsIfIdle()
    }

    private func removeMonitorsIfIdle() {
        if panel?.isVisible != true && aboutPanel?.isVisible != true {
            removeMonitors()
        }
    }

    private func installMonitorsIfNeeded() {
        guard eventMonitors.isEmpty else { return }
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hidePanelIfClickedOutside()
            }
        }
        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] event in
            self?.hidePanelIfClickedOutside()
            return event
        }
        eventMonitors = [globalMonitor, localMonitor].compactMap { $0 }
    }

    private func removeMonitors() {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors = []
    }

    private func hidePanelIfClickedOutside() {
        guard panel?.isVisible == true || aboutPanel?.isVisible == true else { return }
        let mouse = NSEvent.mouseLocation
        var itemFrame: NSRect?
        if let button = statusItem?.button, let window = button.window {
            itemFrame = window.convertToScreen(button.bounds)
        }

        for visiblePanel in [panel, aboutPanel].compactMap({ $0 }) where visiblePanel.isVisible {
            if visiblePanel.frame.contains(mouse) { continue }
            if InlineInteractionSession.containsPopupClick(for: visiblePanel, at: mouse) { continue }
            if let itemFrame, itemFrame.contains(mouse) { continue }
            visiblePanel.orderOut(nil)
        }
        removeMonitorsIfIdle()
    }

    // MARK: 右键菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        contextMenu.removeAllItems()

        let openItem = NSMenuItem(
            title: t("打开待办面板", "Open task panel"),
            action: #selector(openPanelFromMenu),
            keyEquivalent: ""
        )
        openItem.target = self
        contextMenu.addItem(openItem)

        contextMenu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: t("设置…", "Settings…"),
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        contextMenu.addItem(settingsItem)

        contextMenu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: t("关于 TodoBar", "About TodoBar"),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        contextMenu.addItem(aboutItem)

        contextMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: t("退出 TodoBar", "Quit TodoBar"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        contextMenu.addItem(quitItem)
    }

    @objc private func openPanelFromMenu() {
        revealPanelAction()
    }

    @objc private func showAbout() {
        let panel = self.aboutPanel ?? makeAboutPanel()
        self.aboutPanel = panel
        if panel.isVisible {
            panel.orderOut(nil)
            removeMonitorsIfIdle()
            return
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        installMonitorsIfNeeded()
    }

    @objc private func showSettings() {
        hidePanel()
        settingsController.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func t(_ chinese: String, _ english: String) -> String {
        LanguageSettings.shared.text(chinese, english)
    }
}

/// 菜单栏面板的宿主视图
private struct MenuPanelHostView: View {
    let store: TaskStore
    let widgetController: DesktopWidgetController

    var body: some View {
        TodoPanelView(widget: widgetController)
            .environmentObject(store)
    }
}

/// 关于窗口：应用信息 + 可点击跳转的仓库链接
struct AboutView: View {
    let onClose: () -> Void
    @ObservedObject private var languageSettings = LanguageSettings.shared

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }

    private var repoURL: URL {
        URL(string: "https://github.com/yueseqaz/todobar")!
    }

    var body: some View {
        VStack(spacing: 13) {
            HStack {
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(t("关闭", "Close"))
            }

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 62, height: 62)
                .shadow(color: .black.opacity(0.18), radius: 7, y: 3)

            VStack(spacing: 3) {
                Text("TodoBar")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(t("版本 \(version) · 本地优先的菜单栏待办", "Version \(version) · Local-first menu bar todos"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                NSWorkspace.shared.open(repoURL)
            } label: {
                Label(t("GitHub 仓库", "GitHub repository"), systemImage: "safari")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.blue.opacity(0.13), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.blue.opacity(0.35), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help(repoURL.absoluteString)

            Text(t("任务仅保存在本机 · ⌥⌘T 快速收集", "Tasks stay on this Mac · ⌥⌘T quick capture"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(width: 280, height: 244)
        .glassSurface(cornerRadius: 20)
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}

@MainActor
final class TodoBarServices {
    private weak var taskStore: TaskStore?
    private let hotKeyManager = GlobalHotKeyManager()
    private let quickCaptureController = QuickCaptureController()
    private let eveningReminderController: EveningReminderController

    init(reminders: ReminderSettings) {
        eveningReminderController = EveningReminderController(settings: reminders)
    }
    private var isConfigured = false

    func configure(with taskStore: TaskStore) {
        guard !isConfigured else { return }
        isConfigured = true
        self.taskStore = taskStore

        quickCaptureController.configure(with: taskStore)
        hotKeyManager.start {
            self.quickCaptureController.toggle()
        }

        LegacyNotificationCleaner.clearTodoBarNotifications()
        eveningReminderController.configure(with: taskStore)
        taskStore.onTasksChanged = { [weak self] tasks in
            self?.eveningReminderController.handleTaskChange(tasks)
        }
    }
}

private let todoBarHotKeyHandler: EventHandlerUPP = { _, _, _ in
    DispatchQueue.main.async {
        GlobalHotKeyManager.sharedAction?()
    }
    return noErr
}

final class GlobalHotKeyManager {
    static var sharedAction: (() -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    func start(action: @escaping () -> Void) {
        guard hotKeyRef == nil else { return }
        GlobalHotKeyManager.sharedAction = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            todoBarHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        guard handlerStatus == noErr else {
            NSLog("TodoBar: unable to install global hot key handler (\(handlerStatus))")
            return
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x54424B31), id: 1)
        let modifierFlags = UInt32(optionKey | cmdKey)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            NSLog("TodoBar: unable to register Option-Command-T (\(registerStatus))")
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}

@MainActor
final class QuickCaptureSession: ObservableObject {
    @Published var draft = InlineTaskDraft()
    @Published private(set) var isPresented = false
    @Published private(set) var generation = 0

    func present() {
        generation += 1
        isPresented = true
    }

    @discardableResult
    func dismiss(generation expected: Int? = nil) -> Bool {
        guard expected == nil || expected == generation else { return false }
        generation += 1
        isPresented = false
        return true
    }

    func takeSubmission(generation expected: Int) -> InlineTaskDraft? {
        guard isPresented, expected == generation, draft.canSubmit else { return nil }
        let submitted = draft
        draft = InlineTaskDraft()
        dismiss()
        return submitted
    }
}

private final class QuickCaptureFeedbackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickCaptureFeedbackController {
    private(set) var panel: NSPanel?
    private var dismissTimer: Timer?

    deinit { dismissTimer?.invalidate() }

    func show(title: String, near frame: NSRect) {
        hide()
        let panel = makePanel(title: title)
        self.panel = panel
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2))
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: LanguageSettings.shared.text("已添加：\(title)", "Added: \(title)"),
            .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
        dismissTimer = Timer(timeInterval: 1.1, repeats: false) { [weak self, weak panel] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, self.panel === panel else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
                    panel.animator().alphaValue = 0
                } completionHandler: { [weak self, weak panel] in
                    Task { @MainActor [weak self, weak panel] in
                        guard let self, let panel, self.panel === panel else { return }
                        self.hide()
                    }
                }
            }
        }
        if let dismissTimer { RunLoop.main.add(dismissTimer, forMode: .common) }
    }

    func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func makePanel(title: String) -> NSPanel {
        let panel = QuickCaptureFeedbackPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 48),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: QuickCaptureFeedbackView(title: title))
        return panel
    }
}

struct QuickCaptureFeedbackView: View {
    let title: String
    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        HStack(spacing: 9) {
            Text(languageSettings.text("已添加", "Added"))
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 280, height: 48)
        .glassSurface(cornerRadius: 12, usesLiveBlur: false)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
final class QuickCaptureController {
    private weak var taskStore: TaskStore?
    private var panel: NSPanel?
    let session = QuickCaptureSession()
    private let feedback = QuickCaptureFeedbackController()
    private let activateApp: @MainActor () -> Void

    init(panel: NSPanel? = nil, activateApp: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.panel = panel
        self.activateApp = activateApp
    }

    func configure(with taskStore: TaskStore) {
        self.taskStore = taskStore
    }

    func toggle() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            show()
        }
    }

    private func show() {
        guard taskStore != nil else { return }
        feedback.hide()
        if panel == nil {
            panel = makePanel()
        }

        guard let panel else { return }
        activateApp()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        session.present()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 388, height: 194),
            styleMask: [.titled, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: QuickCaptureView(
            session: session,
            onSave: { [weak self] generation in self?.save(generation: generation) },
            onDismiss: { [weak self] generation in self?.dismiss(generation: generation) }
        ))
        return panel
    }

    private func save(generation: Int) {
        guard let taskStore, let panel,
              let draft = session.takeSubmission(generation: generation) else { return }
        taskStore.add(title: draft.trimmedTitle, priority: draft.priority, dueDate: draft.schedule.dueDate())
        let frame = panel.frame
        panel.orderOut(nil)
        feedback.show(title: draft.trimmedTitle, near: frame)
    }

    private func dismiss(generation: Int? = nil) {
        guard session.dismiss(generation: generation) else { return }
        panel?.orderOut(nil)
    }
}

struct QuickCaptureView: View {
    @ObservedObject var session: QuickCaptureSession
    let onSave: (Int) -> Void
    let onDismiss: (Int) -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(t("快速记录", "Quick capture"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⌥⌘T")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            if session.isPresented {
                let generation = session.generation
                InlineTaskInput(
                    draft: $session.draft,
                    showsPlus: true,
                    submitTitle: t("添加", "Add"),
                    onActivate: {},
                    onSubmit: { onSave(generation); return false },
                    onEnd: { onDismiss(generation) }
                )
                .id(generation)
            }
        }
        .padding(16)
        .frame(width: 388)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}

private enum LegacyNotificationCleaner {
    private static let identifierPrefix = "local.todobar.reminder."

    static func clearTodoBarNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let identifiers = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(identifierPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }
}

/// Persist delivery per local day and time, not just once per day.
final class ReminderDeliveryHistory {
    private let defaults: UserDefaults
    private let key = "TodoBar.reminders.handledSlots"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    @discardableResult
    func consumeLatest(_ times: [ReminderTime], at now: Date, calendar: Calendar = .current) -> Bool {
        let due = ReminderSchedule.dueTimes(times, at: now, calendar: calendar)
        guard let latest = due.last else { return false }
        let prefix = ReminderSchedule.dayKey(at: now, calendar: calendar) + ":"
        var handled = Set((defaults.stringArray(forKey: key) ?? []).filter { $0.hasPrefix(prefix) })
        let shouldDeliver = !handled.contains(prefix + String(latest.minuteOfDay))
        // After sleep or launch, deliver only the latest missed slot, never a burst.
        due.forEach { handled.insert(prefix + String($0.minuteOfDay)) }
        defaults.set(handled.sorted(), forKey: key)
        return shouldDeliver
    }
}

@MainActor
final class EveningReminderController {
    private weak var taskStore: TaskStore?
    private let settings: ReminderSettings
    private let history: ReminderDeliveryHistory
    private var subscriptions = Set<AnyCancellable>()
    private var scheduleTimer: Timer?
    private var snoozeTimer: Timer?
    private var panel: NSPanel?

    var nextScheduledReminder: Date? {
        scheduleTimer?.isValid == true ? scheduleTimer?.fireDate : nil
    }

    deinit {
        scheduleTimer?.invalidate()
        snoozeTimer?.invalidate()
    }

    init(settings: ReminderSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.history = ReminderDeliveryHistory(defaults: defaults)
    }

    func configure(with taskStore: TaskStore) {
        guard self.taskStore == nil else { return }
        self.taskStore = taskStore
        Publishers.CombineLatest(settings.$times, settings.$isEnabled)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.snoozeTimer?.invalidate()
                self.dismiss()
                // Editing a past time does not immediately interrupt the user.
                if self.settings.isEnabled {
                    self.history.consumeLatest(self.settings.times, at: Date())
                }
                self.scheduleNextCheck()
            }
            .store(in: &subscriptions)

        let clockEvents = [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged]
        for name in clockEvents {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshSchedule() }
                .store(in: &subscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSchedule() }
            .store(in: &subscriptions)
        refreshSchedule()
    }

    func handleTaskChange(_ tasks: [TodoItem]) {
        guard panel?.isVisible == true else { return }
        let remainingTasks = dueTodayTasks(from: tasks)
        if remainingTasks.isEmpty {
            dismiss()
        } else {
            updatePanel(tasks: remainingTasks)
        }
    }

    private func refreshSchedule() {
        if let taskStore { handleTaskChange(taskStore.tasks) }
        presentReminderIfNeeded()
        scheduleNextCheck()
    }

    private func scheduleNextCheck(from now: Date = Date()) {
        scheduleTimer?.invalidate()
        guard settings.isEnabled,
              let target = ReminderSchedule.nextDate(settings.times, after: now) else { return }
        scheduleTimer = Timer(fire: target, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSchedule() }
        }
        if let scheduleTimer { RunLoop.main.add(scheduleTimer, forMode: .common) }
    }

    private func presentReminderIfNeeded() {
        guard settings.isEnabled, let taskStore,
              history.consumeLatest(settings.times, at: Date()) else { return }
        let tasks = dueTodayTasks(from: taskStore.tasks)
        guard !tasks.isEmpty else { return }
        snoozeTimer?.invalidate()
        show(tasks: tasks)
    }

    private func dueTodayTasks(from tasks: [TodoItem]) -> [TodoItem] {
        let calendar = Calendar.current
        return tasks.filter { item in
            guard !item.isCompleted, let dueDate = item.dueDate else { return false }
            return calendar.isDate(dueDate, inSameDayAs: Date())
        }
    }

    private func show(tasks: [TodoItem]) {
        if panel == nil {
            panel = makePanel()
        }

        updatePanel(tasks: tasks)
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 300),
            styleMask: [.titled, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        return panel
    }

    private func updatePanel(tasks: [TodoItem]) {
        panel?.contentView = NSHostingView(rootView: EveningReminderView(
            tasks: tasks,
            onLater: { [weak self] in self?.snooze() },
            onDismiss: { [weak self] in self?.dismiss() }
        ))
    }

    private func snooze() {
        dismiss()
        snoozeTimer?.invalidate()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 1_800, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.settings.isEnabled, let taskStore = self.taskStore else { return }
                let tasks = self.dueTodayTasks(from: taskStore.tasks)
                guard !tasks.isEmpty else { return }
                self.show(tasks: tasks)
            }
        }
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }
}

struct EveningReminderView: View {
    let tasks: [TodoItem]
    let onLater: () -> Void
    let onDismiss: () -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("今日待办清单", "Today’s to-do list"))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text(t("今天还有 \(tasks.count) 件待办没有完成", "You still have \(tasks.count) tasks due today"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(tasks.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }

            ScrollView(showsIndicators: tasks.count > 4) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(tasks) { task in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(task.priority.color)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(2)
                                Text(t("今天到期 · 尚未完成", "Due today · Not completed"))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.03), lineWidth: 1)
                        }
                    }
                }
            }
            .frame(maxHeight: 214)

            HStack {
                Button(t("30 分钟后再提醒", "Remind me in 30 min")) { onLater() }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .buttonStyle(.plain)
                Spacer()
                Button(t("知道了", "Got it")) { onDismiss() }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 410)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.25), Color.white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}

struct TodoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var priority: TaskPriority
    var dueDate: Date?
    var isCompleted: Bool
    let createdAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        priority: TaskPriority = .medium,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

enum InlineTaskSchedule: Equatable {
    case today
    case tomorrow
    case custom(Date)
    case unscheduled

    func dueDate(relativeTo now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .custom(let date):
            return calendar.startOfDay(for: date)
        case .unscheduled:
            return nil
        }
    }
}

struct InlineTaskDraft: Equatable {
    var title = ""
    var priority: TaskPriority = .medium
    var schedule: InlineTaskSchedule = .today

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSubmit: Bool { !trimmedTitle.isEmpty }

    init(title: String = "", priority: TaskPriority = .medium, schedule: InlineTaskSchedule = .today) {
        self.title = title
        self.priority = priority
        self.schedule = schedule
    }

    init(item: TodoItem) {
        title = item.title
        priority = item.priority
        schedule = item.dueDate.map { .custom($0) } ?? .unscheduled
    }
}

enum TaskPriority: String, CaseIterable, Codable, Identifiable {
    case high
    case medium
    case low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }

    func title(in language: AppLanguage) -> String {
        guard language == .english else { return title }
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }

    func priorityLabel(in language: AppLanguage) -> String {
        language == .english ? "\(title(in: language)) priority" : "\(title)优先级"
    }

    func subtitle(in language: AppLanguage) -> String {
        guard language == .english else {
            switch self {
            case .high: return "尽快处理"
            case .medium: return "正常安排"
            case .low: return "有空再做"
            }
        }
        switch self {
        case .high: return "Handle soon"
        case .medium: return "Normal pace"
        case .low: return "When you're free"
        }
    }

    var color: Color {
        switch self {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        }
    }

    var symbol: String {
        switch self {
        case .high: return "exclamationmark.2"
        case .medium: return "minus"
        case .low: return "arrow.down"
        }
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TodoItem] = []
    // Share the unsent draft across panel rebuilds, collapse/expand, and editing.
    @Published var inlineDraft = InlineTaskDraft()
    var onTasksChanged: (([TodoItem]) -> Void)?

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default) {
        let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDirectory = supportDirectory.appendingPathComponent("TodoBar", isDirectory: true)
        self.fileURL = appDirectory.appendingPathComponent("tasks.json")

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        do {
            try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("TodoBar: unable to prepare application support directory: \(error.localizedDescription)")
        }

        load()
    }

    var remainingCount: Int {
        tasks.lazy.filter { !$0.isCompleted }.count
    }

    var completedTasks: [TodoItem] {
        tasks
            .filter(\.isCompleted)
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    var openTasks: [TodoItem] {
        tasks
            .filter { !$0.isCompleted }
            .sorted(by: TaskStore.openTaskOrder)
    }

    var progress: Double {
        guard !tasks.isEmpty else { return 0 }
        return Double(tasks.filter(\.isCompleted).count) / Double(tasks.count)
    }

    /// 今天已完成：completedAt 在今天的任务
    var completedTodayCount: Int {
        let calendar = Calendar.current
        return tasks.filter { item in
            guard item.isCompleted, let completedAt = item.completedAt else { return false }
            return calendar.isDateInToday(completedAt)
        }.count
    }

    /// 今天待完成：到期日是今天或未安排日期的未完成任务（与面板“当天待完成”分组一致）
    var todayOpenCount: Int {
        let calendar = Calendar.current
        return tasks.filter { item in
            guard !item.isCompleted else { return false }
            guard let dueDate = item.dueDate else { return true }
            return calendar.isDateInToday(dueDate)
        }.count
    }

    /// 今日进度基数 = 今天已完成 + 今天待完成
    var todayScopeTotal: Int {
        completedTodayCount + todayOpenCount
    }

    func add(title: String, priority: TaskPriority, dueDate: Date?) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        tasks.append(TodoItem(title: trimmedTitle, priority: priority, dueDate: dueDate))
        save()
    }

    @discardableResult
    func submitInlineDraft() -> Bool {
        guard inlineDraft.canSubmit else { return false }
        add(title: inlineDraft.trimmedTitle, priority: inlineDraft.priority, dueDate: inlineDraft.schedule.dueDate())
        inlineDraft = InlineTaskDraft()
        return true
    }

    @discardableResult
    func saveInlineEdit(id: UUID, draft: InlineTaskDraft) -> Bool {
        guard draft.canSubmit, let item = tasks.first(where: { $0.id == id }) else { return false }
        let dueDate = draft.schedule.dueDate()
        guard item.title != draft.trimmedTitle || item.priority != draft.priority || item.dueDate != dueDate else { return true }
        update(item, title: draft.trimmedTitle, priority: draft.priority, dueDate: dueDate)
        return true
    }

    func toggle(_ item: TodoItem) {
        guard let index = tasks.firstIndex(where: { $0.id == item.id }) else { return }
        tasks[index].isCompleted.toggle()
        tasks[index].completedAt = tasks[index].isCompleted ? Date() : nil
        save()
    }

    func updatePriority(_ item: TodoItem, to priority: TaskPriority) {
        guard let index = tasks.firstIndex(where: { $0.id == item.id }) else { return }
        tasks[index].priority = priority
        save()
    }

    func updateDueDate(_ item: TodoItem, to dueDate: Date?) {
        guard let index = tasks.firstIndex(where: { $0.id == item.id }) else { return }
        tasks[index].dueDate = dueDate
        save()
    }

    func update(_ item: TodoItem, title: String, priority: TaskPriority, dueDate: Date?) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, let index = tasks.firstIndex(where: { $0.id == item.id }) else { return }
        tasks[index].title = trimmedTitle
        tasks[index].priority = priority
        tasks[index].dueDate = dueDate
        save()
    }

    func delete(_ item: TodoItem) {
        tasks.removeAll { $0.id == item.id }
        save()
    }

    func clearCompleted() {
        tasks.removeAll(where: \.isCompleted)
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            tasks = try decoder.decode([TodoItem].self, from: Data(contentsOf: fileURL))
        } catch {
            NSLog("TodoBar: unable to load saved tasks: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            let data = try encoder.encode(tasks)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("TodoBar: unable to save tasks: \(error.localizedDescription)")
        }
        onTasksChanged?(tasks)
    }

    private static func openTaskOrder(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhs.priority != rhs.priority {
                return priorityRank(lhs.priority) > priorityRank(rhs.priority)
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private static func priorityRank(_ priority: TaskPriority) -> Int {
        switch priority {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }
}

struct TodoPanelView: View {
    @EnvironmentObject private var taskStore: TaskStore
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @ObservedObject var widget: DesktopWidgetController
    var panelID: UInt32? = nil
    var showsWidgetControls = false
    @State private var editingItemID: UUID?
    @State private var completedExpanded = false

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return t("早上好", "Good morning")
        case 12..<18: return t("下午好", "Good afternoon")
        default: return t("晚上好", "Good evening")
        }
    }

    private var headerDate: String {
        Date.now.formatted(.dateTime.locale(languageSettings.language.locale).month(.wide).day().weekday(.wide))
    }

    private var overdueTasks: [TodoItem] {
        taskStore.openTasks.filter { item in
            guard let dueDate = item.dueDate else { return false }
            return Calendar.current.startOfDay(for: dueDate) < today
        }
    }

    private var todayTasks: [TodoItem] {
        taskStore.openTasks.filter { item in
            guard let dueDate = item.dueDate else { return true }
            return Calendar.current.startOfDay(for: dueDate) == today
        }
    }

    private var upcomingTasks: [TodoItem] {
        taskStore.openTasks.filter { item in
            guard let dueDate = item.dueDate else { return false }
            return Calendar.current.startOfDay(for: dueDate) > today
        }
    }

    var body: some View {
        taskListPanel
            .frame(width: 360, height: 460)
            .glassSurface(cornerRadius: 22)
            .environment(\.locale, languageSettings.language.locale)
            .preferredColorScheme(nil)
    }

    private var taskListPanel: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 11)

            Divider().opacity(0.35)

            InlineTaskComposer(onActivate: focusInlineComposer)
                .padding(.horizontal, 13)
                .padding(.top, 13)
                .padding(.bottom, 10)

            Divider().opacity(0.2)

            // Keep the header and the new-task action fixed. Only this list
            // consumes mouse-wheel events, so the panel itself never drifts.
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    if taskStore.openTasks.isEmpty {
                        emptyState
                    } else {
                        if !overdueTasks.isEmpty {
                            taskSection(title: t("已推迟", "Overdue"), subtitle: t("优先处理", "Needs attention"), tasks: overdueTasks)
                        }

                        if !todayTasks.isEmpty {
                            taskSection(title: t("当天待完成", "Due today"), subtitle: t("今天内完成", "Finish today"), tasks: todayTasks)
                        }

                        if !upcomingTasks.isEmpty {
                            taskSection(title: t("未来待完成", "Upcoming"), subtitle: t("后续安排", "Planned ahead"), tasks: upcomingTasks)
                        }
                    }

                    if !taskStore.completedTasks.isEmpty {
                        completedSection
                    }
                }
                .padding(.horizontal, 13)
                .padding(.bottom, 2)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(headerDate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if showsWidgetControls {
                Button {
                    if let panelID {
                        widget.setExpanded(false, for: panelID)
                    } else {
                        widget.setExpanded(false)
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .help(t("收纳为侧边标签", "Collapse to edge tab"))
                .accessibilityLabel(t("收纳为侧边标签", "Collapse to edge tab"))
            }

            Button {
                widget.toggleEnabled()
            } label: {
                Image(systemName: widget.isEnabled ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(widget.isEnabled ? Color.blue : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(widget.isEnabled ? Color.blue.opacity(0.14) : Color.primary.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
            .help(t("桌面常驻小组件", "Pin to desktop"))
            .accessibilityLabel(t("桌面常驻小组件", "Pin to desktop"))

            TodayProgressBadge(done: taskStore.completedTodayCount, total: taskStore.todayScopeTotal)
                .help(t("今天的完成进度", "Today's completion progress"))
        }
    }

    private func focusInlineComposer() {
        guard showsWidgetControls else { return }
        if let panelID {
            widget.focusPanel(on: panelID)
        } else {
            widget.focusPanel()
        }
    }

    private func taskSection(title: String, subtitle: String, tasks: [TodoItem]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text("\(tasks.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(spacing: 7) {
                ForEach(tasks) { item in
                    editableTaskRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private func editableTaskRow(_ item: TodoItem, compactCompletedStyle: Bool = false) -> some View {
        if editingItemID == item.id {
            InlineTaskEditor(item: item, onActivate: focusInlineComposer, onFinish: {
                if editingItemID == item.id { editingItemID = nil }
            })
        } else {
            TaskRow(item: item, onEdit: { editingItemID = item.id }, compactCompletedStyle: compactCompletedStyle)
        }
    }

    private var completedSection: some View {
        DisclosureGroup(isExpanded: $completedExpanded) {
            VStack(spacing: 7) {
                ForEach(taskStore.completedTasks) { item in
                    editableTaskRow(item, compactCompletedStyle: true)
                }

                Button {
                    taskStore.clearCompleted()
                } label: {
                    Label(t("清除 \(taskStore.completedTasks.count) 项", "Clear \(taskStore.completedTasks.count) tasks"), systemImage: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Color.red.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 5)
                .accessibilityLabel(t("清除全部已完成任务", "Clear all completed tasks"))
            }
            .padding(.top, 9)
        } label: {
            HStack {
                Text(t("已完成", "Completed"))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text("\(taskStore.completedTasks.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
        }
        .tint(.secondary)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(
                    LinearGradient(colors: [.indigo, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text(t("今天的清单很清爽", "Your list is clear today"))
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text(t("从上方快速记下一件想完成的事。", "Capture one thing you want to do above."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }

}

@MainActor
final class InlineInteractionSession: ObservableObject {
    private static let activeSessions = NSHashTable<InlineInteractionSession>.weakObjects()
    private let regions = NSHashTable<NSView>.weakObjects()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var onOutside: (() -> Void)?
    private var generation = 0
    private(set) var isActive = false

    func register(_ view: NSView) { regions.add(view) }
    func unregister(_ view: NSView) { regions.remove(view) }

    static func containsPopupClick(for panel: NSWindow, at point: NSPoint) -> Bool {
        activeSessions.allObjects.contains { session in
            let views = session.regions.allObjects
            guard views.contains(where: { $0.window === panel }) else { return false }
            return views.contains { view in
                guard let window = view.window, window !== panel, window.isVisible else { return false }
                return window.frame.contains(point)
            }
        }
    }

    func start(onOutside: @escaping () -> Void) {
        stop()
        self.onOutside = onOutside
        isActive = true
        Self.activeSessions.add(self)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handlePointerDown(event)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.dismiss() }
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isActive else { return }
                if !self.regions.allObjects.contains(where: { $0.window?.isKeyWindow == true }) {
                    self.dismiss()
                }
            }
        }
    }

    func stop() {
        generation += 1
        isActive = false
        Self.activeSessions.remove(self)
        onOutside = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        localMonitor = nil
        globalMonitor = nil
        resignObserver = nil
    }

    func contains(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        return regions.allObjects.contains { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
    }

    func handlePointerDown(_ event: NSEvent) {
        if isActive && !contains(event) { dismiss() }
    }

    func requestFocus(_ action: @escaping () -> Void) {
        let expectedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, self.generation == expectedGeneration else { return }
            guard self.regions.allObjects.contains(where: { $0.window?.isKeyWindow == true }) else { return }
            action()
        }
    }

    func dismiss() {
        guard isActive else { return }
        let callback = onOutside
        stop()
        let expectedGeneration = generation
        // Do not consume the click or reflow the list before its target handles it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            callback?()
        }
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

private struct InlineInteractionRegion: NSViewRepresentable {
    let session: InlineInteractionSession

    func makeNSView(context: Context) -> InlineInteractionRegionView {
        let view = InlineInteractionRegionView()
        session.register(view)
        view.session = session
        return view
    }

    func updateNSView(_ view: InlineInteractionRegionView, context: Context) {}

    static func dismantleNSView(_ view: InlineInteractionRegionView, coordinator: ()) {
        view.session?.unregister(view)
    }
}

private final class InlineInteractionRegionView: NSView {
    weak var session: InlineInteractionSession?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct InlineTaskComposer: View {
    @EnvironmentObject private var taskStore: TaskStore
    @ObservedObject private var languageSettings = LanguageSettings.shared
    let onActivate: () -> Void
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        Group {
            if isExpanded {
                InlineTaskInput(
                    draft: $taskStore.inlineDraft,
                    showsPlus: true,
                    submitTitle: t("添加", "Add"),
                    onActivate: onActivate,
                    onSubmit: { taskStore.submitInlineDraft() },
                    onEnd: { isExpanded = false }
                )
            } else {
                Button { isExpanded = true } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(taskStore.inlineDraft.title.isEmpty ? t("添加待办…", "Add a task…") : taskStore.inlineDraft.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(taskStore.inlineDraft.title.isEmpty ? .secondary : .primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                    .background(Color.primary.opacity(isHovering ? 0.06 : 0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.03), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(taskStore.inlineDraft.title.isEmpty ? t("新建待办", "New task") : t("继续编辑待办草稿", "Continue task draft"))
            }
        }
        .onHover { isHovering = $0 }
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}

struct InlineTaskEditor: View {
    @EnvironmentObject private var taskStore: TaskStore
    @ObservedObject private var languageSettings = LanguageSettings.shared
    let item: TodoItem
    let onActivate: () -> Void
    let onFinish: () -> Void
    @State private var draft: InlineTaskDraft
    @State private var didFinish = false

    init(item: TodoItem, onActivate: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.item = item
        self.onActivate = onActivate
        self.onFinish = onFinish
        _draft = State(initialValue: InlineTaskDraft(item: item))
    }

    var body: some View {
        InlineTaskInput(
            draft: $draft,
            showsPlus: false,
            submitTitle: languageSettings.text("保存", "Save"),
            onActivate: onActivate,
            onSubmit: { finish(); return false },
            onEnd: finish,
            onDelete: {
                didFinish = true
                taskStore.delete(item)
                onFinish()
            }
        )
        .onDisappear {
            // Switching rows or collapsing a window must not discard valid edits.
            if !didFinish { taskStore.saveInlineEdit(id: item.id, draft: draft) }
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        taskStore.saveInlineEdit(id: item.id, draft: draft)
        onFinish()
    }
}

struct InlineTaskInput: View {
    @Binding var draft: InlineTaskDraft
    let showsPlus: Bool
    let submitTitle: String
    let onActivate: () -> Void
    let onSubmit: () -> Bool
    let onEnd: () -> Void
    var onDelete: (() -> Void)? = nil
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @StateObject private var interaction = InlineInteractionSession()
    @State private var showsPriorityPicker = false
    @State private var showsDatePicker = false
    @State private var customDate = Date()
    @FocusState private var titleIsFocused: Bool

    private var scheduleLabel: String {
        switch draft.schedule {
        case .today: return t("今天", "Today")
        case .tomorrow: return t("明天", "Tomorrow")
        case .unscheduled: return t("不设日期", "No date")
        case .custom(let date):
            let format = Date.FormatStyle.dateTime.locale(languageSettings.language.locale)
            return Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
                ? date.formatted(format.month(.abbreviated).day())
                : date.formatted(format.year().month(.abbreviated).day())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                if showsPlus {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                TextField(showsPlus ? t("添加待办…", "Add a task…") : t("待办内容", "Task title"), text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($titleIsFocused)
                    .onSubmit { submit() }
                    .onExitCommand { end() }
                    .accessibilityLabel(t("待办内容", "Task title"))
            }
            HStack(spacing: 8) {
                priorityButton
                dateButton
                Spacer(minLength: 0)
                if let onDelete {
                    Button(action: {
                        interaction.stop()
                        titleIsFocused = false
                        onDelete()
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t("删除事项", "Delete task"))
                }
                Button(submitTitle) { submit() }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(draft.canSubmit ? .primary : .tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .buttonStyle(.plain)
                    .disabled(!draft.canSubmit)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .background(InlineInteractionRegion(session: interaction))
        .onAppear {
            interaction.start(onOutside: end)
            onActivate()
            focusTitle()
        }
        .onDisappear {
            interaction.stop()
            titleIsFocused = false
        }
    }

    private var priorityButton: some View {
        Button { showsPriorityPicker = true } label: {
            optionLabel(draft.priority.priorityLabel(in: languageSettings.language))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("选择优先级", "Choose priority"))
        .popover(isPresented: $showsPriorityPicker) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(TaskPriority.allCases) { option in
                    Button {
                        draft.priority = option
                        showsPriorityPicker = false
                        focusTitle()
                    } label: {
                        Text(option.priorityLabel(in: languageSettings.language))
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.primary.opacity(draft.priority == option ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .frame(width: 150)
            .background(InlineInteractionRegion(session: interaction))
        }
    }

    private var dateButton: some View {
        Button {
            customDate = draft.schedule.dueDate() ?? Date()
            showsDatePicker = true
        } label: {
            optionLabel(scheduleLabel)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("选择日期", "Choose date"))
        .popover(isPresented: $showsDatePicker) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    quickDateButton(t("今天", "Today"), schedule: .today)
                    quickDateButton(t("明天", "Tomorrow"), schedule: .tomorrow)
                    quickDateButton(t("不设日期", "No date"), schedule: .unscheduled)
                }
                Divider()
                DatePicker(t("截止日期", "Due date"), selection: $customDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    Spacer()
                    Button(t("确定", "Done")) { selectSchedule(.custom(customDate)) }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                }
            }
            .padding(14)
            .frame(width: 280)
            .environment(\.locale, languageSettings.language.locale)
            .background(InlineInteractionRegion(session: interaction))
        }
    }

    private func optionLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func quickDateButton(_ label: String, schedule: InlineTaskSchedule) -> some View {
        Button(label) { selectSchedule(schedule) }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .buttonStyle(.plain)
    }

    private func selectSchedule(_ schedule: InlineTaskSchedule) {
        draft.schedule = schedule
        showsDatePicker = false
        focusTitle()
    }

    private func focusTitle() {
        interaction.requestFocus { titleIsFocused = true }
    }

    private func end() {
        interaction.stop()
        titleIsFocused = false
        onEnd()
    }

    private func submit() {
        guard draft.canSubmit else { return }
        if onSubmit() {
            focusTitle()
        } else {
            interaction.stop()
            titleIsFocused = false
        }
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}

struct TaskRow: View {
    @EnvironmentObject private var taskStore: TaskStore
    @ObservedObject private var languageSettings = LanguageSettings.shared
    let item: TodoItem
    let onEdit: () -> Void
    var compactCompletedStyle = false
    @State private var isHovering = false
    @FocusState private var statusActionFocused: Bool

    private var statusActionVisible: Bool { isHovering || statusActionFocused }

    private var statusActionLabel: String {
        item.isCompleted ? t("恢复", "Restore") : t("完成", "Complete")
    }

    private var dueDescription: (text: String, color: Color)? {
        guard let dueDate = item.dueDate else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dueDay = calendar.startOfDay(for: dueDate)
        let days = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0

        if days < 0 { return (t("已推迟 \(-days) 天", "Overdue \(-days) days"), .red) }

        if days == 0 {
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: today) ?? Date()
            let remainingSeconds = max(0, endOfToday.timeIntervalSinceNow)
            let remainingHours = max(1, Int(ceil(remainingSeconds / 3_600)))
            return (t("还剩 \(remainingHours) 小时", "\(remainingHours) hours left"), .blue)
        }

        return (t("还有 \(days) 天", "\(days) days left"), .blue)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(item.isCompleted ? .secondary : .primary)
                        .strikethrough(item.isCompleted, color: .secondary.opacity(0.7))
                        .lineLimit(2)

                    if !item.isCompleted {
                        HStack(spacing: 7) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(item.priority.color)
                                    .frame(width: 6, height: 6)
                                Text(item.priority.priorityLabel(in: languageSettings.language))
                            }
                            .foregroundStyle(.secondary)

                            if let dueDescription {
                                Label(dueDescription.text, systemImage: "calendar")
                                    .foregroundStyle(dueDescription.color)
                            }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t("点击编辑待办", "Click to edit task"))
            .accessibilityLabel(t("编辑：\(item.title)", "Edit: \(item.title)"))
            .accessibilityAction(named: Text(statusActionLabel)) { taskStore.toggle(item) }

            Button {
                taskStore.toggle(item)
            } label: {
                Text(statusActionLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .focused($statusActionFocused)
            // Reserve the action's width so revealing it never shifts the title.
            .opacity(statusActionVisible ? 1 : 0)
            .allowsHitTesting(statusActionVisible)
            .help(item.isCompleted ? t("恢复未完成", "Mark as incomplete") : t("标记为完成", "Mark as complete"))
            .accessibilityLabel(item.isCompleted ? t("恢复：\(item.title)", "Restore: \(item.title)") : t("完成：\(item.title)", "Complete: \(item.title)"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compactCompletedStyle ? 7 : 8)
        .background(
            item.isCompleted
                ? Color.primary.opacity(0.02)
                : (isHovering ? Color.primary.opacity(0.09) : Color.primary.opacity(0.04)),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: statusActionFocused)
        .onHover { isHovering = $0 }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.03), lineWidth: 1)
        }
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}

struct TodayProgressBadge: View {
    let done: Int
    let total: Int
    @ObservedObject private var languageSettings = LanguageSettings.shared

    private var progress: Double {
        total == 0 ? 0 : Double(done) / Double(total)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                    .frame(width: total == 0 ? 0 : max(5, 56 * progress))
            }
            .frame(width: 56, height: 5)

            Text("\(done)/\(total)")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .animation(.snappy(duration: 0.3), value: progress)
        .accessibilityLabel(t("今天完成 \(done) / \(total) 项", "Completed \(done) of \(total) today"))
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}
