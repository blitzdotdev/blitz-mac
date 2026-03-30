import Foundation

actor ASCDaemonLogger {
    static let shared = ASCDaemonLogger()

    private let formatter: ISO8601DateFormatter

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    func info(_ message: String) async {
        await write(level: "INFO", message: message)
    }

    func error(_ message: String) async {
        await write(level: "ERROR", message: message)
    }

    func debug(_ message: String) async {
        await write(level: "DEBUG", message: message)
    }

    private func write(level: String, message: String) async {
        let timestamp = formatter.string(from: Date())
        BlitzLaunchLog.append("[\(timestamp)] [ASCD] [\(level)] \(message)\n")
    }
}
