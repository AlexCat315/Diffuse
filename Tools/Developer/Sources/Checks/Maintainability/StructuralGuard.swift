/// The structural metrics the maintainability guard measures for one Swift
/// declaration. Raw values match the Python checker's metric names so reports
/// and the baseline file stay byte-compatible.
enum Metric: String, CaseIterable {
  case storedProperties = "stored_properties"
  case initializerParameters = "initializer_parameters"
  case initializerAssignments = "initializer_assignments"

  /// The hard limit every declaration must respect, independent of the baseline.
  var limit: Int {
    switch self {
    case .storedProperties: 20
    case .initializerParameters: 16
    case .initializerAssignments: 20
    }
  }
}

/// One declaration's measured structural size.
struct DeclarationMetrics: Equatable {
  var storedProperties = 0
  var initializerParameters = 0
  var initializerAssignments = 0

  subscript(metric: Metric) -> Int {
    get {
      switch metric {
      case .storedProperties: storedProperties
      case .initializerParameters: initializerParameters
      case .initializerAssignments: initializerAssignments
      }
    }
    set {
      switch metric {
      case .storedProperties: storedProperties = newValue
      case .initializerParameters: initializerParameters = newValue
      case .initializerAssignments: initializerAssignments = newValue
      }
    }
  }

  /// Keeps the largest of each metric, matching how the Python checker merges
  /// repeated qualified names inside one file.
  mutating func raise(to other: DeclarationMetrics) {
    for metric in Metric.allCases { self[metric] = max(self[metric], other[metric]) }
  }
}

/// A lexical token and its code-point range in the scanned source.
private struct SourceToken {
  let text: String
  let start: Int
  let end: Int
}

/// Tokenizer-based structural guard for oversized Swift declarations. This is a
/// lexical approximator, not a Swift parser: it ignores comments and string
/// literals, and it never looks inside a type's nested scopes for members.
enum StructuralGuard {
  /// Measures every `struct`, `class`, and `extension` in `source`, keyed by
  /// its (possibly nested, `Outer.Inner`-qualified) name in source order.
  static func measure(_ source: String) -> OrderedMap<DeclarationMetrics> {
    let scalars = Array(source.unicodeScalars)
    let tokens = Tokenizer.tokens(in: scalars)

    var pairs: [Int: Int] = [:]
    var stack: [Int] = []
    var depths: [Int] = []
    depths.reserveCapacity(tokens.count)
    for (index, token) in tokens.enumerated() {
      depths.append(stack.count)
      if token.text == "{" || token.text == "(" || token.text == "[" {
        stack.append(index)
      } else if token.text == "}" || token.text == ")" || token.text == "]", !stack.isEmpty {
        pairs[stack.removeLast()] = index
      }
    }

    var types: [(qualified: String, opening: Int, closing: Int)] = []
    for (index, token) in tokens.enumerated() {
      guard token.text == "struct" || token.text == "class" || token.text == "extension" else {
        continue
      }
      guard index + 1 < tokens.count else { continue }
      if index > 0, tokens[index - 1].text == "import" || tokens[index - 1].text == "." { continue }
      let name = tokens[index + 1].text
      if name == "func" || name == "var" || name == "let" { continue }
      var opening = index + 2
      while opening < tokens.count,
        tokens[opening].text != "{", tokens[opening].text != "=", tokens[opening].text != ";"
      {
        opening += 1
      }
      guard opening < tokens.count, tokens[opening].text == "{", let closing = pairs[opening] else {
        continue
      }
      let parent = types.last { $0.opening < index && index < $0.closing }?.qualified
      types.append((parent.map { "\($0).\(name)" } ?? name, opening, closing))
    }

    var result = OrderedMap<DeclarationMetrics>()
    for type in types {
      var fields: Set<String> = []
      var initializers: [(parameters: Int, body: Int, end: Int)] = []
      for index in (type.opening + 1)..<type.closing {
        guard depths[index] == depths[type.opening] + 1 else { continue }
        let token = tokens[index]
        if token.text == "let" || token.text == "var" {
          if isStaticOrClass(scalars, before: token.start) { continue }
          var end = index + 2
          while end < type.closing {
            if hasNewline(scalars, from: tokens[end - 1].end, to: tokens[end].start) { break }
            if tokens[end].text == "{" || tokens[end].text == ";" || tokens[end].text == "}" {
              break
            }
            end += 1
          }
          let header = tokens[(index + 2)..<end].map(\.text)
          let observer =
            end + 1 < type.closing
            && (tokens[end + 1].text == "didSet" || tokens[end + 1].text == "willSet")
          let computed =
            end < type.closing && tokens[end].text == "{"
            && !header.contains("=") && !observer
          if !computed { fields.insert(tokens[index + 1].text) }
        } else if token.text == "init" {
          var parameterStart = index + 1
          if tokens[parameterStart].text == "?" || tokens[parameterStart].text == "!" {
            parameterStart += 1
          }
          guard let parameterEnd = pairs[parameterStart], tokens[parameterStart].text == "(" else {
            continue
          }
          var count = 0
          var angleDepth = 0
          for argument in (parameterStart + 1)..<parameterEnd {
            guard depths[argument] == depths[parameterStart] + 1 else { continue }
            let value = tokens[argument].text
            if value == "<" {
              angleDepth += 1
            } else if value == ">", angleDepth > 0 {
              angleDepth -= 1
            } else if value == ":", angleDepth == 0 {
              count += 1
            }
          }
          var body = parameterEnd + 1
          while body < type.closing, tokens[body].text != "{" { body += 1 }
          if let bodyEnd = pairs[body] { initializers.append((count, body, bodyEnd)) }
        }
      }

      var assignments = 0
      for initializer in initializers {
        var assigned: Set<String> = []
        if initializer.body + 1 < initializer.end - 1 {
          for index in (initializer.body + 1)..<(initializer.end - 1) {
            let token = tokens[index].text
            if !fields.contains(token) { continue }
            if tokens[index + 1].text != "=" { continue }
            if tokens[index + 2].text == "=" { continue }
            if tokens[index - 1].text == "let" || tokens[index - 1].text == "var" { continue }
            assigned.insert(token)
          }
        }
        assignments = max(assignments, assigned.count)
      }

      var entry = DeclarationMetrics()
      entry.storedProperties = fields.count
      entry.initializerParameters = initializers.map(\.parameters).max() ?? 0
      entry.initializerAssignments = assignments
      var merged = result[type.qualified] ?? DeclarationMetrics()
      merged.raise(to: entry)
      result.insert(merged, for: type.qualified)
    }
    return result
  }
}

