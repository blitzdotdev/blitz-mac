import Foundation

/// Thin ASC/event logger that writes into the shared per-launch debug file.
actor ASCUpdateLogger {
    static let shared = ASCUpdateLogger()

    private let formatter: ISO8601DateFormatter
    private let maxBodyLength = 12_000

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    func event(_ name: String, metadata: [String: String] = [:]) async {
        let metadataSuffix = render(metadata: metadata)
        let message = metadataSuffix.isEmpty ? name : "\(name) \(metadataSuffix)"
        await write(kind: "EVENT", message: message)
    }

    func request(id: String, method: String, path: String, body: Data?) async {
        await write(
            kind: "REQUEST",
            message: "id=\(id) \(method.uppercased()) \(path)",
            body: formatBody(body)
        )
    }

    func response(id: String, method: String, path: String, statusCode: Int, body: Data) async {
        await write(
            kind: "RESPONSE",
            message: "id=\(id) \(method.uppercased()) \(path) -> \(statusCode)",
            body: formatBody(body)
        )
    }

    func failure(id: String, method: String, path: String, error: Error) async {
        await write(
            kind: "FAILURE",
            message: "id=\(id) \(method.uppercased()) \(path) error=\(sanitize(error.localizedDescription))"
        )
    }

    func snapshot(label: String, body: String) async {
        await write(kind: "STATE", message: sanitize(label), body: body)
    }

    private func write(kind: String, message: String, body: String? = nil) async {
        let timestamp = formatter.string(from: Date())
        var entry = "[\(timestamp)] [ASC] [\(kind)] \(message)\n"
        if let body, !body.isEmpty {
            entry += "body:\n\(body)\n"
        }
        entry += "\n"
        BlitzLaunchLog.append(entry)
    }

    private func render(metadata: [String: String]) -> String {
        metadata.keys.sorted().compactMap { key in
            guard let value = metadata[key], !value.isEmpty else { return nil }
            return "\(key)=\(sanitize(value))"
        }.joined(separator: " ")
    }

    private func formatBody(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "<empty>" }

        if let object = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(object),
           let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            return truncate(prettyString)
        }

        if let utf8String = String(data: data, encoding: .utf8), !utf8String.isEmpty {
            return truncate(utf8String)
        }

        return "<\(data.count) bytes>"
    }

    private func truncate(_ value: String) -> String {
        guard value.count > maxBodyLength else { return value }
        return String(value.prefix(maxBodyLength)) + "\n… <truncated>"
    }

    private func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "\\n")
    }
}
