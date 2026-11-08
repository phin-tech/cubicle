import AppKit
import ApplicationServices

/// Adds a Space. macOS has no public API for this, so Cubicle does what you would: opens Mission Control and presses
/// its "+" (Add Desktop) button through the Accessibility API, then closes Mission Control again.
/// This needs Accessibility permission, and it depends on how the Dock labels that button, so it can fail on
/// a macOS release that changes it; callers should show `Failure.message` and the manual fallback.
enum SpaceCreator {
  enum Failure: Error, Equatable {
    case notTrusted
    case dockNotFound
    case buttonNotFound

    var message: String {
      switch self {
      case .notTrusted:
        return "Cubicle needs the Accessibility permission to press the + in Mission Control."
      case .dockNotFound:
        return "Could not reach Mission Control."
      case .buttonNotFound:
        return "Could not find the + button. Open Mission Control and click the + at the top right."
      }
    }
  }

  /// Whether an accessibility element looks like Mission Control's Add Desktop button. The identifier is the
  /// reliable signal; the English label is a fallback for builds that do not set one.
  static func isAddDesktopButton(role: String?, identifier: String?, title: String?, description: String?) -> Bool {
    guard role == "AXButton" else { return false }
    if identifier == "mc.spaces.add" { return true }
    let text = [title, description].compactMap { $0?.lowercased() }.joined(separator: " ")
    return text.contains("add desktop") || text.contains("add space") || text.contains("new desktop")
  }

  private static let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

  /// Opens Mission Control, presses +, and closes it. `completion` runs on the main queue.
  static func addSpace(completion: @escaping @Sendable (Result<Void, Failure>) -> Void) {
    guard AXIsProcessTrusted() else {
      completion(.failure(.notTrusted))
      return
    }
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
      completion(.failure(.dockNotFound))
      return
    }
    let dockPID = dock.processIdentifier

    NSWorkspace.shared.open(missionControlURL)
    DispatchQueue.global(qos: .userInitiated).async {
      var button: AXUIElement?
      // Mission Control takes a moment to appear and populate; poll for the button.
      for _ in 0..<25 {
        Thread.sleep(forTimeInterval: 0.2)
        button = findAddButton(in: AXUIElementCreateApplication(dockPID))
        if button != nil { break }
      }

      var result: Result<Void, Failure> = .failure(.buttonNotFound)
      if let button, AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
        result = .success(())
        Thread.sleep(forTimeInterval: 0.8)  // let the new Space appear before leaving Mission Control
      }
      pressEscape()
      DispatchQueue.main.async { completion(result) }
    }
  }

  // MARK: - Accessibility tree search

  /// Breadth-first search with a node budget, so an unexpected tree cannot make this run away.
  private static func findAddButton(in root: AXUIElement, budget: Int = 4000) -> AXUIElement? {
    var queue = [root]
    var visited = 0
    while !queue.isEmpty, visited < budget {
      let element = queue.removeFirst()
      visited += 1
      if isAddDesktopButton(
        role: string(element, kAXRoleAttribute), identifier: string(element, kAXIdentifierAttribute),
        title: string(element, kAXTitleAttribute), description: string(element, kAXDescriptionAttribute))
      {
        return element
      }
      var children: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
        let array = children as? [AXUIElement]
      {
        queue.append(contentsOf: array)
      }
    }
    return nil
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  private static func pressEscape() {
    for keyDown in [true, false] {
      CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: keyDown)?.post(tap: .cghidEventTap)
    }
  }
}
