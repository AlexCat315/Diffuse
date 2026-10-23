import GuavaPluginKit

/// Formats a LaTeX document: LF line endings, no trailing spaces or tabs,
/// at most one blank line in a row, and one final newline.
func format(text: String) -> String {
    guard !text.isEmpty else { return JSON.string("").serialized }
    var lines: [String] = []
    var current: [UInt8] = []
    var source = text
    source.withUTF8 { bytes in
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0A || byte == 0x0D {
                if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 1
                }
                lines.append(trimmedLine(current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            index += 1
        }
    }
    if !current.isEmpty { lines.append(trimmedLine(current)) }

    var output: [String] = []
    var pendingBlank = false
    for line in lines {
        if line.isEmpty {
            if !output.isEmpty { pendingBlank = true }
            continue
        }
        if pendingBlank { output.append("") }
        pendingBlank = false
        output.append(line)
    }
    guard !output.isEmpty else { return JSON.string("").serialized }
    output.append("")
    return JSON.string(output.joined(separatorByte: 0x0A)).serialized
}

private func trimmedLine(_ bytes: [UInt8]) -> String {
    var end = bytes.count
    while end > 0 {
        let byte = bytes[end - 1]
        guard byte == 0x20 || byte == 0x09 || byte == 0x0D else { break }
        end -= 1
    }
    guard end > 0 else { return "" }
    return bytes.withUnsafeBufferPointer { buffer in
        String(utf8: UnsafeBufferPointer(rebasing: buffer[0..<end]))
    }
}
