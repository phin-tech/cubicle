import AppKit
import ApplicationServices
import CubicleIPC

/// Stashing (see CONTEXT.md): a window tucked away against the left, right or top edge of its display, with a Tab
/// on that edge on every workspace. Hovering the Tab pops the window out beside it; it tucks back once the mouse
/// leaves the window and the Tabs. Clicking the Tab, or into the window, keeps it out until you click elsewhere.
///
/// A tucked window is parked just off the display's bottom corner, as a window on a hidden workspace is, and it
/// belongs to no workspace while it's stashed. The Tabs follow Slaps' edge Tabs: borderless panels over other
/// windows that never take the keyboard, worked by where the mouse is rather than by hover events.
@MainActor
final class Stash {
  static let shared = Stash()
  /// Posted when a window is stashed, unstashed or moved, or a stashed window closes.
  static let didChange = Notification.Name("CubicleStashDidChange")

  struct Entry: Codable, Equatable {
    let id: UInt32
    let pid: pid_t
    var edge: StashEdge
    /// Where along the edge its Tab sits, as saved before Tabs could go anywhere; `position` has taken over.
    var slot: StashSlot?
    /// Where along the edge its Tab sits: 0 its start, 1 its end. Tabs at exactly the same place line up together.
    var position: CGFloat?
    /// Its place along the edge, from either; the middle if it has neither.
    var along: CGFloat { position ?? slot?.position ?? 0.5 }
    var display: String
    /// Where the window was before it was stashed: unstashing, and quitting Cubicle, put it back there.
    var home: CGRect
    /// Its size when it pops out, kept as you resize it.
    var size: CGSize
  }

  private var entries: [Entry] = []
  /// What a window being dragged would land on if let go now: display, edge and position.
  private var dropTarget: Drop?

  private enum Drop {
    /// Onto an edge, at a place along it.
    case edge(display: String, edge: StashEdge, position: CGFloat)
    /// Away from the edges: the window is unstashed, here.
    case unstash(CGRect)
  }
  private var elements: [UInt32: AXUIElement] = [:]
  /// The window popped out, where it was put, and whether a click is keeping it out.
  private var out: UInt32?
  private var outFrame: CGRect?
  private var pinned = false
  /// The app in front before a window popped out, to go back to when it tucks away.
  private var previousApp: NSRunningApplication?
  /// The app Cubicle brought forward itself, popping one of its windows out, and when: that isn't you switching to it.
  private var raisedByUs: (pid: pid_t, at: Date)?
  private var panels: [String: StashPanel] = [:]
  private var monitors: [Any] = []
  private var observers: [NSObjectProtocol] = []
  private var timer: Timer?
  private var pendingTuck: DispatchWorkItem?
  /// A Tab pressed and not yet let go, and whether it has been dragged far enough to be moving along the edge.
  private var press: (id: UInt32, start: CGPoint)?
  private var dragging: UInt32?
  private let ghost = StashPanel()
  /// Where a window being dragged against an edge would stash: a Tab shown there before you let go.
  private let hint = StashPanel()
  /// The badges on stashed apps' Dock icons, by app (see `DockBadges`).
  private var badges: [String: String] = [:]
  /// How many times each window's Tab has wiggled for news on its app's badge; a new count sets it off again.
  private var wiggles: [UInt32: Int] = [:]
  private var badgesRead = false
  /// The window being previewed beside its Tab, and the last picture of each window (see `StashPeek`).
  private var peeking: UInt32?
  private let peek = StashPeekPanel()
  private var pictures: [UInt32: CGImage] = [:]

  var look: StashTabLook {
    StashTabLook(rawValue: UserDefaults.standard.string(forKey: StashTabLook.defaultsKey) ?? "") ?? .icon
  }

  var openOn: StashOpen {
    StashOpen(rawValue: UserDefaults.standard.string(forKey: StashOpen.defaultsKey) ?? "") ?? .hover
  }

  var hideWhen: StashHide {
    StashHide(rawValue: UserDefaults.standard.string(forKey: StashHide.defaultsKey) ?? "") ?? .mouseOut
  }

  /// Whether the window that's out stays out when the mouse leaves it: clicked to keep it, or hidden only by a click.
  private var keepsOut: Bool { pinned || hideWhen == .clickOut }

  func contains(_ id: UInt32) -> Bool { entries.contains { $0.id == id } }

  // MARK: - Starting and stopping