/// Single-pass tokenizer mirroring the Python guard's alternation order:
/// line comments, block comments, raw/multiline strings, string literals,
/// backtick identifiers, identifiers, then any other non-whitespace scalar.
private enum Tokenizer {
  static func tokens(in scalars: [Unicode.Scalar]) -> [SourceToken] {
    var tokens: [SourceToken] = []
    var index = 0
    while index < scalars.count {
      if isWhitespace(scalars[index]) {
        index += 1
        continue
      }
      let end = tokenEnd(in: scalars, at: index)
      let text = string(of: scalars, from: index, to: end)
      if !text.hasPrefix("//"), !text.hasPrefix("/*") {
        tokens.append(SourceToken(text: text, start: index, end: end))
      }
      index = end
    }
    return tokens
  }

  /// Returns the exclusive end of the first matching alternative. Always
  /// advances, because the final alternative accepts any non-whitespace scalar.
  private static func tokenEnd(in scalars: [Unicode.Scalar], at index: Int) -> Int {
    if scalars[index] == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
      var end = index + 2
      while end < scalars.count, scalars[end] != "\n" { end += 1 }
      return end
    }
    if scalars[index] == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
      var end = index + 2
      while end + 1 < scalars.count {
        if scalars[end] == "*", scalars[end + 1] == "/" { return end + 2 }
        end += 1
      }
    }
    if let end = multilineStringEnd(in: scalars, at: index) { return end }
    if let end = stringEnd(in: scalars, at: index) { return end }
    if scalars[index] == "`", index + 1 < scalars.count, scalars[index + 1] != "`" {
      var end = index + 1
      while end < scalars.count, scalars[end] != "`" { end += 1 }
      if end < scalars.count, end >= index + 2 { return end + 1 }
    }
    if isIdentifierStart(scalars[index]) {
      var end = index + 1
      while end < scalars.count, isIdentifierContinue(scalars[end]) { end += 1 }
      return end
    }
    return index + 1
  }

  /// `#*"""..."""#*`, with the shortest body that reaches a closing delimiter.
  private static func multilineStringEnd(in scalars: [Unicode.Scalar], at index: Int) -> Int? {
    var quote = index
    while quote < scalars.count, scalars[quote] == "#" { quote += 1 }
    guard quote + 2 < scalars.count,
      scalars[quote] == "\"", scalars[quote + 1] == "\"", scalars[quote + 2] == "\""
    else { return nil }
    var end = quote + 3
    while end + 2 < scalars.count {
      if scalars[end] == "\"", scalars[end + 1] == "\"", scalars[end + 2] == "\"" {
        return hashesEnd(in: scalars, at: end + 3)
      }
      end += 1
    }
    return nil
  }

  /// `#*"(?:\\.|[^"\\])*"#*`. A backslash only escapes another scalar, never
  /// the end of a line, exactly like the Python pattern.
  private static func stringEnd(in scalars: [Unicode.Scalar], at index: Int) -> Int? {
    var quote = index
    while quote < scalars.count, scalars[quote] == "#" { quote += 1 }
    guard quote < scalars.count, scalars[quote] == "\"" else { return nil }
    var end = quote + 1
    while end < scalars.count {
      if scalars[end] == "\"" { return hashesEnd(in: scalars, at: end + 1) }
      if scalars[end] == "\\" {
        guard end + 1 < scalars.count, scalars[end + 1] != "\n" else { return nil }
        end += 2
        continue
      }
      end += 1
    }
    return nil
  }

  private static func hashesEnd(in scalars: [Unicode.Scalar], at index: Int) -> Int {
    var end = index
    while end < scalars.count, scalars[end] == "#" { end += 1 }
    return end
  }
}

