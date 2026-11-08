import Foundation

/// The pages of the first-run walkthrough, in order.
enum OnboardingStep: Int, CaseIterable, Equatable {
  case welcome
  case accessibility
  case spaces
  case names
  case grid
  case tools
  case finish

  var title: String {
    switch self {
    case .welcome: return "Welcome to Cubicle"
    case .accessibility: return "Let Cubicle switch Spaces"
    case .spaces: return "Make some Spaces"
    case .names: return "Name your Spaces"
    case .grid: return "Jump around"
    case .tools: return "Command line and Alfred"
    case .finish: return "You're all set"
    }
  }

  var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
  var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
  var isFirst: Bool { previous == nil }
  var isLast: Bool { next == nil }

  /// 1-based position, for "Step 3 of 7".
  var position: Int { rawValue + 1 }
  static var count: Int { allCases.count }

  /// Only the Accessibility page holds you back, and only until the permission is granted. It can also be skipped.
  func canAdvance(accessibilityGranted: Bool) -> Bool {
    self == .accessibility ? accessibilityGranted : true
  }
}
