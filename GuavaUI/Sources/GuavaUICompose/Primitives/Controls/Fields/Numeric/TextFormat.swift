import Foundation

/// Locale affects presentation and input only; the binding stays a plain Float.
/// Strict parsing consumes the full draft instead of accepting numeric prefixes.
struct NumericTextFormat {
    let locale: Locale
    let decimals: Int

    private var formatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = min(6, max(0, decimals))
        formatter.roundingMode = .halfEven
        return formatter
    }

    func format(_ value: Float) -> String {
        let formatter = formatter
        let text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        if formatter.number(from: text)?.doubleValue == 0 {
            return formatter.string(from: 0) ?? "0"
        }
        return text
    }

    func parse(_ text: String) -> Float? {
        let formatter = formatter
        var draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = formatter.decimalSeparator ?? "."
        // Grouping is deliberately unsupported: a decimal editor must not
        // silently reinterpret 1.234 as 1234 in a comma-decimal locale.
        if separator != ".", draft.contains(".") { return nil }
        if let grouping = formatter.groupingSeparator, !grouping.isEmpty, grouping != separator,
           draft.contains(grouping) { return nil }
        draft = draft.replacingOccurrences(of: separator, with: ".")
        draft = draft.replacingOccurrences(of: formatter.minusSign ?? "-", with: "-")
        draft = draft.replacingOccurrences(of: formatter.plusSign ?? "+", with: "+")
        draft = String(String.UnicodeScalarView(draft.unicodeScalars.filter {
            ![UInt32(0x061C), 0x200E, 0x200F].contains($0.value)
        }))
        draft = draft.map { character in
            if let digit = character.wholeNumberValue, (0...9).contains(digit) { return String(digit) }
            return String(character)
        }.joined()
        guard !draft.isEmpty, let value = Float(draft), value.isFinite else { return nil }
        return value
    }
}
