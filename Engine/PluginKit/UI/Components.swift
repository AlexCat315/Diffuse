import Swift

/// Components of a plugin view, as the editor's view protocol reads them.
/// Each function returns the component's JSON; nest them and pass the root to
/// ``UI/result(state:ui:effects:)``. Tones are `normal`, `muted`, `accent`,
/// `success`, `warning` and `danger`.
public enum UI {
    /// What a view entry point returns. A nil `state` keeps the previous one.
    public static func result(state: JSON?, ui: JSON, effects: [JSON] = []) -> String {
        var object: JSONObject = ["ui": ui]
        object["state"] = state
        if !effects.isEmpty { object["effects"] = .array(effects) }
        return JSON.object(object).serialized
    }

    /// What a command entry point returns.
    public static func commandResult(effects: [JSON] = []) -> String {
        JSON.object(["effects": .array(effects)]).serialized
    }

    // MARK: Layout

    /// `align` is `start`, `center`, `end` or `stretch`.
    public static func column(_ children: [JSON], spacing: Int = 0, padding: Int = 0, align: String? = nil,
                              key: String? = nil, flex: Int? = nil) -> JSON {
        stack("column", children, spacing: spacing, padding: padding, align: align, key: key, flex: flex)
    }

    public static func row(_ children: [JSON], spacing: Int = 0, padding: Int = 0, align: String? = nil,
                           key: String? = nil, flex: Int? = nil) -> JSON {
        stack("row", children, spacing: spacing, padding: padding, align: align, key: key, flex: flex)
    }

    public static func scroll(_ child: JSON, flex: Int? = nil) -> JSON {
        node("scroll", ["child": child], flex: flex)
    }

    public static func section(_ title: String?, _ children: [JSON], key: String? = nil) -> JSON {
        var props: JSONObject = ["children": .array(children)]
        props["title"] = title.map(JSON.string)
        return node("section", props, key: key)
    }

    public static func spacer() -> JSON { node("spacer", [:]) }

    // MARK: Content

    /// `style` is `body`, `caption`, `label`, `strong`, `mono` or `title`.
    public static func text(_ text: String, style: String? = nil, tone: String? = nil, flex: Int? = nil) -> JSON {
        var props: JSONObject = ["text": .string(text)]
        props["style"] = style.map(JSON.string)
        props["tone"] = tone.map(JSON.string)
        return node("text", props, flex: flex)
    }

    public static func badge(_ text: String, tone: String? = nil) -> JSON {
        var props: JSONObject = ["text": .string(text)]
        props["tone"] = tone.map(JSON.string)
        return node("badge", props)
    }

    /// `name` is one of the editor's toolbar icons.
    public static func icon(_ name: String, tone: String? = nil) -> JSON {
        var props: JSONObject = ["name": .string(name)]
        props["tone"] = tone.map(JSON.string)
        return node("icon", props)
    }

    /// Nil shows an indeterminate spinner.
    public static func progress(percent: Int? = nil) -> JSON {
        var props = JSONObject()
        props["percent"] = percent.map { JSON($0) }
        return node("progress", props)
    }

    // MARK: Controls

    /// `style` is `primary`, `secondary`, `ghost` or `danger`.
    public static func button(_ title: String?, icon: String? = nil, style: String? = nil, action: String,
                              arguments: JSON? = nil, disabled: Bool = false, key: String? = nil) -> JSON {
        var props: JSONObject = ["action": .string(action)]
        props["title"] = title.map(JSON.string)
        props["icon"] = icon.map(JSON.string)
        props["style"] = style.map(JSON.string)
        props["arguments"] = arguments
        if disabled { props["disabled"] = true }
        return node("button", props, key: key)
    }

    /// The editor keeps what the user types. A `value` returned in answer to an
    /// event replaces it, so returning `""` after a submit clears it; without a
    /// `value` the text is left to the editor.
    public static func textField(id: String, placeholder: String? = nil, value: String? = nil, secure: Bool = false,
                                 submit: String? = nil, change: String? = nil, flex: Int? = nil) -> JSON {
        var props: JSONObject = ["id": .string(id)]
        props["placeholder"] = placeholder.map(JSON.string)
        props["value"] = value.map(JSON.string)
        if secure { props["secure"] = true }
        props["submit"] = submit.map(JSON.string)
        props["change"] = change.map(JSON.string)
        return node("textField", props, flex: flex)
    }

    public static func toggle(id: String, label: String? = nil, value: Bool, action: String? = nil) -> JSON {
        var props: JSONObject = ["id": .string(id), "value": .bool(value)]
        props["label"] = label.map(JSON.string)
        props["action"] = action.map(JSON.string)
        return node("toggle", props)
    }

    public static func select(id: String, options: [(value: String, label: String)], value: String,
                              action: String? = nil) -> JSON {
        var props: JSONObject = ["id": .string(id), "value": .string(value)]
        var list: [JSON] = []
        for option in options { list.append(["value": .string(option.value), "label": .string(option.label)]) }
        props["options"] = .array(list)
        props["action"] = action.map(JSON.string)
        return node("select", props)
    }

    public static func disclosure(_ title: String, expanded: Bool, action: String, arguments: JSON? = nil,
                                  _ children: [JSON], key: String? = nil) -> JSON {
        var props: JSONObject = ["title": .string(title), "expanded": .bool(expanded), "action": .string(action),
                                 "children": .array(children)]
        props["arguments"] = arguments
        return node("disclosure", props, key: key)
    }

    public static func table(columns: [String], rows: [JSON]) -> JSON {
        node("table", ["columns": JSON(columns), "rows": .array(rows)])
    }

    /// One row of a ``table(columns:rows:)``; with an action, clicking it raises the action.
    public static func tableRow(_ cells: [String], action: String? = nil, arguments: JSON? = nil) -> JSON {
        var row: JSONObject = ["cells": JSON(cells)]
        row["action"] = action.map(JSON.string)
        row["arguments"] = arguments
        return .object(row)
    }

    // MARK: Effects

    public static func message(_ text: String) -> JSON { ["type": "message", "text": .string(text)] }
    public static func error(_ text: String) -> JSON { ["type": "error", "text": .string(text)] }
    /// Brings forward one of the package's own panels.
    public static func showPanel(_ id: String) -> JSON { ["type": "panel", "id": .string(id)] }
    /// Opens a project-relative file in the editor.
    public static func open(path: String) -> JSON { ["type": "open", "path": .string(path)] }

    // MARK: Building

    private static func stack(_ type: String, _ children: [JSON], spacing: Int, padding: Int, align: String?,
                              key: String?, flex: Int?) -> JSON {
        var props: JSONObject = ["children": .array(children)]
        if spacing != 0 { props["spacing"] = JSON(spacing) }
        if padding != 0 { props["padding"] = JSON(padding) }
        props["align"] = align.map(JSON.string)
        return node(type, props, key: key, flex: flex)
    }

    private static func node(_ type: String, _ props: JSONObject, key: String? = nil, flex: Int? = nil) -> JSON {
        var object: JSONObject = ["type": .string(type)]
        for member in props.members { object[member.key] = member.value }
        object["key"] = key.map(JSON.string)
        object["flex"] = flex.map { JSON($0) }
        return .object(object)
    }
}
