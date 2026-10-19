import Foundation
import EngineKernel
import GuavaUIRuntime

/// Numeric text field that keeps an editable draft and commits parsed floats on submit or blur.
///
/// With a `prefix`, a leading label chip is drawn inside the field. Dragging
/// the chip horizontally scrubs the value (one step per 4pt; hold Shift when
/// starting for ×10, Option/Alt for ×0.1). With a `resetValue`, double-clicking
/// the chip restores it.
public struct NumberField: View {
    /// A short leading label, such as an axis name, that doubles as the scrub handle.
    public struct Prefix {
        public var title: String
        public var tint: SemanticColorRef

        public init(_ title: String, tint: SemanticColorRef = .onSurfaceMuted) {
            self.title = title
            self.tint = tint
        }
    }

    public let value: Binding<Float>
    public let decimals: Int
    public let size: TextField.Size
    public let isEnabled: Bool
    public let minValue: Float?
    public let maxValue: Float?
    public let step: Float?
    public let showsStepper: Bool
    public let mixedValueLabel: String?
    public let prefix: Prefix?
    public let resetValue: Float?
    public let locale: Locale

    public init(value: Binding<Float>,
                decimals: Int = 2,
                size: TextField.Size = .automatic,
                isEnabled: Bool = true,
                minValue: Float? = nil,
                maxValue: Float? = nil,
                step: Float? = nil,
                showsStepper: Bool = false,
                mixedValueLabel: String? = nil,
                prefix: Prefix? = nil,
                resetValue: Float? = nil,
                locale: Locale = .current) {
        self.value = value
        self.decimals = max(0, min(decimals, 6))
        self.size = size
        self.isEnabled = isEnabled
        self.minValue = minValue
        self.maxValue = maxValue
        self.step = step
        self.showsStepper = showsStepper
        self.mixedValueLabel = mixedValueLabel
        self.prefix = prefix
        self.resetValue = resetValue
        self.locale = locale
    }

    public var body: some View {
        _StatefulNumberField(field: self)
    }

    static func format(_ value: Float, decimals: Int, locale: Locale = .current) -> String {
        NumericTextFormat(locale: locale, decimals: decimals).format(value)
    }

    static func parse(_ text: String, locale: Locale = .current) -> Float? {
        NumericTextFormat(locale: locale, decimals: 6).parse(text)
    }
}

private struct _StatefulNumberField: View {
    let field: NumberField

    @State var draft = TextBuffer.empty
    @State var isEditing: Bool = false
    @State var draftChanged: Bool = false

    var body: some View {
        let committed = field.mixedValueLabel == nil
            ? NumberField.format(normalized(field.value.wrappedValue), decimals: field.decimals, locale: field.locale) : ""
        let committedBuffer = TextBuffer(committed)
        let input = TextField(field.mixedValueLabel ?? "", text: Binding(
                get: { isEditing ? draft : committedBuffer },
                set: { draft = $0; draftChanged = true }
            )) { input in
            input.decoration.size = field.size
            input.behavior.disabled = !field.isEnabled
            input.events.onSubmit = {
                commitDraft()
            }
            input.events.onKeyDown = { event in
                guard event.scancode == Scancode.arrowUp || event.scancode == Scancode.arrowDown else { return false }
                let multiplier: Float = !event.modifiers.isDisjoint(with: .shift) ? 10
                    : (!event.modifiers.isDisjoint(with: .alt) ? 0.1 : 1)
                adjust(by: event.scancode == Scancode.arrowUp ? multiplier : -multiplier)
                return true
            }
            input.events.onFocus = {
                if !isEditing {
                    draft = committedBuffer
                    draftChanged = false
                    isEditing = true
                }
            }
            input.events.onBlur = {
                commitDraft()
                isEditing = false
            }
        }

        // A prefix joins the scrub chip to the field's own chrome, so border,
        // hover and focus ring wrap both.
        let styled = field.prefix.map { AnyView(prefixed(input, prefix: $0)) } ?? AnyView(input)
        return AnyView(stepped(styled))
    }

