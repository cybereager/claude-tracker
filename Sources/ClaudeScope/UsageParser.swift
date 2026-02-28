import Foundation

// MARK: - File Offset Cache

actor FileOffsetCache {
    private var offsets: [String: UInt64] = [:]

    func offset(for path: String) -> UInt64 {
        return offsets[path] ?? 0
    }

    func setOffset(_ offset: UInt64, for path: String) {
        offsets[path] = offset
    }

    func clearAll() {
        offsets.removeAll()
    }
}

// MARK: - Usage Parser

actor UsageParser {
    private let projectsURL: URL
    private let offsetCache = FileOffsetCache()
    private var allRecords: [UsageRecord] = []

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.projectsURL = home.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    func parseAll() throws -> [UsageRecord] {
        allRecords = []
        Task { await offsetCache.clearAll() }
        let files = findAllJSONLFiles()
        for fileURL in files {
            let records = parseFile(at: fileURL, fromOffset: 0)
            allRecords.append(contentsOf: records)
        }
        return allRecords
    }

    func parseIncremental() throws -> [UsageRecord] {
        let files = findAllJSONLFiles()
        for fileURL in files {
            let path = fileURL.path
            // Capture the offset synchronously — we're inside the actor already
            // so we need to use a local var and update after
            let currentSize = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 ?? 0
            // We need to synchronously get the offset — use a local snapshot approach
            let newRecords = parseFileIncremental(at: fileURL, currentSize: currentSize)
            allRecords.append(contentsOf: newRecords)
        }
        return allRecords
    }

    // MARK: - Internal Helpers (isolated to actor)

    private var offsetSnapshot: [String: UInt64] = [:]

    func snapshotOffsets() {
        // Used to read offsets synchronously within actor context
        // offsetCache is separate actor, so we maintain a local mirror
    }

    // Local offset mirror (same actor, no async needed)
    private var localOffsets: [String: UInt64] = [:]

    private func parseFileIncremental(at url: URL, currentSize: UInt64) -> [UsageRecord] {
        let path = url.path
        let knownOffset = localOffsets[path] ?? 0
        guard currentSize > knownOffset else { return [] }
        let records = parseFile(at: url, fromOffset: knownOffset)
        return records
    }

    private func parseFile(at url: URL, fromOffset: UInt64) -> [UsageRecord] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        if fromOffset > 0 {
            try? handle.seek(toOffset: fromOffset)
        }

        var records: [UsageRecord] = []
        var remainder = Data()
        let chunkSize = 65_536
        let newlineByte = UInt8(ascii: "\n")
        var lastGoodOffset = fromOffset

        // Deduplication: Claude streams multiple JSONL lines per API call, each with the same
        // message.id + requestId and identical (cumulative) token counts. We count each
        // unique API call exactly once, matching CodexBar's approach.
        var seenKeys = Set<String>()

        while true {
            let chunk: Data
            if #available(macOS 10.15.4, *) {
                guard let c = try? handle.read(upToCount: chunkSize), !c.isEmpty else { break }
                chunk = c
            } else {
                let c = handle.readData(ofLength: chunkSize)
                if c.isEmpty { break }
                chunk = c
            }
            remainder.append(chunk)

            while let newlineIndex = remainder.firstIndex(of: newlineByte) {
                let lineData = remainder[remainder.startIndex..<newlineIndex]
                remainder = Data(remainder[(newlineIndex + 1)...])

                if let (record, dedupKey) = parseLine(lineData, fileURL: url) {
                    if let key = dedupKey {
                        if seenKeys.contains(key) {
                            // Duplicate streaming chunk for the same API call — skip
                        } else {
                            seenKeys.insert(key)
                            records.append(record)
                        }
                    } else {
                        // Older log entries without IDs: treat as distinct
                        records.append(record)
                    }
                }
                if let currentPos = try? handle.offset() {
                    lastGoodOffset = currentPos - UInt64(remainder.count)
                }
            }
        }

        localOffsets[url.path] = lastGoodOffset
        return records
    }

    private static let decoder = JSONDecoder()

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Returns (record, dedupKey) where dedupKey = "messageId:requestId" when both are present.
    /// Callers must skip records whose dedupKey has already been seen in this file scan.
    private func parseLine(_ data: Data, fileURL: URL) -> (UsageRecord, String?)? {
        guard !data.isEmpty else { return nil }

        guard let entry = try? Self.decoder.decode(RawEntry.self, from: data) else { return nil }
        guard entry.type == "assistant" else { return nil }
        guard let message = entry.message else { return nil }
        guard let rawModel = message.model, !rawModel.isEmpty else { return nil }
        guard let modelKind = ModelKind.from(rawModel) else { return nil }
        guard let usage = message.usage else { return nil }

        let totalTokens = usage.inputTokens + usage.outputTokens +
                          usage.cacheCreationInputTokens + usage.cacheReadInputTokens
        guard totalTokens > 0 else { return nil }

        guard let date = parseTimestamp(entry.timestamp) else { return nil }

        let project = projectName(from: entry.cwd, fileURL: fileURL)
        let hasStopReason = message.stopReason != nil

        let record = UsageRecord(
            timestamp: date,
            projectName: project,
            model: modelKind,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreationTokens: usage.cacheCreationInputTokens,
            cacheReadTokens: usage.cacheReadInputTokens,
            hasStopReason: hasStopReason
        )

        // Build dedup key from message.id + requestId (same as CodexBar).
        // Claude emits multiple streaming JSONL lines per API call with identical token counts;
        // only the first occurrence for each unique pair should be counted.
        let dedupKey: String?
        if let msgId = message.id, let reqId = entry.requestId {
            dedupKey = "\(msgId):\(reqId)"
        } else {
            dedupKey = nil
        }

        return (record, dedupKey)
    }

    private func parseTimestamp(_ str: String) -> Date? {
        if let d = Self.iso8601WithFraction.date(from: str) { return d }
        return Self.iso8601NoFraction.date(from: str)
    }

    private func projectName(from cwd: String?, fileURL: URL) -> String {
        if let cwd = cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        let folderName = fileURL.deletingLastPathComponent().lastPathComponent
        // Encoded folder names like "-Users-raj-Projects-cosmico-bank" → "cosmico-bank"
        let parts = folderName.split(separator: "-")
        return parts.last.map(String.init) ?? folderName
    }

    private func findAllJSONLFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            files.append(fileURL)
        }
        return files
    }
}
