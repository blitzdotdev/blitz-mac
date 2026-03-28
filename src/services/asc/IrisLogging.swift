import Foundation

private let irisLogPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".blitz/iris-debug.log")

func irisLog(_ msg: String) {
#if DEBUG
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }

    if FileManager.default.fileExists(atPath: irisLogPath.path),
       let handle = try? FileHandle(forWritingTo: irisLogPath) {
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
        return
    }

    let dir = irisLogPath.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? data.write(to: irisLogPath)
#else
    _ = msg
#endif
}
