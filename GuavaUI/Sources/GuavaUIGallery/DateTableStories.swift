import Foundation
import GuavaUICompose
import GuavaUIRuntime

private struct InventoryRecord: Identifiable {
    let id: Int
    let name: String
    let category: String
    let stock: Int
}
struct TableStory: View {
    let options: GalleryOptions
    @State private var selection: Int?
    @State private var sort: TableSort?
    @State private var widths: [String: Float] = [:]
    @State private var status = "Choose a row or sort a column"
    private let records = (0..<10_000).map { InventoryRecord(id: $0, name: "Asset \($0 + 1)", category: ["Texture", "Material", "Mesh"][$0 % 3], stock: ($0 * 17) % 250) }
    private var columns: [TableColumn<InventoryRecord>] {
        [TableColumn("name", "Name", configure: { $0.layout.width = 220; $0.compare = { $0.name.localizedStandardCompare($1.name) } }) { Text($0.name).font(.label) },
         TableColumn("category", "Category", configure: { $0.layout.width = 180; $0.compare = { $0.category.compare($1.category) } }) { Badge($0.category) },
         TableColumn("stock", "Stock", configure: { $0.layout.width = 120; $0.compare = { $0.stock == $1.stock ? .orderedSame : $0.stock < $1.stock ? .orderedAscending : .orderedDescending } }) { Text(String($0.stock)).font(.label) }]
    }
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
            StorySection("Inventory · 10,000 rows", "Sort headers through ascending, descending and source order. Drag column edges or use Left/Right on a focused divider. Rows are virtualized.") {
                Table(records, id: \.id, columns: columns) {
                    $0.options.selection = $selection; $0.options.sort = $sort; $0.options.columnWidths = $widths
                    $0.options.isEnabled = options.isEnabled; $0.onActivate = { status = "Opened \($0.name)" }
                }.frame(height: 320).flex(0, shrink: 0).debugName("gallery-table")
                Text("\(status) · Selected: \(selection.map(String.init) ?? "None")").font(.caption).foregroundColor(.onSurfaceMuted)
            }
            StorySection("Empty data", "Empty results retain column headers and explain how to recover.") {
                Table([InventoryRecord](), id: \.id, columns: columns).frame(height: 150).flex(0, shrink: 0)
            }
        }
    }
}
struct CalendarStory: View {
    let options: GalleryOptions
    @State private var date: Date?
    var body: some View {
        StorySection("Choose a day", "Browse months, Tab into the day grid, then move with arrows or Home/End. Return selects the focused day. Weekend dates are unavailable.") {
            CalendarView(selection: $date) {
                $0.presentation.isEnabled = options.isEnabled; $0.calendar.firstWeekday = 2
                let calendar = $0.calendar
                $0.availability.isEnabled = { !calendar.isDateInWeekend($0) }
            }
            Text(date?.formatted(date: .long, time: .omitted) ?? "No date selected").font(.caption).foregroundColor(.onSurfaceMuted)
        }
    }
}
struct DatePickerStory: View {
    let options: GalleryOptions
    @State private var date: Date?
    var body: some View {
        StorySection("Date input", "The calendar opens in an anchored popover. Choosing a day commits and closes; the clear action resets the optional value.") {
            DatePicker(selection: $date) { $0.presentation.isEnabled = options.isEnabled }
            Text(date?.formatted(date: .long, time: .omitted) ?? "No date selected").font(.caption).foregroundColor(.onSurfaceMuted)
            DatePicker(selection: .constant(nil)) { $0.presentation.isEnabled = false; $0.presentation.placeholder = "Unavailable" }
        }
    }
}
struct TimeFieldStory: View {
    let options: GalleryOptions
    @State private var time: TimeOfDay? = TimeOfDay(hour: 9, minute: 30)
    @State private var precise: TimeOfDay? = TimeOfDay(hour: 12, minute: 15, second: 30)
    var body: some View {
        StorySection("Time input", "Enter HH:MM and commit on Return/blur. Invalid drafts preserve the saved value. Up/Down steps minutes; Shift steps hours.") {
            TimeField(value: $time) { $0.isEnabled = options.isEnabled; $0.minimum = TimeOfDay(hour: 8); $0.maximum = TimeOfDay(hour: 18); $0.minuteStep = 5 }.frame(width: 240)
            Text("Saved: \(time?.formatted() ?? "None")").font(.caption).foregroundColor(.onSurfaceMuted)
            TimeField(value: $precise) { $0.showSeconds = true; $0.isEnabled = options.isEnabled }.frame(width: 240)
        }
    }
}
