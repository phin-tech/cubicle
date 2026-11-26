import AppKit
import CubicleIPC

/// Dragging a window by its title bar and pushing the mouse against the left, right or top edge of a display stashes
/// it there, on by default (Settings → Stash). Holding it at the edge for a moment shows the Tab it would get; let go
/// then and it's stashed, with its Tab where the mouse is. Pull away first and nothing happens. Edges another display
/// carries on from don't count.
///
/// Only the mouse is watched: a click near the top of a window is remembered, and the window is asked where it is
/// until it either moves with the mouse (a window drag) or doesn't (anything else).
@MainActor
final class StashDragCatcher {
  static let shared = StashDragCatcher()

  static let defaultsKey = "stashByDragging"

  static var isOn: Bool {
    get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
    set {
      UserDefaults.standard.set(newValue, forKey: defaultsKey)
      shared.update()
    }
  }

  /// How long the mouse stays at the edge before letting go stashes.
  private static let dwell: TimeInterval = 0.35

  private struct Drag {
    let window: AXUIElement
    /// Where the window was when the drag began: unstashing puts it back there.
    let start: CGRect
    let mouseStart: CGPoint
    var moving = false
    /// The edge the mouse is against and since when; once it has been there for `dwell`, its place along the edge.
    var edge: (display: String, edge: StashEdge)?
    var position: CGFloat?
  }

  private var drag: Drag?
  private var monitor: Any?
  private var pendingArm: DispatchWorkItem?

  func update() {
    if Self.isOn {
      guard monitor == nil else { return }
      monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
        let type = event.type
        MainActor.assumeIsolated { StashDragCatcher.shared.handle(type) }
      }
    } else if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
      reset()
    }
  }

  private func handle(_ type: NSEvent.EventType) {
    let mouse = Stash.mouse()
    switch type {
    case .leftMouseDown:
      reset()
      guard Self.isNearTitleBar(mouse), let window = Self.window(at: mouse),
        let frame = WindowMover.frame(of: window)
      else { return }
      drag = Drag(window: window, start: frame, mouseStart: mouse)
    case .leftMouseDragged:
      guard var drag else { return }
      if !drag.moving {
        guard let now = WindowMover.frame(of: drag.window) else { return reset() }
        if now.size == drag.start.size && hypot(now.minX - drag.start.minX, now.minY - drag.start.minY) > 3 {
          // Stashed windows have their own drags.
          guard let target = WindowMover.target(for: drag.window), !Stash.shared.contains(target.windowID) else {
            return reset()
          }
          drag.moving = true
        } else if hypot(mouse.x - drag.mouseStart.x, mouse.y - drag.mouseStart.y) > 30 || now.size != drag.start.size {
          // The mouse went on without the window: selecting text, resizing, anything but a window drag.
          return reset()
        } else {
          self.drag = drag
          return
        }
      }
      self.drag = drag
      follow(mouse)
    case .leftMouseUp:
      defer { reset() }
      guard let drag, drag.moving, let (display, edge) = drag.edge, let position = drag.position,
        let target = WindowMover.target(for: drag.window)
      else { return }
      // After whatever the system does with a window let go at an edge (tiling it), so the stash has the last word.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        let outcome = Stash.shared.stash(
          target, to: edge, position: position, display: display, home: drag.start)
        if !outcome.ok { NSSound.beep() }
      }
    default:
      break
    }
  }

  /// Notices the mouse reaching an edge or leaving it, and shows the Tab once it has stayed.
  private func follow(_ mouse: CGPoint) {
    guard var drag else { return }
    let screens = VirtualWorkspaces.screens()
    let pushed = screens.first(where: { $0.bounds.insetBy(dx: -1, dy: -1).contains(mouse) }).flatMap { screen in
      StashLayout.pushedEdge(mouse, on: screen.bounds, among: screens.filter { $0.uuid != screen.uuid }.map(\.bounds))
        .map { (display: screen.uuid, edge: $0) }
    }
    if pushed?.display != drag.edge?.display || pushed?.edge != drag.edge?.edge {
      pendingArm?.cancel()
      pendingArm = nil
      drag.edge = pushed
      drag.position = nil
      Stash.shared.hideDragHint()
      self.drag = drag
      guard pushed != nil else { return }
      let work = DispatchWorkItem {
        MainActor.assumeIsolated {
          let catcher = StashDragCatcher.shared
          catcher.pendingArm = nil
          catcher.showHint(at: Stash.mouse())
        }
      }
      pendingArm = work
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: work)
      return
    }
    self.drag = drag
    if drag.position != nil { showHint(at: mouse) }
  }

  private func showHint(at mouse: CGPoint) {
    guard let drag, let (display, edge) = drag.edge, let target = WindowMover.target(for: drag.window) else { return }
    self.drag?.position = Stash.shared.showDragHint(for: target, display: display, edge: edge, at: mouse)
  }

  private func reset() {
    pendingArm?.cancel()
    pendingArm = nil
    if drag?.position != nil { Stash.shared.hideDragHint() }
    drag = nil
  }

  /// The window whose part is at `point`.
  private static func window(at point: CGPoint) -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, 0.15)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success, let hit else {
      return nil
    }
    var role: CFTypeRef?
    if AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role) == .success,
      role as? String == kAXWindowRole as String
    {
      return hit
    }
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(hit, kAXWindowAttribute as CFString, &window) == .success,
      let window, CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }
    return (window as! AXUIElement)
  }

  /// Whether `point` is near the top of the frontmost ordinary window under it, where its title bar (or a toolbar
  /// that drags it) is. Every click comes here, so this asks no app anything.
  private static func isNearTitleBar(_ point: CGPoint) -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    for info in windows where info[kCGWindowLayer as String] as? Int == 0 {
      guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
        .flatMap({ CGRect(dictionaryRepresentation: $0) }), bounds.contains(point)
      else { continue }
      return point.y - bounds.minY < 60
    }
    return false
  }
}
