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
    override var canBecomeKey: Bool { true }
}

@MainActor
final class DesktopWidgetController: NSObject, ObservableObject {
    static let expandedSize = NSSize(width: 360, height: 460)
    static let collapsedSize = NSSize(width: 56, height: 56)

    private static let enabledKey = "TodoBar.widget.enabled"
    private static let expandedKey = "TodoBar.widget.expanded"
    private static let displayModeKey = "TodoBar.widget.display"
    private static let sideKey = "TodoBar.widget.side"
    private static let yFractionKey = "TodoBar.widget.yFraction"
    private static let legacyFrameKey = "TodoBar.widget.frame"

    enum DisplayMode: String {
        case mainDisplay = "main"
        case allDisplays = "all"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isExpanded: Bool
    @Published private(set) var displayMode: DisplayMode

    /// 每块屏幕一个面板，key 为 CGDirectDisplayID
    private var panels: [UInt32: WidgetPanel] = [:]
    /// 逻辑位置：贴靠的侧边 + 垂直方向的比例（0 = 底部，1 = 顶部），各屏幕共用
    private var side: WidgetSide
    private var yFraction: Double
    private var mirrorTimer: Timer?
    private let taskStore: TaskStore

    init(taskStore: TaskStore) {
        self.taskStore = taskStore
        let defaults = UserDefaults.standard
        _isEnabled = Published(initialValue: defaults.bool(forKey: Self.enabledKey))
        _isExpanded = Published(initialValue: defaults.object(forKey: Self.expandedKey) as? Bool ?? true)
        _displayMode = Published(initialValue: DisplayMode(rawValue: defaults.string(forKey: Self.displayModeKey) ?? "") ?? .mainDisplay)

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
           let legacy = legacySavedFrame(),
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
        yFraction = parsedFraction ?? 1

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
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.displayModeKey)
        guard isEnabled else { return }
        rebuildPanels()
        applyLayout(animated: false)
        panels.values.forEach { $0.orderFrontRegardless() }
    }

