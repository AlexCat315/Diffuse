import Swift

/// What the user did in a plugin view: the `event` input of a view entry point.
public struct UIEvent {
    /// The action of the component that raised the event.
    public let action: String
    public let arguments: JSON?
    /// The new value of the field, toggle or select that raised the event.
    public let value: JSON?
    /// Every field, toggle and select in the view, by component ID.
    public let values: JSONObject

    /// Nil for an empty `event`, which asks the view only to render.
    public init?(_ text: String) {
        guard !text.isEmpty, let object = JSON.parse(text)?.object, let action = object["action"]?.string else { return nil }
        self.action = action
        arguments = object["arguments"]
        value = object["value"]
        values = object["values"]?.object ?? JSONObject()
    }
}
