import Foundation

/// One dumb shared file sink for the current app launch.
enum BlitzLaunchLog {
#if DEBUG
    private static let fileManager = FileManager.default
    private static let queue = DispatchQueue(label: "blitz.launch-log")

    static let fileURL = BlitzPaths.launchLogFile

    static func reset() {
        queue.sync {
            try? fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            // Launch directories are unique, so preserving any early writes is
            // better than truncating the file again.
            if !fileManager.fileExists(atPath: fileURL.path) {
                try? Data().write(to: fileURL, options: .atomic)
            }
        }
    }

    static func append(_ entry: String) {
        queue.sync {
            try? fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            guard let data = entry.data(using: .utf8) else { return }
            if fileManager.fileExists(atPath: fileURL.path) {
                do {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } catch {
                    try? data.write(to: fileURL, options: .atomic)
                }
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
#else
    static func reset() {}

    static func append(_ entry: String) {
        _ = entry
    }
#endif
}