private func string(of scalars: [Unicode.Scalar], from start: Int, to end: Int) -> String {
  var view = String.UnicodeScalarView()
  view.append(contentsOf: scalars[start..<end])
  return String(view)
}

/// Python `\s`: the ASCII controls plus the Unicode separator categories.
private func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar.value {
  case 0x09...0x0D, 0x1C...0x1F, 0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
    return true
  case 0x2000...0x200A:
    return true
  default:
    return false
  }
}

private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar.value {
  case 65...90, 95, 97...122: return true
  default: return false
  }
}

private func isIdentifierContinue(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar.value {
  case 48...57, 65...90, 95, 97...122: return true
  default: return false
  }
}

/// Python `\w`, used for the word boundaries around `static` and `class`.
private func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
  if isIdentifierContinue(scalar) { return true }
  let character = Character(scalar)
  return character.isLetter || character.isNumber
}

/// `re.search(r"\b(static|class)\b", prefix)` for the text between the start of
/// the token's line and the token itself.
private func isStaticOrClass(_ scalars: [Unicode.Scalar], before tokenStart: Int) -> Bool {
  let lineStart = lineStart(scalars, before: tokenStart)
  return containsWord("class", in: scalars, from: lineStart, to: tokenStart)
    || containsWord("static", in: scalars, from: lineStart, to: tokenStart)
}

private func containsWord(
  _ word: String, in scalars: [Unicode.Scalar], from start: Int, to end: Int
) -> Bool {
  let expected = Array(word.unicodeScalars)
  guard !expected.isEmpty, end - start >= expected.count else { return false }
  var index = start
  while index + expected.count <= end {
    var offset = 0
    while offset < expected.count, scalars[index + offset] == expected[offset] { offset += 1 }
    if offset == expected.count,
      index == start || !isWordScalar(scalars[index - 1]),
      index + expected.count == end || !isWordScalar(scalars[index + expected.count])
    {
      return true
    }
    index += 1
  }
  return false
}

private func lineStart(_ scalars: [Unicode.Scalar], before offset: Int) -> Int {
  var index = offset
  while index > 0 {
    index -= 1
    if scalars[index] == "\n" { return index + 1 }
  }
  return 0
}

private func hasNewline(_ scalars: [Unicode.Scalar], from start: Int, to end: Int) -> Bool {
  guard start < end else { return false }
  for index in start..<end where scalars[index] == "\n" { return true }
  return false
}
