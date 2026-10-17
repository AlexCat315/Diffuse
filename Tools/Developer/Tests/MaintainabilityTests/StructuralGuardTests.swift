import XCTest

@testable import Maintainability

/// Regression examples for the structural Swift guard, ported one-to-one from
/// `scripts/test-swift-maintainability.py`.
final class StructuralGuardTests: XCTestCase {
  func testStoredPropertiesExcludeStaticComputedAndStringContents() {
    let source = """

      struct Configuration {
          static let global = 0
          var count: Int = 0
          let text = "struct Fake { var fake: Int }"
          var computed: Int { count * 2 }
          var observed: Int { didSet { print(observed) } }
          // var commented: Int
      }
      """
    XCTAssertEqual(StructuralGuard.measure(source)["Configuration"]?[.storedProperties], 3)
  }

  func testGenericsAndClosuresDoNotInflateParameterCounts() {
    let source = """

      struct Configuration {
          var value = 0
          init(values: Dictionary<String, Int>, apply: (Int, Int) -> Int = { a, b in a + b }) {
              self.value = apply(1, 2)
          }
      }
      """
    let metrics = StructuralGuard.measure(source)["Configuration"]
    XCTAssertEqual(metrics?[.initializerParameters], 2)
    XCTAssertEqual(metrics?[.initializerAssignments], 1)
  }

  func testNestedTypesAreCountedIndependently() {
    let source = "struct Outer { var x = 0; struct Inner { var a = 0; var b = 1 } }"
    let metrics = StructuralGuard.measure(source)
    XCTAssertEqual(metrics["Outer"]?[.storedProperties], 1)
    XCTAssertEqual(metrics["Outer.Inner"]?[.storedProperties], 2)
  }

  func testClassMethodsDoNotCreateFakeTypes() {
    XCTAssertEqual(
      Set(StructuralGuard.measure("class Factory { class func make() -> Int { 1 } }").keys),
      ["Factory"])
  }

  func testLargePropertyListIsDetected() {
    let source =
      "struct Oversized {\n"
      + (0..<21).map { "var field\($0) = 0" }.joined(separator: "\n")
      + "\n}"
    XCTAssertGreaterThan(
      StructuralGuard.measure(source)["Oversized"]?[.storedProperties] ?? 0,
      Metric.storedProperties.limit)
  }
}
