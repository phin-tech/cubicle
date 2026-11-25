import Foundation

/// The display edges a window can be stashed against (see CONTEXT.md). The bottom is left out: the Dock lives there,
/// and parked windows wait just off the bottom corners. The raw values are the names the CLI and Alfred use.
public enum StashEdge: String, CaseIterable, Codable, Sendable {
  case left
  case right
  case top

  /// Accepts the raw names plus a few spellings people reach for.
  public init?(name: String) {
    let key = name.lowercased().trimmingCharacters(in: .whitespaces)
    if let edge = StashEdge(rawValue: key) {
      self = edge
      return
    }
    switch key {
    case "l", "west": self = .left
    case "r", "east": self = .right
    case "t", "up", "north": self = .top
    default: return nil
    }
  }

  public var displayName: String {
    switch self {
    case .left: return "Stash Left"
    case .right: return "Stash Right"
    case .top: return "Stash Top"
    }
  }

  /// Whether Tabs on this edge run down it (left and right) rather than along it (top).
  public var isVertical: Bool { self != .top }

  /// Edges whose name or display name contains every word of `query`, in their usual order.
  public static func matching(_ query: String) -> [StashEdge] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    guard !words.isEmpty else { return allCases }
    return allCases.filter { edge in
      let haystack = "\(edge.displayName.lowercased()) \(edge.rawValue) stash drawer side pop out"
      return words.allSatisfy { haystack.contains($0) }
    }
  }
}

/// Where along its edge a stash Tab sits: the start (top of a side, left of the top), the middle, or the end.
public enum StashSlot: String, CaseIterable, Codable, Sendable {
  case start
  case middle
  case end

  /// Accepts the words that fit either kind of edge: top/bottom for the sides, left/right for the top.
  public init?(name: String) {
    switch name.lowercased().trimmingCharacters(in: .whitespaces) {
    case "start", "top", "left", "first": self = .start
    case "middle", "centre", "center", "mid": self = .middle
    case "end", "bottom", "right", "last": self = .end
    default: return nil
    }
  }

  /// "Top", "Middle" or "Bottom" on a side; "Left", "Centre" or "Right" along the top.
  public func displayName(on edge: StashEdge) -> String {
    switch (self, edge.isVertical) {
    case (.start, true): return "Top"
    case (.end, true): return "Bottom"
    case (.start, false): return "Left"
    case (.end, false): return "Right"
    case (.middle, true): return "Middle"
    case (.middle, false): return "Centre"
    }
  }
}
