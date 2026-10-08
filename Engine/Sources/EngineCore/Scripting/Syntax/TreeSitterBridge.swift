import Foundation
import CTreeSitter
import CTreeSitterSwift

public struct SyntaxPoint: Equatable {
    public let row: Int
    public let byteColumn: Int
    public init(row: Int, byteColumn: Int) { self.row = row; self.byteColumn = byteColumn }
    fileprivate var cPoint: TSPoint { TSPoint(row: UInt32(clamping: row), column: UInt32(clamping: byteColumn)) }
}

public struct SyntaxEdit {
    public let oldByteRange: Range<Int>
    public let newEndByte: Int
    public let start: SyntaxPoint
    public let oldEnd: SyntaxPoint
    public let newEnd: SyntaxPoint
    public init(oldByteRange: Range<Int>, newEndByte: Int, start: SyntaxPoint,
                oldEnd: SyntaxPoint, newEnd: SyntaxPoint) {
        self.oldByteRange = oldByteRange; self.newEndByte = newEndByte
        self.start = start; self.oldEnd = oldEnd; self.newEnd = newEnd
    }
    fileprivate var cEdit: TSInputEdit {
        TSInputEdit(start_byte: UInt32(clamping: oldByteRange.lowerBound),
                    old_end_byte: UInt32(clamping: oldByteRange.upperBound), new_end_byte: UInt32(clamping: newEndByte),
                    start_point: start.cPoint, old_end_point: oldEnd.cPoint, new_end_point: newEnd.cPoint)
    }
}

/// Value descriptions avoid retaining native nodes past an edit. Identity is
/// useful for verifying subtree reuse, and is valid only while the tree lives.
public struct SyntaxNodeInfo {
    public let type: String
    public let byteRange: Range<Int>
    public let fieldName: String?
    public let isNamed: Bool
    public let identity: UInt
}

/// Owns one immutable parse snapshot. The parser edits a cheap native copy,
/// preserving this snapshot for queries and for background consumers.
public final class SyntaxTree: @unchecked Sendable {
    fileprivate let native: OpaquePointer
    fileprivate init(_ native: OpaquePointer) { self.native = native }
    deinit { ts_tree_delete(native) }

    /// Independent native handles are required for queries on another executor.
    public func copy() -> SyntaxTree { SyntaxTree(ts_tree_copy(native)!) }
    public func applying(_ edit: SyntaxEdit) -> SyntaxTree {
        let result = copy(); var edit = edit.cEdit; ts_tree_edit(result.native, &edit); return result
    }

    public var hasErrors: Bool { ts_node_has_error(ts_tree_root_node(native)) }

    /// Cursor descent uses Tree-sitter's subtree index; it never enumerates
    /// every top-level declaration to find a token in a large source file.
    public func path(atUTF8Offset offset: Int) -> [SyntaxNodeInfo] {
        let root = ts_tree_root_node(native), byte = UInt32(clamping: offset)
        guard offset >= 0, byte < ts_node_end_byte(root) else { return [] }
        var cursor = ts_tree_cursor_new(root)
        defer { ts_tree_cursor_delete(&cursor) }
        var result: [SyntaxNodeInfo] = []
        while true {
            let node = ts_tree_cursor_current_node(&cursor)
            let range = Int(ts_node_start_byte(node))..<Int(ts_node_end_byte(node))
            guard range.contains(offset) else { break }
            let field = ts_tree_cursor_current_field_name(&cursor).map { String(cString: $0) }
            result.append(SyntaxNodeInfo(type: String(cString: ts_node_type(node)), byteRange: range,
                                         fieldName: field, isNamed: ts_node_is_named(node),
                                         identity: UInt(bitPattern: node.id)))
            if ts_tree_cursor_goto_first_child_for_byte(&cursor, byte) < 0 { break }
        }
        return result
    }


}

public struct SyntaxParseStatistics {
    public init() {}
    public var parseSeconds = 0.0
    public var editSeconds = 0.0
    public var bytesRead = 0
    public var readCount = 0
    public var usedPreviousTree = false
}

public enum SyntaxParserError: Error { case incompatibleGrammar, parseFailed }

/// Owns the native parser. Use on one executor; copied SyntaxTree snapshots can
/// be handed to another executor independently. Engine has no UI dependency.
public final class TreeSitterSwiftParser {
    private let native: OpaquePointer
    public private(set) var statistics = SyntaxParseStatistics()
    public init() throws {
        guard let parser = ts_parser_new() else { throw SyntaxParserError.parseFailed }
        guard ts_parser_set_language(parser, tree_sitter_swift()) else {
            ts_parser_delete(parser); throw SyntaxParserError.incompatibleGrammar
        }
        native = parser
    }
    deinit { ts_parser_delete(native) }

    public func parse(previous: SyntaxTree? = nil, edit: SyntaxEdit? = nil,
                      read: @escaping (Int, Int) -> [UInt8]) throws -> SyntaxTree {
        let input = SyntaxInputReader(read: read)
        let editStart = Date()
        var old: SyntaxTree?
        if let previous, let copy = ts_tree_copy(previous.native) {
            old = SyntaxTree(copy)
            if let edit { var change = edit.cEdit; ts_tree_edit(copy, &change) }
        }
        let editSeconds = Date().timeIntervalSince(editStart)
        let cInput = TSInput(payload: Unmanaged.passUnretained(input).toOpaque(), read: { payload, byte, _, count in
            guard let payload else { count?.pointee = 0; return nil }
            return Unmanaged<SyntaxInputReader>.fromOpaque(payload).takeUnretainedValue().read(at: Int(byte), count: count)
        }, encoding: TSInputEncodingUTF8, decode: nil)
        let parseStart = Date()
        guard let tree = ts_parser_parse(native, old?.native, cInput) else { throw SyntaxParserError.parseFailed }
        let result = SyntaxTree(tree)
        let parseSeconds = Date().timeIntervalSince(parseStart)
        statistics = input.statistics
        statistics.parseSeconds = parseSeconds
        statistics.editSeconds = editSeconds
        statistics.usedPreviousTree = old != nil
        return result
    }
}

/// Stable callback storage: returning a pointer from withUnsafeBufferPointer
/// would outlive its borrow. This bounded scratch block lives through parsing.
private final class SyntaxInputReader {
    private static let capacity = 4096
    private let scratch = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
    private let provider: (Int, Int) -> [UInt8]
    var statistics = SyntaxParseStatistics()
    init(read: @escaping (Int, Int) -> [UInt8]) { provider = read }
    deinit { scratch.deallocate() }
    func read(at byte: Int, count: UnsafeMutablePointer<UInt32>?) -> UnsafePointer<CChar>? {
        let bytes = provider(byte, Self.capacity)
        let length = min(Self.capacity, bytes.count)
        count?.pointee = UInt32(length)
        guard length > 0 else { return nil }
        _ = bytes.withUnsafeBytes { memcpy(scratch, $0.baseAddress!, length) }
        statistics.bytesRead += length; statistics.readCount += 1
        return UnsafePointer(scratch)
    }
}
