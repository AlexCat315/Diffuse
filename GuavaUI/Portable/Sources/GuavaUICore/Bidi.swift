/// Unicode bidirectional character types (UAX #9, table 4). Explicit
/// embeddings and isolates are treated as boundary neutrals; marks (LRM, RLM,
/// ALM) keep their strong types.
public enum BidiClass: UInt8, Sendable {
    case l, r, al, en, es, et, an, cs, nsm, bn, b, s, ws, on

    public init(_ scalar: Unicode.Scalar) {
        let v = scalar.value
        switch v {
        case 0x0A, 0x0D, 0x1C...0x1E, 0x85, 0x2029: self = .b; return
        case 0x09, 0x0B, 0x1F: self = .s; return
        case 0x0C, 0x20, 0x1680, 0x2000...0x200A, 0x2028, 0x205F, 0x3000: self = .ws; return
        case 0x30...0x39, 0xB2, 0xB3, 0xB9, 0x06F0...0x06F9,
             0x2070, 0x2074...0x2079, 0x2080...0x2089, 0x2488...0x249B, 0xFF10...0xFF19, 0x1D7CE...0x1D7FF:
            self = .en; return
        case 0x0600...0x0605, 0x0660...0x0669, 0x066B, 0x066C, 0x06DD, 0x0890, 0x0891, 0x08E2, 0x10E60...0x10E7E:
            self = .an; return
        case 0x2B, 0x2D, 0x207A, 0x207B, 0x208A, 0x208B, 0x2212, 0xFB29, 0xFE62, 0xFE63, 0xFF0B, 0xFF0D:
            self = .es; return
        case 0x23...0x25, 0xA2...0xA5, 0xB0, 0xB1, 0x058F, 0x0609, 0x060A, 0x066A, 0x09F2, 0x09F3,
             0x0E3F, 0x17DB, 0x2030...0x2034, 0x20A0...0x20CF, 0x212E, 0x2213, 0xFE5F, 0xFE69, 0xFE6A,
             0xFF03...0xFF05, 0xFFE0, 0xFFE1, 0xFFE5, 0xFFE6:
            self = .et; return
        case 0x2C, 0x2E, 0x2F, 0x3A, 0xA0, 0x060C, 0x202F, 0x2044, 0xFE50, 0xFE52, 0xFE55, 0xFF0C, 0xFF0E, 0xFF0F, 0xFF1A:
            self = .cs; return
        case 0x200E: self = .l; return
        case 0x200F: self = .r; return
        case 0x061C: self = .al; return
        case 0x202A...0x202E, 0x2066...0x2069, 0x200B...0x200D, 0x2060...0x2064, 0xFEFF, 0xAD:
            self = .bn; return
        default: break
        }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: self = .nsm; return
        case .format, .control: self = .bn; return
        default: break
        }
        switch v {
        case 0x0590...0x05FF, 0x07C0...0x085F, 0xFB1D...0xFB4F, 0x10800...0x10CFF, 0x10D40...0x10EBF,
             0x10F00...0x10F2F, 0x10F70...0x10FFF, 0x1E800...0x1EDFF, 0x1EF00...0x1EFFF:
            self = .r
        case 0x0600...0x07BF, 0x0860...0x08FF, 0xFB50...0xFDCF, 0xFDF0...0xFDFF, 0xFE70...0xFEFF,
             0x10D00...0x10D3F, 0x10EC0...0x10EFF, 0x10F30...0x10F6F, 0x1EC70...0x1ECBF, 0x1ED00...0x1ED4F,
             0x1EE00...0x1EEFF:
            self = .al
        default:
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .spacingMark, .decimalNumber, .letterNumber, .otherNumber, .privateUse:
                self = .l
            default:
                self = .on
            }
        }
    }

    var isStrongRightToLeft: Bool { self == .r || self == .al }
}

/// Resolved embedding levels for every UTF-8 byte of a text. Each hard line
/// break starts a paragraph with its own base direction (first strong
/// character, or the caller's default when none is found).
public struct BidiParagraphs: Sendable {
    public struct Paragraph: Sendable, Equatable {
        /// UTF-8 byte range, including the terminating separator.
        public let range: Range<Int>
        public let baseLevel: UInt8
        public var isRightToLeft: Bool { baseLevel & 1 == 1 }
    }

