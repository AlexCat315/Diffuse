import Swift

public enum VersionControl {
    /// Branch names the editor accepts for every system: Git's ref rules,
    /// which also keep a name from reading as an option.
    public static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.first != UInt8(ascii: "-") else { return false }
        var previous: UInt8 = 0
        for byte in name.utf8 {
            if byte < 0x21 || byte == 0x7F { return false }
            switch byte {
            case UInt8(ascii: "~"), UInt8(ascii: "^"), UInt8(ascii: ":"), UInt8(ascii: "?"),
                 UInt8(ascii: "*"), UInt8(ascii: "["), UInt8(ascii: "\\"):
                return false
            case UInt8(ascii: ".") where previous == UInt8(ascii: "."):
                return false
            default: previous = byte
            }
        }
        return true
    }
}
