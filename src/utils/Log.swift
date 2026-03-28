import Foundation

// Usage: Log("something happened")  Log("value: \(x)")
// File:  ~/.blitz/debug.log  (cleared on each launch via LogClear())

private let _logURL: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".blitz/debug.log")
}()

func LogClear() {
    try? FileManager.default.createDirectory(
        at: _logURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? "".write(to: _logURL, atomically: true, encoding: .utf8)
}

func Log(_ message: String, file: String = #file, line: Int = #line) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    let entry = "[\(f.string(from: Date()))] \(URL(fileURLWithPath: file).lastPathComponent):\(line)  \(message)\n"
    print(entry, terminator: "")
    guard let data = entry.data(using: .utf8),
          let handle = try? FileHandle(forWritingTo: _logURL) else { return }
    handle.seekToEndOfFile()
    handle.write(data)
    try? handle.close()
}
