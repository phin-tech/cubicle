import Foundation

struct SpaceIdentity: Equatable {
  let key: String?

  /// A workspace's identity (see `VirtualWorkspaces.key`).
  init(key: String) {
    self.key = key
  }
}

extension Notification.Name {
  static let spaceNamesDidChange = Notification.Name("SpaceNamesDidChange")
}

final class SpaceNameStore {
  static let shared = SpaceNameStore()
  static let maximumNameLength = 512
  private let defaults: UserDefaults
  private var names: [String: String]
  private static let defaultsKey = "customSpaceNames"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    names = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
  }

  func name(for key: String?) -> String? {
    guard let key else { return nil }
    return names[key]
  }

  @discardableResult
  func setName(_ name: String, for key: String) -> Bool {
    guard name.count <= Self.maximumNameLength else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed.isEmpty ? nil : trimmed
    guard names[key] != value else { return true }
    names[key] = value
    defaults.set(names, forKey: Self.defaultsKey)
    NotificationCenter.default.post(name: .spaceNamesDidChange, object: self)
    return true
  }

  /// What the switch OSD says for a Space: its name, or its one-based number.
  func message(forTargetIndex index: Int, identity: SpaceIdentity?) -> String {
    name(for: identity?.key) ?? String(index + 1)
  }
}
