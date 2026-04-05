import Foundation

enum LoginShellEnvironment {
    private struct CacheKey: Hashable {
        let shellPath: String
        let home: String?
        let zdotdir: String?
    }

    private static let startMarker = "__BLITZ_ENV_START__"
    private static let endMarker = "__BLITZ_ENV_END__"
    private static let cacheLock = NSLock()
    private static var cachedSnapshots: [CacheKey: [String: String]] = [:]

    static func mergedEnvironment(
        baseEnvironment: [String: String],
        shellPath: String
    ) -> [String: String] {
        guard let shellEnvironment = cachedEnvironment(
            shellPath: shellPath,
            baseEnvironment: baseEnvironment
        ) else {
            return baseEnvironment
        }

        var merged = baseEnvironment
        for (key, value) in shellEnvironment {
            merged[key] = value
        }
        return merged
    }

    static func captureEnvironment(
        shellPath: String,
        baseEnvironment: [String: String]
    ) -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-l", "-i", "-c", captureScript]
        process.environment = baseEnvironment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let outputHandle = outputPipe.fileHandleForReading
        let outputLock = NSLock()
        var outputData = Data()

        outputHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputLock.lock()
            outputData.append(data)
            outputLock.unlock()
        }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            print("[LoginShellEnvironment] Failed to start \(shellPath): \(error)")
            return nil
        }

        process.waitUntilExit()
        outputHandle.readabilityHandler = nil

        let trailingData = outputHandle.readDataToEndOfFile()
        outputLock.lock()
        outputData.append(trailingData)
        let capturedOutput = outputData
        outputLock.unlock()

        guard let output = String(data: capturedOutput, encoding: .utf8) else {
            return nil
        }

        guard let startRange = output.range(of: startMarker),
              let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex)
        else {
            if process.terminationStatus != 0 {
                print("[LoginShellEnvironment] \(shellPath) exited with status \(process.terminationStatus)")
            }
            return nil
        }

        let jsonString = output[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = jsonString.data(using: .utf8),
              let environment = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String]
        else {
            return nil
        }

        return environment
    }

    private static func cachedEnvironment(
        shellPath: String,
        baseEnvironment: [String: String]
    ) -> [String: String]? {
        let key = CacheKey(
            shellPath: shellPath,
            home: baseEnvironment["HOME"],
            zdotdir: baseEnvironment["ZDOTDIR"]
        )

        cacheLock.lock()
        if let cached = cachedSnapshots[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let captured = captureEnvironment(
            shellPath: shellPath,
            baseEnvironment: baseEnvironment
        ) else {
            return nil
        }

        cacheLock.lock()
        cachedSnapshots[key] = captured
        cacheLock.unlock()
        return captured
    }

    private static let captureScript = """
    printf '%s\\n' '__BLITZ_ENV_START__'
    /usr/bin/python3 - <<'PY'
    import json
    import os
    print(json.dumps(dict(os.environ)))
    PY
    printf '%s\\n' '__BLITZ_ENV_END__'
    """
}
