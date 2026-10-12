import Foundation

/// A private cache is retained by the view's state. A fresh view input changes
/// the generation; scrolling the same input only queries the existing index.
final class VariableRowMetrics<ID: Hashable> {
    private var generation: UUID?
    private var width: Float = -1
    private var scaler = TextScaler.identity
    private var spacing: Float = -1
    private var viewportHeight: Double = -1
    private(set) var rows = VariableRowIndex<ID>()

    func synchronize<Data: RandomAccessCollection>(
        _ data: Data, id: KeyPath<Data.Element, ID>, generation: UUID,
        width: Float, scaler: TextScaler, spacing: Float,
        offset: Double, viewport: Double,
        rowHeight: (Data.Element, Float, TextScaler) -> Float
    ) -> Double {
        guard self.generation != generation || self.width != width
                || self.scaler != scaler || self.spacing != spacing else {
            if viewportHeight != viewport {
                viewportHeight = viewport
                return rows.clamp(offset, viewport: viewport)
            }
            // ScrollView owns transient rubber-band offsets. Clamp only the
            // range query while normal scrolling preserves its motion.
            return offset
        }
        let anchor = rows.anchor(at: offset)
        var ids: [ID] = []
        var heights: [Float] = []
        ids.reserveCapacity(data.count)
        heights.reserveCapacity(data.count)
        for element in data {
            ids.append(element[keyPath: id])
            heights.append(rowHeight(element, width, scaler))
        }
        rows.replace(ids: ids, heights: heights, spacing: spacing)
        self.generation = generation
        self.width = width
        self.scaler = scaler
        self.spacing = spacing
        viewportHeight = viewport
        return anchor.map { rows.offset(for: $0, viewport: viewport) }
            ?? rows.clamp(offset, viewport: viewport)
    }
}
