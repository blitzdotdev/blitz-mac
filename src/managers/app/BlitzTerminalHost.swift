import AppKit
import Foundation
import SwiftTerm

protocol BlitzPTYProcessDelegate: AnyObject {
    func terminalProcess(_ process: BlitzPTYProcess, didReceive data: ArraySlice<UInt8>)
    func terminalProcess(_ process: BlitzPTYProcess, didTerminateWith exitCode: Int32?)
    func windowSize(for process: BlitzPTYProcess) -> winsize
}

/// Minimal forkpty-backed PTY runner for interactive shells.
///
/// SwiftTerm's current `LocalProcess` subprocess path starts the shell in a new session
/// without assigning the PTY as its controlling terminal. Interactive children launched
/// from that shell can then get suspended with `SIGTTIN` when they attempt to read input.
/// Using `forkpty` restores the expected controlling-TTY and foreground process-group setup.
final class BlitzPTYProcess {
    private let readSize = 128 * 1024
    private let pendingChunkFlushThreshold = 32
    private let pendingTimeSliceNs: UInt64 = 4_000_000

    private let dispatchQueue: DispatchQueue
    private let readQueue = DispatchQueue(label: "blitz.terminal.read")
    private let pendingLock = NSLock()

    private var io: DispatchIO?
    private var childMonitor: DispatchSourceProcess?
    private var pendingChunks: [[UInt8]] = []
    private var pendingChunkIndex = 0
    private var pendingScheduled = false

    weak var delegate: BlitzPTYProcessDelegate?

    private(set) var childfd: Int32 = -1
    private(set) var shellPid: pid_t = 0
    private(set) var isRunning = false

    init(delegate: BlitzPTYProcessDelegate, dispatchQueue: DispatchQueue = .main) {
        self.delegate = delegate
        self.dispatchQueue = dispatchQueue
    }

    func startProcess(
        executable: String = "/bin/bash",
        args: [String] = [],
        environment: [String]? = nil,
        execName: String? = nil,
        currentDirectory: String? = nil
    ) {
        guard !isRunning else { return }

        var shellArgs = args
        shellArgs.insert(execName ?? executable, at: 0)
        var size = delegate?.windowSize(for: self) ?? winsize()
        let env = environment ?? Terminal.getEnvironmentVariables(termName: "xterm-256color")

        guard let (shellPid, childfd) = BlitzPseudoTerminalHelpers.fork(
            andExec: executable,
            args: shellArgs,
            env: env,
            currentDirectory: currentDirectory,
            desiredWindowSize: &size
        ) else {
            delegate?.terminalProcess(self, didTerminateWith: nil)
            return
        }

        isRunning = true
        self.shellPid = shellPid
        self.childfd = childfd

        let fdToClose = childfd
        io = DispatchIO(
            type: .stream,
            fileDescriptor: childfd,
            queue: dispatchQueue,
            cleanupHandler: { _ in close(fdToClose) }
        )
        io?.setLimit(lowWater: 1)
        io?.setLimit(highWater: readSize)
        io?.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)

        childMonitor = DispatchSource.makeProcessSource(identifier: shellPid, eventMask: .exit, queue: dispatchQueue)
        childMonitor?.setEventHandler { [weak self] in
            self?.processTerminated()
        }
        if #available(macOS 10.12, *) {
            childMonitor?.activate()
        }
    }

    func send(data: ArraySlice<UInt8>) {
        guard isRunning else { return }

        data.withUnsafeBytes { ptr in
            let dispatchData = DispatchData(bytes: ptr)
            DispatchIO.write(
                toFileDescriptor: childfd,
                data: dispatchData,
                runningHandlerOn: DispatchQueue.global(qos: .userInitiated)
            ) { _, _ in }
        }
    }

    func resize() {
        guard isRunning else { return }
        var size = delegate?.windowSize(for: self) ?? winsize()
        _ = BlitzPseudoTerminalHelpers.setWinSize(masterPtyDescriptor: childfd, windowSize: &size)
    }

    func terminate() {
        let pid = shellPid
        if pid != 0 {
            terminateProcessGroupAndLeader(pid: pid)
        }

        io?.close()
        io = nil
        childfd = -1

        childStopped()
    }

    private func childStopped(cancelProcessMonitor: Bool = true) {
        isRunning = false
        if cancelProcessMonitor {
            childMonitor?.cancel()
            childMonitor = nil
        }
    }

    private func processTerminated() {
        var status: Int32 = 0
        let waitResult = waitpid(shellPid, &status, WNOHANG)
        let exitCode: Int32?
        if waitResult > 0 {
            if waitStatusExited(status) {
                exitCode = waitStatusExitCode(status)
            } else if waitStatusSignaled(status) {
                exitCode = waitStatusSignal(status)
            } else {
                exitCode = status
            }
        } else {
            exitCode = nil
        }

        delegate?.terminalProcess(self, didTerminateWith: exitCode)
        childStopped()
    }

    private func childProcessRead(done: Bool, data: DispatchData?, errno: Int32) {
        guard let data else {
            if !done, isRunning {
                io?.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)
            }
            return
        }

        if data.count == 0 {
            childfd = -1
            if isRunning {
                // PTY EOF can arrive before the process exit notification.
                childStopped(cancelProcessMonitor: false)
            }
            return
        }

        var chunk = [UInt8](repeating: 0, count: data.count)
        chunk.withUnsafeMutableBufferPointer { ptr in
            _ = data.copyBytes(to: ptr)
        }
        enqueueReceivedData(chunk)

        io?.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)
    }

    private func enqueueReceivedData(_ bytes: [UInt8]) {
        pendingLock.lock()
        pendingChunks.append(bytes)
        let shouldSchedule = !pendingScheduled
        if shouldSchedule {
            pendingScheduled = true
        }
        pendingLock.unlock()

        if shouldSchedule {
            dispatchQueue.async { [weak self] in
                self?.drainReceivedData()
            }
        }
    }

    private func drainReceivedData() {
        let start = DispatchTime.now().uptimeNanoseconds

        while true {
            var chunk: [UInt8]?

            pendingLock.lock()
            if pendingChunkIndex < pendingChunks.count {
                chunk = pendingChunks[pendingChunkIndex]
                pendingChunkIndex += 1
                if pendingChunkIndex >= pendingChunkFlushThreshold {
                    pendingChunks.removeFirst(pendingChunkIndex)
                    pendingChunkIndex = 0
                }
            } else {
                pendingChunks.removeAll(keepingCapacity: true)
                pendingChunkIndex = 0
                pendingScheduled = false
                pendingLock.unlock()
                return
            }
            pendingLock.unlock()

            if let chunk {
                delegate?.terminalProcess(self, didReceive: chunk[...])
            }

            if DispatchTime.now().uptimeNanoseconds - start >= pendingTimeSliceNs {
                dispatchQueue.async { [weak self] in
                    self?.drainReceivedData()
                }
                return
            }
        }
    }

    private func waitStatusExited(_ status: Int32) -> Bool {
        (status & 0x7f) == 0
    }

    private func waitStatusExitCode(_ status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }

    private func waitStatusSignaled(_ status: Int32) -> Bool {
        let signal = status & 0x7f
        return signal != 0 && signal != 0x7f
    }

    private func waitStatusSignal(_ status: Int32) -> Int32 {
        status & 0x7f
    }

    private func terminateProcessGroupAndLeader(pid: pid_t) {
        let processGroup = getpgid(pid)
        sendTerminationSignal(SIGHUP, to: pid, processGroup: processGroup)
        usleep(50_000)
        sendTerminationSignal(SIGTERM, to: pid, processGroup: processGroup)
        usleep(50_000)
        sendTerminationSignal(SIGKILL, to: pid, processGroup: processGroup)
    }

    private func sendTerminationSignal(_ signal: Int32, to pid: pid_t, processGroup: pid_t) {
        if processGroup > 0 {
            _ = kill(-processGroup, signal)
        }
        _ = kill(pid, signal)
    }
}

