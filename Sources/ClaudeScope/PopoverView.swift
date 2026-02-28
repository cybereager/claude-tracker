import SwiftUI

struct PopoverView: View {
    @ObservedObject var manager: MenuBarManager
    @State private var selectedPeriod: TimePeriod = .today
    @State private var showEmailEditor: Bool = false

    // Use explicit Binding wrappers to avoid @MainActor isolation issues
    private var modePick: Binding<DisplayMode> {
        Binding(get: { manager.displayMode }, set: { manager.displayMode = $0 })
    }
    private var planPick: Binding<PlanType> {
        Binding(get: { manager.planType }, set: { manager.planType = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            modePickerRow
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    if manager.displayMode == .usage {
                        subscriptionView
                    } else {
                        periodPickerRow
                        costSummaryCard
                    }
                    modelSection
                    projectSection
                }
                .padding(12)
            }
            Divider()
            footerView
        }
        .frame(width: 420, height: 560)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ClaudeScope")
                    .font(.headline)
                if manager.isLoading {
                    Text("Loading…")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let err = manager.lastError {
                    Text("Error: \(err)")
                        .font(.caption).foregroundStyle(.red).lineLimit(1)
                } else {
                    Text("Updated \(manager.currentStats.lastUpdated.relativeString)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if manager.isLoading {
                ProgressView().scaleEffect(0.7).frame(width: 20, height: 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Mode Picker Row (API Cost / Subscription toggle)

    private var modePickerRow: some View {
        HStack {
            Text("Mode")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: modePick) {
                ForEach(DisplayMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Period Picker Row (only shown in cost mode)

    private var periodPickerRow: some View {
        Picker("", selection: $selectedPeriod) {
            ForEach(TimePeriod.allCases, id: \.self) { p in
                Text(p.rawValue).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 0)
    }

    // MARK: - Subscription View

    private var subscriptionView: some View {
        VStack(spacing: 12) {
            accountCard
            sessionBarsCard
        }
    }

    private var accountCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                // Avatar circle
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Text(emailInitial)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    if showEmailEditor {
                        TextField("your@email.com", text: Binding(
                            get: { manager.userEmail },
                            set: { manager.userEmail = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .onSubmit { showEmailEditor = false }
                    } else {
                        HStack(spacing: 4) {
                            Text(manager.userEmail.isEmpty ? "Tap to set email" : manager.userEmail)
                                .font(.callout)
                                .foregroundStyle(manager.userEmail.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                            if manager.detectedAccount != nil {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                                    .help("Auto-detected from ~/.claude.json")
                            }
                        }
                        .onTapGesture { showEmailEditor = true }
                    }
                    HStack(spacing: 4) {
                        Text(planLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if manager.detectedAccount != nil {
                            Text("· auto-detected")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                Picker("", selection: planPick) {
                    ForEach(PlanType.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 90)
            }
            .padding(.vertical, 2)
        }
    }

    private var emailInitial: String {
        guard let first = manager.userEmail.first else { return "?" }
        return String(first).uppercased()
    }

    private var planLabel: String {
        switch manager.planType {
        case .api:   return "API (pay-per-token)"
        case .pro:   return "Pro subscription"
        case .max5:  return "Max (5×) subscription"
        case .max20: return "Max (20×) subscription"
        }
    }

    private var sessionBarsCard: some View {
        GroupBox {
            VStack(spacing: 16) {
                if manager.planType.isSubscription {
                    let oauth = manager.oauthUsage

                    // 5-hour session bar — real data only, no fake estimates
                    usageBar(
                        label: "5-hr Session",
                        fraction: oauth?.fiveHourUtilization,
                        subtitle: fiveHourResetSubtitle,
                        isLive: oauth?.fiveHourUtilization != nil
                    )
                    Divider()

                    // Weekly bar — real data only
                    usageBar(
                        label: "Weekly",
                        fraction: oauth?.weeklyUtilization,
                        subtitle: weeklyResetSubtitle,
                        isLive: oauth?.weeklyUtilization != nil
                    )

                    if let err = manager.oauthError {
                        Divider()
                        Text("⚠ \(err)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()
                    // Quick stats row
                    HStack(spacing: 0) {
                        miniStat(label: "Today", value: "\(manager.currentStats.todayRequests) msgs")
                        Divider().frame(height: 28)
                        miniStat(label: "Month", value: "\(manager.currentStats.monthRequests) msgs")
                        Divider().frame(height: 28)
                        miniStat(label: "All Time", value: "\(manager.currentStats.recordCount) msgs")
                    }
                } else {
                    // API mode — show quick numbers without bars
                    HStack(spacing: 0) {
                        miniStat(label: "Last 5h", value: "\(manager.currentStats.fiveHourRequests) msgs")
                        Divider().frame(height: 28)
                        miniStat(label: "This Week", value: "\(manager.currentStats.weekRequests) msgs")
                        Divider().frame(height: 28)
                        miniStat(label: "All Time", value: "\(manager.currentStats.recordCount) msgs")
                    }
                    Text("Select Pro or Max to see usage bars")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Reset Time Subtitles

    private var fiveHourResetSubtitle: String {
        // Prefer real reset time from OAuth API
        let resets = manager.oauthUsage?.fiveHourResetsAt
            ?? manager.currentStats.fiveHourWindowResets

        guard let resets else {
            return "No activity in the last 5 hours"
        }
        let diff = resets.timeIntervalSinceNow
        if diff <= 0 {
            return "Window resetting — counter clears on next message"
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        let timeStr = fmt.string(from: resets)
        let h = Int(diff) / 3600
        let m = (Int(diff) % 3600) / 60
        if h > 0 {
            return "Resets at \(timeStr) · in \(h)h \(m)m"
        } else {
            return "Resets at \(timeStr) · in \(m)m"
        }
    }

    private var weeklyResetSubtitle: String {
        // Prefer real reset time from OAuth API
        if let resetsAt = manager.oauthUsage?.weeklyResetsAt {
            let diff = max(0, resetsAt.timeIntervalSinceNow)
            let fmt = DateFormatter()
            fmt.dateStyle = .none
            fmt.timeStyle = .short
            let timeStr = fmt.string(from: resetsAt)
            let d = Int(diff) / 86400
            let h = (Int(diff) % 86400) / 3600
            let m = (Int(diff) % 3600) / 60
            if d > 1 {
                return "Resets \(fmt.string(from: resetsAt).isEmpty ? "soon" : "at \(timeStr)") · in \(d)d \(h)h"
            } else if d == 1 {
                return "Resets tomorrow at \(timeStr) · in \(h)h \(m)m"
            } else if h > 0 {
                return "Resets today at \(timeStr) · in \(h)h \(m)m"
            } else {
                return "Resets at \(timeStr) · in \(m)m"
            }
        }

        // Fall back to calendar-computed next Monday
        let calendar = Calendar.current
        var comps = DateComponents()
        comps.weekday = 2   // Monday
        comps.hour    = 0
        comps.minute  = 0
        comps.second  = 0
        guard let nextMonday = calendar.nextDate(
            after: Date(),
            matching: comps,
            matchingPolicy: .nextTime
        ) else { return "Resets every Monday" }

        let diff = max(0, nextMonday.timeIntervalSinceNow)
        let d = Int(diff) / 86400
        let h = (Int(diff) % 86400) / 3600
        let m = (Int(diff) % 3600) / 60

        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        let timeStr = fmt.string(from: nextMonday)

        if d > 1 {
            return "Resets Monday at \(timeStr) · in \(d)d \(h)h"
        } else if d == 1 {
            return "Resets tomorrow at \(timeStr) · in \(h)h \(m)m"
        } else {
            return "Resets tonight at \(timeStr) · in \(h)h \(m)m"
        }
    }

    private func usageBar(
        label: String,
        fraction: Double?,          // nil = no data yet
        subtitle: String,
        isLive: Bool = false
    ) -> some View {
        let f = fraction.map { min($0, 1.0) } ?? 0.0
        let hasData = fraction != nil
        let barColor: Color = f > 0.9 ? .red : f > 0.7 ? .orange : .accentColor

        return VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if isLive {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .help("Live data from Claude API")
                }
                Spacer()
                if hasData {
                    Text("\(Int(f * 100))%")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(barColor)
                        .monospacedDigit()
                } else {
                    Text("—")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }
            }
            // Bar track (always shown; fill only when data is available)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 8)
                    if hasData {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(barColor)
                            .frame(width: max(geo.size.width * f, f > 0 ? 8 : 0), height: 8)
                            .animation(.easeInOut(duration: 0.4), value: f)
                    }
                }
            }
            .frame(height: 8)
            HStack {
                Text(hasData ? subtitle : "Waiting for data…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func miniStat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.callout)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - API Cost Summary Card

    private var costSummaryCard: some View {
        let (cost, tokens) = costAndTokens(for: selectedPeriod)
        let reqs = requests(for: selectedPeriod)
        return GroupBox {
            HStack(spacing: 0) {
                statPill(label: "Cost", value: cost.costString, accent: true)
                Divider().frame(height: 40)
                statPill(label: "Tokens", value: tokens.tokenString)
                Divider().frame(height: 40)
                statPill(label: "Requests", value: "\(reqs)")
            }
        }
    }

    private func statPill(label: String, value: String, accent: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(accent ? Color.accentColor : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Model Section

    private var modelSection: some View {
        GroupBox("By Model") {
            if manager.currentStats.byModel.isEmpty {
                emptyLabel
            } else {
                VStack(spacing: 0) {
                    if manager.displayMode == .usage {
                        tableHeader(["Model", "Requests", "Tokens"])
                        Divider()
                        ForEach(sortedModels, id: \.model) { m in
                            HStack {
                                Text(m.model.displayName).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(m.requestCount)").frame(width: 80, alignment: .trailing).monospacedDigit()
                                Text(allTokens(m).tokenString).frame(width: 80, alignment: .trailing).monospacedDigit()
                            }
                            .font(.callout).padding(.vertical, 5)
                            rowDivider(last: m.model == sortedModels.last?.model)
                        }
                    } else {
                        tableHeader(["Model", "Requests", "Tokens", "Cost"])
                        Divider()
                        ForEach(sortedModels, id: \.model) { m in
                            HStack {
                                Text(m.model.displayName).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(m.requestCount)").frame(width: 60, alignment: .trailing).monospacedDigit()
                                Text(allTokens(m).tokenString).frame(width: 60, alignment: .trailing).monospacedDigit()
                                Text(m.cost.costString).frame(width: 64, alignment: .trailing).monospacedDigit()
                            }
                            .font(.callout).padding(.vertical, 5)
                            rowDivider(last: m.model == sortedModels.last?.model)
                        }
                    }
                }
            }
        }
    }

    private var sortedModels: [ModelStats] {
        manager.currentStats.byModel.values.sorted { $0.cost > $1.cost }
    }

    private func allTokens(_ m: ModelStats) -> Int {
        m.inputTokens + m.outputTokens + m.cacheWriteTokens + m.cacheReadTokens
    }

    // MARK: - Project Section

    private var projectSection: some View {
        GroupBox("By Project") {
            if manager.currentStats.byProject.isEmpty {
                emptyLabel
            } else {
                VStack(spacing: 0) {
                    if manager.displayMode == .usage {
                        tableHeader(["Project", "Requests", "Tokens"])
                        Divider()
                        ForEach(sortedProjects, id: \.projectName) { p in
                            HStack {
                                Text(p.projectName).frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1).truncationMode(.middle)
                                Text("\(p.requestCount)").frame(width: 80, alignment: .trailing).monospacedDigit()
                                Text(p.totalTokens.tokenString).frame(width: 80, alignment: .trailing).monospacedDigit()
                            }
                            .font(.callout).padding(.vertical, 5)
                            rowDivider(last: p.projectName == sortedProjects.last?.projectName)
                        }
                    } else {
                        tableHeader(["Project", "Requests", "Tokens", "Cost"])
                        Divider()
                        ForEach(sortedProjects, id: \.projectName) { p in
                            HStack {
                                Text(p.projectName).frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1).truncationMode(.middle)
                                Text("\(p.requestCount)").frame(width: 60, alignment: .trailing).monospacedDigit()
                                Text(p.totalTokens.tokenString).frame(width: 60, alignment: .trailing).monospacedDigit()
                                Text(p.cost.costString).frame(width: 64, alignment: .trailing).monospacedDigit()
                            }
                            .font(.callout).padding(.vertical, 5)
                            rowDivider(last: p.projectName == sortedProjects.last?.projectName)
                        }
                    }
                }
            }
        }
    }

    private var sortedProjects: [ProjectStats] {
        manager.currentStats.byProject.values.sorted { $0.cost > $1.cost }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Text("\(manager.currentStats.recordCount) total requests")
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Text("Auto-refreshes every 60s")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    // MARK: - Shared Helpers

    private var emptyLabel: some View {
        Text("No data yet")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func rowDivider(last: Bool) -> some View {
        if !last { Divider().opacity(0.4) }
    }

    private func tableHeader(_ cols: [String]) -> some View {
        let rest = Array(cols.dropFirst())
        let fixedW: CGFloat = cols.count == 4 ? 60 : 80
        return HStack {
            Text(cols[0]).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(rest.enumerated()), id: \.offset) { idx, col in
                let isLast = idx == rest.count - 1
                Text(col).frame(width: (cols.count == 4 && isLast) ? 64 : fixedW, alignment: .trailing)
            }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 3)
    }

    private func costAndTokens(for period: TimePeriod) -> (Double, Int) {
        let s = manager.currentStats
        switch period {
        case .today: return (s.todayCost,   s.todayTokens)
        case .week:  return (s.weekCost,    s.weekTokens)
        case .month: return (s.monthCost,   s.monthTokens)
        case .all:   return (s.allTimeCost, s.allTimeTokens)
        }
    }

    private func requests(for period: TimePeriod) -> Int {
        let s = manager.currentStats
        switch period {
        case .today: return s.todayRequests
        case .week:  return s.weekRequests
        case .month: return s.monthRequests
        case .all:   return s.recordCount
        }
    }
}

// MARK: - Date Relative String

extension Date {
    var relativeString: String {
        let diff = Date().timeIntervalSince(self)
        switch diff {
        case ..<5:    return "just now"
        case ..<60:   return "\(Int(diff))s ago"
        case ..<3600: return "\(Int(diff / 60))m ago"
        default:      return "\(Int(diff / 3600))h ago"
        }
    }
}
