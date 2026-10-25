import GuavaPluginKit

/// Both views come through here; the editor says which one in `view`.
func view(view: String, state: String, event: String, context: String) -> String {
    view == "csv-table" ? table(context: context) : checklist(state: state, event: event)
}

// MARK: Checklist

/// The state is the whole list; the editor hands it back with every event.
struct Item {
    var text: String
    var done: Bool
}

func checklist(state: String, event: String) -> String {
    let saved = JSON.parse(state)
    var items: [Item] = []
    for element in saved?["items"]?.array ?? [] {
        if let text = element["text"]?.string { items.append(Item(text: text, done: element["done"]?.bool ?? false)) }
    }
    var filter = saved?["filter"]?.string ?? "all"
    var effects: [JSON] = []
    var draft: String? = nil

    if let event = UIEvent(event) {
        switch event.action {
        case "add":
            let text = event.values["draft"]?.string ?? ""
            if !text.isEmpty {
                items.append(Item(text: text, done: false))
                draft = ""
            }
        case "toggle":
            if let index = event.arguments?["index"]?.int, index < items.count {
                items[index].done = event.value?.bool ?? !items[index].done
            }
        case "remove":
            if let index = event.arguments?["index"]?.int, index < items.count { items.remove(at: index) }
        case "clear":
            let before = items.count
            items = items.filter { !$0.done }
            effects.append(UI.message("Cleared \(before - items.count) item(s)"))
        case "filter":
            filter = event.value?.string ?? filter
        default:
            break
        }
    }

    var rows: [JSON] = []
    for (index, item) in items.enumerated() where filter == "all" || (filter == "done") == item.done {
        rows.append(UI.row([
            UI.toggle(id: "done-\(index)", value: item.done, action: "toggle"),
            UI.text(item.text, tone: item.done ? "muted" : nil, flex: 1),
            UI.button("Remove", style: "ghost", action: "remove", arguments: ["index": JSON(index)]),
        ], spacing: 6, align: "center", key: "item-\(index)"))
    }
    let open = items.filter { !$0.done }.count
    let ui = UI.column([
        UI.row([
            UI.textField(id: "draft", placeholder: "New item", value: draft, submit: "add", flex: 1),
            UI.button("Add", style: "primary", action: "add"),
        ], spacing: 6, align: "center"),
        UI.row([
            UI.select(id: "filter", options: [("all", "All"), ("open", "Open"), ("done", "Done")],
                      value: filter, action: "filter"),
            UI.spacer(),
            UI.badge("\(open) open"),
        ], spacing: 6, align: "center"),
        rows.isEmpty ? UI.text("Nothing here yet", tone: "muted") : UI.scroll(UI.column(rows, spacing: 2), flex: 1),
        UI.button("Clear Completed", style: "secondary", action: "clear", disabled: open == items.count),
    ], spacing: 8, padding: 10)

    var itemsJSON: [JSON] = []
    for item in items { itemsJSON.append(["text": .string(item.text), "done": .bool(item.done)]) }
    return UI.result(state: ["items": .array(itemsJSON), "filter": .string(filter)], ui: ui, effects: effects)
}

// MARK: CSV table

/// A plain CSV reader: one record per line, fields split at commas.
func table(context: String) -> String {
    let text = JSON.parse(context)?["text"]?.string ?? ""
    var lines: [[String]] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        var fields: [String] = []
        for field in line.split(separator: ",", omittingEmptySubsequences: false) { fields.append(String(field)) }
        lines.append(fields)
    }
    guard let header = lines.first, !header.isEmpty else {
        return UI.result(state: nil, ui: UI.text("This file has no rows.", tone: "muted"))
    }
    var rows: [JSON] = []
    for line in lines.dropFirst().prefix(1_000) {
        var cells = Array(line.prefix(header.count))
        while cells.count < header.count { cells.append("") }
        rows.append(UI.tableRow(cells))
    }
    return UI.result(state: nil, ui: UI.scroll(UI.column([
        UI.text("\(lines.count - 1) rows", style: "caption", tone: "muted"),
        UI.table(columns: header, rows: rows),
    ], spacing: 6, padding: 10)))
}
