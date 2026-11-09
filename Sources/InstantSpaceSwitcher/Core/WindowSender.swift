import AppKit
import ISS

/// Sends a window to another Space on its display. The CLI (`cubicle send`), the grid's send mode and the
/// right-click menu all go through here.
@MainActor
enum WindowSender {
  enum Route {
    /// Hold the title bar while stepping with Ctrl+arrow; you go with the window.
    case drag
    /// Hold the title bar while Cubicle switches instantly.
    case quickDrag
    /// Park the window on another real display while this one switches.
    case viaDisplay
    /// Park the window on Cubicle's virtual staging display while this one switches.
    case viaVirtual
  }

  struct Outcome {
    let ok: Bool
    /// One line, for the OSD.
    let summary: String
    /// Everything the move reported, for the CLI.
    let details: String
  }

  /// True while a send is running. Sends don't overlap, and switch OSDs stay quiet meanwhile.
  private(set) static var sending = false

  /// How the grid and the right-click menu move windows: through staging, so you stay where you are, when
  /// displays have separate Spaces (staging needs that); otherwise by dragging.
  static var interactiveRoute: (route: Route, stay: Bool) {
    NSScreen.screensHaveSeparateSpaces ? (.viaVirtual, true) : (.drag, false)
  }

  /// The Spaces on the window's display. Space lookups follow the cursor, so it visits the window's title bar
  /// for a moment.
  static func spaces(for window: WindowMover.Target) -> (cells: [SpaceGridCell], info: ISSSpaceInfo)? {
    let savedCursor = CGEvent(source: nil)?.location ?? .zero
    CGWarpMouseCursorPosition(window.anchor)
    defer { CGWarpMouseCursorPosition(savedCursor) }
    return SpaceGridWindow.currentCells()
  }

  /// "Mail", or "Space 2" for a Space without a name.
  static func name(of cell: SpaceGridCell) -> String {
    cell.hasCustomName ? cell.title : "Space \(cell.title)"
  }

  static func send(
    _ window: WindowMover.Target, toIndex target: Int, route: Route, stay: Bool,
    completion: @escaping (Outcome) -> Void
  ) {
    func fail(_ message: String) { completion(Outcome(ok: false, summary: message, details: message)) }

    guard !sending else { return fail("Already moving a window.") }
    guard AXIsProcessTrusted() else { return fail("Accessibility is not granted to Cubicle.") }
    guard let (cells, info) = spaces(for: window) else {
      return fail("Could not read the Spaces on the window's display.")
    }
    guard cells.indices.contains(target) else {
      return fail("There is no Space \(target + 1); this display has \(cells.count).")
    }
    let title = name(of: cells[target])
    let displayID = stringFromCStringBuffer(info.displayID)
    guard let spaceID = SpaceCatalog.shared.displays.first(where: { $0.identifier == displayID })?
      .spaces.first(where: { $0.index == UInt32(target) })?.spaceID, spaceID != 0
    else { return fail("Could not resolve \(title)'s Space ID.") }
    let before = iss_space_for_window(window.windowID)
    if before == spaceID {
      let message = "\(window.appName) is already on \(title)."
      return completion(Outcome(ok: true, summary: message, details: message))
    }

    sending = true
    let report = "window \(window.windowID); target \(title) = Space \(spaceID); window on \(before)"
    func finish(_ moved: Bool, _ details: String) {
      sending = false
      let summary = moved ? "\(window.appName) → \(title)" : "Could not move \(window.appName) to \(title)."
      completion(Outcome(ok: moved, summary: summary, details: "\(summary)\n\(report)\n\(details)"))
    }
    func abort(_ message: String) {
      sending = false
      fail(message)
    }

    switch route {
    case .viaVirtual:
      guard NSScreen.screensHaveSeparateSpaces else { return abort("Requires Displays have separate Spaces.") }
      guard VirtualDisplaySession.begin() else { return abort("A virtual-display move is already running.") }
      let setupStarted = ProcessInfo.processInfo.systemUptime
      let display = iss_ensure_virtual_display()
      guard display != 0 else {
        VirtualDisplaySession.end(window: window, display: display)
        return abort("Could not create the experimental virtual display.")
      }
      // Display registration and its initial Space arrive asynchronously.
      WindowMover.waitUntil({
        NSScreen.screens.contains {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
      }, timeout: 3) { ready in
        guard ready else {
          VirtualDisplaySession.end(window: window, display: display)
          return abort("Virtual display did not become ready. Check the menu toggle.")
        }
        let setupMS = Int((ProcessInfo.processInfo.systemUptime - setupStarted) * 1000)
        WindowMover.moveViaDisplay(
          window, toIndex: target, spaceID: spaceID, stagingDisplayID: display,
          returnToIndex: stay ? Int(info.currentIndex) : nil
        ) { moved, details in
          VirtualDisplaySession.end(window: window, display: display)
          let lifecycle = VirtualDisplaySession.automaticShutdown
            ? "auto-off after \(VirtualDisplaySession.idleSeconds)s idle if the window is clear of staging."
            : "automatic shutdown off; display kept alive."
          finish(moved, "virtual display \(display): \(details)\nDisplay ready=\(setupMS)ms; \(lifecycle)")
        }
      }
    case .viaDisplay:
      WindowMover.moveViaDisplay(
        window, toIndex: target, spaceID: spaceID, returnToIndex: stay ? Int(info.currentIndex) : nil
      ) { moved, details in
        finish(moved, "via display: \(details)")
      }
    case .drag, .quickDrag:
      // The private move calls and minimize/restore don't work on macOS 27; see docs/moving-windows-between-spaces.md.
      WindowMover.moveByDragging(
        window, from: Int(info.currentIndex), toIndex: target, spaceID: spaceID, quickSwitch: route == .quickDrag
      ) { moved in
        finish(moved, "drag: " + WindowMover.lastDragReport)
      }
    }
  }

  /// Sends with the interactive route and reports on the OSD: progress if the move takes a moment, then where the
  /// window went or why it didn't.
  static func sendShowingProgress(_ window: WindowMover.Target, toIndex target: Int, screenID: UInt32) {
    let (route, stay) = interactiveRoute
    var finished = false
    // A cold start of the staging display takes most of a second; say something so it doesn't look stuck.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      guard !finished, sending else { return }
      OSDWindow.shared.show(message: "Moving \(window.appName)…", screenID: screenID, force: true, duration: 5)
    }
    send(window, toIndex: target, route: route, stay: stay) { outcome in
      finished = true
      if !outcome.ok { NSSound.beep() }
      OSDWindow.shared.show(
        message: outcome.summary, screenID: screenID, force: true, duration: outcome.ok ? 1.2 : 2.5)
    }
  }
}
