import AppKit
import CubicleIPC
import ISS

/// Runs commands that arrive from the `cubicle` CLI. These execute inside the app, so they use the app's
/// Accessibility permission rather than the terminal's.
@MainActor
enum CommandHandler {
  static func handle(_ request: CubicleRequest) -> CubicleResponse {
    switch request.command {
    case "list": return list()
    case "go": return go(request.argument ?? "")
    case "left": return step(ISSDirectionLeft)
    case "right": return step(ISSDirectionRight)
    case "grid":
      SpaceGridWindow.shared.show()
      return CubicleResponse(ok: true)
    default:
      return CubicleResponse(ok: false, message: "Unknown command '\(request.command)'.")
    }
  }

  private static func list() -> CubicleResponse {
    SpaceCatalog.shared.refresh()
    var entries: [CubicleSpaceEntry] = []
    for display in SpaceCatalog.shared.displays {
      for space in display.spaces {
        let isCurrent = display.currentSpaceID.map { $0 != 0 && $0 == space.spaceID } ?? false
        entries.append(
          CubicleSpaceEntry(
            display: display.name, index: Int(space.index) + 1,
            name: SpaceNameStore.shared.name(for: space.identity.key), isCurrent: isCurrent))
      }
    }
    return CubicleResponse(ok: true, spaces: entries)
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
