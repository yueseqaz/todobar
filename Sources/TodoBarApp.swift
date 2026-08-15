import SwiftUI
import Foundation
import AppKit
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

@main
struct TodoBarApp: App {
    @StateObject private var model = TodoBarModel()

    var body: some Scene {
        MenuBarExtra {
            TodoPanelView()
                .environmentObject(model.taskStore)
        } label: {
            MenuBarLabel(remainingCount: model.taskStore.remainingCount)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class TodoBarModel: ObservableObject {
    let taskStore: TaskStore
    private let services: TodoBarServices

    init() {
        let store = TaskStore()
        self.taskStore = store
        self.services = TodoBarServices()
        self.services.configure(with: store)
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
                    .foregroundStyle(.teal)
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
                    .tint(.teal)
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
            onOpenTodoBar: { [weak self] in self?.openTodoBar() }
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

    private func openTodoBar() {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }
}

struct EveningReminderView: View {
    let tasks: [TodoItem]
    let onLater: () -> Void
    let onOpenTodoBar: () -> Void

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

            VStack(alignment: .leading, spacing: 7) {
                ForEach(tasks.prefix(4)) { task in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(task.priority.color)
                            .frame(width: 7, height: 7)
                        Text(task.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }

                if tasks.count > 4 {
                    Text(t("还有 \(tasks.count - 4) 件待办", "And \(tasks.count - 4) more tasks"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }

            HStack {
                Button(t("30 分钟后再提醒", "Remind me in 30 min")) { onLater() }
                    .buttonStyle(.bordered)
                Spacer()
                Button(t("查看 TodoBar", "View TodoBar")) { onOpenTodoBar() }
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

    var color: Color {
        switch self {
        case .high: return .red
        case .medium: return .orange
        case .low: return .teal
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

struct MenuBarLabel: View {
    let remainingCount: Int
    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: remainingCount == 0 ? "checkmark.circle.fill" : "checkmark.circle")
            if remainingCount > 0 {
                Text("\(remainingCount)")
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(remainingCount == 0 ? t("TodoBar，所有任务已完成", "TodoBar, all tasks are complete") : t("TodoBar，剩余 \(remainingCount) 项任务", "TodoBar, \(remainingCount) tasks remaining"))
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}

struct TodoPanelView: View {
    @EnvironmentObject private var taskStore: TaskStore
    @ObservedObject private var languageSettings = LanguageSettings.shared
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
            .background(.ultraThinMaterial)
            .environment(\.locale, languageSettings.language.locale)
            .preferredColorScheme(nil)
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
                            colors: [.mint, .teal],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .shadow(color: .teal.opacity(0.16), radius: 4, y: 2)

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

            Menu {
                Picker(t("语言", "Language"), selection: $languageSettings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } label: {
                Text(languageSettings.language.shortName)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .help(t("切换语言", "Switch language"))

            ProgressRing(progress: taskStore.progress, remainingCount: taskStore.remainingCount)
                .accessibilityLabel(t("完成进度 \(Int(taskStore.progress * 100))%，剩余 \(taskStore.remainingCount) 项", "\(Int(taskStore.progress * 100))% complete, \(taskStore.remainingCount) remaining"))
        }
    }

    private var createTaskCard: some View {
        Button {
            panelContent = .composer
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.teal)
                    .frame(width: 24, height: 24)
                    .background(Color.teal.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(t("新建待办", "New task"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(t("依次设置内容、优先级与日期", "Set content, priority, then date"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            }
            .padding(10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.03), lineWidth: 1)
            }
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
        VStack(alignment: .leading, spacing: 20) {
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
                .tint(.teal)
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
                    Text("\(number)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(number <= step ? .white : .secondary)
                        .frame(width: 18, height: 18)
                        .background(number <= step ? Color.teal : Color.primary.opacity(0.08), in: Circle())
                    Text(stepName(number))
                        .font(.caption.weight(number == step ? .semibold : .regular))
                        .foregroundStyle(number == step ? .primary : .secondary)
                }

                if number < 3 {
                    Rectangle()
                        .fill(number < step ? Color.teal.opacity(0.55) : Color.primary.opacity(0.1))
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 1:
            VStack(alignment: .leading, spacing: 10) {
                Text(t("写下要做的事", "Write down the task"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(t("保持简短、具体，下一步再安排细节。", "Keep it short and specific; arrange details next."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField(t("例如：整理项目周报", "e.g. Prepare the project update"), text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                    .focused($titleIsFocused)
                    .onSubmit {
                        if isTitleValid { step = 2 }
                    }
                    .padding(.top, 4)
            }
            .frame(minHeight: 118, alignment: .top)
        case 2:
            VStack(alignment: .leading, spacing: 10) {
                Text(t("选择优先级", "Choose priority"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(t("优先级用于帮你安排任务顺序。", "Priority helps you arrange the task order."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(TaskPriority.allCases) { option in
                        Button {
                            priority = option
                        } label: {
                            VStack(spacing: 7) {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 10, height: 10)
                                Text(option.priorityLabel(in: languageSettings.language))
                                    .font(.caption.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(priority == option ? option.color.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(priority == option ? option.color.opacity(0.55) : Color.primary.opacity(0.04), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .frame(minHeight: 118, alignment: .top)
        default:
            VStack(alignment: .leading, spacing: 10) {
                Text(t("选择日期", "Choose date"))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text(t("默认安排在今天；需要时再调整日期。", "It defaults to today; adjust only when needed."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    dateWheelPicker(title: t("月", "Month"), selection: $selectedMonth, values: Array(1...12), suffix: languageSettings.language == .english ? "" : "月")
                    dateWheelPicker(title: t("日", "Day"), selection: $selectedDay, values: Array(1...daysInSelectedMonth), suffix: languageSettings.language == .english ? "" : "日")
                }
                .frame(height: 122)
                .padding(.top, 5)

                Text(t("已选择 \(selectedMonth) 月 \(selectedDay) 日", "Selected: \(selectedMonth)/\(selectedDay)"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.teal)
                    .padding(.top, 2)
            }
            .frame(minHeight: 270, alignment: .top)
        }
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
                .tint(.teal)
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
                        .fill(item.isCompleted ? Color.teal : Color.clear)
                        .overlay {
                            Circle()
                                .strokeBorder(item.isCompleted ? Color.teal : Color.primary.opacity(0.32), lineWidth: 1.5)
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
        .background(item.isCompleted ? Color.primary.opacity(0.02) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.03), lineWidth: 1)
        }
    }

    private func t(_ chinese: String, _ english: String) -> String {
        languageSettings.text(chinese, english)
    }
}

struct ProgressRing: View {
    let progress: Double
    let remainingCount: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 4))

            Circle()
                .trim(from: 0, to: max(0.04, progress))
                .stroke(
                    LinearGradient(colors: [.mint, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.snappy(duration: 0.35), value: progress)

            Text(remainingCount == 0 ? "✓" : "\(remainingCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(remainingCount == 0 ? Color.teal : Color.primary)
        }
        .frame(width: 36, height: 36)
    }
}
