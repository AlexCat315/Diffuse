//! Tokenizer-based structural guard for oversized Swift declarations. This is a
//! lexical approximator, not a Swift parser: it ignores comments and string
//! literals, and it never looks inside a type's nested scopes for members.
//!
//! The source language is still Swift: the guard measures the Swift sources
//! that remain in the checkout, so its token rules are kept verbatim from
//! `scripts/test-swift-maintainability.py`.

use super::ordered_map::OrderedMap;

/// The structural metrics the guard measures for one declaration. Raw values
/// match the Python checker's metric names so reports and the baseline file stay
/// byte-compatible.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Metric {
    StoredProperties,
    InitializerParameters,
    InitializerAssignments,
}

impl Metric {
    pub const ALL: [Metric; 3] = [
        Metric::StoredProperties,
        Metric::InitializerParameters,
        Metric::InitializerAssignments,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Metric::StoredProperties => "stored_properties",
            Metric::InitializerParameters => "initializer_parameters",
            Metric::InitializerAssignments => "initializer_assignments",
        }
    }

    pub fn from_raw(value: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|metric| metric.raw_value() == value)
    }

    /// The hard limit every declaration must respect, independent of the
    /// baseline.
    pub fn limit(self) -> i64 {
        match self {
            Metric::StoredProperties => 20,
            Metric::InitializerParameters => 16,
            Metric::InitializerAssignments => 20,
        }
    }
}

/// One declaration's measured structural size.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DeclarationMetrics {
    pub stored_properties: i64,
    pub initializer_parameters: i64,
    pub initializer_assignments: i64,
}

impl DeclarationMetrics {
    pub fn get(&self, metric: Metric) -> i64 {
        match metric {
            Metric::StoredProperties => self.stored_properties,
            Metric::InitializerParameters => self.initializer_parameters,
            Metric::InitializerAssignments => self.initializer_assignments,
        }
    }

    pub fn set(&mut self, metric: Metric, value: i64) {
        match metric {
            Metric::StoredProperties => self.stored_properties = value,
            Metric::InitializerParameters => self.initializer_parameters = value,
            Metric::InitializerAssignments => self.initializer_assignments = value,
        }
    }

    /// Keeps the largest of each metric, matching how the Python checker merges
    /// repeated qualified names inside one file.
    pub fn raise(&mut self, other: &DeclarationMetrics) {
        for metric in Metric::ALL {
            let value = self.get(metric).max(other.get(metric));
            self.set(metric, value);
        }
    }
}

/// A lexical token and its code-point range in the scanned source.
#[derive(Clone, Debug, PartialEq, Eq)]
struct SourceToken {
    text: String,
    start: usize,
    end: usize,
}

pub struct StructuralGuard;

