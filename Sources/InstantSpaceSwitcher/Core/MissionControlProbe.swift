import AppKit
import ApplicationServices
import ISS

/// Spike: opens Mission Control and writes the Dock's accessibility tree (role, identifier, title, description,
/// frame, actions) to a file, to see whether window thumbnails and desktop thumbnails can be located.
enum MissionControlProbe {
  static func dump(to path: String, completion: @escaping @Sendable (String) -> Void) {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
      return completion("Dock not found")
    }
    let pid = dock.processIdentifier
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    DispatchQueue.global(qos: .userInitiated).async {
      var lines: [String] = []
      // Wait for Mission Control's group to fill in, then a moment more for the thumbnails to settle.
      for attempt in 0..<30 {
        Thread.sleep(forTimeInterval: 0.2)
        lines = []
        walk(AXUIElementCreateApplication(pid), depth: 0, lines: &lines, budget: 3000)
        if let mc = lines.firstIndex(where: { $0.contains("id=mc ") }), mc + 1 < lines.count {
          Thread.sleep(forTimeInterval: 0.6)
          lines = ["(populated after \(attempt + 1) polls)"]
          walk(AXUIElementCreateApplication(pid), depth: 0, lines: &lines, budget: 3000)
          break
        }
      }
      // Extra diagnostics: every attribute on the Mission Control group, and whether Dock overlay windows are up.
      if let mc = findMC(AXUIElementCreateApplication(pid)) {
        var names: CFArray?
        AXUIElementCopyAttributeNames(mc, &names)
        for name in (names as? [String]) ?? [] {
          var value: CFTypeRef?
          let err = AXUIElementCopyAttributeValue(mc, name as CFString, &value)
          let text = value.map { String(describing: $0).prefix(160) } ?? "nil"
          lines.append("mc.\(name) [\(err.rawValue)] = \(text)")
        }
      }
      let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
      let dockLayers = windows.filter { ($0[kCGWindowOwnerName as String] as? String) == "Dock" }
        .compactMap { $0[kCGWindowLayer as String] as? Int }
      lines.append("Dock on-screen window layers: \(dockLayers.sorted())")
      lines.append("iss_is_mission_control_active: \(iss_is_mission_control_active())")
      for keyDown in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: keyDown)?.post(tap: .cghidEventTap)
      }
      try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
      completion("Wrote \(lines.count) elements to \(path)")
    }
  }

  private static func walk(_ element: AXUIElement, depth: Int, lines: inout [String], budget: Int) {
    guard lines.count < budget, depth < 14 else { return }
    var parts = [String(repeating: "  ", count: depth) + (string(element, kAXRoleAttribute) ?? "?")]
    if let v = string(element, kAXSubroleAttribute) { parts.append("sub=\(v)") }
    if let v = string(element, kAXIdentifierAttribute) { parts.append("id=\(v)") }
    if let v = string(element, kAXTitleAttribute), !v.isEmpty { parts.append("title=\"\(v)\"") }
    if let v = string(element, kAXDescriptionAttribute), !v.isEmpty { parts.append("desc=\"\(v)\"") }
    if let frame = frame(element) { parts.append("frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))") }
    var actions: CFArray?
    if AXUIElementCopyActionNames(element, &actions) == .success, let names = actions as? [String], !names.isEmpty {
      parts.append("actions=\(names.joined(separator: ","))")
    }
    lines.append(parts.joined(separator: " "))
    var children: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
      let array = children as? [AXUIElement]
    {
      for child in array { walk(child, depth: depth + 1, lines: &lines, budget: budget) }
    }
  }

  private static func findMC(_ app: AXUIElement) -> AXUIElement? {
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success,
      let array = children as? [AXUIElement]
    else { return nil }
    return array.first { string($0, kAXIdentifierAttribute) == "mc" }
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  private static func frame(_ element: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success, let p, let s
    else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
  }
}
