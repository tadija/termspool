import Foundation
import CTermSpool
#if os(Linux)
import Glibc
#else
import Darwin
#endif

private struct TerminalError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

public enum TerminationTarget: Sendable {
    case process, processGroup
}

public final class TerminalPTY: @unchecked Sendable {
    private let fd: Int32
    private let pid: Int32
    private let lock = NSLock()
    private let inputLock = NSLock()
    private var closed = false
    private let terminationTarget: TerminationTarget

    public init(executable: String, arguments: [String] = [], workingDirectory: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                terminationTarget: TerminationTarget = .processGroup) throws {
        self.terminationTarget = terminationTarget
        let args = [executable] + arguments
        guard executable.hasPrefix("/"), !args.contains(where: { $0.utf8.contains(0) }),
              workingDirectory?.utf8.contains(0) != true,
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") &&
                  !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            throw TerminalError("Invalid terminal launch parameters")
        }
        let pointers = args.map { strdup($0) }
        let variables = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (pointers + variables).forEach { free($0) } }
        guard !pointers.contains(nil), !variables.contains(nil) else { throw TerminalError("Out of memory") }
        var master: Int32 = -1
        let pid = termspool_spawn_pty(executable, pointers + [nil], variables + [nil], workingDirectory, &master)
        guard pid > 0 else { throw TerminalError("Cannot launch terminal PTY") }; self.pid = pid; fd = master
    }
    public func readChunk() async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var pollFD = pollfd(fd: self.fd, events: Int16(POLLIN), revents: 0)
                while true {
                    self.lock.lock(); let closed = self.closed; self.lock.unlock()
                    if closed { continuation.resume(returning: nil); return }
                    let result = poll(&pollFD, 1, 250)
                    if result == 0 { continue }
                    if result < 0 { if errno == EINTR { continue }; continuation.resume(returning: nil); return }
                    var bytes = [UInt8](repeating: 0, count: 16384)
                    self.lock.lock()
                    let count = self.closed ? -1 : read(self.fd, &bytes, bytes.count)
                    self.lock.unlock()
                    continuation.resume(returning: count > 0 ? Data(bytes.prefix(count)) : nil); return
                }
            }
        }
    }
    public func input(_ data: Data) throws {
        guard data.count <= 65536 else { throw TerminalError("Input too large") }
        inputLock.lock(); defer { inputLock.unlock() }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                lock.lock()
                guard !closed else { lock.unlock(); throw TerminalError("Terminal closed") }
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                let writeError = errno
                lock.unlock()
                if count > 0 { offset += count; continue }
                if count < 0 && writeError == EINTR { continue }
                if count < 0 && (writeError == EAGAIN || writeError == EWOULDBLOCK) {
                    // Let the reader drain output while the child catches up with input.
                    // Periodically recheck closed so disconnects can interrupt a blocked paste.
                    var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let result = poll(&writable, 1, 250)
                    if result >= 0 || errno == EINTR { continue }
                }
                throw TerminalError("PTY write failed")
            }
        }
    }
    public func resize(cols: Int, rows: Int) throws {
        guard (2...500).contains(cols), (2...300).contains(rows) else { throw TerminalError("Invalid terminal size") }
        lock.lock(); defer { lock.unlock() }; if !closed {
            _ = termspool_resize_pty(fd, UInt16(cols), UInt16(rows))
            // Also notify OpenSSH directly; it forwards local geometry to the remote PTY.
            _ = kill(pid, SIGWINCH)
        }
    }
    public func signal(_ signal: String) throws {
        switch signal { case "INT": try input(Data([3])); case "EOF": try input(Data([4])); default: throw TerminalError("Unsupported terminal signal") }
    }
    public func closeSession() {
        lock.lock(); if closed { lock.unlock(); return }; closed = true
        _ = kill(terminationTarget == .processGroup ? -pid : pid, SIGHUP); _ = close(fd); lock.unlock()
        let child = pid; let terminationTarget = terminationTarget
        DispatchQueue.global().async {
            var status: Int32 = 0
            for _ in 0..<20 { if waitpid(child, &status, WNOHANG) != 0 { return }; usleep(50_000) }
            _ = kill(terminationTarget == .processGroup ? -child : child, SIGKILL); _ = waitpid(child, &status, 0)
        }
    }
    deinit { closeSession() }
}