    func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        UserDefaults.standard.set(expanded, forKey: Self.expandedKey)
        applyLayout(animated: true)
    }

    /// 让面板在 App 未激活时也能接收键盘输入（面板内新建/编辑待办）
    func focusPanel() {
        let target = panelUnderMouse() ?? panels.values.first { $0.isVisible }
        target?.makeKeyAndOrderFront(nil)
    }

    /// 菜单栏「打开面板」：始终展开并显示
    func expandFromStatusBar() {
        guard isEnabled else { return }
        if panels.isEmpty {
            rebuildPanels()
        }
        if !isExpanded {
            setExpanded(true)
        }
        panels.values.forEach { $0.orderFrontRegardless() }
    }

    /// 菜单栏左键点按：展开 ⇄ 收纳成小图标
    func toggleFromStatusBar() {
        guard isEnabled else { return }
        if isExpanded, !panels.isEmpty {
            setExpanded(false)
        } else {
            expandFromStatusBar()
        }
    }

    func snap(to side: WidgetSide) {
        self.side = side
        persistPosition()
        applyLayout(animated: true)
    }

    /// 拖动收纳后的小图标（SwiftUI 的 y 轴向下，窗口坐标 y 轴向上）
    func moveBy(dx: CGFloat, dy: CGFloat) {
        guard let target = panelUnderMouse() else { return }
        var origin = target.frame.origin
        origin.x += dx
        origin.y += dy
        target.setFrameOrigin(origin)
    }

    func finishDragging() {
        guard let target = panelUnderMouse() else { return }
        // 悬浮窗只贴靠屏幕左右两侧：松手时按所在屏幕吸附，并镜像到其他屏幕
        recordPosition(from: target.frame, screen: target.screen ?? screenHosting(target.frame))
        applyLayout(animated: false)
        panels.values.forEach { $0.invalidateShadow() }
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
            panels[id] = makePanel()
        }
    }

    private func desiredDisplayIDs() -> Set<UInt32> {
        let screens = displayMode == .allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        return Set(screens.compactMap(Self.displayID(of:)))
    }

    private func applyLayout(animated: Bool) {
        let size = isExpanded ? Self.expandedSize : Self.collapsedSize
        for (_, panel) in panels {
            guard let screen = panel.screen ?? screenHosting(panel.frame) else { continue }
            let visible = screen.visibleFrame
            let y = visible.minY + CGFloat(yFraction) * max(visible.height - size.height, 0)
            let target = Self.frame(size: size, side: side, y: y, in: visible)
            if abs(panel.frame.origin.x - target.origin.x) > 0.5
                || abs(panel.frame.origin.y - target.origin.y) > 0.5
                || abs(panel.frame.width - target.width) > 0.5
                || abs(panel.frame.height - target.height) > 0.5 {
                panel.setFrame(target, display: true, animate: animated)
            }
        }
        panels.values.forEach { $0.invalidateShadow() }
    }

    private func makePanel() -> WidgetPanel {
        let panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let hosting = NSHostingView(rootView: WidgetHostRootView(store: taskStore, controller: self))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private func panelUnderMouse() -> WidgetPanel? {
        panels.values.first { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) }
            ?? panels.values.first { $0.isVisible }
    }

    private func recordPosition(from frame: NSRect, screen: NSScreen?) {
        guard let screen else { return }
        let visible = screen.visibleFrame
        side = Self.nearestSide(of: frame, in: visible)
        yFraction = Self.fraction(of: frame.origin.y, height: frame.height, in: visible)
    }

    private func persistPosition() {
        UserDefaults.standard.set(side.rawValue, forKey: Self.sideKey)
        UserDefaults.standard.set(yFraction, forKey: Self.yFractionKey)
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

    @objc private func screensChanged() {
        guard isEnabled else { return }
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
}

extension DesktopWidgetController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSPanel,
              panels.contains(where: { $0.value === window }) else { return }
        recordPosition(from: window.frame, screen: window.screen ?? screenHosting(window.frame))
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

    var body: some View {
        DesktopWidgetRootView(controller: controller)
            .environmentObject(store)
    }
}

struct DesktopWidgetRootView: View {
    @ObservedObject var controller: DesktopWidgetController
    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        Group {
            if controller.isExpanded {
                TodoPanelView(widget: controller, showsWidgetControls: true)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                WidgetCollapsedBadge(controller: controller)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: controller.isExpanded)
        .contextMenu { widgetContextMenu }
    }

