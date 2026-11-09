import AppKit
import ApplicationServices
import CubicleIPC
import ISS

/// Runs commands that arrive from the `cubicle` CLI. These execute inside the app, so they use the app's
/// Accessibility permission rather than the terminal's.
@MainActor
enum CommandHandler {
  static func handle(_ request: CubicleRequest, reply: @escaping (CubicleResponse) -> Void) {
    if request.command == "mc-dump" {
      MissionControlProbe.dump(to: request.argument ?? NSTemporaryDirectory() + "cubicle-mc.txt") { message in
        DispatchQueue.main.async { reply(CubicleResponse(ok: true, message: message)) }
      }
    } else if request.command == "send" {
      send(request.argument ?? "", reply: reply)
    } else {
      reply(handle(request))
    }
  }

  static func handle(_ request: CubicleRequest) -> CubicleResponse {
    switch request.command {
    case "list": return list(request)
    case "go": return go(request.argument ?? "")
    case "left": return step(ISSDirectionLeft)
    case "right": return step(ISSDirectionRight)
    case "new-space":
      guard AXIsProcessTrusted() else {
        return CubicleResponse(ok: false, message: SpaceCreator.Failure.notTrusted.message)
      }
      // Mission Control takes a second or two to open and close, so this does not wait for it.
      SpaceCreator.addSpace { _ in }
      return CubicleResponse(ok: true, message: "Adding a Space (Mission Control opens briefly).")
    case "grid":
      SpaceGridWindow.shared.show()
      return CubicleResponse(ok: true)
    default:
      return CubicleResponse(ok: false, message: "Unknown command '\(request.command)'.")
    }
  }

  private static func list(_ request: CubicleRequest) -> CubicleResponse {
    SpaceCatalog.shared.refresh()

    var cursorDisplayID: String?
    if request.here == true {
      var info = ISSSpaceInfo()
      guard iss_get_space_info(&info) else {
        return CubicleResponse(ok: false, message: "Could not read the display under the cursor.")
      }
      cursorDisplayID = stringFromCStringBuffer(info.displayID)
    }

    var entries: [CubicleSpaceEntry] = []
    for display in SpaceCatalog.shared.displays where cursorDisplayID == nil || display.identifier == cursorDisplayID {
      for space in display.spaces {
        let isCurrent = display.currentSpaceID.map { $0 != 0 && $0 == space.spaceID } ?? false
        entries.append(
          CubicleSpaceEntry(
            display: display.name, index: Int(space.index) + 1,
            name: SpaceNameStore.shared.name(for: space.identity.key), isCurrent: isCurrent))
      }
    }

    if let query = request.query {
      let titles = entries.map { $0.name ?? String($0.index) }
      entries = SpaceGridLayout.ranked(titles: titles, query: query).map { entries[$0] }
    }
    return CubicleResponse(ok: true, spaces: entries)
  }

