import Foundation
import os

private let logger = Logger(subsystem: "com.blitz.macos", category: "PortAllocator")

/// Find a free TCP port
struct PortAllocator {
    /// Get a random available TCP port
    static func findFreePort() -> UInt16 {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // Let OS pick
        addr.sin_addr.s_addr = UInt32(INADDR_ANY).bigEndian

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            logger.error("socket() failed: \(errno)")
            return 0
        }
        defer { close(sock) }

        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("bind() failed: \(errno)")
            return 0
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gsnResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &addrLen)
            }
        }

        guard gsnResult == 0 else {
            logger.error("getsockname() failed: \(errno)")
            return 0
        }

        let port = UInt16(bigEndian: boundAddr.sin_port)
        return port
    }
}
