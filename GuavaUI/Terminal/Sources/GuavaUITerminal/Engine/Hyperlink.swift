internal import GhosttyVt

extension TerminalEngine {
    /// OSC 8 target of the viewport cell, if any.
    func hyperlink(column: Int, row: Int) -> String? {
        guard (0..<columns).contains(column), (0..<rows).contains(row) else { return nil }
        var ref = sized(GhosttyGridRef())
        let point = GhosttyPoint(tag: GHOSTTY_POINT_TAG_VIEWPORT,
                                 value: GhosttyPointValue(coordinate: GhosttyPointCoordinate(x: UInt16(column), y: UInt32(row))))
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        var length = 0
        _ = ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &length)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard ghostty_grid_ref_hyperlink_uri(&ref, &buffer, buffer.count, &length) == GHOSTTY_SUCCESS else { return nil }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }
}