  /// Takes back the windows stashed when Cubicle last quit, and tucks them away again. Call before the workspaces
  /// start, so they leave these windows alone.
  func start() {
    for entry in State.load() {
      guard case .success(let window) = WindowSnapper.resolve(.window(entry.id)), window.pid == entry.pid else {
        continue
      }
      entries.append(entry)
      elements[entry.id] = window.window
    }
    let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
    if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { _ in
      MainActor.assumeIsolated { Stash.shared.trackMouse() }
    }) { monitors.append(global) }
    if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { event in
      MainActor.assumeIsolated { Stash.shared.trackMouse() }
      return event
    }) { monitors.append(local) }
    if let global = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp], handler: { event in
        let type = event.type
        MainActor.assumeIsolated { Stash.shared.clickedElsewhere(type) }
      })
    { monitors.append(global) }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp], handler: localClick)
    {
      monitors.append(local)
    }
    observers.append(NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { Stash.shared.refresh() } })
    observers.append(NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { Stash.shared.lookMayHaveChanged() } })
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { Stash.shared.prune() } })
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { notification in
      let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
      MainActor.assumeIsolated { Stash.shared.appActivated(pid) }
    })
    for entry in entries { tuck(entry.id, refocus: false) }
    refresh()
  }

  /// Puts every stashed window back where it was before it was stashed, so quitting Cubicle never leaves one off
  /// screen. They're kept, and stashed again at the next launch.
  func stop() {
    for monitor in monitors { NSEvent.removeMonitor(monitor) }
    monitors = []
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    timer?.invalidate()
    timer = nil
    for entry in entries {
      guard let target = target(entry.id) else { continue }
      WindowSnapper.setFrame(Self.onScreen(entry.home), of: target)
    }
    for panel in panels.values { panel.orderOut(nil) }
  }

  // MARK: - Commands

  /// Stashes the window `selector` picks against `edge`. Stashing a window against the edge it's already on
  /// unstashes it; against another edge, moves its Tab there.
  func stash(_ edge: StashEdge, slot: StashSlot? = nil, _ selector: WindowSnapper.Selector = .focused)
    -> WindowSnapper.Outcome
  {
    guard AXIsProcessTrusted() else { return .init(ok: false, message: "Accessibility is not granted to Cubicle.") }
    switch WindowSnapper.resolve(selector) {
    case .failure(let failure): return .init(ok: false, message: failure.message)
    case .success(let window): return stash(window, to: edge, slot: slot)
    }
  }

  /// Stashes a window against `edge`, its Tab in `slot` (the middle unless you say) or at `position`. Dragged there,
  /// `display` is the one it was dragged to and `home` where it was before the drag.
  func stash(
    _ window: WindowMover.Target, to edge: StashEdge, slot: StashSlot? = nil, position: CGFloat? = nil,
    display: String? = nil, home: CGRect? = nil
  ) -> WindowSnapper.Outcome {
    let position = position ?? slot?.position
    let id = window.windowID
    let name = window.displayName
    if let index = entries.firstIndex(where: { $0.id == id }) {
      let current = entries[index].along
      if entries[index].edge == edge && (position == nil || position! == current) { return unstash(id) }
      if out == id { tuck(id, refocus: false) }
      entries[index].edge = edge
      entries[index].position = position ?? current
      entries[index].slot = nil
      save()
      refresh()
      return .init(ok: true, message: "\(edge.displayName): \(name).")
    }
    if Self.bool(window.window, kAXMinimizedAttribute) { return .init(ok: false, message: "The window is minimized.") }
    if Self.string(window.window, kAXRoleAttribute) == kAXSheetRole as String {
      return .init(ok: false, message: "That is a sheet; stash its window instead.")
    }
    if Self.bool(window.window, "AXFullScreen") { return .init(ok: false, message: "The window is in full screen.") }
    if FullScreen.shared.contains(id) { FullScreen.shared.leave(id) }
    let frame = WindowMover.frame(of: window.window) ?? window.frame
    let screens = VirtualWorkspaces.screens()
    let center = CGPoint(x: frame.midX, y: frame.midY)
    guard
      let screen = screens.first(where: { $0.uuid == display }) ?? screens.first(where: { $0.bounds.contains(center) })
        ?? screens.first
    else {
      return .init(ok: false, message: "Could not find the display \(name) is on.")
    }
    // Out of its zone, as Center and Restore let go of a window; then off every workspace.
    StackManager.shared.didSnap(window, action: .center, frame: frame)
    VirtualWorkspaces.shared.release(id)
    entries.append(Entry(
      id: id, pid: window.pid, edge: edge, slot: nil, position: position, display: screen.uuid, home: home ?? frame,
      size: (home ?? frame).size))
    elements[id] = window.window
    tuck(id, refocus: true)
    save()
    refresh()
    return .init(ok: true, message: "\(edge.displayName): \(name).")
  }

  /// Takes the window `selector` picks off the edge.
  func unstash(_ selector: WindowSnapper.Selector) -> WindowSnapper.Outcome {
    switch selector {
    case .window(let id) where contains(id): return unstash(id)
    case .focused where out != nil: return unstash(out!)
    default: break
    }
    switch WindowSnapper.resolve(selector) {
    case .failure(let failure):
      // A tucked window is off screen, so ask after it by app too.
      if case .app(let name) = selector, let entry = entries.first(where: { matches($0, app: name) }) {
        return unstash(entry.id)
      }
      return .init(ok: false, message: failure.message)
    case .success(let window):
      if contains(window.windowID) { return unstash(window.windowID) }
      return .init(ok: false, message: "\(window.displayName) isn't stashed.")
    }
  }

  /// Puts a stashed window back where it was before it was stashed, on the workspace showing there.
  func unstash(_ id: UInt32, keepingFrame: Bool = false) -> WindowSnapper.Outcome {
    unstash(id, keepingFrame: keepingFrame, to: nil)
  }

  /// Unstashes a window into `frame`: where its Tab was torn off and let go.
  func unstash(_ id: UInt32, to frame: CGRect) -> WindowSnapper.Outcome {
    unstash(id, keepingFrame: false, to: frame)
  }

  private func unstash(_ id: UInt32, keepingFrame: Bool, to frame: CGRect?) -> WindowSnapper.Outcome {
    guard let index = entries.firstIndex(where: { $0.id == id }) else {
      return .init(ok: false, message: "That window isn't stashed.")
    }
    let entry = entries.remove(at: index)
    if out == id { endOut() }
    defer {
      elements[id] = nil
      save()
      refresh()
    }
    guard var window = target(id) else { return .init(ok: true, message: "The stashed window has closed.") }
    if !keepingFrame { WindowSnapper.setFrame(frame ?? Self.onScreen(entry.home), of: window) }
    window = WindowMover.target(for: window.window) ?? window
    VirtualWorkspaces.shared.adopt(window)
    raise(window)
    return .init(ok: true, message: "Unstashed \(window.displayName).")
  }

  /// A stashed window as Settings shows it.
  struct Stashed {
    let id: UInt32
    let app: NSRunningApplication?
    let title: String
    let edge: StashEdge
    /// Its slot, if its Tab is at one; nil when it was dragged somewhere between.
    let slot: StashSlot?
  }

  var stashed: [Stashed] {
    entries.map { entry in
      let app = NSRunningApplication(processIdentifier: entry.pid)
      let title = target(entry.id).map { $0.title.isEmpty ? $0.appName : $0.title } ?? app?.localizedName ?? "Window"
      return Stashed(id: entry.id, app: app, title: title, edge: entry.edge, slot: StashSlot(position: entry.along))
    }
  }

  /// Moves a stashed window's Tab to another edge, keeping its place along it.
  func move(_ id: UInt32, to edge: StashEdge) {
    guard let entry = entry(id), entry.edge != edge else { return }
    move(id, display: entry.display, edge: edge, position: entry.along)
  }

  /// Brings out the next stashed window, in the order their Tabs run, and keeps it out: the first if none is out,
  /// else the one after the window that's out. After the last, it tucks that one away.
  func showNext() -> WindowSnapper.Outcome {
    let order = placed
      .sorted { ($0.display, $0.edge.rawValue, $0.strip.minX + $0.strip.minY) < ($1.display, $1.edge.rawValue, $1.strip.minX + $1.strip.minY) }
      .flatMap(\.entries).map(\.id)
    guard let first = order.first else { return .init(ok: false, message: "No windows are stashed.") }
    var next = first
    if let id = out, let index = order.firstIndex(of: id) {
      guard index + 1 < order.count else {
        tuck(id, refocus: true)
        return .init(ok: true, message: "Tucked away.")
      }
      next = order[index + 1]
    }
    popOut(next)
    pinned = true
    return .init(ok: true, message: target(next)?.displayName ?? "Stashed window")
  }

  /// Tucks a stashed window away, if it's out.
  func tuckAway(_ id: UInt32) {
    if out == id { tuck(id, refocus: true) }
  }

  func unstashAll() {
    for entry in entries { _ = unstash(entry.id) }
  }

  /// The stashed windows, for the CLI: edge, app and title.
  func list() -> [(edge: StashEdge, id: UInt32, name: String)] {
    entries.map { entry in
      let name = target(entry.id)?.displayName
        ?? NSRunningApplication(processIdentifier: entry.pid)?.localizedName ?? "Window"
      return (entry.edge, entry.id, name)
    }
  }

  private func matches(_ entry: Entry, app name: String) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: entry.pid) else { return false }
    let wanted = name.lowercased()
    return app.bundleIdentifier?.lowercased() == wanted || app.localizedName?.lowercased().hasPrefix(wanted) == true
  }

  // MARK: - Popping out and tucking away

  /// ⌘-Tab, the Dock or anything else bringing an app forward: if the window it focuses is stashed, it comes out and
  /// stays out, as if its Tab were clicked. Going to another app tucks away the window that's out.
  private func appActivated(_ pid: pid_t?) {
    guard let pid, pid != ProcessInfo.processInfo.processIdentifier, press == nil, dragging == nil else { return }
    if let raised = raisedByUs, raised.pid == pid, Date().timeIntervalSince(raised.at) < 1 {
      raisedByUs = nil
      return
    }
    if let id = out, entry(id)?.pid != pid {
      tuck(id, refocus: false)
    }
    guard entries.contains(where: { $0.pid == pid }), let window = WindowMover.focusedWindow(), window.pid == pid,
      contains(window.windowID)
    else { return }
    if out != window.windowID { popOut(window.windowID) }
    pinned = true
  }

  private func popOut(_ id: UInt32) {
    cancelTuck()
    hidePeek()
    guard out != id else { return }
    if let current = out { tuck(current, refocus: false) }
    guard let entry = entries.first(where: { $0.id == id }), let window = target(id),
      let (layout, tab) = place(of: id)
    else { return }
    let front = NSWorkspace.shared.frontmostApplication
    if front?.processIdentifier != entry.pid, front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
      previousApp = front
    }
    let frame = layout.popped(entry.size, from: tab)
    WindowSnapper.setFrame(frame, of: window)
    out = id
    outFrame = WindowMover.frame(of: window.window) ?? frame
    raisedByUs = (entry.pid, Date())
    raise(window)
    refresh()
    // A fresh picture for its preview, once it's on screen.
    if openOn == .peek {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        guard self?.out == id else { return }
        self?.takePicture(of: id)
      }
    }
  }

  /// Parks the window just off its display's bottom corner. `refocus` gives the keyboard back to the app that had
  /// it before, if the tucked window's app still has it.
  private func tuck(_ id: UInt32, refocus: Bool) {
    guard let index = entries.firstIndex(where: { $0.id == id }), let element = elements[id] else { return }
    if out == id {
      // Keep a size you gave it while it was out.
      if let now = WindowMover.frame(of: element), let was = outFrame, now.size != was.size {
        entries[index].size = now.size
        save()
      }
      endOut()
    }
    guard let current = WindowMover.frame(of: element) else { return }
    let screens = VirtualWorkspaces.screens()
    guard let screen = screens.first(where: { $0.uuid == entries[index].display }) ?? screens.first else { return }
    let spot = VirtualWorkspaces.parkingSpot(
      for: current.size, bounds: screen.bounds, others: screens.filter { $0.uuid != screen.uuid }.map(\.bounds))
    AXUIElementSetMessagingTimeout(element, 0.5)
    var point = spot
    if let value = AXValueCreate(.cgPoint, &point) {
      AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }
    if refocus, NSWorkspace.shared.frontmostApplication?.processIdentifier == entries[index].pid {
      (previousApp.flatMap { $0.isTerminated ? nil : $0 }
        ?? AppHistory.shared.previous(excluding: entries[index].pid))?.activate()
    }
    previousApp = nil
    refresh()
  }

  private func endOut() {
    out = nil
    outFrame = nil
    pinned = false
    cancelTuck()
  }

  private func raise(_ window: WindowMover.Target) {
    AXUIElementSetAttributeValue(window.window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(window.window, kAXRaiseAction as CFString)
    NSRunningApplication(processIdentifier: window.pid)?.activate()
  }

  // MARK: - The mouse

  /// Pops out the window whose Tab is under the mouse, and tucks the one that's out away once the mouse has left it
  /// and the Tabs for a moment. A click keeps it out, and hovering does nothing until that click is let go.
  private func trackMouse() {
    guard !entries.isEmpty, press == nil else { return }
    let mouse = Self.mouse()
    if let hit = tab(at: mouse) {
      if openOn == .hover && !pinned && hit != out { popOut(hit) } else { cancelTuck() }
      if openOn == .peek && hit != out { showPeek(hit) } else { hidePeek() }
      return
    }
    hidePeek()
    guard let id = out, !keepsOut else { return }
    if inOutZone(mouse, frame: outFrame) { cancelTuck() } else { scheduleTuck(id) }
  }

  private func scheduleTuck(_ id: UInt32) {
    guard pendingTuck == nil else { return }
    let work = DispatchWorkItem {
      MainActor.assumeIsolated {
        let stash = Stash.shared
        stash.pendingTuck = nil
        guard stash.out == id, !stash.keepsOut else { return }
        // Not while a button is down (moving or resizing the window), and judged by where the window is now.
        let live = stash.elements[id].flatMap(WindowMover.frame(of:))
        if NSEvent.pressedMouseButtons != 0 || stash.inOutZone(Self.mouse(), frame: live ?? stash.outFrame) { return }
        stash.tuck(id, refocus: true)
      }
    }
    pendingTuck = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
  }

  private func cancelTuck() {
    pendingTuck?.cancel()
    pendingTuck = nil
  }

  private func inOutZone(_ point: CGPoint, frame: CGRect?) -> Bool {
    if let frame, frame.insetBy(dx: -12, dy: -12).contains(point) { return true }
    guard let id = out, let place = placed.first(where: { $0.entries.contains { $0.id == id } }) else { return false }
    return place.strip.insetBy(dx: -4, dy: -4).contains(point)
  }

  /// A click in another app: into the window that's out keeps it out (when windows open on hover); anywhere else tucks
  /// it away. Letting go after dragging the window away from the edge unstashes it where you left it.
  private func clickedElsewhere(_ type: NSEvent.EventType) {
    guard let id = out, let element = elements[id] else { return }
    let live = WindowMover.frame(of: element)
    if type == .leftMouseUp {
      if let live, let was = outFrame, abs(live.minX - was.minX) > 40 || abs(live.minY - was.minY) > 40,
        live.size == was.size
      {
        _ = unstash(id, keepingFrame: true)
      }
      return
    }
    if let live, live.contains(Self.mouse()) {
      if openOn == .hover { pinned = true }
      cancelTuck()
    } else {
      tuck(id, refocus: false)
    }
  }

  /// Local monitors run on the main thread. A Tab's own clicks and drags stop here.
  private func localClick(_ event: NSEvent) -> NSEvent? {
    handleTabEvent(event) ? nil : event
  }

  /// The mouse on the Tabs. A left click keeps its window out (or, if it's kept out already, tucks it away);
  /// dragging a Tab puts it wherever along an edge you let go, or onto another edge or display; a right click opens
  /// its menu.
  /// Returns whether the event was the Tabs'.
  private func handleTabEvent(_ event: NSEvent) -> Bool {
    let mouse = Self.mouse()
    switch event.type {
    case .rightMouseDown:
      guard let id = tab(at: mouse) else { return false }
      showMenu(for: id, event: event)
      return true
    case .leftMouseDown:
      guard let id = tab(at: mouse) else { return false }
      hidePeek()
      press = (id, mouse)
      return true
    case .leftMouseDragged:
      guard let press else { return false }
      if dragging == nil, hypot(mouse.x - press.start.x, mouse.y - press.start.y) > 5 {
        if out == press.id { tuck(press.id, refocus: true) }
        dragging = press.id
        refresh()
      }
      if dragging != nil { moveGhost(to: mouse) }
      return true
    case .leftMouseUp:
      guard let press else { return false }
      self.press = nil
      if let id = dragging {
        dragging = nil
        ghost.orderOut(nil)
        switch dropTarget {
        case .edge(let display, let edge, let position)?: move(id, display: display, edge: edge, position: position)
        case .unstash(let frame)?: _ = unstash(id, to: frame)
        case nil: break
        }
        dropTarget = nil
        refresh()
      } else if out == press.id && (pinned || openOn.isClick) {
        tuck(press.id, refocus: true)
      } else {
        // On hover, a click keeps it out; on click, it opened by the click and hides as the setting says.
        if out != press.id { popOut(press.id) }
        pinned = openOn == .hover
      }
      return true
    default:
      return false
    }
  }

  /// The dragged Tab, against whichever edge of the display under the mouse is nearest, at the mouse. Dropped onto
  /// other Tabs, it lines up with them.
  private func moveGhost(to mouse: CGPoint) {
    guard let id = dragging, let entry = entry(id), let primaryHeight = NSScreen.screens.first?.frame.height,
      let screen = VirtualWorkspaces.screens().first(where: { $0.bounds.contains(mouse) })
        ?? VirtualWorkspaces.screens().first(where: { $0.uuid == entry.display }),
      let visible = WindowSnapper.visibleFrame(containing: screen.bounds)
    else { return }
    let edge = StashLayout.nearestEdge(to: mouse, in: visible)
    let layout = StashLayout(edge: edge, look: look, visible: visible)
    let rect: CGRect
    if StashLayout.isTornOff(mouse, in: visible) {
      // Away from the edges, it floats with the mouse; let go, and the window is back where it's dropped.
      let size = layout.tabSize
      rect = CGRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height)
      dropTarget = .unstash(StashLayout.torn(entry.size, at: mouse, in: visible))
    } else {
      rect = layout.tab(following: mouse)
      let onto = placed.first { $0.display == screen.uuid && $0.edge == edge && $0.strip.intersects(rect) }
      dropTarget = .edge(display: screen.uuid, edge: edge, position: onto?.position ?? layout.position(at: mouse))
    }
    var item = self.item(for: entry, among: [entry])
    item.isDragged = true
    ghost.show(
      StashTabsView(items: [item], edge: edge, look: look, tabSize: layout.tabSize),
      frame: SnapGeometry.flipped(rect, primaryHeight: primaryHeight))
  }

  /// Moves a window's Tab to `slot` on its edge, after the Tabs already there.
  func move(_ id: UInt32, to slot: StashSlot) {
    guard let entry = entry(id) else { return }
    move(id, display: entry.display, edge: entry.edge, position: slot.position)
  }

  /// Moves a window's Tab to `position` along `edge` of a display, after any Tabs already there.
  func move(_ id: UInt32, display: String, edge: StashEdge, position: CGFloat) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    var entry = entries[index]
    guard entry.display != display || entry.edge != edge || entry.along != position else { return }
    if out == id { tuck(id, refocus: false) }
    entries.remove(at: index)
    entry.display = display
    entry.edge = edge
    entry.position = position
    entry.slot = nil
    entries.append(entry)
    save()
    refresh()
  }

  private func showMenu(for id: UInt32, event: NSEvent) {
    guard let entry = entry(id), let view = event.window?.contentView else { return }
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(MenuAction.item("Unstash") { _ = Stash.shared.unstash(id) })
    menu.addItem(.separator())
    for slot in StashSlot.allCases {
      let item = MenuAction.item(slot.displayName(on: entry.edge)) { Stash.shared.move(id, to: slot) }
      item.state = entry.along == slot.position ? .on : .off
      menu.addItem(item)
    }
    menu.addItem(.separator())
    for edge in StashEdge.allCases where edge != entry.edge {
      menu.addItem(MenuAction.item("Move to \(edge.rawValue.capitalized) Edge") { Stash.shared.move(id, to: edge) })
    }
    if look.isNote, let app = NSRunningApplication(processIdentifier: entry.pid), let bundleID = app.bundleIdentifier {
      menu.addItem(.separator())
      let colours = NSMenuItem(title: "Note Colour", action: nil, keyEquivalent: "")
      let submenu = NSMenu()
      let chosen = StashNoteColor.chosen(for: bundleID)
      let automatic = MenuAction.item("From the App's Icon") {
        StashNoteColor.choose(nil, for: bundleID)
        Stash.shared.refresh()
      }
      automatic.state = chosen == nil ? .on : .off
      submenu.addItem(automatic)
      submenu.addItem(.separator())
      for colour in StashNoteColor.allCases {
        let item = MenuAction.item(colour.displayName) {
          StashNoteColor.choose(colour, for: bundleID)
          Stash.shared.refresh()
        }
        item.image = Self.swatch(colour.color)
        item.state = chosen == colour ? .on : .off
        submenu.addItem(item)
      }
      colours.submenu = submenu
      menu.addItem(colours)
    }
    menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
  }

  private static func swatch(_ color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
      color.setFill()
      NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).fill()
      NSColor.black.withAlphaComponent(0.25).setStroke()
      NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
      return true
    }
  }

  // MARK: - The Tabs

  private func entry(_ id: UInt32) -> Entry? { entries.first { $0.id == id } }

  /// The Tabs in each place, in the order they were stashed, and the strip each place's Tabs fill: a place is a
  /// display, an edge and a position along it. A Tab being dragged is in none.
  private var placed: [Place] {
    var places: [Place] = []
    for entry in entries where entry.id != dragging {
      if let i = places.firstIndex(where: {
        $0.display == entry.display && $0.edge == entry.edge && $0.position == entry.along
      }) {
        places[i].entries.append(entry)
      } else {
        places.append(Place(display: entry.display, edge: entry.edge, position: entry.along, entries: [entry]))
      }
    }
    // Places close together on an edge push apart rather than overlap.
    for key in Set(places.map { "\($0.display)|\($0.edge.rawValue)" }) {
      let indices = places.indices.filter { "\(places[$0].display)|\(places[$0].edge.rawValue)" == key }
      guard let first = indices.first, let layout = layout(places[first].display, places[first].edge) else { continue }
      let strips = layout.strips(indices.map { (places[$0].entries.count, places[$0].position) })
      for (i, strip) in zip(indices, strips) {
        places[i].layout = layout
        places[i].strip = strip
      }
    }
    return places.filter { $0.layout != nil }
  }

  private struct Place {
    let display: String
    let edge: StashEdge
    let position: CGFloat
    var entries: [Entry]
    var layout: StashLayout?
    var strip = CGRect.zero

    var key: String { "\(display)|\(edge.rawValue)|\(position)" }
  }

  private func layout(_ display: String, _ edge: StashEdge) -> StashLayout? {
    guard let screen = VirtualWorkspaces.screens().first(where: { $0.uuid == display }),
      let visible = WindowSnapper.visibleFrame(containing: screen.bounds)
    else { return nil }
    return StashLayout(edge: edge, look: look, visible: visible)
  }

  /// The layout of a stashed window's edge and the rectangle of its Tab.
  private func place(of id: UInt32) -> (StashLayout, CGRect)? {
    for place in placed {
      guard let layout = place.layout, let index = place.entries.firstIndex(where: { $0.id == id }) else { continue }
      return (layout, layout.tab(index, in: place.strip))
    }
    return nil
  }

  private func tab(at point: CGPoint) -> UInt32? {
    for place in placed where place.strip.contains(point) {
      guard let layout = place.layout else { continue }
      return place.entries.indices.first { layout.tab($0, in: place.strip).contains(point) }.map { place.entries[$0].id }
    }
    return nil
  }

  private func item(for entry: Entry, among group: [Entry]) -> StashTabsView.Item {
    let app = NSRunningApplication(processIdentifier: entry.pid)
    let appName = app?.localizedName ?? "Window"
    let title = target(entry.id).map { $0.title.isEmpty ? $0.appName : $0.title } ?? appName
    let sameApp = group.filter { $0.pid == entry.pid }
    let number = sameApp.count > 1 ? (sameApp.firstIndex(of: entry) ?? 0) + 1 : nil
    return .init(
      id: entry.id, icon: app?.icon, title: title, appName: appName,
      color: look.isNote ? StashNoteColor.color(for: app) : .clear, number: number, isOut: out == entry.id,
      badge: DockBadges.badge(for: app, in: badges), wiggles: wiggles[entry.id] ?? 0)
  }

  /// Puts up a panel for each place with Tabs, sized to them, and takes away the rest. Windows whose display has
  /// gone join the main display's edge.
  func refresh() {
    let screens = VirtualWorkspaces.screens()
    if let main = screens.first {
      for i in entries.indices where !screens.contains(where: { $0.uuid == entries[i].display }) {
        entries[i].display = main.uuid
      }
    }
    guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
    var used = Set<String>()
    let look = look
    for place in placed {
      guard let layout = place.layout else { continue }
      used.insert(place.key)
      let panel = panels[place.key] ?? StashPanel()
      panels[place.key] = panel
      let items = place.entries.map { item(for: $0, among: place.entries) }
      panel.show(
        StashTabsView(items: items, edge: place.edge, look: look, tabSize: layout.tabSize),
        frame: SnapGeometry.flipped(place.strip, primaryHeight: primaryHeight))
    }
    for (key, panel) in panels where !used.contains(key) {
      panel.orderOut(nil)
      panels[key] = nil
    }
    // Closing a stashed window doesn't always activate an app, and badges change, so keep checking while there are
    // any.
    if entries.isEmpty {
      timer?.invalidate()
      timer = nil
      hidePeek()
    } else if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        MainActor.assumeIsolated { Stash.shared.tick() }
      }
      DispatchQueue.main.async { Stash.shared.tick() }
    }
  }

  private var lastLook: String?
  private func lookMayHaveChanged() {
    let now = "\(look.rawValue)|\(StashTabFont.chosen)"
    guard now != lastLook else { return }
    lastLook = now
    refresh()
  }

  private func tick() {
    prune()
    guard !entries.isEmpty else { return }
    let now = DockBadges.current()
    guard now != badges else { return }
    // The first read after launch is what was there already, not news.
    for entry in entries where badgesRead {
      let app = NSRunningApplication(processIdentifier: entry.pid)
      if DockBadges.isNews(from: DockBadges.badge(for: app, in: badges), to: DockBadges.badge(for: app, in: now)) {
        wiggles[entry.id, default: 0] += 1
      }
    }
    badges = now
    badgesRead = true
    refresh()
  }

  /// Forgets windows that have closed.
  private func prune() {
    guard !entries.isEmpty else { return }
    let live = Set(
      (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
        .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    let gone = entries.filter { !live.contains($0.id) || NSRunningApplication(processIdentifier: $0.pid) == nil }
    guard !gone.isEmpty else { return }
    for entry in gone {
      if out == entry.id { endOut() }
      if peeking == entry.id { hidePeek() }
      elements[entry.id] = nil
      pictures[entry.id] = nil
      wiggles[entry.id] = nil
    }
    entries.removeAll { entry in gone.contains(entry) }
    save()
    refresh()
  }

  // MARK: - Dragging a window to an edge

  /// Shows where `window` would stash, let go now: a Tab against `edge` of `display`, at the mouse. Returns its place
  /// along the edge, joining Tabs already there if it's over them.
  func showDragHint(for window: WindowMover.Target, display: String, edge: StashEdge, at mouse: CGPoint) -> CGFloat? {
    guard let layout = layout(display, edge), let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
    let rect = layout.tab(following: mouse)
    let onto = placed.first { $0.display == display && $0.edge == edge && $0.strip.intersects(rect) }
    let position = onto?.position ?? layout.position(at: mouse)
    let app = NSRunningApplication(processIdentifier: window.pid)
    let item = StashTabsView.Item(
      id: window.windowID, icon: app?.icon, title: window.title.isEmpty ? window.appName : window.title,
      appName: app?.localizedName ?? window.appName,
      color: look.isNote ? StashNoteColor.color(for: app) : .clear, number: nil, isOut: false, isDragged: true)
    hint.ignoresMouseEvents = true
    hint.alphaValue = 0.8
    hint.show(
      StashTabsView(items: [item], edge: edge, look: look, tabSize: layout.tabSize),
      frame: SnapGeometry.flipped(rect, primaryHeight: primaryHeight))
    return position
  }

  func hideDragHint() {
    hint.orderOut(nil)
  }

  // MARK: - Previews

  /// A preview of a tucked window beside its Tab, while you point at the Tab (when windows open on a click). It
  /// shows the last picture taken of the window, then a fresh one.
  private func showPeek(_ id: UInt32) {
    guard peeking != id, let entry = entry(id), let (layout, tab) = place(of: id),
      let primaryHeight = NSScreen.screens.first?.frame.height
    else { return }
    peeking = id
    let app = NSRunningApplication(processIdentifier: entry.pid)
    let title = target(id).map { $0.title.isEmpty ? $0.appName : $0.title } ?? app?.localizedName ?? "Window"
    let size = StashPeekView.size(for: entry.size)
    let frame = SnapGeometry.flipped(layout.popped(size, from: tab), primaryHeight: primaryHeight)
    func show() {
      peek.show(
        StashPeekView(picture: pictures[id], icon: app?.icon, title: title, badge: DockBadges.badge(for: app, in: badges)),
        frame: frame)
    }
    show()
    takePicture(of: id) { [weak self] in
      if self?.peeking == id { show() }
    }
  }

  private func hidePeek() {
    guard peeking != nil else { return }
    peeking = nil
    peek.orderOut(nil)
  }

  /// Takes a picture of a stashed window for its preview, if Cubicle may record the screen.
  private func takePicture(of id: UInt32, then done: (() -> Void)? = nil) {
    guard #available(macOS 14.0, *) else { return }
    Task { @MainActor in
      guard let picture = await StashPeek.picture(of: id) else { return }
      self.pictures[id] = picture
      done?()
    }
  }

  // MARK: - Helpers

  private func target(_ id: UInt32) -> WindowMover.Target? {
    guard let element = elements[id] else { return nil }
    return WindowMover.target(for: element)
  }

  /// The mouse, in top-left-origin coordinates as Accessibility uses.
  static func mouse() -> CGPoint {
    let point = NSEvent.mouseLocation
    let height = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: point.x, y: height - point.y)
  }

  /// `frame` if it's on a display still connected, else the same size inside the main display.
  private static func onScreen(_ frame: CGRect) -> CGRect {
    let screens = VirtualWorkspaces.screens()
    if screens.contains(where: { $0.bounds.intersects(frame) }) { return frame }
    guard let main = screens.first else { return frame }
    let usable = WindowSnapper.visibleFrame(containing: main.bounds) ?? main.bounds
    return VirtualWorkspaces.rescued(frame, into: usable)
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
    return value as? Bool ?? false
  }

  // MARK: - Saved state

  private enum State {
    static var url: URL? {
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Cubicle", isDirectory: true)
        .appendingPathComponent("stash.json")
    }

    static func load() -> [Entry] {
      guard let url, let data = try? Data(contentsOf: url) else { return [] }
      return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
  }

  private func save() {
    guard let url = State.url else { return }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    } catch {
      NSLog("Cubicle could not save stashed windows: %@", error.localizedDescription)
    }
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }
}

/// A menu item that runs a closure.
private final class MenuAction: NSObject {
  private let run: () -> Void

  private init(_ run: @escaping () -> Void) { self.run = run }

  static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
    let action = MenuAction(run)
    let item = NSMenuItem(title: title, action: #selector(runAction), keyEquivalent: "")
    item.target = action
    item.representedObject = action  // the item keeps its target alive
    return item
  }

  @objc private func runAction() { run() }
}
