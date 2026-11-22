import Foundation
import Testing
import TermSpool
#if os(Linux)
import Glibc
#else
import Darwin
#endif
import CTermSpool

@Test func nativePTYUnblocksSignalsAndResizes() throws {
    var blocked = sigset_t(); sigemptyset(&blocked); sigaddset(&blocked, SIGWINCH)
    var previous = sigset_t(); _ = pthread_sigmask(SIG_BLOCK, &blocked, &previous)
    defer { _ = pthread_sigmask(SIG_SETMASK, &previous, nil) }
    let args = ["/bin/sh", "-c", "trap 'stty size; exit' WINCH; printf READY; while :; do sleep 0.05; done"]
    let pointers = args.map { strdup($0) }; defer { pointers.forEach { free($0) } }
    var argv = pointers + [nil]; var fd: Int32 = -1
    let pid = argv.withUnsafeMutableBufferPointer { termspool_spawn_pty("/bin/sh", $0.baseAddress, [nil], nil, &fd) }
    #expect(pid > 0); guard pid > 0 else { return }
    defer { _ = kill(-pid, SIGTERM); _ = close(fd); var status: Int32 = 0; _ = waitpid(pid, &status, 0) }
    func receive() -> String {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 2000) > 0 else { return "" }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &bytes, bytes.count)
        return count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
    }
    #expect(receive().contains("READY"))
    #expect(termspool_resize_pty(fd, 101, 31) == 0); _ = kill(pid, SIGWINCH)
    #expect(receive().contains("31 101"))
}

@Test func nativePTYStartsWithNormalOutputProcessing() throws {
    let args = ["/bin/sh", "-c", "printf 'NORMAL_ONE\\nNORMAL_TWO\\n'"]
    let pointers = args.map { strdup($0) }; defer { pointers.forEach { free($0) } }
    var argv = pointers + [nil]; var fd: Int32 = -1
    let pid = argv.withUnsafeMutableBufferPointer { termspool_spawn_pty("/bin/sh", $0.baseAddress, [nil], nil, &fd) }
    #expect(pid > 0); guard pid > 0 else { return }
    defer { _ = close(fd); var status: Int32 = 0; _ = waitpid(pid, &status, 0) }
    var output = Data()
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    while poll(&descriptor, 1, 2000) > 0 {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &bytes, bytes.count); if count <= 0 { break }
        output.append(contentsOf: bytes.prefix(count))
    }
    #expect(String(decoding: output, as: UTF8.self).contains("NORMAL_ONE\r\nNORMAL_TWO\r\n"))
}

@Test func interactiveProcess() async throws {
    let terminal = try TerminalPTY(executable: "/bin/sh",
        arguments: ["-c", "stty -echo; printf READY; read -r line; printf '\\033[31m%s:%s:%s\\033[0m\\n' \"$line\" \"$MARK\" \"$PWD\"; cat"],
        workingDirectory: "/", environment: ["MARK": "value", "PATH": "/usr/bin:/bin"])
    defer { terminal.closeSession() }
    let timeout = Task {
        try await Task.sleep(for: .seconds(5))
        terminal.closeSession()
    }
    defer { timeout.cancel() }
    var ready = Data()
    while ready.count < 5, let chunk = await terminal.readChunk() { ready.append(chunk) }
    try #require(ready == Data("READY".utf8))
    try terminal.input(Data("hello\n".utf8))
    try terminal.signal("EOF")
    var output = Data()
    while let chunk = await terminal.readChunk() { output.append(chunk) }
    #expect(output == Data("\u{1b}[31mhello:value:/\u{1b}[0m\r\n".utf8))
    terminal.closeSession()
    #expect(throws: (any Error).self) { try terminal.input(Data([1])) }
}
