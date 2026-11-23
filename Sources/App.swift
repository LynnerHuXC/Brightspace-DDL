import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Use the property wrapper on command-line SDKs that omit the new State macro plugin.
private typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct BrightspaceMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var popover: NSPopover!
    private var store: DeadlineStore!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        store = DeadlineStore()
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 470, height: 650)
        popover.contentViewController = NSHostingController(rootView: Dashboard(store: store))
        popover.appearance = NSAppearance(named: .darkAqua)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "Brightspace DDL")
        item.button?.imagePosition = .imageLeading
        item.button?.title = " DDL"
        item.button?.toolTip = "Brightspace DDL — 查看作业截止日期"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        store.onOpen = { [weak self] in self?.show() }
        store.onUpdate = { [weak self] in
            guard let self else { return }
            let count = upcoming(self.store.events, now: Date()).count
            self.item.button?.title = " DDL \(count)"
        }
        store.start()
        if CommandLine.arguments.contains("--import-config") { show() }
        UserDefaults.standard.set(true, forKey: "hasLaunched")
    }
    @objc func toggle() { if popover.isShown { popover.performClose(nil) } else { show() } }
    func show() {
        guard let button = item?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
}

struct FrostedPanel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct Dashboard: View {
    @ObservedObject var store: DeadlineStore
    @ViewState private var settings = false
    @ViewState private var feed = ""
    private let purple = Color(red: 0.70, green: 0.85, blue: 0.98)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(purple)
                    .frame(width: 44, height: 44).background(.white.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("DDL").font(.title2.bold())
                    Text("纽约时间 · 每天 17:00 提醒").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { settings.toggle() } label: { Image(systemName: settings ? "list.bullet" : "gearshape") }
                    .help(settings ? "返回截止日期" : "设置").accessibilityLabel(settings ? "返回截止日期" : "设置")
            }.padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if settings || (!store.configured && store.fetchedAt == nil && store.externalSources.isEmpty) { settingsView }
                    else { deadlinesView }
                    if let error = store.externalError { Text(error).font(.caption).foregroundStyle(.orange) }
                    if let error = store.errorMessage { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                    if let message = store.notificationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.syncing ? "正在同步…" : store.localSnapshot ? "本地日历快照 · 不会自动更新" : store.configured ? "每小时自动同步" : "尚未连接日历").font(.caption)
                    Text(store.fetchedAt.map { "\(store.localSnapshot ? "导入" : "上次同步")：\(NYTime.display($0))" } ?? "尚未成功同步").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新") { Task { await store.sync() } }.disabled(store.syncing)
                Button("退出") { NSApp.terminate(nil) }
            }.padding(20)
        }.frame(minWidth: 420, minHeight: 420)
            .background(Color(red: 0.30, green: 0.40, blue: 0.48).opacity(0.28))
            .background(FrostedPanel())
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
            .preferredColorScheme(.dark)
            .tint(purple)
    }

    @ViewBuilder private var deadlinesView: some View {
        let items = upcoming(store.events, now: store.clock)
        let urgent = items.filter { $0.hasExactDeadline && $0.deadline.timeIntervalSince(store.clock) <= 86400 }.count
        HStack(alignment: .firstTextBaseline) {
            Text("未来 7 天").font(.headline)
            Spacer()
            Text("\(items.count) 项截止日期").font(.subheadline).foregroundStyle(.secondary)
        }
        sourceStatus
        if store.localSnapshot {
            Text("这是手动导入的 .ics 快照。要自动获取新增作业和改期，请在设置中添加订阅链接。")
                .font(.caption).foregroundStyle(.orange)
        }
        if !store.notificationsAllowed {
            HStack {
                Label("开启通知以接收每日提醒", systemImage: "bell.badge")
                Spacer()
                Button("开启通知") { Task { await store.enableNotifications() } }
            }.font(.caption).padding(12).background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
        if urgent > 0 { Label("\(urgent) 项将在 24 小时内截止", systemImage: "clock.fill").font(.subheadline.bold()).foregroundStyle(.orange) }
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "calendar").font(.largeTitle).foregroundStyle(purple)
                Text(store.fetchedAt == nil ? "正在获取你的日历" : "未来 7 天暂无日历收录的 DDL").font(.headline)
            }.frame(maxWidth: .infinity).padding(.vertical, 24)
        }
        ForEach(items) { event in eventRow(event) }
        if !store.recentChanges.isEmpty {
            Text("本次运行发现的更新").font(.headline)
            ForEach(store.recentChanges, id: \.current.id) { change in
                VStack(alignment: .leading, spacing: 4) {
                    Text(change.current.title).font(.subheadline.bold())
                    Text(change.previousDate.map { "\(NYTime.display($0)) → \(change.current.dateLabel)" } ?? "新增 · \(change.current.dateLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        let submitted = store.events.filter { $0.submitted == true && $0.deadline >= store.clock }
        if !submitted.isEmpty {
            DisclosureGroup("已提交 / 已完成（不提醒）") { ForEach(submitted) { event in eventRow(event) } }
        }
        let others = store.events.filter { !$0.isDue && $0.deadline >= store.clock }.prefix(8)
        if !others.isEmpty {
            DisclosureGroup("其他日历事件（含考试）") { ForEach(Array(others)) { event in eventRow(event) } }
        }
        Text("仅包含已同步的平台项目，可能遗漏公告或教学大纲。Brightspace 和 WebAssign 不推断提交状态；网页中消失的旧项目保留待核实。")
            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
    }

    private var sourceStatus: some View {
        DisclosureGroup("网页来源 · \(store.externalSources.count) 个连接") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Chrome 支持 Gradescope 作业页、WebAssign Home / My Assignments、Keenly Tasks 和 ALEKS Assignments。ALEKS 读取当前页面，作业有变动时请刷新网页。App 每分钟读取本机同步结果。")
                    .font(.caption).foregroundStyle(.secondary)
                if store.externalSources.isEmpty { Text("尚未连接：请加载配套 Chrome 扩展后刷新课程页面。").font(.caption).foregroundStyle(.orange) }
                ForEach(store.externalSources) { source in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(source.displayName) · \(source.course)").font(.caption.bold())
                        Text("\(source.events.count) 项 · 上次同步 \(NYTime.display(source.fetchedAt))").font(.caption)
                        if store.clock.timeIntervalSince(source.fetchedAt) > 7200 { Text("数据可能过期，请打开课程页面检查登录。").font(.caption).foregroundStyle(.orange) }
                        if let warning = source.warning { Text(warning).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.padding(.vertical, 8)
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(event.sourceName) · \(event.course)").font(.caption).foregroundStyle(purple)
            Text(event.title.replacingOccurrences(of: " - Due", with: "")).font(.headline).fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(event.dateLabel, systemImage: "clock").font(.caption)
                Spacer()
                if let url = event.url { Link("打开作业 ↗", destination: url).font(.caption) }
            }.foregroundStyle(.secondary)
            if event.submitted == true { Text("已提交 / 已完成 · 不再提醒").font(.caption).foregroundStyle(.green) }
            if let seen = event.observedAt, store.clock.timeIntervalSince(seen) > 7200 {
                Text("此项目上次确认：\(NYTime.display(seen))；请核实网站最新状态。").font(.caption).foregroundStyle(.orange)
            }
            if event.isDue && !event.allDay && event.submitted != true {
                let hours = max(0, Int(event.date.timeIntervalSince(store.clock) / 3600))
                Text(hours < 1 ? "不足 1 小时" : hours < 24 ? "还剩约 \(hours) 小时" : "还剩约 \(hours / 24) 天 \(hours % 24) 小时")
                    .font(.caption.bold()).foregroundStyle(hours < 24 ? Color.orange : Color.secondary)
            }
        }.padding(.vertical, 12).padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.16)).frame(height: 1) }
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chrome 扩展安装").font(.headline)
            Text(store.chromeSetupMessage).font(.caption)
            Text("打开 Chrome 的 chrome://extensions，开启开发者模式，选择“加载已解压的扩展程序”，选中下方打开的 Extension 文件夹。安装后刷新课程页面。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("打开扩展文件夹") {
                    if let folder = Bundle.main.resourceURL?.appendingPathComponent("Extension") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
                Button("修复 Chrome 连接") { store.setupChrome() }
            }
            Divider()
            sourceStatus
            Text("提醒设置").font(.headline)
            Text("每天纽约时间 17:00，汇总未来 7 天 DDL。电脑唤醒后会补同步，并补发当天错过的汇总。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("登录 Mac 时自动启动", isOn: Binding(get: { store.loginEnabled }, set: { store.setLogin($0) }))
            HStack {
                Button(store.notificationsAllowed ? "发送测试通知" : "开启并测试通知") { Task { await store.testNotification() } }
                Text(store.notificationsAllowed ? "通知权限已开启" : "通知权限未开启").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(store.configured ? "更新日历订阅" : "连接 NYU Brightspace").font(.headline)
            Text("自动同步：在 Brightspace → Calendar → Subscribe 中复制显示的完整链接（不是点击 Download）。链接以 .ics?token=… 结尾，仅保存在本机钥匙串。").font(.caption).foregroundStyle(.secondary)
            SecureField("粘贴私人日历订阅链接", text: $feed)
                .textFieldStyle(.roundedBorder).accessibilityLabel("日历订阅链接")
            HStack {
                Button("保存并同步") { save(feed) }.disabled(feed.isEmpty)
                Button("导入 .ics 文件…") { importConfig() }.disabled(store.syncing)
            }
            Text("下载的 .ics 文件也可以导入查看和提醒，但只是快照，不会自动更新。").font(.caption).foregroundStyle(.secondary)
            if store.configured { Label("已连接 NYU 日历", systemImage: "checkmark.shield").foregroundStyle(.green).font(.caption) }
            Divider()
            Text("关闭窗口后仍在菜单栏运行；点击“退出”会停止同步和提醒。休眠、关机和专注模式可能延迟通知。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func save(_ value: String) {
        do {
            try store.configure(value); feed = ""; settings = false
            Task { await store.enableNotifications(); await store.sync() }
        } catch { store.errorMessage = error.localizedDescription }
    }
    private func importConfig() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ics") ?? .data, .json]
        panel.message = "选择 Brightspace 下载的 .ics 日历文件。文件导入是一次性快照，自动更新需填写订阅链接。"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                switch try CalendarImport.read(Data(contentsOf: url), fileExtension: url.pathExtension) {
                case .subscription(let value): save(value)
                case .snapshot(let events):
                    try store.importSnapshot(events); settings = false
                    Task { await store.enableNotifications(); await store.sync() }
                }
            } catch { store.errorMessage = "导入失败：\(error.localizedDescription)" }
        }
    }
}
