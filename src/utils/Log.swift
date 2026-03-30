import Foundation

// Usage: Log("something happened")  Log("value: \(x)")
// File: ~/.blitz/logs/<launch-timestamp>/blitz.log

func LogClear() {
    BlitzLaunchLog.reset()
}

func Log(_ message: String, file: String = #file, line: Int = #line) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    let entry = "[\(f.string(from: Date()))] \(URL(fileURLWithPath: file).lastPathComponent):\(line)  \(message)\n"
    print(entry, terminator: "")
    BlitzLaunchLog.append(entry)
}
