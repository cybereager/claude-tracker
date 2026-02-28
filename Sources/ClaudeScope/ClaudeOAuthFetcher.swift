import Foundation
import Security
import CommonCrypto
import SQLite3

// MARK: - Shared Result Type

struct OAuthUsageData {
    let fiveHourUtilization: Double?   // 0.0 – 1.0
    let weeklyUtilization: Double?     // 0.0 – 1.0
    let fiveHourResetsAt: Date?
    let weeklyResetsAt: Date?
}

// MARK: - Errors

enum OAuthError: LocalizedError {
    case noCredentials
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:               return "No credentials found. Open Chrome and sign in to claude.ai, then relaunch."
        case .invalidResponse:             return "Invalid response from Claude API"
        case .httpError(let c, let m):     return "HTTP \(c): \(m)"
        }
    }
}

// MARK: - Main Fetcher (tries Chrome → OAuth file)

struct ClaudeOAuthFetcher {

    static func fetchUsage() async throws -> OAuthUsageData {
        // 1. Chrome cookie approach (primary)
        if let data = try? await ChromeUsageFetcher.fetch() {
            return data
        }
        // 2. ~/.claude/.credentials.json OAuth fallback
        if let data = try? await OAuthFileFetcher.fetch() {
            return data
        }
        throw OAuthError.noCredentials
    }
}

// MARK: - Chrome Cookie Approach

private struct ChromeUsageFetcher {

    static func fetch() async throws -> OAuthUsageData {
        let (sessionKey, orgId) = try ChromeCookieReader.readSessionAndOrg()
        guard !sessionKey.isEmpty else { throw OAuthError.noCredentials }

        // If orgId not in cookies, discover it from the session API
        let resolvedOrgId: String
        if let oid = orgId {
            resolvedOrgId = oid
        } else {
            resolvedOrgId = try await discoverOrgId(sessionKey: sessionKey)
        }

        return try await fetchClaudeAiUsage(sessionKey: sessionKey, orgId: resolvedOrgId)
    }

    private static func discoverOrgId(sessionKey: String) async throws -> String {
        // GET /api/organizations returns [{id, ...}], pick first
        let url = URL(string: "https://claude.ai/api/organizations")!
        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: req)
        // Response is an array of org objects
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = arr.first,
           let id = first["id"] as? String {
            return id
        }
        throw OAuthError.invalidResponse
    }

    private static func fetchClaudeAiUsage(sessionKey: String, orgId: String) async throws -> OAuthUsageData {
        let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!
        var req = URLRequest(url: url)
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.httpError(http.statusCode, body)
        }

        // This endpoint returns utilization as 0–100 (not 0.0–1.0)
        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
        struct Response: Decodable {
            let fiveHour: Window?
            let sevenDay: Window?
            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
            }
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return iso.date(from: s) ?? isoPlain.date(from: s)
        }

        return OAuthUsageData(
            fiveHourUtilization: decoded.fiveHour?.utilization.map { $0 / 100.0 },
            weeklyUtilization:   decoded.sevenDay?.utilization.map  { $0 / 100.0 },
            fiveHourResetsAt:    parseDate(decoded.fiveHour?.resetsAt),
            weeklyResetsAt:      parseDate(decoded.sevenDay?.resetsAt)
        )
    }
}

// MARK: - Chrome Cookie Reader

private struct ChromeCookieReader {

    /// Returns (sessionKey, lastActiveOrg?) — both decrypted from Chrome's cookie store.
    static func readSessionAndOrg() throws -> (String, String?) {
        let src = chromeCookiesPath()
        guard let src else { throw OAuthError.noCredentials }

        // Copy to temp file so we don't conflict with Chrome's file lock
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claudescope_cc_tmp.sqlite")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: src, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let encSession = queryCookie(db: tmp.path, host: ".claude.ai", name: "sessionKey")
        let encOrg     = queryCookie(db: tmp.path, host: ".claude.ai", name: "lastActiveOrg")

        guard let encSession else { throw OAuthError.noCredentials }

        let key = try chromeAESKey()
        let sessionKey = try decrypt(encSession, key: key)
        let orgId      = encOrg.flatMap { try? decrypt($0, key: key) }

        return (sessionKey, orgId)
    }

    // MARK: SQLite query

    private static func queryCookie(db path: String, host: String, name: String) -> Data? {
        var dbHandle: OpaquePointer?
        guard sqlite3_open_v2(path, &dbHandle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(dbHandle) }

        let sql = "SELECT encrypted_value FROM cookies WHERE host_key=? AND name=? ORDER BY last_access_utc DESC LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dbHandle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (host as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let bytes = sqlite3_column_blob(stmt, 0)
        let count = sqlite3_column_bytes(stmt, 0)
        guard let bytes, count > 0 else { return nil }
        return Data(bytes: bytes, count: Int(count))
    }

