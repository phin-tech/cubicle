import XCTest

@testable import InstantSpaceSwitcher

final class OnboardingTests: XCTestCase {
  func testStepsRunInOrderFromWelcomeToFinish() {
    XCTAssertEqual(OnboardingStep.allCases.first, .welcome)
    XCTAssertEqual(OnboardingStep.allCases.last, .finish)
    XCTAssertEqual(OnboardingStep.welcome.next, .accessibility)
    XCTAssertEqual(OnboardingStep.finish.previous, .tools)
    XCTAssertNil(OnboardingStep.welcome.previous)
    XCTAssertNil(OnboardingStep.finish.next)
    XCTAssertTrue(OnboardingStep.welcome.isFirst)
    XCTAssertTrue(OnboardingStep.finish.isLast)
  }

  func testEveryStepHasATitleAndAUniquePosition() {
    XCTAssertEqual(Set(OnboardingStep.allCases.map(\.title)).count, OnboardingStep.count)
    XCTAssertTrue(OnboardingStep.allCases.allSatisfy { !$0.title.isEmpty })
    XCTAssertEqual(OnboardingStep.allCases.map(\.position), Array(1...OnboardingStep.count))
  }

  func testOnlyTheAccessibilityStepHoldsYouBackUntilGranted() {
    XCTAssertFalse(OnboardingStep.accessibility.canAdvance(accessibilityGranted: false))
    XCTAssertTrue(OnboardingStep.accessibility.canAdvance(accessibilityGranted: true))
    for step in OnboardingStep.allCases where step != .accessibility {
      XCTAssertTrue(step.canAdvance(accessibilityGranted: false), "\(step) should not be gated")
    }
  }
}