impl StructuralGuard {
    /// Measures every `struct`, `class`, and `extension` in `source`, keyed by
    /// its (possibly nested, `Outer.Inner`-qualified) name in source order.
    pub fn measure(source: &str) -> OrderedMap<DeclarationMetrics> {
        let scalars: Vec<char> = source.chars().collect();
        let tokens = Tokenizer::tokens(&scalars);

        let mut pairs: std::collections::HashMap<usize, usize> = std::collections::HashMap::new();
        let mut stack: Vec<usize> = Vec::new();
        let mut depths: Vec<usize> = Vec::with_capacity(tokens.len());
        for (index, token) in tokens.iter().enumerate() {
            depths.push(stack.len());
            if token.text == "{" || token.text == "(" || token.text == "[" {
                stack.push(index);
            } else if (token.text == "}" || token.text == ")" || token.text == "]")
                && let Some(opening) = stack.pop()
            {
                pairs.insert(opening, index);
            }
        }

        let mut types: Vec<(String, usize, usize)> = Vec::new();
        for (index, token) in tokens.iter().enumerate() {
            if token.text != "struct" && token.text != "class" && token.text != "extension" {
                continue;
            }
            if index + 1 >= tokens.len() {
                continue;
            }
            if index > 0 && (tokens[index - 1].text == "import" || tokens[index - 1].text == ".") {
                continue;
            }
            let name = tokens[index + 1].text.clone();
            if name == "func" || name == "var" || name == "let" {
                continue;
            }
            let mut opening = index + 2;
            while opening < tokens.len()
                && tokens[opening].text != "{"
                && tokens[opening].text != "="
                && tokens[opening].text != ";"
            {
                opening += 1;
            }
            if opening >= tokens.len() || tokens[opening].text != "{" {
                continue;
            }
            let Some(closing) = pairs.get(&opening).copied() else {
                continue;
            };
            let parent = types
                .iter()
                .rev()
                .find(|(_, type_opening, type_closing)| {
                    *type_opening < index && index < *type_closing
                })
                .map(|(qualified, _, _)| qualified.clone());
            types.push((
                parent.map_or_else(|| name.clone(), |parent| format!("{parent}.{name}")),
                opening,
                closing,
            ));
        }

        let mut result: OrderedMap<DeclarationMetrics> = OrderedMap::new();
        for (qualified, opening, closing) in &types {
            let mut fields: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
            let mut initializers: Vec<(i64, usize, usize)> = Vec::new();
            for index in (opening + 1)..*closing {
                if depths[index] != depths[*opening] + 1 {
                    continue;
                }
                let token = &tokens[index];
                if token.text == "let" || token.text == "var" {
                    if is_static_or_class(&scalars, token.start) {
                        continue;
                    }
                    let mut end = index + 2;
                    while end < *closing {
                        if has_newline(&scalars, tokens[end - 1].end, tokens[end].start) {
                            break;
                        }
                        if tokens[end].text == "{"
                            || tokens[end].text == ";"
                            || tokens[end].text == "}"
                        {
                            break;
                        }
                        end += 1;
                    }
                    let header: Vec<&str> = tokens[index + 2..end]
                        .iter()
                        .map(|token| token.text.as_str())
                        .collect();
                    let observer = end + 1 < *closing
                        && (tokens[end + 1].text == "didSet" || tokens[end + 1].text == "willSet");
                    let computed = end < *closing
                        && tokens[end].text == "{"
                        && !header.contains(&"=")
                        && !observer;
                    if !computed {
                        fields.insert(tokens[index + 1].text.clone());
                    }
                } else if token.text == "init" {
                    let mut parameter_start = index + 1;
                    if tokens[parameter_start].text == "?" || tokens[parameter_start].text == "!" {
                        parameter_start += 1;
                    }
                    if tokens[parameter_start].text != "(" {
                        continue;
                    }
                    let Some(parameter_end) = pairs.get(&parameter_start).copied() else {
                        continue;
                    };
                    let mut count = 0;
                    let mut angle_depth = 0;
                    for argument in (parameter_start + 1)..parameter_end {
                        if depths[argument] != depths[parameter_start] + 1 {
                            continue;
                        }
                        let value = tokens[argument].text.as_str();
                        if value == "<" {
                            angle_depth += 1;
                        } else if value == ">" && angle_depth > 0 {
                            angle_depth -= 1;
                        } else if value == ":" && angle_depth == 0 {
                            count += 1;
                        }
                    }
                    let mut body = parameter_end + 1;
                    while body < *closing && tokens[body].text != "{" {
                        body += 1;
                    }
                    if let Some(body_end) = pairs.get(&body).copied() {
                        initializers.push((count, body, body_end));
                    }
                }
            }

            let mut assignments = 0;
            for (_, body, body_end) in &initializers {
                let mut assigned: std::collections::BTreeSet<String> =
                    std::collections::BTreeSet::new();
                if body + 1 < body_end.saturating_sub(1) {
                    for index in (body + 1)..(body_end - 1) {
                        let token = tokens[index].text.as_str();
                        if !fields.contains(token) {
                            continue;
                        }
                        if tokens[index + 1].text != "=" {
                            continue;
                        }
                        if tokens[index + 2].text == "=" {
                            continue;
                        }
                        if tokens[index - 1].text == "let" || tokens[index - 1].text == "var" {
                            continue;
                        }
                        assigned.insert(token.to_string());
                    }
                }
                assignments = assignments.max(assigned.len() as i64);
            }

            let mut entry = DeclarationMetrics::default();
            entry.stored_properties = fields.len() as i64;
            entry.initializer_parameters = initializers
                .iter()
                .map(|(parameters, _, _)| *parameters)
                .max()
                .unwrap_or(0);
            entry.initializer_assignments = assignments;
            let mut merged = result.get(qualified).copied().unwrap_or_default();
            merged.raise(&entry);
            result.insert(merged, qualified);
        }
        result
    }
}

/// Single-pass tokenizer mirroring the Python guard's alternation order: line
/// comments, block comments, raw/multiline strings, string literals, backtick
/// identifiers, identifiers, then any other non-whitespace scalar.
struct Tokenizer;

impl Tokenizer {
    fn tokens(scalars: &[char]) -> Vec<SourceToken> {
        let mut tokens: Vec<SourceToken> = Vec::new();
        let mut index = 0;
        while index < scalars.len() {
            if is_whitespace(scalars[index]) {
                index += 1;
                continue;
            }
            let end = Self::token_end(scalars, index);
            let text: String = scalars[index..end].iter().collect();
            if !text.starts_with("//") && !text.starts_with("/*") {
                tokens.push(SourceToken {
                    text,
                    start: index,
                    end,
                });
            }
            index = end;
        }
        tokens
    }

