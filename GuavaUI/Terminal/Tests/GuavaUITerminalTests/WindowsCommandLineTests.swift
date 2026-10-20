import Testing
@testable import GuavaUITerminal

/// The ConPTY backend only builds on Windows; its string encodings are
/// checked everywhere.
@Suite("Windows command line encoding")
struct WindowsCommandLineTests {
    @Test("Arguments round-trip through CommandLineToArgvW quoting rules")
    func quoting() {
        #expect(WindowsCommandLine.commandLineString(["C:\\Program Files\\pwsh.exe", "-NoLogo"])
                == #""C:\Program Files\pwsh.exe" -NoLogo"#)
        #expect(WindowsCommandLine.commandLineString(["echo", ""]) == #"echo """#)
        #expect(WindowsCommandLine.commandLineString(["say \"hi\""]) == #""say \"hi\"""#)
        #expect(WindowsCommandLine.commandLineString(["a\\\"b"]) == #""a\\\"b""#)
        #expect(WindowsCommandLine.commandLineString(["dir with space\\"]) == #""dir with space\\""#)
        #expect(WindowsCommandLine.commandLineString(["C:\\no\\spaces\\"]) == #"C:\no\spaces\"#)
    }

    @Test("The environment block is sorted case-insensitively and double-terminated")
    func environmentBlock() {
        let block = WindowsCommandLine.environmentBlockUTF16(["path": "C:\\", "Apple": "1", "TERM": "xterm"])
        let text = String(decoding: block, as: UTF16.self)
        #expect(text == "Apple=1\u{0}path=C:\\\u{0}TERM=xterm\u{0}\u{0}")
    }
}
