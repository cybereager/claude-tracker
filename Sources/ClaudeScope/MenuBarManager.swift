import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var currentStats: UsageStats = .empty
    @Published private(set) var isLoading: Bool = true
    @Published private(set) var lastError: String? = nil

    @Published var displayMode: DisplayMode = {
        DisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .cost
    }() {
        didSet {
            UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode")
            updateStatusBarTitle()
        }
    }

    @Published var planType: PlanType = {
        PlanType(rawValue: UserDefaults.standard.string(forKey: "planType") ?? "") ?? .api
    }() {
        didSet {
            UserDefaults.standard.set(planType.rawValue, forKey: "planType")
            updateStatusBarTitle()
        }
    }

    @Published var userEmail: String = UserDefaults.standard.string(forKey: "userEmail") ?? "" {
        didSet {
            UserDefaults.standard.set(userEmail, forKey: "userEmail")
        }
    }

    /// Auto-detected account info from ~/.claude.json. nil if file not found.
    @Published private(set) var detectedAccount: AccountInfo? = nil

    // MARK: - Private

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 60.0
    private let parser = UsageParser()

    // MARK: - Setup

    override init() {
        super.init()
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
    }

    func startTracking() {
        detectAccount()
        Task {
            await performFullParse()
            startTimer()
        }
    }

    // MARK: - Account Detection

    private func detectAccount() {
        guard let info = AccountDetector.detect() else { return }
        detectedAccount = info
        // Auto-fill email if user hasn't set one manually
        if userEmail.isEmpty {
            userEmail = info.email
        }
        // Auto-set plan if still on default .api and we detected a subscription
        if planType == .api && info.planType != .api {
            planType = info.planType
        }
        updateStatusBarTitle()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.title = "◆ ..."
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        button.action = #selector(handleClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateStatusBarTitle() {
        guard let button = statusItem?.button else { return }
        if isLoading {
            button.title = "◆ …"
            button.toolTip = "Claude Tracker — loading…"
        } else if lastError != nil {
            button.title = "◆ !"
            button.toolTip = "Claude Tracker — error, click to view"
        } else if displayMode == .usage {
            let fiveHr  = currentStats.fiveHourRequests
            let weekly  = currentStats.weekRequests
            if let fiveHrLimit = planType.fiveHourLimit,
               let weeklyLimit = planType.weeklyLimit {
                let fPct = min(Int(Double(fiveHr) / Double(fiveHrLimit) * 100), 100)
                let wPct = min(Int(Double(weekly) / Double(weeklyLimit) * 100), 100)
                button.title = "◆ \(fPct)% | \(wPct)%"
                button.toolTip = "5-hr session: \(fiveHr)/\(fiveHrLimit) msgs (\(fPct)%)  Weekly: \(weekly)/\(weeklyLimit) msgs (\(wPct)%)"
            } else {
                button.title = "◆ \(fiveHr) msgs"
                button.toolTip = "Last 5h: \(fiveHr) msgs  Week: \(weekly) msgs"
            }
        } else {
            let cost = currentStats.todayCost
            button.title = "◆ \(cost.costString)"
            let tip = "Today: \(currentStats.todayCost.costString)  Week: \(currentStats.weekCost.costString)  Month: \(currentStats.monthCost.costString)"
            button.toolTip = tip
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        let contentView = PopoverView(manager: self)
        let vc = NSHostingController(rootView: contentView)
        popover.contentViewController = vc
        popover.contentSize = CGSize(width: 420, height: 560)
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let reloadItem = NSMenuItem(title: "Reload All Data", action: #selector(reloadAll), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit ClaudeTracker", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Event Monitor

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if self.popover.isShown {
                self.popover.performClose(nil)
            }
        }
    }

    // MARK: - Refresh

    private func startTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performIncrementalRefresh()
            }
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)
    }

    private func performFullParse() async {
        isLoading = true
        lastError = nil
        updateStatusBarTitle()

        do {
            let records = try await Task.detached(priority: .userInitiated) { [parser] in
                try await parser.parseAll()
            }.value
            currentStats = CostCalculator.compute(from: records)
            isLoading = false
        } catch {
            lastError = error.localizedDescription
            isLoading = false
        }
        updateStatusBarTitle()
    }

    private func performIncrementalRefresh() async {
        do {
            let records = try await Task.detached(priority: .background) { [parser] in
                try await parser.parseIncremental()
            }.value
            currentStats = CostCalculator.compute(from: records)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        updateStatusBarTitle()
    }

    @objc private func reloadAll() {
        Task { await performFullParse() }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    deinit {
        refreshTimer?.invalidate()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
