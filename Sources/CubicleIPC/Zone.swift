import Foundation

/// A named rectangle windows can be stacked in (see CONTEXT.md). Every Space has the same zones, and each covers
/// exactly the rectangle of the matching snap. The raw values are the names the CLI uses.
public enum Zone: String, CaseIterable, Codable, Sendable {
  case leftHalf = "left-half"
  case rightHalf = "right-half"
  case topHalf = "top-half"
  case bottomHalf = "bottom-half"
  case topLeft = "top-left"
  case topRight = "top-right"
  case bottomLeft = "bottom-left"
  case bottomRight = "bottom-right"
  case full

  /// Accepts the zone names plus the snap spellings ("left", "maximize").
  public init?(name: String) {
    let key = name.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
    if let zone = Zone(rawValue: key) {
      self = zone
    } else if let zone = SnapAction(name: key)?.zone {
      self = zone
    } else {
      return nil
    }
  }

  /// The snap that covers this zone's rectangle.
  public var snapAction: SnapAction {
    switch self {
    case .leftHalf: return .leftHalf
    case .rightHalf: return .rightHalf
    case .topHalf: return .topHalf
    case .bottomHalf: return .bottomHalf
    case .topLeft: return .topLeft
    case .topRight: return .topRight
    case .bottomLeft: return .bottomLeft
    case .bottomRight: return .bottomRight
    case .full: return .maximize
    }
  }

  public var displayName: String { self == .full ? "Full" : snapAction.displayName }

  public enum Direction: String, CaseIterable, Sendable {
    case left, right, up, down
  }

  /// The zone next to this one in `direction`, for swapping: halves pair with their opposite half and quarters
  /// with the quarter beside them. Full has no neighbour.
  public func neighbour(_ direction: Direction) -> Zone? {
    switch (self, direction) {
    case (.leftHalf, .right): return .rightHalf
    case (.rightHalf, .left): return .leftHalf
    case (.topHalf, .down): return .bottomHalf
    case (.bottomHalf, .up): return .topHalf
    case (.topLeft, .right): return .topRight
    case (.topLeft, .down): return .bottomLeft
    case (.topRight, .left): return .topLeft
    case (.topRight, .down): return .bottomRight
    case (.bottomLeft, .up): return .topLeft
    case (.bottomLeft, .right): return .bottomRight
    case (.bottomRight, .up): return .topRight
    case (.bottomRight, .left): return .bottomLeft
    default: return nil
    }
  }
}

extension SnapAction {
  /// The zone a snap puts a window in. Full Screen, Center and Restore have none: they let go of the window.
  public var zone: Zone? {
    switch self {
    case .leftHalf: return .leftHalf
    case .rightHalf: return .rightHalf
    case .topHalf: return .topHalf
    case .bottomHalf: return .bottomHalf
    case .topLeft: return .topLeft
    case .topRight: return .topRight
    case .bottomLeft: return .bottomLeft
    case .bottomRight: return .bottomRight
    case .maximize: return .full
    case .fullScreen, .center, .restore: return nil
    }
  }
}