    /// One level per UTF-8 byte offset.
    public let levels: [UInt8]
    public let paragraphs: [Paragraph]
    private let classes: [BidiClass]

    /// Cheap pre-check: text without right-to-left characters lays out
    /// exactly as before when the default direction is left-to-right.
    public static func containsRightToLeft(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            guard v >= 0x0590 else { return false }
            let type = BidiClass(scalar)
            return type == .r || type == .al || type == .an
        }
    }

    public init(_ text: String, defaultRightToLeft: Bool = false) {
        var scalarTypes: [BidiClass] = []
        var scalarBytes: [Int] = []
        for scalar in text.unicodeScalars {
            scalarTypes.append(BidiClass(scalar))
            scalarBytes.append(UTF8.width(scalar))
        }
        var scalarLevels = [UInt8](repeating: 0, count: scalarTypes.count)
        var paragraphs: [Paragraph] = []
        var start = 0, byteStart = 0
        func resolveParagraph(_ end: Int) {
            guard start < end || paragraphs.isEmpty else { return }
            let base = Self.baseLevel(scalarTypes[start..<end], defaultRightToLeft: defaultRightToLeft)
            Self.resolve(scalarTypes, range: start..<end, base: base, levels: &scalarLevels)
            let bytes = scalarBytes[start..<end].reduce(0, +)
            paragraphs.append(Paragraph(range: byteStart..<(byteStart + bytes), baseLevel: base))
            byteStart += bytes
            start = end
        }
        for index in scalarTypes.indices where scalarTypes[index] == .b { resolveParagraph(index + 1) }
        if start < scalarTypes.count || paragraphs.isEmpty { resolveParagraph(scalarTypes.count) }

        var levels: [UInt8] = []
        var classes: [BidiClass] = []
        levels.reserveCapacity(text.utf8.count)
        for index in scalarLevels.indices {
            for _ in 0..<scalarBytes[index] { levels.append(scalarLevels[index]); classes.append(scalarTypes[index]) }
        }
        self.levels = levels
        self.classes = classes
        self.paragraphs = paragraphs
    }

    public var isMixed: Bool { levels.contains { $0 != 0 } || paragraphs.contains { $0.isRightToLeft } }

    public func level(atByte offset: Int) -> UInt8 {
        offset >= 0 && offset < levels.count ? levels[offset] : paragraph(atByte: offset).baseLevel
    }

    public func paragraph(atByte offset: Int) -> Paragraph {
        paragraphs.first { $0.range.contains(offset) } ?? paragraphs.last ?? Paragraph(range: 0..<0, baseLevel: 0)
    }

    /// Whitespace and segment separators that L1 resets at a line end.
    public func isTrailingWhitespace(atByte offset: Int) -> Bool {
        guard offset >= 0 && offset < classes.count else { return false }
        let type = classes[offset]
        return type == .ws || type == .s || type == .b || type == .bn
    }

    /// Maximal byte ranges of equal level inside `range`, in logical order.
    public func levelRuns(in range: Range<Int>) -> [(range: Range<Int>, level: UInt8)] {
        var runs: [(range: Range<Int>, level: UInt8)] = []
        var start = range.lowerBound
        for offset in range where offset > range.lowerBound && levels[offset] != levels[offset - 1] {
            runs.append((start..<offset, levels[start])); start = offset
        }
        if start < range.upperBound { runs.append((start..<range.upperBound, levels[start])) }
        return runs
    }

    /// Rule L2: indices of `levels` in visual left-to-right order.
    public static func visualOrder(_ levels: [UInt8]) -> [Int] {
        var order = Array(levels.indices)
        guard let highest = levels.max(), let lowestOdd = levels.filter({ $0 & 1 == 1 }).min() else { return order }
        var level = highest
        while level >= lowestOdd {
            var index = 0
            while index < order.count {
                guard levels[order[index]] >= level else { index += 1; continue }
                var end = index
                while end + 1 < order.count && levels[order[end + 1]] >= level { end += 1 }
                order[index...end].reverse()
                index = end + 1
            }
            if level == 0 { break }
            level -= 1
        }
        return order
    }

    // MARK: - Resolution

    private static func baseLevel(_ types: ArraySlice<BidiClass>, defaultRightToLeft: Bool) -> UInt8 {
        for type in types {
            if type == .l { return 0 }
            if type.isStrongRightToLeft { return 1 }
        }
        return defaultRightToLeft ? 1 : 0
    }

    private static func resolve(_ source: [BidiClass], range: Range<Int>, base: UInt8, levels: inout [UInt8]) {
        guard !range.isEmpty else { return }
        let sos: BidiClass = base & 1 == 1 ? .r : .l
        var types = Array(source[range])
        // W1: marks (and removed boundary neutrals) take the previous type.
        for i in types.indices where types[i] == .nsm || types[i] == .bn {
            types[i] = i == 0 ? sos : types[i - 1]
        }
        // W2, W3: European numbers after Arabic letters become Arabic numbers.
        var lastStrong = sos
        for i in types.indices {
            switch types[i] {
            case .l, .r, .al: lastStrong = types[i]
            case .en where lastStrong == .al: types[i] = .an
            default: break
            }
        }
        for i in types.indices where types[i] == .al { types[i] = .r }
        // W4: a single separator between two numbers of one kind joins them.
        if types.count >= 3 {
            for i in 1..<(types.count - 1) {
                let previous = types[i - 1], next = types[i + 1]
                if types[i] == .es, previous == .en, next == .en { types[i] = .en }
                else if types[i] == .cs, previous == next, previous == .en || previous == .an { types[i] = previous }
            }
        }
        // W5: terminators adjacent to European numbers become numbers.
        var i = 0
        while i < types.count {
            guard types[i] == .et else { i += 1; continue }
            var end = i
            while end + 1 < types.count && types[end + 1] == .et { end += 1 }
            let touches = (i > 0 && types[i - 1] == .en) || (end + 1 < types.count && types[end + 1] == .en)
            if touches { for j in i...end { types[j] = .en } }
            i = end + 1
        }
        // W6: remaining separators and terminators are neutral.
        for i in types.indices where types[i] == .es || types[i] == .et || types[i] == .cs { types[i] = .on }
        // W7: European numbers after left-to-right text are left-to-right.
        lastStrong = sos
        for i in types.indices {
            switch types[i] {
            case .l, .r: lastStrong = types[i]
            case .en where lastStrong == .l: types[i] = .l
            default: break
            }
        }
        // N1, N2: neutral runs take matching surroundings, else the embedding direction.
        func strongDirection(_ type: BidiClass) -> BidiClass? {
            switch type {
            case .l: .l
            case .r, .en, .an: .r
            default: nil
            }
        }
        i = 0
        while i < types.count {
            guard strongDirection(types[i]) == nil else { i += 1; continue }
            var end = i
            while end + 1 < types.count && strongDirection(types[end + 1]) == nil { end += 1 }
            let before = i > 0 ? strongDirection(types[i - 1])! : sos
            let after = end + 1 < types.count ? strongDirection(types[end + 1])! : sos
            let resolved = before == after ? before : sos
            for j in i...end where source[range.lowerBound + j] != .b && source[range.lowerBound + j] != .s {
                types[j] = resolved
            }
            i = end + 1
        }
        // I1, I2 and L1 for separators: levels from resolved types.
        for (offset, type) in types.enumerated() {
            let original = source[range.lowerBound + offset]
            let level: UInt8
            if original == .b || original == .s {
                level = base
            } else if base & 1 == 0 {
                level = type == .r ? base + 1 : type == .an || type == .en ? base + 2 : base
            } else {
                level = type == .l || type == .en || type == .an ? base + 1 : base
            }
            levels[range.lowerBound + offset] = level
        }
        // L1: whitespace before the paragraph end returns to the base level.
        var tail = range.upperBound - 1
        while tail >= range.lowerBound {
            let original = source[tail]
            guard original == .ws || original == .b || original == .s || original == .bn else { break }
            levels[tail] = base; tail -= 1
        }
    }
}