final class BlitzTerminalView: TerminalView, TerminalViewDelegate, BlitzPTYProcessDelegate {
    private static let navigationClusterKeyCodes: Set<UInt16> = [
        123, // left
        124, // right
        125, // down
        126, // up
        115, // home
        119, // end
        116, // page up
        121, // page down
    ]
    private static let focusInSequence = [UInt8]([0x1b, 0x5b, 0x49])
    private static let focusOutSequence = [UInt8]([0x1b, 0x5b, 0x4f])

    private lazy var process = BlitzPTYProcess(delegate: self)
    private var localKeyEventMonitor: Any?

    var onProcessTerminated: ((Int32?) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onDirectoryChanged: ((String?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        if let localKeyEventMonitor {
            NSEvent.removeMonitor(localKeyEventMonitor)
        }
    }

    private func setup() {
        terminalDelegate = self
        localKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            guard self.window?.firstResponder === self else { return event }
            return self.normalizedKeyEvent(from: event)
        }
    }

    func startProcess(
        executable: String = "/bin/bash",
        args: [String] = [],
        environment: [String]? = nil,
        execName: String? = nil,
        currentDirectory: String? = nil
    ) {
        process.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: execName,
            currentDirectory: currentDirectory
        )
    }

    func terminate() {
        process.terminate()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if Self.shouldSuppressTerminalGeneratedSequence(data) {
            return
        }
        process.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        process.resize()
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitleChanged?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onDirectoryChanged?(directory)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let string = String(bytes: content, encoding: .utf8) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([string as NSString])
        }
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func terminalProcess(_ process: BlitzPTYProcess, didReceive data: ArraySlice<UInt8>) {
        feed(byteArray: data)
    }

    func terminalProcess(_ process: BlitzPTYProcess, didTerminateWith exitCode: Int32?) {
        onProcessTerminated?(exitCode)
    }

    func windowSize(for process: BlitzPTYProcess) -> winsize {
        let frame = self.frame
        return winsize(
            ws_row: UInt16(terminal.rows),
            ws_col: UInt16(terminal.cols),
            ws_xpixel: UInt16(frame.width),
            ws_ypixel: UInt16(frame.height)
        )
    }

    static func normalizedModifierFlags(
        for keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> NSEvent.ModifierFlags {
        guard modifierFlags.contains(.numericPad),
              navigationClusterKeyCodes.contains(keyCode),
              let charactersIgnoringModifiers,
              let scalar = charactersIgnoringModifiers.unicodeScalars.first else {
            return modifierFlags
        }

        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey,
             NSRightArrowFunctionKey,
             NSUpArrowFunctionKey,
             NSDownArrowFunctionKey,
             NSHomeFunctionKey,
             NSEndFunctionKey,
             NSPageUpFunctionKey,
             NSPageDownFunctionKey:
            return modifierFlags.subtracting(.numericPad)
        default:
            return modifierFlags
        }
    }

    private func normalizedKeyEvent(from event: NSEvent) -> NSEvent {
        let normalizedFlags = Self.normalizedModifierFlags(
            for: event.keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        )
        guard normalizedFlags != event.modifierFlags else {
            return event
        }

        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: normalizedFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    static func shouldSuppressTerminalGeneratedSequence(_ data: ArraySlice<UInt8>) -> Bool {
        let bytes = Array(data)
        return bytes == Self.focusInSequence || bytes == Self.focusOutSequence
    }
}
