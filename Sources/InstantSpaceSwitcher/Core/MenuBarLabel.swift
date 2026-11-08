import Foundation

/// The text shown next to the menu bar badge: the current Space's custom name.
enum MenuBarLabel {
  static let defaultsKey = "showSpaceNameInMenuBar"
  static let maximumLength = 24

  /// On by default; unnamed Spaces never show a label, so this only matters once you have named some.
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
  }

  /// The name as a single trimmed line, shortened with an ellipsis so a long name cannot fill the menu bar.
  /// Nil when there is nothing to show.
  static func title(forName name: String?, maximumLength: Int = maximumLength) -> String? {
    guard let name else { return nil }
    let oneLine = name.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    guard !oneLine.isEmpty else { return nil }
    let limit = max(1, maximumLength)
    guard oneLine.count > limit else { return oneLine }
    return String(oneLine.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }
}
