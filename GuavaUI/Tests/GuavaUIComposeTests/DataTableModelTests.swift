import Foundation
import Testing
@testable import GuavaUICompose

private struct TableTestRow: Sendable {
    let id: Int
    var value: Int
}
@Suite("DataTable persistent model", .serialized)
@MainActor
struct DataTableModelTests {
    private let compare: @Sendable (TableTestRow, TableTestRow) -> ComparisonResult = {
        $0.value == $1.value ? .orderedSame : $0.value < $1.value ? .orderedAscending : .orderedDescending
    }
    private func finish(_ model: DataTableModel<TableTestRow, Int>) async throws {
        let deadline = Date.timeIntervalSinceReferenceDate + 10
        while model.sorting.isPending, Date.timeIntervalSinceReferenceDate < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!model.sorting.isPending)
    }
    @Test("200K rows have stable asynchronous projections and constant-time ID lookup")
    func largeProjection() async throws {
        let model = DataTableModel((0..<200_000).map { TableTestRow(id: $0, value: $0 % 10) }, id: \.id)
        let start = Date.timeIntervalSinceReferenceDate
        model.setSort(TableSort("value"), compare: compare)
        #expect(Date.timeIntervalSinceReferenceDate - start < 0.1)
        #expect(model.sorting.isPending)
        try await finish(model)
        #expect(model.sorting.completedBuilds == 1)
        #expect(model.rowID(at: 0) == 0 && model.rowID(at: 1) == 10)
        #expect(model.index(for: 199_999) == 199_999)
        for _ in 0..<100 {
            for index in stride(from: 0, to: model.count, by: 1_997) { #expect(model.index(for: model.rowID(at: index)) == index) }
        }
        #expect(model.sorting.completedBuilds == 1)
        model.setSort(TableSort("value", direction: .descending), compare: compare)
        try await finish(model)
        #expect(model.rowID(at: 0) == 9 && model.rowID(at: 1) == 19)
        model.setSort(TableSort("value"), compare: compare)
        #expect(!model.sorting.isPending && model.sorting.cacheHits == 1 && model.sorting.completedBuilds == 2)
        model.setSort(nil)
        #expect(model.rowID(at: 1) == 1 && model.index(for: 199_999) == 199_999)
    }
    @Test("Row edits, replacement and superseded sort replies preserve the latest data")
    func editAndReplacement() async throws {
        let model = DataTableModel((0..<10_000).map { TableTestRow(id: $0, value: 10_000 - $0) }, id: \.id)
        model.setSort(TableSort("value"), compare: compare)
        model.updateRow(5) { $0.value = -1 }
        try await finish(model)
        #expect(model.rowID(at: 0) == 5 && model.record(for: 5)?.value == -1)
        model.setSort(TableSort("value", direction: .descending), compare: compare)
        model.replaceRows([TableTestRow(id: 80, value: 2), TableTestRow(id: 90, value: 3)])
        try await finish(model)
        #expect(model.count == 2 && model.rowID(at: 0) == 90 && model.index(for: 5) == nil)
        #expect(!model.updateRow(5) { $0.value = 0 })
        model.setSort(nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.rowID(at: 0) == 80)
    }
    @Test("Range selection follows display order; toggles, deletion cleanup and single mode work")
    func selection() async throws {
        let model = DataTableModel((0..<12).map { TableTestRow(id: $0, value: 12 - $0) }, id: \.id)
        model.setSort(TableSort("value"), compare: compare); try await finish(model)
        var selection = DataTableSelection<Int>()
        selection.select(index: 1, in: model, mode: .multiple)
        selection.select(index: 4, in: model, mode: .multiple, modifiers: .shift)
        #expect(selection.selectedIDs == [10, 9, 8, 7] && selection.anchorID == 10 && selection.focusedID == 7)
        selection.select(index: 3, in: model, mode: .multiple, modifiers: .gui)
        #expect(selection.selectedIDs == [10, 9, 7])
        selection.select(index: 0, in: model, mode: .single, modifiers: .shift)
        #expect(selection.selectedIDs == [11])
        model.replaceRows([TableTestRow(id: 99, value: 0)])
        selection.retainExisting(in: model)
        #expect(selection.selectedIDs.isEmpty && selection.focusedID == nil && selection.anchorID == nil)
        try await finish(model)
    }
    @Test("Hundreds of columns are searched by width, keeping frozen columns independent")
    func columnWindow() {
        let geometry = DataTableColumnGeometry(widths: Array(repeating: 100, count: 500), frozenCount: 2)
        #expect(geometry.frozenWidth == 200 && geometry.movingWidth == 49_800)
        let window = geometry.visibleColumns(offset: 20_000, width: 350)
        #expect(window == 201..<207)
        #expect(window.count < 10)
    }
}
