import Foundation

struct AccountInfo {
    let email: String
    let displayName: String
    let planType: PlanType
    let hasExtraUsage: Bool
}

/// Reads account info from Claude's local config file (~/.claude.json).
/// This file is written by the Claude Code CLI and contains OAuth account data.
struct AccountDetector {

    static func detect() -> AccountInfo? {
        guard let url = configFileURL(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthAccount = json["oauthAccount"] as? [String: Any],
              let email = oauthAccount["emailAddress"] as? String,
              !email.isEmpty
        else { return nil }

        let displayName = oauthAccount["displayName"] as? String ?? ""
        let billingType = oauthAccount["billingType"] as? String ?? ""
        let hasExtraUsage = oauthAccount["hasExtraUsageEnabled"] as? Bool ?? false

        // Infer plan from billing type:
        //   "stripe_subscription" = Pro (or Max — Max shows hasExtraUsageEnabled = true)
        //   anything else (empty, "free") = API/free tier
        let plan: PlanType
        if billingType.lowercased().contains("subscription") {
            plan = hasExtraUsage ? .max5 : .pro
        } else {
            plan = .api
        }

        return AccountInfo(
            email: email,
            displayName: displayName,
            planType: plan,
            hasExtraUsage: hasExtraUsage
        )
    }

    /// Returns the URL of ~/.claude.json, falling back to the most recent backup.
    private static func configFileURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Primary: ~/.claude.json
        let primary = home.appendingPathComponent(".claude.json")
        if FileManager.default.fileExists(atPath: primary.path) {
            return primary
        }

        // Fallback: most recent backup in ~/.claude/backups/
        let backupsDir = home.appendingPathComponent(".claude/backups")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: backupsDir,
            includingPropertiesForKeys: nil
        )) ?? []

        return files
            .filter { $0.lastPathComponent.hasPrefix(".claude.json.backup.") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // sort by timestamp suffix descending
            .first
    }
}
