import CoreGraphics
import Foundation

/// The Rectangle-style window commands. See CONTEXT.md: a snap moves and resizes one window to a preset region of
/// the display it is on. The raw values are the names the CLI and Alfred use. It lives here so the CLI can list
/// the actions without asking the app.
public enum SnapAction: String, CaseIterable, Codable, Sendable {
  case leftHalf = "left-half"
  case rightHalf = "right-half"
  case topHalf = "top-half"
  case bottomHalf = "bottom-half"
  case topLeft = "top-left"
  case topRight = "top-right"
  case bottomLeft = "bottom-left"
  case bottomRight = "bottom-right"
  case maximize
  case center
  case restore

  /// Accepts the raw name plus a few spellings people reach for ("full" is the zone name for Maximize).
  public init?(name: String) {
    let key = name.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
    if let action = SnapAction(rawValue: key) {
      self = action
      return
    }
    switch key {
    case "left": self = .leftHalf
    case "right": self = .rightHalf
    case "top", "up": self = .topHalf
    case "bottom", "down": self = .bottomHalf
    case "full", "max", "maximise": self = .maximize
    case "centre": self = .center
    default: return nil
    }
  }

  public var displayName: String {
    switch self {
    case .leftHalf: return "Left Half"
    case .rightHalf: return "Right Half"
    case .topHalf: return "Top Half"
    case .bottomHalf: return "Bottom Half"
    case .topLeft: return "Top Left Quarter"
    case .topRight: return "Top Right Quarter"
    case .bottomLeft: return "Bottom Left Quarter"
    case .bottomRight: return "Bottom Right Quarter"
    case .maximize: return "Maximize"
    case .center: return "Center"
    case .restore: return "Restore"
    }
  }

  /// The region as fractions of the usable area (x, y from the top-left, width, height), or nil for the snaps
  /// without a fixed region.
  public var region: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)? {
    switch self {
    case .leftHalf: return (0, 0, 0.5, 1)
    case .rightHalf: return (0.5, 0, 0.5, 1)
    case .topHalf: return (0, 0, 1, 0.5)
    case .bottomHalf: return (0, 0.5, 1, 0.5)
    case .topLeft: return (0, 0, 0.5, 0.5)
    case .topRight: return (0.5, 0, 0.5, 0.5)
    case .bottomLeft: return (0, 0.5, 0.5, 0.5)
    case .bottomRight: return (0.5, 0.5, 0.5, 0.5)
    case .maximize: return (0, 0, 1, 1)
    case .center, .restore: return nil
    }
  }

  /// Other words that find this action in a search ("full" finds Maximize).
  public var searchTerms: [String] {
    switch self {
    case .topLeft, .topRight, .bottomLeft, .bottomRight: return ["quarter", "corner"]
    case .maximize: return ["full", "fill"]
    case .center: return ["centre", "middle"]
    case .restore: return ["undo", "back", "original"]
    default: return ["half"]
    }
  }

  /// Actions whose name or search terms contain every word of `query`, best match first. An empty query keeps
  /// them all, in their usual order.
  public static func matching(_ query: String) -> [SnapAction] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return allCases }
    func haystack(_ action: SnapAction) -> String {
      ([action.displayName.lowercased(), action.rawValue] + action.searchTerms).joined(separator: " ")
    }
    let hits = allCases.filter { action in words.allSatisfy { haystack(action).contains($0) } }
    // Names that start with the first word come first ("left" puts Left Half before Top Left).
    return hits.enumerated().sorted { a, b in
      let aStarts = a.element.displayName.lowercased().hasPrefix(words[0])
      let bStarts = b.element.displayName.lowercased().hasPrefix(words[0])
      return aStarts != bStarts ? aStarts : a.offset < b.offset
    }.map(\.element)
  }
}
