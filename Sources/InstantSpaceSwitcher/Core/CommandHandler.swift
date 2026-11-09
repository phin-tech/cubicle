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
    case "snap": return snap(request)
    case "windows":
      guard AXIsProcessTrusted() else {
        return CubicleResponse(ok: false, message: "Accessibility is not granted to Cubicle.")
      }
      return CubicleResponse(ok: true, windows: WindowSnapper.listWindows())
    case "gap": return gap(request.argument)
    default:
      return CubicleResponse(ok: false, message: "Unknown command '\(request.command)'.")
    }
  }

  private static func list(_ request: CubicleRequest) -> CubicleResponse {
    SpaceCatalog.shared.refresh()

    var cursorDisplayID: String?
    if request.here == true {
      guard let spaces = SpaceCatalog.shared.spacesUnderCursor() else {
        return CubicleResponse(ok: false, message: "Could not read the display under the cursor.")
      }
      cursorDisplayID = spaces.display.identifier
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

  /// Moves the focused window to a Space on its display (by name or number). By default it holds the title bar
  /// while the system switches Spaces, so you go along with it; the flags pick another route.
  private static func send(_ query: String, reply: @escaping (CubicleResponse) -> Void) {
    var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var route = WindowSender.Route.drag
    var stay = false
    while let flag = trimmed.split(separator: " ", maxSplits: 1).first, flag.hasPrefix("--") {
      switch flag {
      case "--via-virtual": route = .viaVirtual
      case "--via-display": route = .viaDisplay
      case "--quick-drag": route = .quickDrag
      case "--stay": stay = true
      default: return reply(CubicleResponse(ok: false, message: "Unknown send option: \(flag)"))
      }
      trimmed = String(trimmed.dropFirst(flag.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if stay && route != .viaVirtual && route != .viaDisplay {
      return reply(CubicleResponse(ok: false, message: "--stay currently requires --via-virtual or --via-display."))
    }
    guard !trimmed.isEmpty else { return reply(CubicleResponse(ok: false, message: "Usage: cubicle send <name|number>")) }
    guard AXIsProcessTrusted() else {
      return reply(CubicleResponse(ok: false, message: "Accessibility is not granted to Cubicle."))
    }
    guard let window = WindowMover.focusedWindow() else {
      return reply(CubicleResponse(ok: false, message: "Could not find the focused window."))
    }
    guard let spaces = WindowSender.spaces(for: window) else {
      return reply(CubicleResponse(ok: false, message: "Could not read the Spaces on the window's display."))
    }
    let cells = SpaceGridWindow.cells(for: spaces)

    let target: Int
    if let number = Int(trimmed) {
      guard (1...cells.count).contains(number) else {
        return reply(CubicleResponse(ok: false, message: "There is no Space \(number); this display has \(cells.count)."))
      }
      target = number - 1
    } else {
      let hits = SpaceGridLayout.matches(in: cells, query: trimmed)
      guard let best = SpaceGridLayout.bestMatch(in: cells, query: trimmed, among: hits) else {
        return reply(CubicleResponse(ok: false, message: "No Space matches '\(trimmed)'."))
      }
      target = best
    }
    WindowSender.send(window, toIndex: target, route: route, stay: stay) { outcome in
      reply(CubicleResponse(ok: outcome.ok, message: outcome.details))
    }
  }

  /// Which window a window command acts on: `--window`, then `--app`, then `--previous`, else the focused one.
  static func selector(for request: CubicleRequest) -> WindowSnapper.Selector {
    if let id = request.window { return .window(id) }
    if let app = request.app, !app.isEmpty { return .app(app) }
    if request.previous == true { return .previous }
    return .focused
  }

  private static func snap(_ request: CubicleRequest) -> CubicleResponse {
    let name = request.argument ?? ""
    guard let action = SnapAction(name: name) else {
      let names = SnapAction.allCases.map(\.rawValue).joined(separator: ", ")
      return CubicleResponse(ok: false, message: "Unknown snap '\(name)'. Use one of: \(names).")
    }
    let outcome = WindowSnapper.snap(action, selector(for: request))
    return CubicleResponse(ok: outcome.ok, message: outcome.message)
  }

  private static func gap(_ argument: String?) -> CubicleResponse {
    guard let argument, !argument.isEmpty else {
      return CubicleResponse(ok: true, message: "\(WindowSnapper.gap)")
    }
    guard let value = Int(argument), (0...WindowSnapper.maximumGap).contains(value) else {
      return CubicleResponse(ok: false, message: "The gap is a whole number of points from 0 to \(WindowSnapper.maximumGap).")
    }
    WindowSnapper.gap = value
    return CubicleResponse(ok: true, message: "Gap set to \(value) pt.")
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
    guard let spaces = SpaceCatalog.shared.spacesUnderCursor() else {
      return CubicleResponse(ok: false, message: "Could not read the Spaces on the current display.")
    }

    let cells = SpaceGridWindow.cells(for: spaces)
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
    if target == spaces.currentIndex {
      return CubicleResponse(ok: true, message: "Already on \(title).")
    }
    guard iss_switch_to_index(UInt32(target)) else {
      return CubicleResponse(ok: false, message: "Switch failed. Is Accessibility granted to Cubicle?")
    }
    let also = alternatives.isEmpty ? "" : " (also matches: \(alternatives.joined(separator: ", ")))"
    return CubicleResponse(ok: true, message: "Switched to \(title).\(also)")
  }
}