    // MARK: Chrome path discovery

    private static func chromeCookiesPath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "Library/Application Support/Google/Chrome/Default/Cookies",
            "Library/Application Support/Google/Chrome Beta/Default/Cookies",
            "Library/Application Support/Chromium/Default/Cookies",
            "Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies",
            "Library/Application Support/Microsoft Edge/Default/Cookies"
        ]
        for rel in candidates {
            let url = home.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    // MARK: Key derivation

    private static func chromeAESKey() throws -> Data {
        // Read "Chrome Safe Storage" password from Keychain using modern API
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "Chrome Safe Storage" as CFString,
            kSecAttrAccount: "Chrome" as CFString,
            kSecReturnData:  true as CFBoolean,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let pwdData = result as? Data, !pwdData.isEmpty else {
            throw OAuthError.noCredentials
        }
        let password = pwdData

        // PBKDF2-HMAC-SHA1(password, salt:"saltysalt", iterations:1003, keyLen:16)
        let salt = Data("saltysalt".utf8)
        var key = Data(count: 16)
        let pbkdfStatus = key.withUnsafeMutableBytes { keyBuf in
            password.withUnsafeBytes { pwdBuf in
                salt.withUnsafeBytes { saltBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwdBuf.baseAddress?.assumingMemoryBound(to: Int8.self),
                        pwdBuf.count,
                        saltBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltBuf.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        16
                    )
                }
            }
        }
        guard pbkdfStatus == kCCSuccess else { throw OAuthError.noCredentials }
        return key
    }

    // MARK: AES-128-CBC decrypt

    /// Chrome cookie values are: `v10` (3 bytes) + AES-128-CBC ciphertext.
    /// IV = 16 space characters (0x20).
    private static func decrypt(_ data: Data, key: Data) throws -> String {
        // Strip leading prefix: "v10" or "v11"
        let prefix = 3
        guard data.count > prefix else { throw OAuthError.invalidResponse }
        let ciphertext = data.dropFirst(prefix)

        let iv = Data(repeating: 0x20, count: 16)  // 16 spaces
        var outLen = ciphertext.count + kCCBlockSizeAES128
        var outBuf = Data(count: outLen)

        let cryptStatus: CCCryptorStatus = outBuf.withUnsafeMutableBytes { outPtr in
            ciphertext.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, ciphertext.count,
                            outPtr.baseAddress, outLen,
                            &outLen
                        )
                    }
                }
            }
        }
        guard cryptStatus == kCCSuccess else { throw OAuthError.invalidResponse }
        outBuf = outBuf.prefix(outLen)
        guard let str = String(data: outBuf, encoding: .utf8) else { throw OAuthError.invalidResponse }
        return str
    }
}

// MARK: - OAuth File Fallback

private struct OAuthFileFetcher {

    private struct CredFile: Decodable {
        let claudeAiOauth: Entry?
        struct Entry: Decodable {
            let accessToken: String?
            enum CodingKeys: String, CodingKey { case accessToken }
        }
    }

    static func fetch() async throws -> OAuthUsageData {
        let home  = FileManager.default.homeDirectoryForCurrentUser
        let url   = home.appendingPathComponent(".claude/.credentials.json")
        guard let data  = try? Data(contentsOf: url),
              let creds = try? JSONDecoder().decode(CredFile.self, from: data),
              let token = creds.claudeAiOauth?.accessToken,
              !token.isEmpty else {
            throw OAuthError.noCredentials
        }
        return try await callAnthropicOAuthAPI(accessToken: token)
    }

    private static func callAnthropicOAuthAPI(accessToken: String) async throws -> OAuthUsageData {
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20",      forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }
        guard http.statusCode == 200 else {
            throw OAuthError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        struct Window: Decodable {
            let utilization: Double?
            let resetsAt: String?
            enum CodingKeys: String, CodingKey {
                case utilization
                case resetsAt = "resets_at"
            }
        }
        struct Response: Decodable {
            let fiveHour: Window?
            let sevenDay: Window?
            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
            }
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter(); iso2.formatOptions = [.withInternetDateTime]
        func parseDate(_ s: String?) -> Date? { guard let s else { return nil }; return iso.date(from: s) ?? iso2.date(from: s) }

        // OAuth endpoint returns utilization as 0.0–1.0
        return OAuthUsageData(
            fiveHourUtilization: decoded.fiveHour?.utilization,
            weeklyUtilization:   decoded.sevenDay?.utilization,
            fiveHourResetsAt:    parseDate(decoded.fiveHour?.resetsAt),
            weeklyResetsAt:      parseDate(decoded.sevenDay?.resetsAt)
        )
    }
}