    /// Returns the exclusive end of the first matching alternative. Always
    /// advances, because the final alternative accepts any non-whitespace
    /// scalar.
    fn token_end(scalars: &[char], index: usize) -> usize {
        if scalars[index] == '/'
            && index + 1 < scalars.len()
            && scalars[index + 1] == '/'
        {
            let mut end = index + 2;
            while end < scalars.len() && scalars[end] != '\n' {
                end += 1;
            }
            return end;
        }
        if scalars[index] == '/'
            && index + 1 < scalars.len()
            && scalars[index + 1] == '*'
        {
            let mut end = index + 2;
            while end + 1 < scalars.len() {
                if scalars[end] == '*' && scalars[end + 1] == '/' {
                    return end + 2;
                }
                end += 1;
            }
        }
        if let Some(end) = Self::multiline_string_end(scalars, index) {
            return end;
        }
        if let Some(end) = Self::string_end(scalars, index) {
            return end;
        }
        if scalars[index] == '`' && index + 1 < scalars.len() && scalars[index + 1] != '`' {
            let mut end = index + 1;
            while end < scalars.len() && scalars[end] != '`' {
                end += 1;
            }
            if end < scalars.len() && end >= index + 2 {
                return end + 1;
            }
        }
        if is_identifier_start(scalars[index]) {
            let mut end = index + 1;
            while end < scalars.len() && is_identifier_continue(scalars[end]) {
                end += 1;
            }
            return end;
        }
        index + 1
    }

    /// `#*"""..."""#*`, with the shortest body that reaches a closing delimiter.
    fn multiline_string_end(scalars: &[char], index: usize) -> Option<usize> {
        let mut quote = index;
        while quote < scalars.len() && scalars[quote] == '#' {
            quote += 1;
        }
        if quote + 2 >= scalars.len()
            || scalars[quote] != '"'
            || scalars[quote + 1] != '"'
            || scalars[quote + 2] != '"'
        {
            return None;
        }
        let mut end = quote + 3;
        while end + 2 < scalars.len() {
            if scalars[end] == '"' && scalars[end + 1] == '"' && scalars[end + 2] == '"' {
                return Some(Self::hashes_end(scalars, end + 3));
            }
            end += 1;
        }
        None
    }

    /// `#*"(?:\\.|[^"\\])*"#*`. A backslash only escapes another scalar, never
    /// the end of a line, exactly like the Python pattern.
    fn string_end(scalars: &[char], index: usize) -> Option<usize> {
        let mut quote = index;
        while quote < scalars.len() && scalars[quote] == '#' {
            quote += 1;
        }
        if quote >= scalars.len() || scalars[quote] != '"' {
            return None;
        }
        let mut end = quote + 1;
        while end < scalars.len() {
            if scalars[end] == '"' {
                return Some(Self::hashes_end(scalars, end + 1));
            }
            if scalars[end] == '\\' {
                if end + 1 >= scalars.len() || scalars[end + 1] == '\n' {
                    return None;
                }
                end += 2;
                continue;
            }
            end += 1;
        }
        None
    }

    fn hashes_end(scalars: &[char], index: usize) -> usize {
        let mut end = index;
        while end < scalars.len() && scalars[end] == '#' {
            end += 1;
        }
        end
    }
}

/// Python `\s`: the ASCII controls plus the Unicode separator categories.
fn is_whitespace(scalar: char) -> bool {
    let code = scalar as u32;
    matches!(
        code,
        0x09..=0x0D
            | 0x1C..=0x1F
            | 0x20
            | 0x85
            | 0xA0
            | 0x1680
            | 0x2028
            | 0x2029
            | 0x202F
            | 0x205F
            | 0x3000
    ) || (0x2000..=0x200A).contains(&code)
}

fn is_identifier_start(scalar: char) -> bool {
    let code = scalar as u32;
    matches!(code, 65..=90 | 95 | 97..=122)
}

fn is_identifier_continue(scalar: char) -> bool {
    let code = scalar as u32;
    matches!(code, 48..=57 | 65..=90 | 95 | 97..=122)
}

/// Python `\w`, used for the word boundaries around `static` and `class`.
fn is_word_scalar(scalar: char) -> bool {
    is_identifier_continue(scalar) || scalar.is_alphanumeric()
}

/// `re.search(r"\b(static|class)\b", prefix)` for the text between the start of
/// the token's line and the token itself.
fn is_static_or_class(scalars: &[char], token_start: usize) -> bool {
    let line_start = line_start(scalars, token_start);
    contains_word("class", scalars, line_start, token_start)
        || contains_word("static", scalars, line_start, token_start)
}

