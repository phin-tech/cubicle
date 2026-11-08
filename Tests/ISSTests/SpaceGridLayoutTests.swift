import XCTest

@testable import InstantSpaceSwitcher

final class SpaceGridLayoutTests: XCTestCase {
  func testColumnsFollowSquareRoot() {
    XCTAssertEqual(SpaceGridLayout.columns(for: 0), 1)
    XCTAssertEqual(SpaceGridLayout.columns(for: 1), 1)
    XCTAssertEqual(SpaceGridLayout.columns(for: 2), 2)
    XCTAssertEqual(SpaceGridLayout.columns(for: 4), 2)
    XCTAssertEqual(SpaceGridLayout.columns(for: 5), 3)
    XCTAssertEqual(SpaceGridLayout.columns(for: 16), 4)
  }

  func testRowsCoverEveryCell() {
    for count in 1...16 {
      let capacity = SpaceGridLayout.rows(for: count) * SpaceGridLayout.columns(for: count)
      XCTAssertGreaterThanOrEqual(capacity, count)
    }
    XCTAssertEqual(SpaceGridLayout.rows(for: 0), 0)
  }

  func testMovementStaysInsideGrid() {
    // 5 spaces -> 3 columns: [0 1 2] / [3 4 _]
    XCTAssertEqual(SpaceGridLayout.move(0, .left, count: 5), 0)
    XCTAssertEqual(SpaceGridLayout.move(0, .up, count: 5), 0)
    XCTAssertEqual(SpaceGridLayout.move(0, .right, count: 5), 1)
    XCTAssertEqual(SpaceGridLayout.move(0, .down, count: 5), 3)
    XCTAssertEqual(SpaceGridLayout.move(4, .right, count: 5), 4)
    XCTAssertEqual(SpaceGridLayout.move(4, .down, count: 5), 4)
    // Cell 2 has no cell below it in the short last row.
    XCTAssertEqual(SpaceGridLayout.move(2, .down, count: 5), 2)
  }

  func testMovementWithNoCells() {
    XCTAssertEqual(SpaceGridLayout.move(0, .right, count: 0), 0)
  }

  func testDigitsMapToExistingSpacesOnly() {
    XCTAssertEqual(SpaceGridLayout.index(forDigit: "1", count: 2), 0)
    XCTAssertEqual(SpaceGridLayout.index(forDigit: "2", count: 2), 1)
    XCTAssertNil(SpaceGridLayout.index(forDigit: "3", count: 2))
    XCTAssertNil(SpaceGridLayout.index(forDigit: "0", count: 2))
    XCTAssertNil(SpaceGridLayout.index(forDigit: "x", count: 2))
  }

  private func cells(_ titles: [String]) -> [SpaceGridCell] {
    titles.enumerated().map { SpaceGridCell(index: $0.offset, title: $0.element, hasCustomName: true) }
  }

  func testEmptyQueryMatchesEverything() {
    let all = cells(["Mail", "Code", "Café"])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: ""), [0, 1, 2])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "   "), [0, 1, 2])
  }

  func testSearchIgnoresCaseAndDiacritics() {
    let all = cells(["Mail", "Code", "Café", "My Work"])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "mai"), [0])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "CAFE"), [2])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "o"), [1, 3])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "my w"), [3])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "zzz"), [])
  }

  func testSearchMatchesNumberLabelsOfUnnamedSpaces() {
    let all = [SpaceGridCell(index: 0, title: "1", hasCustomName: false),
               SpaceGridCell(index: 1, title: "Mail", hasCustomName: true)]
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "1"), [0])
  }

  func testStepCyclesThroughMatches() {
    XCTAssertEqual(SpaceGridLayout.step(from: 1, by: 1, among: [1, 3, 4]), 3)
    XCTAssertEqual(SpaceGridLayout.step(from: 4, by: 1, among: [1, 3, 4]), 1)
    XCTAssertEqual(SpaceGridLayout.step(from: 1, by: -1, among: [1, 3, 4]), 4)
    XCTAssertEqual(SpaceGridLayout.step(from: 2, by: 1, among: [1, 3, 4]), 1)
    XCTAssertEqual(SpaceGridLayout.step(from: 2, by: 1, among: []), 2)
  }

  func testFuzzyMatchesLettersInOrder() {
    let all = cells(["main", "innopts"])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "ino"), [1])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "inpts"), [1])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "oni"), [])
  }

  func testCurrentSpaceIsExcludedOnlyWhileSearching() {
    let all = cells(["main", "innopts"])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "n", excluding: 0), [1])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "m", excluding: 0), [])
    XCTAssertEqual(SpaceGridLayout.matches(in: all, query: "", excluding: 0), [0, 1])
  }

  func testBestMatchPrefersPrefixThenSubstringThenFuzzy() {
    let all = cells(["xxmailxx", "m-a-i-l", "mail"])
    let hits = SpaceGridLayout.matches(in: all, query: "mail")
    XCTAssertEqual(hits, [0, 1, 2])
    XCTAssertEqual(SpaceGridLayout.bestMatch(in: all, query: "mail", among: hits), 2)
    XCTAssertEqual(SpaceGridLayout.bestMatch(in: all, query: "mail", among: [0, 1]), 0)
    XCTAssertNil(SpaceGridLayout.bestMatch(in: all, query: "zzz", among: hits))
  }
}
