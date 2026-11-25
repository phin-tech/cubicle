import AppKit

/// Sends a window to another workspace on its display. The CLI (`cubicle send`), the grid's send mode and the
/// modifier-click menu all go through here.
@MainActor
enum WindowSender {
  struct Outcome {
    let ok: Bool
    let message: String
  }

  /// The workspaces on the window's display.
  static func spaces(for window: WindowMover.Target) -> DisplaySpaces? {
    SpaceCatalog.shared.spaces(at: window.anchor)
  }

  /// "Mail", or "Workspace 2" for a workspace without a name.
  static func name(of cell: SpaceGridCell) -> String {
    cell.hasCustomName ? cell.title : "Workspace \(cell.title)"
  }

  static func send(_ window: WindowMover.Target, toIndex target: Int) -> Outcome {
    guard AXIsProcessTrusted() else { return Outcome(ok: false, message: "Accessibility is not granted to Cubicle.") }
    let result = VirtualWorkspaces.shared.send(window, toIndex: target)
    return Outcome(ok: result.ok, message: result.message)
  }

  /// Sends and says on the OSD where the window went, or why it didn't.
  static func sendShowingResult(_ window: WindowMover.Target, toIndex target: Int, screenID: UInt32) {
    let outcome = send(window, toIndex: target)
    if !outcome.ok { NSSound.beep() }
    OSDWindow.shared.show(message: outcome.message, screenID: screenID, force: true, duration: outcome.ok ? 1.2 : 2.5)
  }
}
