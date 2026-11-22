# TermSpool

Embeddable interactive terminal sessions for Swift apps on macOS and Linux.

TermSpool starts a program with a controlling pseudo-terminal. A single reader receives the combined output of stdout and stderr as bytes, including ANSI escape sequences. The child starts with normal terminal line processing and an 80-column, 24-row window.

## Getting started

Add `https://github.com/tadija/termspool.git` as a Swift package dependency and link the `TermSpool` product. Requires Swift 6 and macOS 14 or Linux with glibc supporting `POSIX_SPAWN_SETSID`.

```swift
import Foundation
import TermSpool

func runSession() async throws {
    let terminal = try TerminalPTY(
        executable: "/bin/sh",
        arguments: ["-c", "read -r name; printf 'Hello, %s!\\n' \"$name\""],
        workingDirectory: "/tmp",
        environment: ["TERM": "xterm-256color"]
    )
    defer { terminal.closeSession() }

    try terminal.resize(cols: 100, rows: 32)
    try terminal.input(Data("Swift\n".utf8))
    while let bytes = await terminal.readChunk() {
        FileHandle.standardOutput.write(bytes)
    }
}
```

Supply an absolute executable path. Omitting the working directory or environment inherits the parent's value. An explicit environment replaces the inherited one. Write up to 64 KiB per input call. Resizes accept 2–500 columns and 2–300 rows and notify the child with SIGWINCH.

Use `signal("INT")` or `signal("EOF")` to send the terminal control bytes for Ctrl+C or Ctrl+D. The child's line discipline determines their effect. Closing the session releases the descriptor, sends SIGHUP, and reaps the child in the background, escalating to SIGKILL if needed. Termination targets the process group by default. Pass `terminationTarget: .process` to target only the launched child.

Run `swift test` to exercise the package against real pseudo-terminals.

---

`done for fun`
