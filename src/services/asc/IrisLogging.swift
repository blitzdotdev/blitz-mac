import Foundation

func irisLog(_ msg: String) {
#if DEBUG
    let ts = ISO8601DateFormatter().string(from: Date())
    BlitzLaunchLog.append("[\(ts)] [IRIS] \(msg)\n")
#else
    _ = msg
#endif
}
