import Foundation

// MARK: - Raw JSONL Parsing Models

struct RawEntry: Decodable {
    let type: String
    let timestamp: String
    let cwd: String?
    let sessionId: String?
    let message: RawMessage?
    let isSidechain: Bool?
}

struct RawMessage: Decodable {
    let model: String?
    let usage: RawUsage?
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case model
        case usage
        case stopReason = "stop_reason"
    }
}

struct RawUsage: Decodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = (try? c.decode(Int.self, forKey: .inputTokens)) ?? 0
        outputTokens = (try? c.decode(Int.self, forKey: .outputTokens)) ?? 0
        cacheCreationInputTokens = (try? c.decode(Int.self, forKey: .cacheCreationInputTokens)) ?? 0
        cacheReadInputTokens = (try? c.decode(Int.self, forKey: .cacheReadInputTokens)) ?? 0
    }
}

// MARK: - Domain Models

struct UsageRecord {
    let timestamp: Date
    let projectName: String
    let model: ModelKind
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    /// true when stop_reason is non-nil — i.e. a complete API response (end_turn, tool_use,
    /// stop_sequence), not a streaming intermediate chunk. Claude's subscription counting
    /// tracks ALL complete responses, not just end_turn final replies.
    let hasStopReason: Bool

    var cost: Double {
        model.pricing.cost(
            input: inputTokens,
            output: outputTokens,
            cacheWrite: cacheCreationTokens,
            cacheRead: cacheReadTokens
        )
    }
}

enum ModelKind: String, CaseIterable, Identifiable, Hashable {
    case opus4   = "claude-opus-4"
    case sonnet4 = "claude-sonnet-4"
    case haiku45 = "claude-haiku-4-5"
    case unknown = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus4:   return "Opus 4"
        case .sonnet4: return "Sonnet 4"
        case .haiku45: return "Haiku 4.5"
        case .unknown: return "Other"
        }
    }

    var pricing: Pricing {
        switch self {
        case .opus4:
            return Pricing(inputPerM: 15, outputPerM: 75, cacheWritePerM: 18.75, cacheReadPerM: 1.50)
        case .sonnet4:
            return Pricing(inputPerM: 3, outputPerM: 15, cacheWritePerM: 3.75, cacheReadPerM: 0.30)
        case .haiku45:
            return Pricing(inputPerM: 0.80, outputPerM: 4, cacheWritePerM: 1.00, cacheReadPerM: 0.08)
        case .unknown:
            return Pricing(inputPerM: 3, outputPerM: 15, cacheWritePerM: 3.75, cacheReadPerM: 0.30)
        }
    }

    static func from(_ rawModel: String) -> ModelKind? {
        guard rawModel != "<synthetic>" else { return nil }
        if rawModel.contains("claude-opus-4")    { return .opus4 }
        if rawModel.contains("claude-haiku-4-5") { return .haiku45 }
        if rawModel.contains("claude-sonnet-4")  { return .sonnet4 }
        return .unknown
    }
}

struct Pricing {
    let inputPerM: Double
    let outputPerM: Double
    let cacheWritePerM: Double
    let cacheReadPerM: Double

    func cost(input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        return (
            Double(input)      * inputPerM      +
            Double(output)     * outputPerM     +
            Double(cacheWrite) * cacheWritePerM +
            Double(cacheRead)  * cacheReadPerM
        ) / 1_000_000.0
    }
}

// MARK: - Aggregated Stats

struct UsageStats {
    var todayCost: Double = 0
    var weekCost: Double = 0
    var monthCost: Double = 0
    var allTimeCost: Double = 0

    var todayTokens: Int = 0
    var weekTokens: Int = 0
    var monthTokens: Int = 0
    var allTimeTokens: Int = 0

    var byModel: [ModelKind: ModelStats] = [:]
    var byProject: [String: ProjectStats] = [:]

    var todayRequests: Int = 0
    var weekRequests: Int = 0
    var monthRequests: Int = 0

    /// Messages sent in the last 5 hours (Claude's short-term rate-limit window)
    var fiveHourRequests: Int = 0
    var fiveHourTokens: Int = 0

    /// When the 5-hour session window resets (earliest msg in window + 5h). nil if no msgs.
    var fiveHourWindowResets: Date? = nil

    var lastUpdated: Date = Date()
    var recordCount: Int = 0

    static let empty = UsageStats()
}

struct ModelStats {
    var model: ModelKind
    var cost: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var cacheReadTokens: Int = 0
    var requestCount: Int = 0
}

struct ProjectStats {
    var projectName: String
    var cost: Double = 0
    var totalTokens: Int = 0
    var requestCount: Int = 0
}

enum TimePeriod: String, CaseIterable {
    case today = "Today"
    case week  = "This Week"
    case month = "This Month"
    case all   = "All Time"
}

// MARK: - Display Mode

enum DisplayMode: String, CaseIterable {
    case cost  = "API Cost"
    case usage = "Subscription"
}

// MARK: - Plan Type

enum PlanType: String, CaseIterable {
    case api   = "API"
    case pro   = "Pro"
    case max5  = "Max (5x)"
    case max20 = "Max (20x)"

    var displayName: String { rawValue }
    var isSubscription: Bool { self != .api }

    /// Approximate API-response limit per 5-hour session window.
    /// Counts all complete responses (non-null stop_reason), matching Claude's actual
    /// subscription tracking. nil = API plan (no subscription window).
    var fiveHourLimit: Int? {
        switch self {
        case .api:   return nil
        case .pro:   return 186
        case .max5:  return 930
        case .max20: return 3_720
        }
    }

    /// Approximate API-response limit per 7-day window.
    var weeklyLimit: Int? {
        switch self {
        case .api:   return nil
        case .pro:   return 1_950
        case .max5:  return 9_750
        case .max20: return 39_000
        }
    }
}
