import AppKit
import SwiftUI
import Security
import ServiceManagement
import UserNotifications

enum FeedSecret {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.brightspace.ddl",
         kSecAttrAccount as String: "nyu-calendar"]
    }
    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw AppFailure.message("无法保存到钥匙串。") }
        } else if status != errSecSuccess { throw AppFailure.message("无法更新钥匙串中的订阅地址。") }
    }
}

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct Snapshot: Codable {
    var events: [CalendarEvent]
    var fetchedAt: Date
}

@MainActor
final class DeadlineStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var events: [CalendarEvent] = []
    @Published var externalSources: [ExternalSnapshot] = []
    @Published var externalError: String?
    private var brightspaceEvents: [CalendarEvent] = []
    @Published var fetchedAt: Date?
    @Published var errorMessage: String?
    @Published var notificationMessage: String?
    @Published var syncing = false
    @Published var configured = false
    @Published var localSnapshot = false
    @Published var notificationsAllowed = false
    @Published var loginEnabled = false
    @Published var clock = Date()
    @Published var recentChanges: [EventChange] = []
    var onOpen: (() -> Void)?
    var onUpdate: (() -> Void)?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastAttempt: Date?
    private var lastDailyAttempt: Date?
    private var feedURL: URL?
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private let cache: URL

    override init() {
        cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrightspaceDDL/snapshot.json")
        super.init()
        if let data = try? Data(contentsOf: cache), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            brightspaceEvents = snapshot.events; events = snapshot.events; fetchedAt = snapshot.fetchedAt
        }
        loadExternal()
        localSnapshot = defaults.bool(forKey: "localSnapshot")
        if !localSnapshot, let secret = FeedSecret.read(), let url = Self.validURL(secret) { feedURL = url; configured = true }
        center.delegate = self
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    static func validURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host == "brightspace.nyu.edu", url.user == nil, url.password == nil,
              url.path == "/d2l/le/calendar/feed/user/feed.ics",
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "token" && !($0.value ?? "").isEmpty }) == true else { return nil }
        return url
    }

    func start() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--import-config"), args.indices.contains(index + 1) {
            do {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[index + 1]))) as? [String: String]
                guard let value = object?["feed_url"] else { throw AppFailure.message("配置中缺少订阅地址。") }
                try configure(value)
            } catch { errorMessage = error.localizedDescription }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer?.tolerance = 10
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        Task {
            await refreshPermission()
            await sync()
        }
    }

    func configure(_ value: String) throws {
        guard let url = Self.validURL(value) else { throw AppFailure.message("请输入 NYU Brightspace 的完整 HTTPS 日历订阅链接。") }
        try FeedSecret.save(url.absoluteString)
        feedURL = url; configured = true; localSnapshot = false; errorMessage = nil
        defaults.set(false, forKey: "localSnapshot")
    }

    func importSnapshot(_ parsed: [CalendarEvent]) throws {
        guard !syncing else { throw AppFailure.message("请等待当前同步完成后再导入。") }
        let snapshot = Snapshot(events: parsed, fetchedAt: Date())
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: cache, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
        brightspaceEvents = parsed; mergeEvents(); fetchedAt = snapshot.fetchedAt; recentChanges = []
        feedURL = nil; configured = false; localSnapshot = true; errorMessage = nil
        defaults.set(true, forKey: "localSnapshot")
        notificationMessage = "已导入日历快照。它不会自动更新；添加订阅链接后可开启后台同步。"
        onUpdate?()
    }

    func refreshPermission() async {
        notificationsAllowed = await center.notificationSettings().authorizationStatus == .authorized
        loginEnabled = SMAppService.mainApp.status == .enabled
    }

    func enableNotifications() async {
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            notificationsAllowed = allowed
            notificationMessage = allowed ? "通知已开启。" : "请在系统设置 → 通知 → Brightspace DDL 中允许通知。"
        } catch { notificationMessage = "无法申请通知权限，请在系统设置中检查。" }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { notificationMessage = "请在系统设置 → 通用 → 登录项中允许 Brightspace DDL。" }
        } catch { notificationMessage = "无法修改登录启动：\(error.localizedDescription)" }
    }

    func tick() async {
        clock = Date()
        loadExternal()
        await refreshPermission()
        let dailyDue = NYTime.shouldSendDaily(now: clock, lastDay: defaults.string(forKey: "lastDailyDay"))
        let dailyRetryReady = lastDailyAttempt.map { NYTime.dayKey($0) != NYTime.dayKey(clock) || clock.timeIntervalSince($0) >= 300 } ?? true
        if (dailyDue && dailyRetryReady) || lastAttempt == nil || clock.timeIntervalSince(lastAttempt!) >= 3600 { await sync() }
        onUpdate?()
    }

    func sync() async {
        loadExternal()
        if localSnapshot || feedURL == nil {
            clock = Date(); lastAttempt = clock
            await dailyIfNeeded(); onUpdate?(); return
        }
        guard let feedURL, !syncing else { return }
        syncing = true; lastAttempt = Date(); clock = Date()
        defer { syncing = false; onUpdate?() }
        do {
            var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("text/calendar", forHTTPHeaderField: "Accept")
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 10_000_000, let text = String(data: data, encoding: .utf8) else {
                throw AppFailure.message("无法读取日历订阅，请检查网络或更新订阅链接。")
            }
            let parsed = try ICS.parse(text)
            let updated = fetchedAt == nil ? [] : changes(from: brightspaceEvents, to: parsed, now: Date())
            let snapshot = Snapshot(events: parsed, fetchedAt: Date())
            try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: cache, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
            brightspaceEvents = parsed; mergeEvents(); fetchedAt = snapshot.fetchedAt; errorMessage = nil
            if !updated.isEmpty {
                recentChanges = updated
                let body = updated.prefix(4).map { change in
                    let before = change.previousDate.map { "\(NYTime.display($0)) → " } ?? "新增 · "
                    return "\(change.current.title)\n\(before)\(change.current.dateLabel)"
                }.joined(separator: "\n")
                _ = await notify(id: "changes-\(UUID().uuidString)", title: "\(updated.count) 项 DDL 更新", body: body)
            }
        } catch {
            errorMessage = (error as? ICS.Failure)?.errorDescription ?? (error as? AppFailure)?.errorDescription ?? "同步失败，请检查网络。上次成功的数据已保留。"
        }
        await dailyIfNeeded()
    }

    private func mergeEvents() {
        events = (brightspaceEvents + externalSources.flatMap(\.events)).sorted { $0.deadline < $1.deadline }
    }

    func loadExternal() {
        let directory = ExternalSnapshot.directory
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            let loaded = try files.map { try JSONDecoder().decode(ExternalSnapshot.self, from: Data(contentsOf: $0)) }.sorted { $0.id < $1.id }
            if loaded != externalSources {
                let updates = changes(from: externalSources.flatMap(\.events), to: loaded.flatMap(\.events), now: Date())
                if !externalSources.isEmpty && !updates.isEmpty { recentChanges = updates }
                externalSources = loaded
                mergeEvents()
                onUpdate?()
            }
            externalError = nil
        } catch { externalError = "网页同步数据读取失败，已保留上次数据。" }
    }

    private func dailyIfNeeded() async {
        let now = Date()
        guard NYTime.shouldSendDaily(now: now, lastDay: defaults.string(forKey: "lastDailyDay")) else { return }
        lastDailyAttempt = now
        let items = upcoming(events, now: now)
        let urgent = items.filter { $0.hasExactDeadline && $0.deadline.timeIntervalSince(now) <= 86400 }.count
        let title = errorMessage != nil ? "DDL 汇总 · 本次同步失败" : "未来 7 天 \(items.count) 项 DDL · 24 小时内 \(urgent) 项"
        var body = items.prefix(4).map { "\($0.title) · \($0.dateLabel)" }.joined(separator: "\n")
        if items.isEmpty { body = fetchedAt == nil && externalSources.isEmpty ? "尚无可用日历数据，请打开 App 检查订阅。" : "未来 7 天没有日历已收录的作业 DDL。" }
        if let fetchedAt, errorMessage != nil { body = "上次同步：\(NYTime.display(fetchedAt))，数据可能过期。\n" + body }
        body += "\n点击查看完整清单。仅含已同步平台发布的项目。"
        if !externalSources.isEmpty { body += "\n网页来源按最后同步数据提醒；已明确提交或完成的任务已排除。" }
        if externalSources.contains(where: { now.timeIntervalSince($0.fetchedAt) > 7200 }) || items.contains(where: { $0.observedAt.map { now.timeIntervalSince($0) > 7200 } ?? false }) || externalError != nil {
            body = "网页数据可能过期，请打开 Chrome 课程页面同步。\n" + body
        }
        if localSnapshot { body = "来自手动导入的日历快照，未自动更新。\n" + body }
        if await notify(id: "daily-\(NYTime.dayKey(now))", title: title, body: body) {
            defaults.set(NYTime.dayKey(now), forKey: "lastDailyDay")
        }
    }

    private func notify(id: String, title: String, body: String) async -> Bool {
        await refreshPermission()
        guard notificationsAllowed else { return false }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch { notificationMessage = "通知未能提交给系统，请检查通知权限。"; return false }
    }

    func testNotification() async {
        await enableNotifications()
        if await notify(id: "test-\(UUID().uuidString)", title: "Brightspace DDL 已准备好", body: "每天纽约时间 17:00 汇总未来 7 天截止日期。点击通知打开清单。") {
            notificationMessage = "测试通知已提交给 macOS；显示方式受专注模式和系统通知设置影响。"
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.onOpen?() }
        completionHandler()
    }
}
