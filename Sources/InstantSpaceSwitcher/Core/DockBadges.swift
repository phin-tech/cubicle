import AppKit
import ApplicationServices

/// The badges apps show on their Dock icons (an unread count, a dot), read from the Dock through Accessibility, as
/// VoiceOver reads them. An app has to be in the Dock to have one.
@MainActor
enum DockBadges {
  /// Each badged app's badge, keyed by its bundle identifier (or path, for one without).
  static func current() -> [String: String] {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
      return [:]
    }
    let app = AXUIElementCreateApplication(dock.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.2)
    var badges: [String: String] = [:]
    for list in children(of: app) where string(list, kAXRoleAttribute) == kAXListRole as String {
      for item in children(of: list) {
        guard let badge = string(item, "AXStatusLabel"), !badge.isEmpty else { continue }
        var url: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &url) == .success,
          let url = url as? URL
        else { continue }
        badges[key(for: url)] = badge
      }
    }
    return badges
  }

  /// The badge on `app`'s Dock icon, from what `current()` read.
  static func badge(for app: NSRunningApplication?, in badges: [String: String]) -> String? {
    guard let app else { return nil }
    if let id = app.bundleIdentifier, let badge = badges[id] { return badge }
    return app.bundleURL.flatMap { badges[$0.standardizedFileURL.path] }
  }

  /// Bundle identifiers by path, so the Dock's items aren't read from disk every time.
  private static var identifiers: [String: String] = [:]

  /// Safari's Dock item is inside a cryptex, not where the app says it is, so apps are matched by identifier.
  private static func key(for url: URL) -> String {
    let path = url.standardizedFileURL.path
    if let id = identifiers[path] { return id }
    let id = Bundle(url: url)?.bundleIdentifier ?? path
    identifiers[path] = id
    return id
  }

  private static func children(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }
}
