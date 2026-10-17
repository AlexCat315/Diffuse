internal import Foundation
internal import ToolSupport

#if canImport(FoundationXML)
  internal import FoundationXML
#endif

/// One JUnit/xUnit `<testcase>` record, reduced to the values the GPU
/// regression inventory checks: its suite, method name, reported time, and
/// whether it carries a `skipped`, `failure`, or `error` child.
struct TestCase: Equatable {
  var classname: String
  var name: String
  var time: String
  var hasSkipped = false
  var hasFailure = false
  var hasError = false

  /// Python's `len(case)`: the number of child elements. `load_cases` uses it
  /// only as a truthiness test, to keep a logged failure from being hidden by
  /// a matching childless XML record.
  var childCount: Int { (hasSkipped ? 1 : 0) + (hasFailure ? 1 : 0) + (hasError ? 1 : 0) }

  /// Whether `verify_cases` must reject the run because of this record.
  var failsGate: Bool { hasSkipped || hasFailure || hasError }
}

/// The XML side of the report: reads every `<testcase>` from an xUnit report
/// and writes the XCTest log records back out as one synthetic `<testsuite>`.
///
/// Both operations stand in for Python's `xml.etree.ElementTree`; the written
/// document matches ElementTree's attribute order and declaration.
enum XUnit {
  static func testCases(at url: URL) throws -> [TestCase] {
    guard let parser = XMLParser(contentsOf: url) else {
      throw ToolError.message("Cannot read xUnit report: \(url.path)")
    }
    let collector = Collector()
    parser.delegate = collector
    guard parser.parse() else {
      let reason =
        collector.failure ?? parser.parserError?.localizedDescription ?? "unknown parse error"
      throw ToolError.message("Malformed xUnit report \(url.path): \(reason)")
    }
    return collector.cases
  }

  static func write(_ cases: [TestCase], to url: URL) throws {
    var text = "<?xml version='1.0' encoding='utf-8'?>\n"
    text += "<testsuite name=\"XCTest\" tests=\"\(cases.count)\">"
    for item in cases {
      text +=
        "<testcase classname=\"\(escape(item.classname))\" name=\"\(escape(item.name))\" time=\"\(escape(item.time))\""
      if item.hasSkipped {
        text += "><skipped /></testcase>"
      } else if item.hasFailure {
        text += "><failure /></testcase>"
      } else if item.hasError {
        text += "><error /></testcase>"
      } else {
        text += " />"
      }
    }
    text += "</testsuite>"
    try Fs.write(text, to: url)
  }

  /// `ElementTree._escape_attrib`: the ampersand first, then the delimiters
  /// and whitespace that an XML attribute value cannot carry literally.
  private static func escape(_ value: String) -> String {
    var text = value
    for (character, replacement) in [
      ("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"),
      ("\r", "&#13;"), ("\n", "&#10;"), ("\t", "&#09;"),
    ] {
      if text.contains(character) {
        text = text.replacingOccurrences(of: character, with: replacement)
      }
    }
    return text
  }

  /// Collects `<testcase>` descendants and their status children. `iter()`'s
  /// descendant scan is reproduced by tracking the element stack.
  private final class Collector: NSObject, XMLParserDelegate {
    private(set) var cases: [TestCase] = []
    private(set) var failure: String?
    private var current: TestCase?
    private var depth = 0

    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
      qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
      switch elementName {
      case "testcase":
        current = TestCase(
          classname: attributeDict["classname"] ?? "",
          name: attributeDict["name"] ?? "",
          time: attributeDict["time"] ?? "")
        depth = 0
      case "skipped" where current != nil:
        current?.hasSkipped = true
      case "failure" where current != nil:
        current?.hasFailure = true
      case "error" where current != nil:
        current?.hasError = true
      default:
        break
      }
      if current != nil { depth += 1 }
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
      qualifiedName qName: String?
    ) {
      guard current != nil else { return }
      depth -= 1
      if depth == 0 {
        cases.append(current!)
        current = nil
      }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
      failure = parser.parserError?.localizedDescription ?? parseError.localizedDescription
    }
  }
}