  /// Moves the focused window to a Space on its display (by name or number) by holding its title bar while the
  /// system switches Spaces. You go along with it.
  private static func send(_ query: String, reply: @escaping (CubicleResponse) -> Void) {
    var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var viaVirtual = false
    var viaDisplay = false
    var quickDrag = false
    var stay = false
    while let flag = trimmed.split(separator: " ", maxSplits: 1).first, flag.hasPrefix("--") {
      switch flag {
      case "--via-virtual": viaVirtual = true
      case "--via-display": viaDisplay = true
      case "--quick-drag": quickDrag = true
      case "--stay": stay = true
      default: return reply(CubicleResponse(ok: false, message: "Unknown send option: \(flag)"))
      }
      trimmed = String(trimmed.dropFirst(flag.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if stay && !viaVirtual && !viaDisplay {
      return reply(CubicleResponse(ok: false, message: "--stay currently requires --via-virtual or --via-display."))
    }
    guard !trimmed.isEmpty else { return reply(CubicleResponse(ok: false, message: "Usage: cubicle send <name|number>")) }
    guard AXIsProcessTrusted() else {
      return reply(CubicleResponse(ok: false, message: "Accessibility is not granted to Cubicle."))
    }
    guard let window = WindowMover.focusedWindow() else {
      return reply(CubicleResponse(ok: false, message: "Could not find the focused window."))
    }

    // Resolve Spaces on the window's display: put the cursor there first, since lookups and switches follow it.
    let savedCursor = CGEvent(source: nil)?.location ?? .zero
    CGWarpMouseCursorPosition(CGPoint(x: window.frame.midX, y: window.frame.minY + 8))
    guard let (cells, info) = SpaceGridWindow.currentCells() else {
      CGWarpMouseCursorPosition(savedCursor)
      return reply(CubicleResponse(ok: false, message: "Could not read the Spaces on the window's display."))
    }

    let target: Int
    if let number = Int(trimmed) {
      guard (1...cells.count).contains(number) else {
        CGWarpMouseCursorPosition(savedCursor)
        return reply(CubicleResponse(ok: false, message: "There is no Space \(number); this display has \(cells.count)."))
      }
      target = number - 1
    } else {
      let hits = SpaceGridLayout.matches(in: cells, query: trimmed)
      guard let best = SpaceGridLayout.bestMatch(in: cells, query: trimmed, among: hits) else {
        CGWarpMouseCursorPosition(savedCursor)
        return reply(CubicleResponse(ok: false, message: "No Space matches '\(trimmed)'."))
      }
      target = best
    }
    let title = cells[target].title
    let displayID = stringFromCStringBuffer(info.displayID)
    guard let spaceID = SpaceCatalog.shared.displays.first(where: { $0.identifier == displayID })?
      .spaces.first(where: { $0.index == UInt32(target) })?.spaceID, spaceID != 0
    else {
      CGWarpMouseCursorPosition(savedCursor)
      return reply(CubicleResponse(ok: false, message: "Could not resolve \(title)'s Space ID."))
    }
    if iss_space_for_window(window.windowID) == spaceID {
      CGWarpMouseCursorPosition(savedCursor)
      return reply(CubicleResponse(ok: true, message: "The window is already on \(title)."))
    }

    CGWarpMouseCursorPosition(savedCursor)
    let before = iss_space_for_window(window.windowID)
    let report = "window \(window.windowID); target \(title) = Space \(spaceID); window on \(before)"
    if viaVirtual {
      guard NSScreen.screensHaveSeparateSpaces else {
        return reply(CubicleResponse(ok: false, message: "Requires Displays have separate Spaces."))
      }
      guard VirtualDisplaySession.begin() else {
        return reply(CubicleResponse(ok: false, message: "A virtual-display move is already running."))
      }
      let setupStarted = ProcessInfo.processInfo.systemUptime
      let display = iss_ensure_virtual_display()
      guard display != 0 else {
        VirtualDisplaySession.end(window: window, display: display)
        return reply(CubicleResponse(ok: false, message: "Could not create the experimental virtual display."))
      }
      // Display registration and its initial Space arrive asynchronously.
      WindowMover.waitUntil({
        NSScreen.screens.contains {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
      }, timeout: 3) { ready in
        guard ready else {
          VirtualDisplaySession.end(window: window, display: display)
          return reply(CubicleResponse(ok: false, message: "Virtual display did not become ready. Check the menu toggle."))
        }
        let setupMS = Int((ProcessInfo.processInfo.systemUptime - setupStarted) * 1000)
        WindowMover.moveViaDisplay(window, toIndex: target, spaceID: spaceID, stagingDisplayID: display, returnToIndex: stay ? Int(info.currentIndex) : nil) { moved, details in
          VirtualDisplaySession.end(window: window, display: display)
          let lifecycle = VirtualDisplaySession.automaticShutdown
            ? "auto-off after \(VirtualDisplaySession.idleSeconds)s idle if the window is clear of staging."
            : "automatic shutdown off; display kept alive."
          let details = details + "\nDisplay ready=\(setupMS)ms; " + lifecycle
          reply(CubicleResponse(ok: moved, message: "\(moved ? "Moved" : "Could not move") to \(title).\n\(report)\nvirtual display \(display): \(details)"))
        }
      }
      return
    }
    if viaDisplay {
      WindowMover.moveViaDisplay(window, toIndex: target, spaceID: spaceID, returnToIndex: stay ? Int(info.currentIndex) : nil) { moved, details in
        reply(CubicleResponse(ok: moved, message: "\(moved ? "Moved" : "Could not move") to \(title).\n\(report)\nvia display: \(details)"))
      }
      return
    }
    // The private move calls and minimize/restore don't work on macOS 27; see docs/moving-windows-between-spaces.md.
    WindowMover.moveByDragging(window, from: Int(info.currentIndex), toIndex: target, spaceID: spaceID, quickSwitch: quickDrag) { moved in
      let full = report + "\ndrag: " + WindowMover.lastDragReport
      reply(
        moved
          ? CubicleResponse(ok: true, message: "Moved to \(title).\n\(full)")
          : CubicleResponse(ok: false, message: "Could not move the window to \(title).\n\(full)"))
    }
  }

  private static func step(_ direction: ISSDirection) -> CubicleResponse {
    iss_switch(direction)
      ? CubicleResponse(ok: true)
      : CubicleResponse(ok: false, message: "No Space in that direction (or Accessibility is not granted to Cubicle).")
  }

  /// Switches on the display under the cursor, the same display the grid and hotkeys act on.
  private static func go(_ query: String) -> CubicleResponse {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return CubicleResponse(ok: false, message: "Usage: cubicle go <name|number>") }
    guard let (cells, info) = SpaceGridWindow.currentCells() else {
      return CubicleResponse(ok: false, message: "Could not read the Spaces on the current display.")
    }

    let target: Int
    var alternatives: [String] = []
    if let number = Int(trimmed) {
      guard (1...cells.count).contains(number) else {
        return CubicleResponse(ok: false, message: "There is no Space \(number); this display has \(cells.count).")
      }
      target = number - 1
    } else {
      let hits = SpaceGridLayout.matches(in: cells, query: trimmed)
      guard let best = SpaceGridLayout.bestMatch(in: cells, query: trimmed, among: hits) else {
        return CubicleResponse(ok: false, message: "No Space matches '\(trimmed)'.")
      }
      target = best
      alternatives = hits.filter { $0 != best }.map { cells[$0].title }
    }

    let title = cells[target].title
    if target == Int(info.currentIndex) {
      return CubicleResponse(ok: true, message: "Already on \(title).")
    }
    guard iss_switch_to_index(UInt32(target)) else {
      return CubicleResponse(ok: false, message: "Switch failed. Is Accessibility granted to Cubicle?")
    }
    let also = alternatives.isEmpty ? "" : " (also matches: \(alternatives.joined(separator: ", ")))"
    return CubicleResponse(ok: true, message: "Switched to \(title).\(also)")
  }
}