    /// Height follows the size and text scale, with the 44pt touch floor, so
    /// the chip and the text grow together.
    private func prefixed(_ input: some View, prefix: NumberField.Prefix) -> some View {
        SurfaceReader { surface in
            TextScalerReader { scaler in
                // TextField owns its layout height, so a fixed-height column sizes it.
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    input
                        .textFieldStyle(NumericPrefixFieldStyle(chip: AnyView(scrubChip(prefix))))
                        .accessibilityLabel(prefix.title)
                        .flex(1, shrink: 1, basis: 0)
                }
                .frame(height: max(scaler.scale(prefixHeight), surface.input.contains(.touch) ? surface.minimumControlExtent : 0))
            }
        }
    }

    private var prefixHeight: Float {
        switch field.size {
        case .large: 40
        case .automatic, .regular: 32
        case .small: 28
        }
    }

    @ViewBuilder
    private func stepped(_ input: some View) -> some View {
            if field.showsStepper {
                // Compact spinner. Keyboard stepping (arrow keys) stays the primary
                // path; the buttons exist so the field is usable with the pointer too.
                Row(alignment: .center, spacing: 2) {
                    input
                        .flex()
                    Box(direction: .column, alignItems: .stretch, spacing: 1) {
                        stepButton(UIIcons.Navigation.chevronUp,
                                   title: "Increment",
                                   isEnabled: canStepUp) { increment() }
                        stepButton(UIIcons.Navigation.chevronDown,
                                   title: "Decrement",
                                   isEnabled: canStepDown) { decrement() }
                    }
                    .frame(minWidth: 22)
                }
            } else {
                input
            }
    }

    @ViewBuilder
    private func scrubChip(_ prefix: NumberField.Prefix) -> some View {
        let scrub = NumericScrub(perPoint: resolvedStep / 4, clamp: { clampedValue($0) }, reset: field.resetValue)
        NumericScrubHandle(value: Binding(get: { currentValue }, set: { set($0) }), scrub: scrub,
                                      isEnabled: field.isEnabled) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Text(prefix.title).font(.label).foregroundColor(prefix.tint)
            }
            .frame(minWidth: 22)
            .padding(horizontal: 5)
        }
        .background(prefix.tint.opacity(field.isEnabled ? 0.12 : 0.05))
        .tooltip(field.resetValue == nil ? "Drag to adjust \(prefix.title)" : "Drag to adjust \(prefix.title); double-click to reset")
    }

    /// Writes a scrubbed or reset value and keeps an open draft in step.
    private func set(_ raw: Float) {
        let next = normalized(raw)
        if field.value.wrappedValue != next || field.mixedValueLabel != nil { field.value.wrappedValue = next }
        draft = TextBuffer(NumberField.format(next, decimals: field.decimals, locale: field.locale))
        draftChanged = false
    }

    private func stepButton(_ icon: BundleImageResource,
                            title: String,
                            isEnabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(role: .normal,
               isEnabled: isEnabled,
               tooltip: title,
               action: action) {
            Icon(icon, size: .small, color: .onSurfaceVariant)
        }
        .buttonStyle(NumberStepButtonStyle())
        .accessibility { $0.label = title }
    }

    /// Stepping past a bound is a no-op, so the button reports it instead of
    /// swallowing the press.
    private var currentValue: Float {
        isEditing ? NumberField.parse(draft.stringValue, locale: field.locale) ?? field.value.wrappedValue : field.value.wrappedValue
    }

    private var canStepUp: Bool {
        guard field.isEnabled else { return false }
        if let maxValue = field.maxValue { return currentValue < maxValue }
        return true
    }

    private var canStepDown: Bool {
        guard field.isEnabled else { return false }
        if let minValue = field.minValue { return currentValue > minValue }
        return true
    }

    private func commitDraft() {
        guard draftChanged else { return }
        draftChanged = false
        if let parsed = NumberField.parse(draft.stringValue, locale: field.locale) {
            let next = normalized(parsed)
            if field.mixedValueLabel != nil || field.value.wrappedValue != next {
                field.value.wrappedValue = next
            }
        }
        let committed = normalized(field.value.wrappedValue)
        if committed != field.value.wrappedValue {
            field.value.wrappedValue = committed
        }
        draft = TextBuffer(NumberField.format(committed, decimals: field.decimals, locale: field.locale))
    }

    private func increment() {
        adjust(by: 1)
    }

    private func decrement() {
        adjust(by: -1)
    }

    private func adjust(by multiplier: Float) {
        let next = normalized(currentValue + resolvedStep * multiplier)
        if field.value.wrappedValue != next {
            field.value.wrappedValue = next
        }
        draft = TextBuffer(NumberField.format(next, decimals: field.decimals, locale: field.locale))
        draftChanged = false
    }

    private var resolvedStep: Float {
        guard let step = field.step, step.isFinite, step > 0 else { return 1 }
        return step
    }

    private func normalized(_ value: Float) -> Float {
        // Step is an increment, not a quantization rule for typed values.
        clampedValue(value)
    }

    private func clampedValue(_ value: Float) -> Float {
        var out = value
        if let minValue = field.minValue {
            out = max(minValue, out)
        }
        if let maxValue = field.maxValue {
            out = min(maxValue, out)
        }
        return out
    }
}

private struct NumberStepButtonStyle: ButtonStyle {
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) { AnyView(c.label) }
            .padding(horizontal: 5, vertical: 1).frame(minHeight: 15)
            .background(c.isPressed ? c.theme.colors.stateLayerPressed : c.isHovered ? c.theme.colors.stateLayerHover : .clear)
            .cornerRadius(c.theme.radius.sm)
            .border(c.isFocused ? c.theme.colors.focusRing : .clear, width: 1)
            .opacity(c.isEnabled ? 1 : 0.45)
    }
}
