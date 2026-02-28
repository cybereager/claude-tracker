import Foundation

struct CostCalculator {

    static func compute(from records: [UsageRecord], now: Date = Date()) -> UsageStats {
        var stats = UsageStats()
        // recordCount = complete API responses (non-null stop_reason, proxy for subscription turns)
        stats.recordCount = records.filter { $0.hasStopReason }.count
        stats.lastUpdated = now

        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        var earliestFiveHour: Date? = nil

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)

        // Monday-based week start
        let weekday = calendar.component(.weekday, from: startOfToday)
        let daysFromMonday = (weekday + 5) % 7
        let startOfWeek = calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfToday)!

        // Month start
        var monthComponents = calendar.dateComponents([.year, .month], from: now)
        monthComponents.day = 1
        let startOfMonth = calendar.date(from: monthComponents)!

        for record in records {
            let cost = record.cost
            let tokens = record.inputTokens + record.outputTokens +
                         record.cacheCreationTokens + record.cacheReadTokens

            stats.allTimeCost   += cost
            stats.allTimeTokens += tokens

            // Cost and tokens: all API calls (accurate for billing)
            // Requests / turns: complete responses only (non-null stop_reason, matches Claude's subscription counting)
            if record.timestamp >= startOfMonth {
                stats.monthCost   += cost
                stats.monthTokens += tokens
                if record.hasStopReason { stats.monthRequests += 1 }
            }
            if record.timestamp >= startOfWeek {
                stats.weekCost   += cost
                stats.weekTokens += tokens
                if record.hasStopReason { stats.weekRequests += 1 }
            }
            if record.timestamp >= startOfToday {
                stats.todayCost   += cost
                stats.todayTokens += tokens
                if record.hasStopReason { stats.todayRequests += 1 }
            }
            if record.timestamp >= fiveHoursAgo {
                stats.fiveHourTokens += tokens
                if record.hasStopReason { stats.fiveHourRequests += 1 }
                // Track earliest timestamp in window to compute exact reset time
                if earliestFiveHour == nil || record.timestamp < earliestFiveHour! {
                    earliestFiveHour = record.timestamp
                }
            }

            // Per-model accumulation
            if stats.byModel[record.model] == nil {
                stats.byModel[record.model] = ModelStats(model: record.model)
            }
            stats.byModel[record.model]!.cost              += cost
            stats.byModel[record.model]!.inputTokens       += record.inputTokens
            stats.byModel[record.model]!.outputTokens      += record.outputTokens
            stats.byModel[record.model]!.cacheWriteTokens  += record.cacheCreationTokens
            stats.byModel[record.model]!.cacheReadTokens   += record.cacheReadTokens
            if record.hasStopReason { stats.byModel[record.model]!.requestCount += 1 }

            // Per-project accumulation
            if stats.byProject[record.projectName] == nil {
                stats.byProject[record.projectName] = ProjectStats(projectName: record.projectName)
            }
            stats.byProject[record.projectName]!.cost        += cost
            stats.byProject[record.projectName]!.totalTokens += tokens
            if record.hasStopReason { stats.byProject[record.projectName]!.requestCount += 1 }
        }

        stats.fiveHourWindowResets = earliestFiveHour.map { $0.addingTimeInterval(5 * 3600) }
        return stats
    }
}

// MARK: - Formatting Helpers

extension Double {
    var costString: String {
        if self >= 1000 {
            return String(format: "$%.0f", self)
        } else if self >= 1 {
            return String(format: "$%.2f", self)
        } else if self >= 0.001 {
            return String(format: "$%.3f", self)
        } else if self == 0 {
            return "$0.00"
        } else {
            return String(format: "$%.4f", self)
        }
    }
}

extension Int {
    var tokenString: String {
        switch self {
        case 1_000_000...: return String(format: "%.1fM", Double(self) / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", Double(self) / 1_000)
        default:           return "\(self)"
        }
    }
}
