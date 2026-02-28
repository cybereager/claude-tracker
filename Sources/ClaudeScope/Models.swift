import Foundation

// MARK: - Raw JSONL Parsing Models

struct RawEntry: Decodable {
    let type: String
    let timestamp: String
    let cwd: String?
    let sessionId: String?
    let requestId: String?        // top-level field — used for deduplication with message.id
    let message: RawMessage?
    let isSidechain: Bool?
}

struct RawMessage: Decodable {
    let id: String?               // message.id — used for deduplication with requestId
    let model: String?
    let usage: RawUsage?
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case id
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
    /// true when stop_reason is non-nil (end_turn, tool_use, stop_sequence).
    /// Used as a proxy for "billable subscription turn" in the absence of OAuth access.
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
    case opus4    = "claude-opus-4"      // original claude-opus-4 — $15/$75
    case opus4x   = "claude-opus-4.x"    // opus 4.5 / 4.6 — $5/$25
    case sonnet4  = "claude-sonnet-4"    // sonnet 4.x — $3/$15 (tiered at 200k)
    case haiku45  = "claude-haiku-4-5"   // haiku 4.5 — $1/$5
    case unknown  = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus4:   return "Opus 4"
        case .opus4x:  return "Opus 4.5/4.6"
        case .sonnet4: return "Sonnet 4"
        case .haiku45: return "Haiku 4.5"
        case .unknown: return "Other"
        }
    }

    var pricing: Pricing {
        switch self {
        case .opus4:
            // Original claude-opus-4 (claude-opus-4-20250514)
            return Pricing(inputPerM: 15, outputPerM: 75, cacheWritePerM: 18.75, cacheReadPerM: 1.50)
        case .opus4x:
            // claude-opus-4-5, claude-opus-4-6 and later minor versions
            return Pricing(inputPerM: 5, outputPerM: 25, cacheWritePerM: 6.25, cacheReadPerM: 0.50)
        case .sonnet4:
            // Tiered: $3/$15 up to 200k input tokens, $6/$22.50 above
            return Pricing(
                inputPerM: 3, outputPerM: 15, cacheWritePerM: 3.75, cacheReadPerM: 0.30,
                inputPerMAbove: 6, outputPerMAbove: 22.50,
                cacheWritePerMAbove: 7.50, cacheReadPerMAbove: 0.60,
                thresholdTokens: 200_000)
        case .haiku45:
            return Pricing(inputPerM: 1, outputPerM: 5, cacheWritePerM: 1.25, cacheReadPerM: 0.10)
        case .unknown:
            return Pricing(inputPerM: 3, outputPerM: 15, cacheWritePerM: 3.75, cacheReadPerM: 0.30)
        }
    }

    static func from(_ rawModel: String) -> ModelKind? {
        guard rawModel != "<synthetic>" else { return nil }
        if rawModel.contains("claude-haiku-4-5") { return .haiku45 }
        if rawModel.contains("claude-sonnet-4")  { return .sonnet4 }
        if rawModel.contains("claude-opus-4") {
            // opus-4-5 / opus-4-6 are the cheaper newer minor versions
            if rawModel.contains("claude-opus-4-5") || rawModel.contains("claude-opus-4-6") {
                return .opus4x
            }
            return .opus4
        }
        return .unknown
    }
}

struct Pricing {
    let inputPerM: Double
    let outputPerM: Double
    let cacheWritePerM: Double
    let cacheReadPerM: Double

    // Optional tiered pricing (e.g. Sonnet 4 doubles after 200k input tokens per request)
    var inputPerMAbove: Double? = nil
    var outputPerMAbove: Double? = nil
    var cacheWritePerMAbove: Double? = nil
    var cacheReadPerMAbove: Double? = nil
    var thresholdTokens: Int? = nil

    func cost(input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        func tiered(_ tokens: Int, base: Double, above: Double?) -> Double {
            let t = max(0, tokens)
            guard let threshold = thresholdTokens, let above else {
                return Double(t) * base / 1_000_000
            }
            let below = min(t, threshold)
            let over = max(t - threshold, 0)
            return (Double(below) * base + Double(over) * above) / 1_000_000
        }
        return tiered(input,      base: inputPerM,      above: inputPerMAbove)
             + tiered(output,     base: outputPerM,     above: outputPerMAbove)
             + tiered(cacheWrite, base: cacheWritePerM, above: cacheWritePerMAbove)
             + tiered(cacheRead,  base: cacheReadPerM,  above: cacheReadPerMAbove)
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

    /// Unique API calls in the last 5 hours (deduplicated, non-null stop_reason).
    /// NOTE: true subscription usage % requires OAuth/web access (like CodexBar uses).
    /// This is an approximation from local JSONL data.
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

    /// Approximate unique-API-call limit per 5-hour session window.
    /// Calibrated against deduplicated (message.id+requestId) counts.
    /// nil = API plan (no subscription window).
    var fiveHourLimit: Int? {
        switch self {
        case .api:   return nil
        case .pro:   return 45
        case .max5:  return 225
        case .max20: return 900
        }
    }

    /// Approximate unique-API-call limit per 7-day window.
    var weeklyLimit: Int? {
        switch self {
        case .api:   return nil
        case .pro:   return 500
        case .max5:  return 2_500
        case .max20: return 10_000
        }
    }
}
