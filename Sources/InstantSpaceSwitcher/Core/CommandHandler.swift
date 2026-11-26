import AppKit
import ApplicationServices
import CubicleIPC

/// Runs commands that arrive from the `cubicle` CLI. These execute inside the app, so they use the app's
/// Accessibility permission rather than the terminal's.
@MainActor
enum CommandHandler {
  static func handle(_ request: CubicleRequest, reply: @escaping (CubicleResponse) -> Void) {
    reply(handle(request))
  }

  static func handle(_ request: CubicleRequest) -> CubicleResponse {
    switch request.command {
    case "list": return list(request)
    case "go": return go(request.argument ?? "")
    case "send": return send(request.argument ?? "", selector(for: request))
    case "focus": return focus(selector(for: request))
    case "new-workspace": return newWorkspace(named: request.argument ?? "", selector(for: request))
    case "left": return step(.left)
    case "right": return step(.right)
    case "move-workspace":
      let outcome = VirtualWorkspaces.shared.moveWorkspaceUnderCursorToNextDisplay()
      return CubicleResponse(ok: outcome.ok, message: outcome.message)
    case "pick-workspace":
      WindowPicker.shared.start()
      return CubicleResponse(ok: true, message: "Click windows, then press Return to name the new workspace.")
    case "new-space":
      let workspaces = VirtualWorkspaces.shared
      guard let screen = workspaces.displayUnderCursor() else {
        return CubicleResponse(ok: false, message: "Could not read the display under the cursor.")
      }
      return CubicleResponse(ok: true, message: "\(screen.name) now has \(workspaces.addWorkspace(on: screen.uuid)) workspaces.")
    case "remove-space": return removeSpace(request.argument ?? "")
    case "rename": return rename(request.argument ?? "", number: request.query)
    case "grid":
      SpaceGridWindow.shared.show()
      return CubicleResponse(ok: true)
    case "snap": return snap(request)
    case "stash":
      let name = request.argument ?? ""
      guard let edge = StashEdge(name: name) else {
        return CubicleResponse(ok: false, message: "Unknown edge '\(name)'. Use left, right or top.")
      }
      var slot: StashSlot?
      if let position = request.query, !position.isEmpty {
        guard let named = StashSlot(name: position) else {
          return CubicleResponse(ok: false, message: "Unknown position '\(position)'. Use top, middle or bottom.")
        }
        slot = named
      }
      let outcome = Stash.shared.stash(edge, slot: slot, selector(for: request))
      return CubicleResponse(ok: outcome.ok, message: outcome.message)
    case "unstash":
      if request.all == true {
        let count = Stash.shared.list().count
        Stash.shared.unstashAll()
        return CubicleResponse(ok: true, message: count == 0 ? "No windows are stashed." : "Unstashed \(count).")
      }
      let outcome = Stash.shared.unstash(selector(for: request))
      return CubicleResponse(ok: outcome.ok, message: outcome.message)
    case "stashed":
      let entries = Stash.shared.entriesForCLI()
      let lines = entries.map {
        "\($0.edge.padding(toLength: 6, withPad: " ", startingAt: 0)) \($0.id)  \($0.name ?? $0.title)\($0.isOut ? "  (out)" : "")"
      }
      return CubicleResponse(
        ok: true, message: lines.isEmpty ? "No windows are stashed." : lines.joined(separator: "\n"), stashed: entries)
    case "open-stashed":
      let outcome = request.argument == "next" ? Stash.shared.showNext() : Stash.shared.open(selector(for: request))
      return CubicleResponse(ok: outcome.ok, message: outcome.message)
    case "rename-tab":
      let outcome = Stash.shared.rename(selector(for: request), to: request.argument)
      return CubicleResponse(ok: outcome.ok, message: outcome.message)
    case "windows":
      guard AXIsProcessTrusted() else {
        return CubicleResponse(ok: false, message: "Accessibility is not granted to Cubicle.")
      }
      return CubicleResponse(ok: true, windows: WindowSnapper.listWindows())
    case "gap": return gap(request.argument)
    case "switch-style":
      guard let name = request.argument, !name.isEmpty else {
        return CubicleResponse(ok: true, message: SwitchStyle.current.rawValue)
      }
      guard let style = SwitchStyle(rawValue: name) else {
        let names = SwitchStyle.allCases.map(\.rawValue).joined(separator: ", ")
        return CubicleResponse(ok: false, message: "Unknown style '\(name)'. Use one of: \(names).")
      }
      SwitchStyle.current = style
      return CubicleResponse(ok: true, message: "Workspace switches now use \(style.rawValue).")
    case "bind", "bind-window": return bind(request)
    case "unbind", "unbind-window":
      return reply(StackManager.shared.unbind(window: request.command == "unbind-window", selector(for: request)))
    case "cycle":
      switch request.argument ?? "next" {
      case "next": return reply(StackManager.shared.cycle(forward: true, selector(for: request)))
      case "prev", "previous": return reply(StackManager.shared.cycle(forward: false, selector(for: request)))
      default: return CubicleResponse(ok: false, message: "Usage: cubicle cycle [next|prev]")
      }
    case "swap": return swap(request)
    case "pause", "resume":
      return reply(StackManager.shared.setPaused(request.command == "pause", everywhere: request.all == true))
    case "ignore", "unignore":
      return reply(StackManager.shared.setIgnored(request.command == "ignore", selector(for: request)))
    case "layout": return CubicleResponse(ok: true, message: StackManager.shared.describeLayout(all: request.all == true))
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

  /// Moves the focused window to a workspace on its display (by name or number). It's instant.
  /// Shows a window's workspace and focuses it.
  private static func focus(_ selector: WindowSnapper.Selector) -> CubicleResponse {
    guard AXIsProcessTrusted() else {
      return CubicleResponse(ok: false, message: "Accessibility is not granted to Cubicle.")
    }
    switch WindowSnapper.resolve(selector) {
    case .failure(let failure): return CubicleResponse(ok: false, message: failure.message)
    case .success(let window):
      let outcome = VirtualWorkspaces.shared.reveal(window)
      return CubicleResponse(ok: outcome.ok, message: outcome.message)
    }
  }

  /// Puts a window on a workspace of its own, named `name` (numbered if empty), and shows it.
  private static func newWorkspace(named name: String, _ selector: WindowSnapper.Selector) -> CubicleResponse {
    guard AXIsProcessTrusted() else {
      return CubicleResponse(ok: false, message: "Accessibility is not granted to Cubicle.")
    }
    switch WindowSnapper.resolve(selector) {
    case .failure(let failure): return CubicleResponse(ok: false, message: failure.message)
    case .success(let window):
      let outcome = VirtualWorkspaces.shared.newWorkspace(
        with: [window], named: name.trimmingCharacters(in: .whitespacesAndNewlines))
      return CubicleResponse(ok: outcome.ok, message: outcome.message)
    }
  }

  private static func send(_ query: String, _ selector: WindowSnapper.Selector) -> CubicleResponse {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return CubicleResponse(ok: false, message: "Usage: cubicle send <name|number>") }
    guard AXIsProcessTrusted() else {
      return CubicleResponse(ok: false, message: "Accessibility is not granted to Cubicle.")
    }
    let window: WindowMover.Target
    switch WindowSnapper.resolve(selector) {
    case .failure(let failure): return CubicleResponse(ok: false, message: failure.message)
    case .success(let found): window = found
    }
    guard let spaces = WindowSender.spaces(for: window) else {
      return CubicleResponse(ok: false, message: "Could not read the workspaces on the window's display.")
    }
    let cells = SpaceGridWindow.cells(for: spaces)

    let target: Int
    if let number = Int(trimmed) {
      guard (1...cells.count).contains(number) else {
        return CubicleResponse(ok: false, message: "There is no workspace \(number); this display has \(cells.count).")
      }
      target = number - 1
    } else {
      let hits = SpaceGridLayout.matches(in: cells, query: trimmed)
      guard let best = SpaceGridLayout.bestMatch(in: cells, query: trimmed, among: hits) else {
        return CubicleResponse(ok: false, message: "No workspace matches '\(trimmed)'.")
      }
      target = best
    }
    let outcome = WindowSender.send(window, toIndex: target)
    return CubicleResponse(ok: outcome.ok, message: outcome.message)
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

  private static func reply(_ outcome: StackManager.Outcome) -> CubicleResponse {
    CubicleResponse(ok: outcome.ok, message: outcome.message)
  }

  /// `bind <zone|space>`: a zone name, or "space" to bind to the Space without a zone.
  private static func bind(_ request: CubicleRequest) -> CubicleResponse {
    let name = (request.argument ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    let zone: Zone?
    if name == "space" || name == "workspace" || name == "none" {
      zone = nil
    } else if let named = Zone(name: name) {
      zone = named
    } else {
      let names = Zone.allCases.map(\.rawValue).joined(separator: ", ")
      return CubicleResponse(ok: false, message: "Unknown zone '\(name)'. Use one of: \(names), or workspace.")
    }
    return reply(StackManager.shared.bind(zone, window: request.command == "bind-window", selector(for: request)))
  }

  /// `swap <left|right|up|down|zone>`.
  private static func swap(_ request: CubicleRequest) -> CubicleResponse {
    let name = (request.argument ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    let target: StackManager.SwapTarget
    if let direction = Zone.Direction(rawValue: name) {
      target = .direction(direction)
    } else if let zone = Zone(name: name) {
      target = .zone(zone)
    } else {
      return CubicleResponse(ok: false, message: "Usage: cubicle swap <left|right|up|down|zone>")
    }
    return reply(StackManager.shared.swap(target, selector(for: request)))
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

  private static func step(_ direction: SwitchDirection) -> CubicleResponse {
    VirtualWorkspaces.shared.stepUnderCursor(direction)
      ? CubicleResponse(ok: true)
      : CubicleResponse(ok: false, message: "No workspace in that direction (or Accessibility is not granted to Cubicle).")
  }

  /// Switches on the display under the cursor, the same display the grid and hotkeys act on.
  /// Names a workspace on the display under the cursor: the one numbered, else the one showing.
  private static func rename(_ name: String, number: String?) -> CubicleResponse {
    guard let spaces = SpaceCatalog.shared.spacesUnderCursor() else {
      return CubicleResponse(ok: false, message: "Could not read the workspaces on the current display.")
    }
    var index = spaces.currentIndex
    if let number {
      guard let value = Int(number), spaces.display.spaces.indices.contains(value - 1) else {
        return CubicleResponse(ok: false, message: "There is no workspace \(number).")
      }
      index = value - 1
    }
    guard let key = spaces.display.spaces[index].identity.key, SpaceNameStore.shared.setName(name, for: key) else {
      return CubicleResponse(ok: false, message: "That name is too long.")
    }
    let named = SpaceNameStore.shared.name(for: key)
    return CubicleResponse(
      ok: true, message: named.map { "Workspace \(index + 1) is now \($0)." } ?? "Workspace \(index + 1) has no name now.")
  }

  /// Removes a workspace on the display under the cursor: the one named or numbered, else the one showing.
  private static func removeSpace(_ query: String) -> CubicleResponse {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let spaces = SpaceCatalog.shared.spacesUnderCursor(),
      let screen = VirtualWorkspaces.shared.displayUnderCursor()
    else { return CubicleResponse(ok: false, message: "Could not read the workspaces on the current display.") }
    let cells = SpaceGridWindow.cells(for: spaces)
    let target: Int
    if trimmed.isEmpty {
      target = spaces.currentIndex
    } else if let number = Int(trimmed) {
      guard (1...cells.count).contains(number) else {
        return CubicleResponse(ok: false, message: "There is no workspace \(number); this display has \(cells.count).")
      }
      target = number - 1
    } else {
      let hits = SpaceGridLayout.matches(in: cells, query: trimmed)
      guard let best = SpaceGridLayout.bestMatch(in: cells, query: trimmed, among: hits) else {
        return CubicleResponse(ok: false, message: "No workspace matches '\(trimmed)'.")
      }
      target = best
    }
    let outcome = VirtualWorkspaces.shared.removeWorkspace(target, on: screen)
    return CubicleResponse(ok: outcome.ok, message: outcome.message)
  }

  private static func go(_ query: String) -> CubicleResponse {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return CubicleResponse(ok: false, message: "Usage: cubicle go <name|number>") }
    guard let spaces = SpaceCatalog.shared.spacesUnderCursor() else {
      return CubicleResponse(ok: false, message: "Could not read the workspaces on the current display.")
    }

    let cells = SpaceGridWindow.cells(for: spaces)
    let target: Int
    var alternatives: [String] = []
    if let number = Int(trimmed) {
      guard (1...cells.count).contains(number) else {
        return CubicleResponse(ok: false, message: "There is no workspace \(number); this display has \(cells.count).")
      }
      target = number - 1
    } else {
      let hits = SpaceGridLayout.matches(in: cells, query: trimmed)
      guard let best = SpaceGridLayout.bestMatch(in: cells, query: trimmed, among: hits) else {
        return CubicleResponse(ok: false, message: "No workspace matches '\(trimmed)'.")
      }
      target = best
      alternatives = hits.filter { $0 != best }.map { cells[$0].title }
    }

    let title = cells[target].title
    if target == spaces.currentIndex {
      return CubicleResponse(ok: true, message: "Already on \(title).")
    }
    guard VirtualWorkspaces.shared.switchUnderCursor(toIndex: target) else {
      return CubicleResponse(ok: false, message: "Switch failed. Is Accessibility granted to Cubicle?")
    }
    let also = alternatives.isEmpty ? "" : " (also matches: \(alternatives.joined(separator: ", ")))"
    return CubicleResponse(ok: true, message: "Switched to \(title).\(also)")
  }
}