fn contains_word(word: &str, scalars: &[char], start: usize, end: usize) -> bool {
    let expected: Vec<char> = word.chars().collect();
    if expected.is_empty() || end <= start || end - start < expected.len() {
        return false;
    }
    let mut index = start;
    while index + expected.len() <= end {
        let mut offset = 0;
        while offset < expected.len() && scalars[index + offset] == expected[offset] {
            offset += 1;
        }
        if offset == expected.len()
            && (index == start || !is_word_scalar(scalars[index - 1]))
            && (index + expected.len() == end
                || !is_word_scalar(scalars[index + expected.len()]))
        {
            return true;
        }
        index += 1;
    }
    false
}

fn line_start(scalars: &[char], before: usize) -> usize {
    let mut index = before;
    while index > 0 {
        index -= 1;
        if scalars[index] == '\n' {
            return index + 1;
        }
    }
    0
}

fn has_newline(scalars: &[char], from: usize, to: usize) -> bool {
    if from >= to {
        return false;
    }
    scalars[from..to].iter().any(|scalar| *scalar == '\n')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stored_properties(source: &str, name: &str) -> i64 {
        StructuralGuard::measure(source)
            .get(name)
            .map(|metrics| metrics.stored_properties)
            .unwrap_or(-1)
    }

    // Swift: testStoredPropertiesExcludeStaticComputedAndStringContents.
    #[test]
    fn stored_properties_exclude_static_computed_and_string_contents() {
        let source = r#"

struct Configuration {
    static let global = 0
    var count: Int = 0
    let text = "struct Fake { var fake: Int }"
    var computed: Int { count * 2 }
    var observed: Int { didSet { print(observed) } }
    // var commented: Int
}
"#;
        assert_eq!(stored_properties(source, "Configuration"), 3);
    }

    // Swift: testGenericsAndClosuresDoNotInflateParameterCounts.
    #[test]
    fn generics_and_closures_do_not_inflate_parameter_counts() {
        let source = r#"

struct Configuration {
    var value = 0
    init(values: Dictionary<String, Int>, apply: (Int, Int) -> Int = { a, b in a + b }) {
        self.value = apply(1, 2)
    }
}
"#;
        let metrics = StructuralGuard::measure(source);
        let entry = metrics.get("Configuration").copied().expect("measured");
        assert_eq!(entry.initializer_parameters, 2);
        assert_eq!(entry.initializer_assignments, 1);
    }

    // Swift: testNestedTypesAreCountedIndependently.
    #[test]
    fn nested_types_are_counted_independently() {
        let source = "struct Outer { var x = 0; struct Inner { var a = 0; var b = 1 } }";
        let metrics = StructuralGuard::measure(source);
        assert_eq!(metrics.get("Outer").unwrap().stored_properties, 1);
        assert_eq!(metrics.get("Outer.Inner").unwrap().stored_properties, 2);
    }

    // Swift: testClassMethodsDoNotCreateFakeTypes.
    #[test]
    fn class_methods_do_not_create_fake_types() {
        let metrics = StructuralGuard::measure("class Factory { class func make() -> Int { 1 } }");
        assert_eq!(metrics.keys(), ["Factory"]);
    }

    // Swift: testLargePropertyListIsDetected.
    #[test]
    fn a_large_property_list_exceeds_the_limit() {
        let mut source = String::from("struct Oversized {\n");
        for index in 0..21 {
            source.push_str(&format!("var field{index} = 0\n"));
        }
        source.push('}');
        let measured = stored_properties(&source, "Oversized");
        assert!(measured > Metric::StoredProperties.limit());
    }

    #[test]
    fn comments_and_strings_do_not_produce_declarations() {
        let metrics = StructuralGuard::measure(
            "// struct Commented { var a = 0 }\nlet text = \"class Fake {\"\n",
        );
        assert!(metrics.is_empty());
    }

    #[test]
    fn metric_raw_values_match_the_baseline_file() {
        assert_eq!(Metric::StoredProperties.raw_value(), "stored_properties");
        assert_eq!(
            Metric::InitializerParameters.raw_value(),
            "initializer_parameters"
        );
        assert_eq!(
            Metric::InitializerAssignments.raw_value(),
            "initializer_assignments"
        );
        assert_eq!(Metric::from_raw("stored_properties"), Some(Metric::StoredProperties));
        assert_eq!(Metric::StoredProperties.limit(), 20);
        assert_eq!(Metric::InitializerParameters.limit(), 16);
        assert_eq!(Metric::InitializerAssignments.limit(), 20);
    }

    #[test]
    fn raising_keeps_the_largest_metric_of_each_kind() {
        let mut left = DeclarationMetrics {
            stored_properties: 3,
            initializer_parameters: 1,
            initializer_assignments: 9,
        };
        left.raise(&DeclarationMetrics {
            stored_properties: 5,
            initializer_parameters: 2,
            initializer_assignments: 1,
        });
        assert_eq!(
            left,
            DeclarationMetrics {
                stored_properties: 5,
                initializer_parameters: 2,
                initializer_assignments: 9,
            }
        );
    }
}