    @ViewBuilder
    private var widgetContextMenu: some View {
        Button(controller.isExpanded ? t("收纳为小图标", "Collapse to icon") : t("展开面板", "Expand panel")) {
            controller.toggleExpanded()
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

/// 收纳后的常驻小图标：点击展开，按住拖动换位置
struct WidgetCollapsedBadge: View {
    @ObservedObject var controller: DesktopWidgetController
    @EnvironmentObject private var taskStore: TaskStore
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @State private var dragTranslation: CGSize = .zero

    var body: some View {
        ZStack {
            GlassEffectView(cornerRadius: 28)
                .clipShape(Circle())

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.45), Color.white.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )

            if taskStore.remainingCount == 0 {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            } else {
                VStack(spacing: 1) {
                    Image(systemName: "checklist")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    Text("\(taskStore.remainingCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.75))
                        .monospacedDigit()
                }
            }
        }
        .frame(width: 56, height: 56)
        .onTapGesture { controller.setExpanded(true) }
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let delta = CGSize(
                        width: value.translation.width - dragTranslation.width,
                        height: value.translation.height - dragTranslation.height
                    )
                    dragTranslation = value.translation
                    controller.moveBy(dx: delta.width, dy: -delta.height)
                }
                .onEnded { _ in
                    dragTranslation = .zero
                    controller.finishDragging()
                }
        )
        .help(t("点击展开 TodoBar，拖动可换位置", "Click to expand TodoBar; drag to reposition"))
        .accessibilityLabel(t("TodoBar 桌面小组件", "TodoBar desktop widget"))
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
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

@MainActor
final class TodoBarModel: ObservableObject {
    let taskStore: TaskStore
    let widgetController: DesktopWidgetController
    let statusBarController: StatusBarController
    private let services: TodoBarServices

    init() {
        let store = TaskStore()
        self.taskStore = store
        self.widgetController = DesktopWidgetController(taskStore: store)
        self.statusBarController = StatusBarController(taskStore: store, widgetController: widgetController)
        self.services = TodoBarServices()
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

    private var statusItem: NSStatusItem?
    private var panel: WidgetPanel?
    private var aboutPanel: WidgetPanel?
    private var eventMonitors: [Any] = []
    private var iconSubscription: AnyCancellable?
    private var widgetSubscription: AnyCancellable?
    private let contextMenu = NSMenu()
    private var isShowingContextMenu = false

    init(taskStore: TaskStore, widgetController: DesktopWidgetController) {
        self.taskStore = taskStore
        self.widgetController = widgetController
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
        updateIcon(remaining: taskStore.remainingCount)

        iconSubscription = taskStore.$tasks.receive(on: DispatchQueue.main).sink { [weak self] tasks in
            let remaining = tasks.lazy.filter { !$0.isCompleted }.count
            self?.updateIcon(remaining: remaining)
        }

        // 小组件开启时收起菜单面板，避免出现两个待办面板
        widgetSubscription = widgetController.$isEnabled.receive(on: DispatchQueue.main).sink { [weak self] enabled in
            if enabled {
                self?.hidePanel()
            }
        }
    }

    private func updateIcon(remaining: Int) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: remaining == 0 ? "checkmark.circle.fill" : "checkmark.circle",
            accessibilityDescription: remaining == 0 ? t("全部完成", "All done") : t("剩余任务", "Tasks remaining")
        )
        button.title = remaining > 0 ? " \(remaining)" : ""
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
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

        let settingsItem = NSMenuItem(title: t("设置", "Settings"), action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: t("设置", "Settings"))

        let languageItem = NSMenuItem(title: t("语言", "Language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: t("语言", "Language"))
        for language in AppLanguage.allCases {
            let item = NSMenuItem(
                title: language.displayName,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == LanguageSettings.shared.language ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        settingsMenu.addItem(languageItem)

        let widgetToggle = NSMenuItem(
            title: t("桌面常驻小组件", "Pin to desktop"),
            action: #selector(toggleWidgetFromMenu),
            keyEquivalent: ""
        )
        widgetToggle.target = self
        widgetToggle.state = widgetController.isEnabled ? .on : .off
        settingsMenu.addItem(widgetToggle)

        let displayItem = NSMenuItem(title: t("显示屏幕", "Displays"), action: nil, keyEquivalent: "")
        let displayMenu = NSMenu(title: t("显示屏幕", "Displays"))
        let displayModes: [(DesktopWidgetController.DisplayMode, String, String)] = [
            (.mainDisplay, "仅主屏幕", "Main display only"),
            (.allDisplays, "所有屏幕", "All displays")
        ]
        for (mode, chinese, english) in displayModes {
            let item = NSMenuItem(
                title: t(chinese, english),
                action: #selector(selectDisplayMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = widgetController.displayMode == mode ? .on : .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        settingsMenu.addItem(displayItem)

        settingsItem.submenu = settingsMenu
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

    @objc private func toggleWidgetFromMenu() {
        widgetController.toggleEnabled()
    }

    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DesktopWidgetController.DisplayMode(rawValue: raw) else { return }
        widgetController.setDisplayMode(mode)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        LanguageSettings.shared.language = language
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
    private let eveningReminderController = EveningReminderController()
    private var isConfigured = false

    func configure(with taskStore: TaskStore) {
        guard !isConfigured else { return }
        isConfigured = true
        self.taskStore = taskStore

        quickCaptureController.configure(with: taskStore)
        hotKeyManager.start {
            self.quickCaptureController.show()
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

extension Notification.Name {
    static let todoBarQuickCaptureActivated = Notification.Name("TodoBarQuickCaptureActivated")
}

@MainActor
final class QuickCaptureController {
    private weak var taskStore: TaskStore?
    private var panel: NSPanel?

    func configure(with taskStore: TaskStore) {
        self.taskStore = taskStore
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }

        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .todoBarQuickCaptureActivated, object: nil)
        }
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
            onSave: { [weak self] title, scheduleForToday in
                self?.taskStore?.add(
                    title: title,
                    priority: .medium,
                    dueDate: scheduleForToday ? Calendar.current.startOfDay(for: Date()) : nil
                )
                self?.dismiss()
            },
            onCancel: { [weak self] in self?.dismiss() }
        ))
        return panel
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }
}

struct QuickCaptureView: View {
    let onSave: (String, Bool) -> Void
    let onCancel: () -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared
    @State private var title = ""
    @State private var scheduleForToday = true
    @FocusState private var titleIsFocused: Bool

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label(t("快速收集", "Quick capture"), systemImage: "text.badge.plus")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.blue)
                Spacer()
                Text("⌥⌘T")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            TextField(t("记下一件想完成的事", "Capture one thing to do"), text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15))
                .focused($titleIsFocused)
                .onSubmit { save() }

            HStack {
                Toggle(t("默认安排在今天", "Schedule for today"), isOn: $scheduleForToday)
                    .toggleStyle(.switch)
                .font(.caption)
                Spacer()
                Button(t("取消", "Cancel")) { onCancel() }
                    .buttonStyle(.bordered)
                Button(t("加入待办", "Add task")) { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!isValid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 388)
        .background(.ultraThinMaterial)
        .onAppear { titleIsFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .todoBarQuickCaptureActivated)) { _ in
            title = ""
            scheduleForToday = true
            titleIsFocused = true
        }
    }

    private func save() {
        guard isValid else { return }
        onSave(title.trimmingCharacters(in: .whitespacesAndNewlines), scheduleForToday)
        title = ""
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

@MainActor
final class EveningReminderController {
    private weak var taskStore: TaskStore?
    private var scheduleTimer: Timer?
    private var snoozeTimer: Timer?
    private var panel: NSPanel?
    private let defaults = UserDefaults.standard
    private let reminderDayKey = "TodoBar.eveningReminderDay"

    func configure(with taskStore: TaskStore) {
        self.taskStore = taskStore
        scheduleNextCheck()
        checkForMissedEveningReminder()
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

    private func scheduleNextCheck(from now: Date = Date()) {
        scheduleTimer?.invalidate()

        let calendar = Calendar.current
        let todayAtNine = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: now) ?? now
        let target = todayAtNine > now
            ? todayAtNine
            : calendar.date(byAdding: .day, value: 1, to: todayAtNine) ?? todayAtNine

        scheduleTimer = Timer(fire: target, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.presentReminderIfNeeded()
                self?.scheduleNextCheck()
            }
        }

        if let scheduleTimer {
            RunLoop.main.add(scheduleTimer, forMode: .common)
        }
    }

    private func checkForMissedEveningReminder() {
        let calendar = Calendar.current
        guard calendar.component(.hour, from: Date()) >= 21 else { return }
        presentReminderIfNeeded()
    }

    private func presentReminderIfNeeded() {
        let dayKey = currentDayKey()
        guard defaults.string(forKey: reminderDayKey) != dayKey else { return }
        defaults.set(dayKey, forKey: reminderDayKey)

        guard let taskStore else { return }
        let tasks = dueTodayTasks(from: taskStore.tasks)
        guard !tasks.isEmpty else { return }
        show(tasks: tasks)
    }

    private func dueTodayTasks(from tasks: [TodoItem]) -> [TodoItem] {
        let calendar = Calendar.current
        return tasks.filter { item in
            guard !item.isCompleted, let dueDate = item.dueDate else { return false }
            return calendar.isDate(dueDate, inSameDayAs: Date())
        }
    }

    private func currentDayKey() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date())
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
                guard let self, let taskStore = self.taskStore else { return }
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 38, height: 38)
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(t("晚上 9 点清单", "9 PM check-in"))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(t("今天还有 \(tasks.count) 件待办没有完成", "You still have \(tasks.count) tasks due today"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            ScrollView(showsIndicators: tasks.count > 4) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(tasks) { task in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(task.priority.color)
                                .frame(width: 7, height: 7)
                            Text(task.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(2)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 205)

            HStack {
                Button(t("30 分钟后再提醒", "Remind me in 30 min")) { onLater() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(t("知道了", "Got it")) { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 410)
        .background(.ultraThinMaterial)
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

enum PanelContent: Equatable {
    case list
    case composer
    case editor(TodoItem)
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
    var showsWidgetControls = false
    @State private var panelContent: PanelContent = .list
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
        panelContentView
            .frame(width: 360, height: 460)
            .glassSurface(cornerRadius: 22)
            .environment(\.locale, languageSettings.language.locale)
            .preferredColorScheme(nil)
            .onChange(of: panelContent) { newValue in
                if showsWidgetControls, newValue != .list {
                    widget.focusPanel()
                }
            }
    }

    @ViewBuilder
    private var panelContentView: some View {
        switch panelContent {
        case .list:
            taskListPanel
        case .composer:
            TaskComposerSheet(
                onCreate: { title, priority, dueDate in
                    taskStore.add(title: title, priority: priority, dueDate: dueDate)
                    panelContent = .list
                },
                onCancel: { panelContent = .list }
            )
        case .editor(let item):
            TaskEditorSheet(
                item: item,
                onSave: { title, priority, dueDate in
                    taskStore.update(item, title: title, priority: priority, dueDate: dueDate)
                    panelContent = .list
                },
                onCancel: { panelContent = .list },
                onDelete: {
                    taskStore.delete(item)
                    panelContent = .list
                }
            )
        }
    }

    private var taskListPanel: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 11)

            Divider().opacity(0.35)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    createTaskCard

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
                .padding(13)
                .padding(.bottom, 2)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .shadow(color: .blue.opacity(0.16), radius: 4, y: 2)

                Image(systemName: taskStore.remainingCount == 0 ? "checkmark" : "checklist")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
            }

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
                    widget.setExpanded(false)
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain)
                .help(t("收纳为小图标", "Collapse to icon"))
                .accessibilityLabel(t("收纳为小图标", "Collapse to icon"))
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

    private var createTaskCard: some View {
        Button {
            panelContent = .composer
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 17, weight: .semibold))

                Text(t("新建待办", "New task"))
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Text(t("内容 · 优先级 · 日期", "Content · Priority · Date"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(
                LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .shadow(color: .blue.opacity(0.22), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("新建待办", "New task"))
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
                    TaskRow(item: item, onEdit: { panelContent = .editor(item) })
                }
            }
        }
    }

    private var completedSection: some View {
        DisclosureGroup(isExpanded: $completedExpanded) {
            VStack(spacing: 7) {
                ForEach(taskStore.completedTasks) { item in
                    TaskRow(item: item, onEdit: { panelContent = .editor(item) }, compactCompletedStyle: true)
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

struct TaskComposerSheet: View {
    let onCreate: (String, TaskPriority, Date) -> Void
    let onCancel: () -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared
    @State private var step = 1
    @State private var title = ""
    @State private var priority: TaskPriority = .medium
    @State private var selectedMonth = Calendar.current.component(.month, from: Date())
    @State private var selectedDay = Calendar.current.component(.day, from: Date())
    @FocusState private var titleIsFocused: Bool

    private var isTitleValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var daysInSelectedMonth: Int {
        var components = DateComponents()
        components.year = Calendar.current.component(.year, from: Date())
        components.month = selectedMonth
        components.day = 1
        guard let firstDay = Calendar.current.date(from: components) else { return 31 }
        return Calendar.current.range(of: .day, in: .month, for: firstDay)?.count ?? 31
    }

    private var selectedDueDate: Date {
        var components = DateComponents()
        components.year = Calendar.current.component(.year, from: Date())
        components.month = selectedMonth
        components.day = min(selectedDay, daysInSelectedMonth)
        return Calendar.current.date(from: components) ?? Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(t("取消", "Cancel")) { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(t("新建待办", "New task"))
                    .font(.system(size: 15, weight: .bold, design: .rounded))

                Spacer()

                Color.clear.frame(width: 28, height: 1)
            }

            stepIndicator
            stepContent

            HStack {
                if step > 1 {
                    Button(t("上一步", "Back")) {
                        withAnimation(.snappy(duration: 0.2)) { step -= 1 }
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                }

                Spacer()

                Button(step == 3 ? t("创建待办", "Create task") : t("下一步", "Next")) {
                    if step == 3 {
                        onCreate(title.trimmingCharacters(in: .whitespacesAndNewlines), priority, selectedDueDate)
                    } else {
                        withAnimation(.snappy(duration: 0.2)) { step += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(step == 1 && !isTitleValid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 350)
        .onAppear { titleIsFocused = true }
        .onChange(of: selectedMonth) { _ in
            selectedDay = min(selectedDay, daysInSelectedMonth)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(1...3, id: \.self) { number in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(number <= step ? Color.blue : Color.primary.opacity(0.08))
                            .frame(width: 20, height: 20)
                        if number < step {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(number)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(number == step ? .white : .secondary)
                        }
                    }
                    Text(stepName(number))
                        .font(.caption.weight(number == step ? .semibold : .regular))
                        .foregroundStyle(number == step ? .primary : .secondary)
                }

                if number < 3 {
                    Rectangle()
                        .fill(number < step ? Color.blue.opacity(0.5) : Color.primary.opacity(0.1))
                        .frame(height: 1.5)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 1: titleStep
        case 2: priorityStep
        default: dateStep
        }
    }

    private func stepHeader(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                    .shadow(color: .blue.opacity(0.25), radius: 5, y: 2)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var titleStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(
                "pencil.line",
                t("写下要做的事", "Write down the task"),
                t("保持简短、具体，下一步再安排细节。", "Keep it short and specific; arrange details next.")
            )
            TextField(t("例如：整理项目周报", "e.g. Prepare the project update"), text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .focused($titleIsFocused)
                .onSubmit {
                    if isTitleValid { step = 2 }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(titleIsFocused ? Color.blue.opacity(0.55) : Color.primary.opacity(0.05), lineWidth: 1.5)
                }
            HStack(spacing: 5) {
                Image(systemName: "return")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(t("按回车进入下一步", "Press return to continue"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(minHeight: 156, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
        }
    }

    private var priorityStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(
                "flag.fill",
                t("选择优先级", "Choose priority"),
                t("优先级帮你安排处理顺序。", "Priority arranges the order you handle things.")
            )
            VStack(spacing: 8) {
                ForEach(TaskPriority.allCases) { option in
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { priority = option }
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(priority == option ? option.color : option.color.opacity(0.15))
                                    .frame(width: 26, height: 26)
                                Image(systemName: option.symbol)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(priority == option ? .white : option.color)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.priorityLabel(in: languageSettings.language))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(option.subtitle(in: languageSettings.language))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if priority == option {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(option.color)
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            priority == option ? option.color.opacity(0.12) : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(priority == option ? option.color.opacity(0.5) : Color.primary.opacity(0.04), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(minHeight: 210, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
        }
    }

    private var dateStep: some View {
        VStack(alignment: .leading, spacing: 11) {
            stepHeader(
                "calendar",
                t("选择日期", "Choose date"),
                t("默认安排在今天，需要时再调整。", "Defaults to today; adjust only when needed.")
            )
            HStack(spacing: 8) {
                quickDateChip(days: 0, label: t("今天", "Today"))
                quickDateChip(days: 1, label: t("明天", "Tomorrow"))
                quickDateChip(days: 2, label: t("后天", "In 2 days"))
                Spacer()
            }
            HStack(spacing: 10) {
                dateWheelPicker(title: t("月", "Month"), selection: $selectedMonth, values: Array(1...12), suffix: languageSettings.language == .english ? "" : "月")
                dateWheelPicker(title: t("日", "Day"), selection: $selectedDay, values: Array(1...daysInSelectedMonth), suffix: languageSettings.language == .english ? "" : "日")
            }
            .frame(height: 112)

            Label(t("已选择 \(selectedMonth) 月 \(selectedDay) 日", "Selected: \(selectedMonth)/\(selectedDay)"), systemImage: "calendar.badge.checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)
        }
        .padding(14)
        .frame(minHeight: 252, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 1)
        }
    }

    private func quickDateChip(days: Int, label: String) -> some View {
        let calendar = Calendar.current
        let target = calendar.startOfDay(for: calendar.date(byAdding: .day, value: days, to: Date()) ?? Date())
        let isSelected = calendar.isDate(selectedDueDate, inSameDayAs: target)
        return Button {
            selectedMonth = calendar.component(.month, from: target)
            selectedDay = calendar.component(.day, from: target)
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.blue : Color.secondary)
                .background(isSelected ? Color.blue.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(isSelected ? Color.blue.opacity(0.45) : Color.clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func dateWheelPicker(title: String, selection: Binding<Int>, values: [Int], suffix: String) -> some View {
        MouseWheelValuePicker(title: title, selection: selection, values: values, suffix: suffix, hint: t("滚动缓慢切换", "Scroll to adjust"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.03), lineWidth: 1)
            }
    }

    private func stepName(_ number: Int) -> String {
        switch number {
        case 1: return t("待办", "Task")
        case 2: return t("优先级", "Priority")
        default: return t("日期", "Date")
        }
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}

struct MouseWheelValuePicker: NSViewRepresentable {
    let title: String
    @Binding var selection: Int
    let values: [Int]
    let suffix: String
    let hint: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WheelPickerNSView {
        let view = WheelPickerNSView()
        view.onStep = { step in
            context.coordinator.move(by: step)
        }
        view.configure(title: title, value: selection, values: values, suffix: suffix, hint: hint)
        return view
    }

    func updateNSView(_ nsView: WheelPickerNSView, context: Context) {
        context.coordinator.parent = self
        nsView.configure(title: title, value: selection, values: values, suffix: suffix, hint: hint)
    }

    final class Coordinator: NSObject {
        var parent: MouseWheelValuePicker

        init(parent: MouseWheelValuePicker) {
            self.parent = parent
        }

        func move(by step: Int) {
            guard let currentIndex = parent.values.firstIndex(of: parent.selection), !parent.values.isEmpty else { return }
            let nextIndex = (currentIndex + step % parent.values.count + parent.values.count) % parent.values.count
            parent.selection = parent.values[nextIndex]
        }
    }
}

final class WheelPickerNSView: NSView {
    var onStep: (Int) -> Void = { _ in }

    private let titleLabel = NSTextField(labelWithString: "")
    private let previousLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let nextLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var accumulatedDelta: CGFloat = 0
    private var lastStepTimestamp: TimeInterval = 0
    private let minimumStepInterval: TimeInterval = 0.32

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true
        [titleLabel, previousLabel, valueLabel, nextLabel, hintLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.alignment = .center
            addSubview($0)
        }

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        previousLabel.font = .systemFont(ofSize: 12, weight: .regular)
        previousLabel.textColor = .tertiaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 21, weight: .semibold)
        valueLabel.textColor = .labelColor
        nextLabel.font = .systemFont(ofSize: 12, weight: .regular)
        nextLabel.textColor = .tertiaryLabelColor
        hintLabel.font = .systemFont(ofSize: 9, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            previousLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            previousLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.topAnchor.constraint(equalTo: previousLabel.bottomAnchor, constant: -1),
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            nextLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: -1),
            nextLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: nextLabel.bottomAnchor, constant: 1),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5)
        ])
    }

    func configure(title: String, value: Int, values: [Int], suffix: String, hint: String) {
        titleLabel.stringValue = title
        valueLabel.stringValue = "\(value)\(suffix)"
        hintLabel.stringValue = hint

        guard let index = values.firstIndex(of: value), !values.isEmpty else {
            previousLabel.stringValue = ""
            nextLabel.stringValue = ""
            return
        }

        let previousIndex = (index - 1 + values.count) % values.count
        let nextIndex = (index + 1) % values.count
        previousLabel.stringValue = "\(values[previousIndex])\(suffix)"
        nextLabel.stringValue = "\(values[nextIndex])\(suffix)"
    }

    override func scrollWheel(with event: NSEvent) {
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 18 : 1
        accumulatedDelta += event.scrollingDeltaY

        guard abs(accumulatedDelta) >= threshold else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStepTimestamp >= minimumStepInterval else { return }

        onStep(accumulatedDelta > 0 ? -1 : 1)
        accumulatedDelta = 0
        lastStepTimestamp = now
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}

struct TaskEditorSheet: View {
    let item: TodoItem
    let onSave: (String, TaskPriority, Date?) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared
    @State private var title: String
    @State private var priority: TaskPriority
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @FocusState private var titleIsFocused: Bool

    init(
        item: TodoItem,
        onSave: @escaping (String, TaskPriority, Date?) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.item = item
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _title = State(initialValue: item.title)
        _priority = State(initialValue: item.priority)
        _hasDueDate = State(initialValue: item.dueDate != nil)
        _dueDate = State(initialValue: Calendar.current.startOfDay(for: item.dueDate ?? Date()))
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text(t("编辑待办", "Edit task"))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help(t("删除任务", "Delete task"))
                Button(t("取消", "Cancel")) { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(t("待办内容", "Task"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(t("待办内容", "Task"), text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleIsFocused)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(t("优先级", "Priority"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(t("优先级", "Priority"), selection: $priority) {
                    ForEach(TaskPriority.allCases) { option in
                        Text(option.priorityLabel(in: languageSettings.language)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 7) {
                Toggle(t("设置截止日期", "Set due date"), isOn: $hasDueDate)
                    .toggleStyle(.switch)

                if hasDueDate {
                    DatePicker(t("截止日期", "Due date"), selection: $dueDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                } else {
                    Text(t("此任务暂不安排日期。", "This task has no scheduled date."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button(t("保存修改", "Save changes")) {
                    onSave(
                        title.trimmingCharacters(in: .whitespacesAndNewlines),
                        priority,
                        hasDueDate ? Calendar.current.startOfDay(for: dueDate) : nil
                    )
                    onCancel()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 350)
        .onAppear { titleIsFocused = true }
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
            Button {
                taskStore.toggle(item)
            } label: {
                ZStack {
                    Circle()
                        .fill(item.isCompleted ? Color.blue : Color.clear)
                        .overlay {
                            Circle()
                                .strokeBorder(item.isCompleted ? Color.blue : Color.primary.opacity(0.32), lineWidth: 1.5)
                        }

                    if item.isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .help(item.isCompleted ? t("恢复未完成", "Mark as incomplete") : t("标记为完成", "Mark as complete"))
            .accessibilityLabel(item.isCompleted ? t("恢复：\(item.title)", "Restore: \(item.title)") : t("完成：\(item.title)", "Complete: \(item.title)"))

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(item.isCompleted ? .secondary : .primary)
                        .strikethrough(item.isCompleted, color: .secondary.opacity(0.7))
                        .lineLimit(2)

                    HStack(spacing: 7) {
                        if !item.isCompleted {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(item.priority.color)
                                    .frame(width: 6, height: 6)
                                Text(item.priority.priorityLabel(in: languageSettings.language))
                            }
                            .foregroundStyle(.secondary)
                        }

                        if !item.isCompleted, let dueDescription {
                            Label(dueDescription.text, systemImage: "calendar")
                                .foregroundStyle(dueDescription.color)
                        }
                    }
                    .font(.system(size: 10.5, weight: .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(t("点击编辑待办", "Click to edit task"))
            .accessibilityLabel(t("编辑：\(item.title)", "Edit: \(item.title)"))
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
