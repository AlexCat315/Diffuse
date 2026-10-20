import Foundation
import Testing
@testable import GuavaUITerminal

/// Runs real programs on a pseudo terminal. Output is applied on the main
/// queue, which the suite yields to while waiting.
@Suite("Terminal session", .serialized)
@MainActor
struct SessionTests {
    private func session(_ command: TerminalCommand) -> TerminalSession {
        TerminalSession(command: command, scrollbackLines: 100) { DispatchQueue.main.async(execute: $0) }
    }

    private func screen(_ session: TerminalSession) -> String {
        let frame = session.frame
        return (0..<frame.rows).map { frame.text(ofRow: $0) }.joined(separator: "\n")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("Program output reaches the screen and the exit code is reported")
    func output() async throws {
        let session = session(TerminalCommand(executable: "/bin/sh", arguments: ["-c", "printf 'hello\\033[1mworld'; exit 3"]))
        var events: [TerminalSession.Event] = []
        session.onEvent = { events.append($0) }
        try session.start()
        #expect(session.status == .running)
        try await waitUntil { session.status != .running }
        #expect(session.status == .exited(code: 3))
        #expect(events.last == .exited(code: 3))
        #expect(screen(session).hasPrefix("helloworld"))
        #expect(screen(session).contains("[Process exited with code 3]"))
        #expect(throws: TerminalError.alreadyStarted) { try session.start() }
    }

    @Test("Typed input is echoed by the line discipline and hang-up ends the program")
    func echo() async throws {
        let session = session(TerminalCommand(executable: "cat"))
        try session.start()
        session.send("ping\r")
        try await waitUntil { screen(session).components(separatedBy: "ping").count >= 3 }
        session.terminate()
        try await waitUntil { session.status != .running }
        #expect(session.status == .exited(code: 128 + SIGHUP))
    }

    @Test("The program sees the fitted grid size and later resizes")
    func size() async throws {
        let session = session(TerminalCommand(executable: "/bin/sh",
                                               arguments: ["-c", "stty size; read _; stty size"]))
        session.fit(columns: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        try session.start()
        try await waitUntil { screen(session).contains("30 100") }
        session.fit(columns: 60, rows: 20, cellWidth: 8, cellHeight: 16)
        session.send("\r")
        try await waitUntil { screen(session).contains("20 60") }
    }

    @Test("Child environment identifies the emulator and honours overrides")
    func environment() async throws {
        var command = TerminalCommand(executable: "/bin/sh", arguments: ["-c", "printf \"$TERM:$GUAVA_TEST\""],
                                      workingDirectory: URL(fileURLWithPath: "/"))
        command.environment["GUAVA_TEST"] = "on"
        let session = session(command)
        try session.start()
        try await waitUntil { session.status != .running }
        #expect(screen(session).hasPrefix("xterm-256color:on"))
    }

    @Test("Missing executables fail before forking and say so on screen")
    func missing() {
        let error = TerminalError.executableNotFound("definitely-not-a-real-binary-guava")
        let session = session(TerminalCommand(executable: "definitely-not-a-real-binary-guava"))
        #expect(throws: error) { try session.start() }
        #expect(session.status == .failed(error))
        #expect(screen(session).hasPrefix("[Executable not found: definitely-not-a-real-binary-guava]"))
        #expect(throws: TerminalError.alreadyStarted) { try session.start() }
    }

    @Test("User input returns the viewport to the live screen")
    func inputScrollsToBottom() {
        let session = session(.loginShell)
        session.fit(columns: 10, rows: 2, cellWidth: 8, cellHeight: 16)
        session.feed(Array("1\r\n2\r\n3\r\n4".utf8))
        session.scroll(rows: -2)
        #expect(!session.frame.scroll.isAtBottom)
        session.send("x")
        #expect(session.frame.scroll.isAtBottom)
    }
}
