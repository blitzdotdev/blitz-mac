import Foundation

struct SequencedPipeBuffer {
    private let newline: UInt8 = 0x0A
    private var buffer = Data()
    private var pendingChunks: [Int: Data] = [:]
    private var nextSequence = 0

    mutating func append(_ data: Data, sequence: Int) -> [Data] {
        pendingChunks[sequence] = data

        var lines: [Data] = []
        while let nextChunk = pendingChunks.removeValue(forKey: nextSequence) {
            nextSequence += 1

            if nextChunk.isEmpty {
                if !buffer.isEmpty {
                    lines.append(buffer)
                    buffer.removeAll(keepingCapacity: false)
                }
                continue
            }

            buffer.append(nextChunk)

            while let newlineIndex = buffer.firstIndex(of: newline) {
                let line = buffer.prefix(upTo: newlineIndex).filter { $0 != 0x0D }
                buffer.removeSubrange(...newlineIndex)
                lines.append(Data(line))
            }
        }

        return lines
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        pendingChunks.removeAll()
        nextSequence = 0
    }
}

actor ASCDaemonClient {
    private final class SequenceCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value += 1
            return current
        }

        func reset() {
            lock.lock()
            value = 0
            lock.unlock()
        }
    }

    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Swift.Error>
        let summary: String
        let startedAt: Date
    }

    struct HTTPResponse: Sendable {
        let statusCode: Int
        let headers: [String: [String]]
        let contentType: String
        let body: Data
    }

    private struct DaemonResponse<Result: Decodable>: Decodable {
        let id: String?
        let result: Result?
        let error: DaemonErrorPayload?
    }

    private struct DaemonErrorPayload: Decodable {
        let code: Int
        let message: String
        let data: String?
    }

    private struct SessionOpenResult: Decodable {
        let session: SessionInfo
    }

    private struct SessionInfo: Decodable {
        let profile: String?
        let usesInMemoryKey: Bool
    }

    private struct SessionRequestResult: Decodable {
        let statusCode: Int
        let headers: [String: [String]]?
        let contentType: String?
        let body: String?
    }

    enum Error: LocalizedError {
        case helperNotFound(String)
        case helperLaunchFailed(String)
        case invalidResponse
        case processExited(Int32, String)
        case helperError(String, String?)
        case invalidRequestBody
        case responseTimeout(String)

        var errorDescription: String? {
            switch self {
            case .helperNotFound(let message),
                 .helperLaunchFailed(let message):
                return message
            case .invalidResponse:
                return "Invalid response from ascd"
            case .processExited(let code, let stderr):
                if stderr.isEmpty {
                    return "ascd exited with status \(code)"
                }
                return "ascd exited with status \(code): \(stderr)"
            case .helperError(let message, let data):
                if let data, !data.isEmpty {
                    return "\(message): \(data)"
                }
                return message
            case .invalidRequestBody:
                return "Request body must be valid JSON"
            case .responseTimeout(let summary):
                return "Timed out waiting for ascd response: \(summary)"
            }
        }
    }

    private let credentials: ASCCredentials
    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()
    private let logger = ASCDaemonLogger.shared
    private let responseTimeoutSeconds: TimeInterval = 45

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var waitTask: Task<Void, Never>?
    private var stdoutReadHandle: FileHandle?
    private var stderrReadHandle: FileHandle?
    private var stdoutBuffer = SequencedPipeBuffer()
    private var stderrBuffer = SequencedPipeBuffer()
    private var pendingResponses: [String: PendingRequest] = [:]
    private var recentStderr: [String] = []
    private var requestCounter = 0
    private var sessionOpen = false
    private let stdoutSequenceCounter = SequenceCounter()
    private let stderrSequenceCounter = SequenceCounter()

    init(credentials: ASCCredentials) {
        self.credentials = credentials
        Task {
            await logger.info("ASCDaemonClient initialized keyId=\(Self.redact(credentials.keyId)) issuerId=\(Self.redact(credentials.issuerId))")
        }
    }

    deinit {
        stdoutReadHandle?.readabilityHandler = nil
        stderrReadHandle?.readabilityHandler = nil
        waitTask?.cancel()
        process?.terminate()
    }

    func request(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutMs: Int = 30_000,
        expectedStatusCodes: Set<Int> = []
    ) async throws -> HTTPResponse {
        try await ensureSessionOpen()

        var params: [String: Any] = [
            "method": method,
            "path": path,
        ]
        if !headers.isEmpty {
            params["headers"] = headers
        }
        if timeoutMs > 0 {
            params["timeoutMs"] = timeoutMs
        }
        if let body {
            params["body"] = try jsonObject(from: body)
        }

        let result: SessionRequestResult = try await send(method: "session.request", params: params)
        let response = HTTPResponse(
            statusCode: result.statusCode,
            headers: result.headers ?? [:],
            contentType: result.contentType ?? "",
            body: Data((result.body ?? "").utf8)
        )
        if (200..<300).contains(response.statusCode) || expectedStatusCodes.contains(response.statusCode) {
            await logger.debug("session.request \(method.uppercased()) \(Self.truncate(path)) -> \(response.statusCode) bytes=\(response.body.count)")
        } else {
            let bodySnippet = Self.truncate(String(decoding: response.body, as: UTF8.self), limit: 1200)
            await logger.error("session.request \(method.uppercased()) \(Self.truncate(path)) -> \(response.statusCode) contentType=\(response.contentType) body=\(bodySnippet)")
        }
        return response
    }

    func cliExec(args: [String]) async throws -> (exitCode: Int, stdout: String, stderr: String) {
        struct CLIExecResult: Decodable {
            let exitCode: Int
            let stdout: String?
            let stderr: String?
        }

        try await ensureProcessRunning()
        let result: CLIExecResult = try await send(method: "cli.exec", params: ["args": args])
        return (result.exitCode, result.stdout ?? "", result.stderr ?? "")
    }

    private func ensureSessionOpen() async throws {
        try await ensureProcessRunning()
        guard !sessionOpen else { return }
        _ = try await send(method: "session.open", params: nil) as SessionOpenResult
        sessionOpen = true
        await logger.info("ascd session opened")
    }

    private func ensureProcessRunning() async throws {
        if let process, process.isRunning, stdinHandle != nil {
            return
        }
        try startProcess()
    }

    private func startProcess() throws {
        let executablePath = try resolveExecutablePath()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executablePath]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = helperEnvironment()

        do {
            try process.run()
        } catch {
            Task {
                await logger.error("Failed to launch ascd at \(executablePath): \(error.localizedDescription)")
            }
            throw Error.helperLaunchFailed("Failed to launch ascd at \(executablePath): \(error.localizedDescription)")
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutReadHandle = stdoutPipe.fileHandleForReading
        self.stderrReadHandle = stderrPipe.fileHandleForReading
        self.sessionOpen = false
        self.recentStderr = []
        self.stdoutBuffer.reset()
        self.stderrBuffer.reset()
        self.stdoutSequenceCounter.reset()
        self.stderrSequenceCounter.reset()

        Task {
            await logger.info("Started ascd pid=\(process.processIdentifier) path=\(executablePath)")
        }

        let stdoutSequenceCounter = self.stdoutSequenceCounter
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, stdoutSequenceCounter] handle in
            let data = handle.availableData
            let sequence = stdoutSequenceCounter.next()
            Task {
                await self?.handlePipeData(data, isStdout: true, sequence: sequence)
            }
        }

        let stderrSequenceCounter = self.stderrSequenceCounter
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, stderrSequenceCounter] handle in
            let data = handle.availableData
            let sequence = stderrSequenceCounter.next()
            Task {
                await self?.handlePipeData(data, isStdout: false, sequence: sequence)
            }
        }

        waitTask = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
            await self.handleProcessExit(status: process.terminationStatus)
        }
    }

    private func resolveExecutablePath() throws -> String {
        let candidates = helperExecutableCandidates()

        for candidate in candidates where !candidate.isEmpty {
            if fileManager.isExecutableFile(atPath: candidate) {
                Task {
                    await logger.debug("Resolved ascd executable path: \(candidate)")
                }
                return candidate
            }
        }

        let searched = candidates.isEmpty ? "(no candidates)" : candidates.joined(separator: ", ")
        Task {
            await logger.error("ascd executable not found. searched=\(searched)")
        }
        throw Error.helperNotFound(
            "ascd not found. Bundle the signed helper at Contents/Helpers/ascd or set BLITZ_ASCD_PATH to the forked helper binary. Searched: \(searched)"
        )
    }

    private func helperExecutableCandidates() -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()

        func appendCandidate(_ rawValue: String?) {
            guard let rawValue else { return }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let expanded = NSString(string: trimmed).expandingTildeInPath
            let normalized: String
            if expanded.hasPrefix("/") {
                normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            } else {
                normalized = expanded
            }

            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            candidates.append(normalized)
        }

        appendCandidate(ProcessInfo.processInfo.environment["BLITZ_ASCD_PATH"])
        appendCandidate(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ascd").path)
        appendCandidate(
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers/ascd").path
        )
        appendCandidate(Bundle.main.privateFrameworksURL?.deletingLastPathComponent().appendingPathComponent("Helpers/ascd").path)

        return candidates
    }

    private func helperEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ASC_KEY_ID"] = credentials.keyId
        environment["ASC_ISSUER_ID"] = credentials.issuerId
        environment["ASC_PRIVATE_KEY"] = credentials.privateKey
        environment["ASC_PRIVATE_KEY_PATH"] = nil
        environment["ASC_PRIVATE_KEY_B64"] = nil
        environment["ASC_BYPASS_KEYCHAIN"] = "1"
        if environment["ASC_DEBUG"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            environment["ASC_DEBUG"] = nil
        }

        let isolatedConfigPath = fileManager.temporaryDirectory
            .appendingPathComponent("blitz-ascd-\(UUID().uuidString).json")
        try? fileManager.removeItem(at: isolatedConfigPath)
        environment["ASC_CONFIG_PATH"] = isolatedConfigPath.path
        Task {
            await logger.debug(
                "Prepared ascd environment keyId=\(Self.redact(credentials.keyId)) " +
                "issuerId=\(Self.redact(credentials.issuerId)) " +
                "configPath=\(isolatedConfigPath.path) " +
                "ascDebug=\(environment["ASC_DEBUG"] ?? "")"
            )
        }
        return environment
    }

    private func handlePipeData(_ data: Data, isStdout: Bool, sequence: Int) async {
        let lineData = if isStdout {
            stdoutBuffer.append(data, sequence: sequence)
        } else {
            stderrBuffer.append(data, sequence: sequence)
        }

        for entry in lineData {
            if let line = String(data: entry, encoding: .utf8) {
                if isStdout {
                    await handleStdoutLine(line)
                } else {
                    await handleStderrLine(line)
                }
            } else {
                await logger.error("Received non-UTF8 pipe output: \(entry.count) bytes")
            }
        }
    }

    private func handleStdoutLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else {
            await logger.error("Received non-UTF8 stdout from ascd")
            return
        }

        let metadata = extractResponseMetadata(from: data)
        guard let id = metadata.id else {
            await logger.error("Received stdout line without response id: \(Self.truncate(line, limit: 1200))")
            return
        }

        guard let pending = pendingResponses.removeValue(forKey: id) else {
            await logger.error("Received unmatched response id=\(id) summary=\(metadata.summary) raw=\(Self.truncate(line, limit: 1200))")
            return
        }

        let elapsed = Date().timeIntervalSince(pending.startedAt)
        await logger.debug("<- [\(id)] \(pending.summary) response=\(metadata.summary) elapsed=\(String(format: "%.3f", elapsed))s")
        pending.continuation.resume(returning: data)
    }

    private func handleStderrLine(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentStderr.append(trimmed)
        if recentStderr.count > 30 {
            recentStderr.removeFirst(recentStderr.count - 30)
        }
        await logger.error("ascd stderr: \(trimmed)")
    }

    private func handleProcessExit(status: Int32) async {
        let message = recentStderr.joined(separator: "\n")
        let error = Error.processExited(status, message)
        await logger.error("ascd exited status=\(status) stderr=\(Self.truncate(message, limit: 1200))")

        for (_, pending) in pendingResponses {
            pending.continuation.resume(throwing: error)
        }
        pendingResponses.removeAll()

        process = nil
        stdinHandle = nil
        sessionOpen = false
        stdoutReadHandle?.readabilityHandler = nil
        stderrReadHandle?.readabilityHandler = nil
        waitTask?.cancel()
        stdoutReadHandle = nil
        stderrReadHandle = nil
        stdoutBuffer.reset()
        stderrBuffer.reset()
        stdoutSequenceCounter.reset()
        stderrSequenceCounter.reset()
        waitTask = nil
    }

    private func send<Result: Decodable>(method: String, params: [String: Any]?, as type: Result.Type = Result.self) async throws -> Result {
        try await ensureProcessRunning()

        requestCounter += 1
        let id = "ascd-\(requestCounter)"
        let summary = Self.requestSummary(method: method, params: params)

        var request: [String: Any] = [
            "id": id,
            "method": method,
        ]
        if let params {
            request["params"] = params
        }

        let requestData = try JSONSerialization.data(withJSONObject: request, options: [])
        await logger.debug("-> [\(id)] \(summary)")

        let timeoutSeconds = self.responseTimeoutSeconds
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                await self?.failPendingRequest(id: id, error: Error.responseTimeout(summary))
            } catch {}
        }

        let rawResponse = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Swift.Error>) in
            pendingResponses[id] = PendingRequest(
                continuation: continuation,
                summary: summary,
                startedAt: Date()
            )
            do {
                try writeRequestLine(requestData)
            } catch {
                pendingResponses.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
        timeoutTask.cancel()

        let response: DaemonResponse<Result>
        do {
            response = try decoder.decode(DaemonResponse<Result>.self, from: rawResponse)
        } catch {
            await logger.error("Failed to decode response for [\(id)] \(summary): \(error.localizedDescription) raw=\(Self.truncate(String(decoding: rawResponse, as: UTF8.self), limit: 1200))")
            throw error
        }
        if let error = response.error {
            await logger.error("Helper returned error for [\(id)] \(summary): code=\(error.code) message=\(error.message) data=\(error.data ?? "")")
            throw Error.helperError(error.message, error.data)
        }
        guard let result = response.result else {
            await logger.error("Missing result payload for [\(id)] \(summary)")
            throw Error.invalidResponse
        }
        return result
    }

    private func failPendingRequest(id: String, error: Swift.Error) async {
        guard let pending = pendingResponses.removeValue(forKey: id) else { return }
        await logger.error("Timed out waiting for [\(id)] \(pending.summary)")
        pending.continuation.resume(throwing: error)
        await restartProcessAfterTimeout(id: id, summary: pending.summary)
    }

    private func restartProcessAfterTimeout(id: String, summary: String) async {
        guard let process else { return }
        await logger.error("Terminating ascd after timeout for [\(id)] \(summary) pid=\(process.processIdentifier)")
        sessionOpen = false
        stdinHandle = nil
        process.terminate()
    }

    private func writeRequestLine(_ requestData: Data) throws {
        guard let stdinHandle else {
            throw Error.helperLaunchFailed("ascd stdin is unavailable")
        }
        var line = requestData
        line.append(0x0A)
        try stdinHandle.write(contentsOf: line)
    }

    private func extractResponseMetadata(from data: Data) -> (id: String?, summary: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, "invalid-json")
        }

        let id = json["id"] as? String

        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 0
            let message = error["message"] as? String ?? "unknown"
            return (id, "error code=\(code) message=\(Self.truncate(message, limit: 200))")
        }

        if let result = json["result"] as? [String: Any] {
            if let statusCode = result["statusCode"] as? Int {
                let contentType = result["contentType"] as? String ?? ""
                return (id, "statusCode=\(statusCode) contentType=\(Self.truncate(contentType, limit: 120))")
            }
            let keys = result.keys.sorted().joined(separator: ",")
            return (id, "result keys=\(keys)")
        }

        return (id, "unknown-payload")
    }

    private func jsonObject(from data: Data) throws -> Any {
        guard !data.isEmpty else { return NSNull() }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func requestSummary(method: String, params: [String: Any]?) -> String {
        switch method {
        case "session.open":
            let profile = (params?["profile"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return profile.isEmpty ? "session.open" : "session.open profile=\(profile)"
        case "session.request":
            let httpMethod = (params?["method"] as? String)?.uppercased() ?? "UNKNOWN"
            let path = truncate(params?["path"] as? String ?? "")
            let timeoutDescription: String
            if let timeoutMs = params?["timeoutMs"] as? Int, timeoutMs > 0 {
                timeoutDescription = " timeoutMs=\(timeoutMs)"
            } else {
                timeoutDescription = ""
            }
            let bodyDescription: String
            if let body = params?["body"] {
                if let data = try? JSONSerialization.data(withJSONObject: body) {
                    bodyDescription = " bodyBytes=\(data.count)"
                } else {
                    bodyDescription = " body=unserializable"
                }
            } else {
                bodyDescription = ""
            }
            return "session.request \(httpMethod) \(path)\(timeoutDescription)\(bodyDescription)"
        case "cli.exec":
            let args = params?["args"] as? [String] ?? []
            return "cli.exec args=\(truncate(args.joined(separator: " "), limit: 200))"
        default:
            return params == nil ? method : "\(method) params"
        }
    }

    private static func truncate(_ value: String, limit: Int = 300) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: "\\n")
        if normalized.count <= limit {
            return normalized
        }
        return String(normalized.prefix(limit)) + "..."
    }

    private static func redact(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else {
            return String(repeating: "*", count: max(trimmed.count, 1))
        }
        let prefix = trimmed.prefix(4)
        let suffix = trimmed.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}
