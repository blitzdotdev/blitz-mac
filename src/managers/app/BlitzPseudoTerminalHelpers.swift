import Foundation
import SwiftTerm

/// Local forkpty helper that restores default signal dispositions before exec.
/// App/test runners can ignore or mask signals like SIGHUP/SIGTERM, and children
/// launched through forkpty inherit that state unless we reset it explicitly.
enum BlitzPseudoTerminalHelpers {
    private struct CStringArray {
        let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let count: Int
    }

    static func fork(
        andExec executable: String,
        args: [String],
        env: [String],
        currentDirectory: String? = nil,
        desiredWindowSize: inout winsize
    ) -> (pid: pid_t, masterFd: Int32)? {
        guard let cArgs = allocateCStringArray(args),
              let cEnv = allocateCStringArray(env),
              let cExecutable = strdup(executable)
        else {
            return nil
        }

        var cCurrentDirectory: UnsafeMutablePointer<CChar>?
        if let currentDirectory {
            guard let duplicated = strdup(currentDirectory) else {
                freeCStringArray(cArgs)
                freeCStringArray(cEnv)
                free(cExecutable)
                return nil
            }
            cCurrentDirectory = duplicated
        }

        defer {
            freeCStringArray(cArgs)
            freeCStringArray(cEnv)
            free(cExecutable)
            if let cCurrentDirectory {
                free(cCurrentDirectory)
            }
        }

        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, &desiredWindowSize)
        if pid < 0 {
            return nil
        }

        if pid == 0 {
            resetSignalStateForExec()

            if let cCurrentDirectory {
                _ = chdir(cCurrentDirectory)
            }

            _ = execve(cExecutable, cArgs.base, cEnv.base)
            _exit(127)
        }

        return (pid, master)
    }

    static func setWinSize(masterPtyDescriptor: Int32, windowSize: inout winsize) -> Int32 {
        ioctl(masterPtyDescriptor, TIOCSWINSZ, &windowSize)
    }

    private static func allocateCStringArray(_ strings: [String]) -> CStringArray? {
        let base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        var initializedCount = 0

        for (index, string) in strings.enumerated() {
            guard let duplicated = strdup(string) else {
                for cleanupIndex in 0..<initializedCount {
                    free(base[cleanupIndex])
                }
                base.deallocate()
                return nil
            }
            base[index] = duplicated
            initializedCount += 1
        }

        base[strings.count] = nil
        return CStringArray(base: base, count: strings.count)
    }

    private static func freeCStringArray(_ array: CStringArray) {
        for index in 0..<array.count {
            free(array.base[index])
        }
        array.base.deallocate()
    }

    private static func resetSignalStateForExec() {
        for signalNumber in 1..<Int32(NSIG) {
            if signalNumber == SIGKILL || signalNumber == SIGSTOP {
                continue
            }
            _ = signal(signalNumber, SIG_DFL)
        }

        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        pthread_sigmask(SIG_SETMASK, &emptyMask, nil)
    }
}
