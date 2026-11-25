import AppKit
import ApplicationServices

enum SwitchDirection {
  case left, right
}

/// The workspaces of one display, as the menu bar shows them.
struct WorkspaceInfo: Equatable {
  let currentIndex: Int
  let count: Int
  let displayID: String
}

extension Notification.Name {
  /// Posted after a virtual workspace switch or a window is sent to another workspace.
  static let virtualWorkspaceDidChange = Notification.Name("VirtualWorkspaceDidChange")
}

/// Workspaces: Cubicle's own desktops, in place of macOS Spaces.
///
/// macOS keeps one Space per display. Every display has a fixed number of workspaces; each window belongs to one
/// workspace on one display. Switching parks the outgoing workspace's windows just off the display's corner (by
/// writing their Accessibility position, as AeroSpace and Spaceman do) and puts the incoming ones back. Because
/// every window stays on the one native Space, moving a window to another workspace is instant and Accessibility
/// can always see it.
///
/// `SpaceCatalog` republishes them for the grid, names, menu, CLI and stacks.
@MainActor
final class VirtualWorkspaces {
  static let shared = VirtualWorkspaces()

  /// Workspaces per display. It starts at 8 and has no upper limit: `cubicle new-space`, the walkthrough and a new
  /// workspace from picked windows add one. A workspace that still has windows never disappears, whatever the
  /// setting says. Only the first 16 have shortcuts of their own.
  var count: Int {
    get {
      let setting = max(UserDefaults.standard.object(forKey: Self.countKey) as? Int ?? Self.defaultCount, 1)
      let inUse = (members.values.map(\.workspace).max() ?? -1) + 1
      return max(setting, inUse, (active.values.max() ?? -1) + 1)
    }
    set {
      UserDefaults.standard.set(max(newValue, 1), forKey: Self.countKey)
      NotificationCenter.default.post(name: .virtualWorkspaceDidChange, object: nil)
    }
  }

  private struct Member {
    var element: AXUIElement
    let pid: pid_t
    var display: String
    var workspace: Int
    /// The frame to restore, while the window is parked.
    var parkedFrame: CGRect?
  }

  struct Screen {
    let uuid: String
    let id: CGDirectDisplayID
    let name: String
    /// Top-left-origin global coordinates, as Accessibility uses.
    let bounds: CGRect
  }

  private static let countKey = "virtualWorkspaceCount"
  private static let defaultCount = 8
  private var members: [UInt32: Member] = [:]
  private var active: [String: Int] = [:]
  private var previous: [String: Int] = [:]
  private var lastFocused: [String: UInt32] = [:]
  /// Displays in the order first seen, so each workspace's fake Space ID stays put while Cubicle runs.
  private var displayOrder: [String] = []
  private var switching = false
  /// Off while launch adopts the windows that already exist, so starting Cubicle doesn't rearrange them.
  private var gathering = false
  private var activationObserver: Any?

  // MARK: - Starting and stopping

  /// Restores the saved state: windows that still exist go back to their workspaces, and anything a crash left
  /// parked on a workspace that's no longer showing stays parked; everything else is adopted where it is.
  func start() {
    if let saved = State.load() {
      active = saved.active
      let alive = Dictionary(currentWindows().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      for window in saved.windows {
        guard let live = alive[window.id], live.pid == window.pid else { continue }
        members[window.id] = Member(
          element: live.element, pid: live.pid, display: window.display, workspace: window.workspace,
          parkedFrame: window.parkedFrame)
      }
    }
    reconcile()
    // Windows whose workspace isn't showing go (back) off screen; the rest come back.
    let showing = members.filter { $0.value.workspace == activeIndex($0.value.display) }.map(\.key)
    move(park: members.keys.filter { !showing.contains($0) }, unpark: showing)
    save()
    gathering = true
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { notification in
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated { VirtualWorkspaces.shared.followFocus(app) }
    }
  }

  /// Puts every parked window back on screen, so quitting Cubicle never strands a window. Workspaces are kept
  /// and reapplied at the next launch.
  func stop() {
    if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    let parked = members.filter { $0.value.parkedFrame != nil }.map(\.key)
    move(park: [], unpark: parked)
    // Anything still in a parking corner (an unpark that failed, or a window stranded before this launch) comes
    // back too, so quitting always shows every window.
    rescueStranded(currentWindows().map(\.id))
    // Keep the assignments, but record that nothing is parked any more.
    save()
  }

  // MARK: - What SpaceCatalog shows

  static func screens() -> [Screen] {
    NSScreen.screens.compactMap { screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
        let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
        let identifier = CFUUIDCreateString(nil, uuid) as String?
      else { return nil }
      return Screen(
        uuid: identifier, id: number.uint32Value, name: screen.localizedName,
        bounds: CGDisplayBounds(number.uint32Value))
    }
  }

  func displays() -> [SpaceDisplay] {
    let screens = Self.screens()
    return screens.map { screen in
      SpaceDisplay(
        identifier: screen.uuid, name: screens.count > 1 ? screen.name : "Workspaces",
        spaces: (0..<count).map { index in
          SpaceDescription(
            index: UInt32(index), identity: SpaceIdentity(key: Self.key(screen.uuid, index)),
            spaceID: spaceID(screen.uuid, index))
        },
        currentSpaceID: spaceID(screen.uuid, activeIndex(screen.uuid)))
    }
  }

  /// The fake Space ID of the workspace a window belongs to, or 0 if Cubicle doesn't know the window.
  func spaceID(ofWindow id: UInt32) -> UInt64 {
    guard let member = members[id] else { return 0 }
    return spaceID(member.display, member.workspace)
  }

  /// Names are saved per display and workspace number.
  nonisolated static func key(_ display: String, _ index: Int) -> String {
    "workspace:\(display.lowercased()):\(index + 1)"
  }

  private func spaceID(_ display: String, _ index: Int) -> UInt64 {
    if !displayOrder.contains(display) { displayOrder.append(display) }
    let ordinal = UInt64(displayOrder.firstIndex(of: display)! + 1)
    return ordinal << 16 | UInt64(index + 1)
  }

  func activeIndex(_ display: String) -> Int {
    min(active[display] ?? 0, count - 1)
  }

  /// What the menu bar shows: the workspaces of the display with the menu bar.
  func menuBarInfo() -> WorkspaceInfo? {
    guard let screen = Self.screens().first else { return nil }
    return WorkspaceInfo(currentIndex: activeIndex(screen.uuid), count: count, displayID: screen.uuid)
  }

  // MARK: - Switching

  /// Switches the display under the cursor to workspace `index`, as a Space hotkey does.
  @discardableResult
  func switchUnderCursor(toIndex index: Int) -> Bool {
    guard let screen = Self.screenUnderCursor() else { return false }
    return switchTo(index, on: screen)
  }

  /// Switches the display under the cursor one workspace left or right.
  @discardableResult
  func stepUnderCursor(_ direction: SwitchDirection) -> Bool {
    guard let screen = Self.screenUnderCursor() else { return false }
    let target = activeIndex(screen.uuid) + (direction == .left ? -1 : 1)
    return switchTo(target, on: screen)
  }

  @discardableResult
  func switchTo(_ index: Int, on screen: Screen, showOSD: Bool = true) -> Bool {
    guard (0..<count).contains(index), !switching else { return false }
    let display = screen.uuid
    let current = activeIndex(display)
    guard index != current else { return true }
    switching = true
    defer { switching = false }

    reconcile()
    if let focused = WindowMover.focusedWindow(), members[focused.windowID]?.display == display {
      lastFocused[Self.key(display, current)] = focused.windowID
    }
    let outgoing = members.filter { $0.value.display == display && $0.value.workspace == current }.map(\.key)
    let incoming = members.filter { $0.value.display == display && $0.value.workspace == index }.map(\.key)
    let focusTarget = focusTarget(display: display, index: index, incoming: incoming)
    let started = Date()
    SwitchCover.shared.cover(screen, style: SwitchStyle.current) {
      move(park: outgoing, unpark: incoming) { focus(focusTarget) }
    }
    NSLog("Cubicle: workspace switch moved %d windows in %.0f ms (%@)", outgoing.count + incoming.count,
          Date().timeIntervalSince(started) * 1000, SwitchStyle.current.rawValue)
    previous[display] = current
    active[display] = index
    save()
    if showOSD {
      let message = SpaceNameStore.shared.message(
        forTargetIndex: index, identity: SpaceIdentity(key: Self.key(display, index)))
      OSDWindow.shared.show(message: message, screenID: screen.id)
    }
    SpaceCatalog.shared.refresh()
    NotificationCenter.default.post(name: .virtualWorkspaceDidChange, object: nil)
    return true
  }

  private func focusTarget(display: String, index: Int, incoming: [UInt32]) -> UInt32? {
    let remembered = lastFocused[Self.key(display, index)]
    return remembered.flatMap { incoming.contains($0) ? $0 : nil } ?? Self.frontmost(of: incoming)
  }

  private func focus(_ target: UInt32?) {
    if let target, let member = members[target] {
      AXUIElementSetAttributeValue(member.element, kAXMainAttribute as CFString, kCFBooleanTrue)
      AXUIElementPerformAction(member.element, kAXRaiseAction as CFString)
      NSRunningApplication(processIdentifier: member.pid)?.activate()
    } else {
      // An empty workspace: leave no parked window focused, or typing would go to it.
      NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    }
  }

  /// Cmd-Tab, the Dock or a notification focused a window on a workspace that isn't showing: go there.
  private func followFocus(_ app: NSRunningApplication?) {
    guard !switching, let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      let window = WindowMover.focusedWindow(), window.pid == app.processIdentifier,
      let member = members[window.windowID], member.workspace != activeIndex(member.display),
      let screen = Self.screens().first(where: { $0.uuid == member.display })
    else { return }
    lastFocused[Self.key(member.display, member.workspace)] = window.windowID
    switchTo(member.workspace, on: screen)
  }

  // MARK: - Moving a workspace to another display

  /// Moves the workspace showing on the display under the cursor to the next display.
  func moveWorkspaceUnderCursorToNextDisplay() -> (ok: Bool, message: String) {
    let screens = Self.screens()
    guard screens.count > 1 else { return (false, "There's only one display.") }
    guard let source = Self.screenUnderCursor(),
      let position = screens.firstIndex(where: { $0.uuid == source.uuid })
    else { return (false, "Could not read the display under the cursor.") }
    return moveWorkspace(from: source, to: screens[(position + 1) % screens.count])
  }

  /// Moves the workspace showing on `source` to `target`, with its windows, name and layout: into the workspace
  /// with the same number there if it's empty, else the first empty one. Each window keeps its place relative to
  /// the screen, so a left half stays a left half. `target` then shows it, and `source` goes back to the
  /// workspace it showed before.
  func moveWorkspace(from source: Screen, to target: Screen) -> (ok: Bool, message: String) {
    guard !switching, source.uuid != target.uuid else { return (false, "Already there.") }
    reconcile()
    let index = activeIndex(source.uuid)
    let moving = members.filter { $0.value.display == source.uuid && $0.value.workspace == index }.map(\.key)
    guard !moving.isEmpty else { return (false, "This workspace has no windows to move.") }
    let occupied = Set(members.values.filter { $0.display == target.uuid }.map(\.workspace))
    guard let landing = ([index] + (0..<count)).first(where: { !occupied.contains($0) }) else {
      return (false, "\(target.name) has no empty workspace. `cubicle new-space` adds one.")
    }

    let fromKey = Self.key(source.uuid, index)
    let toKey = Self.key(target.uuid, landing)
    let names = SpaceNameStore.shared
    if let name = names.name(for: fromKey) {
      names.setName(name, for: toKey)
      names.setName("", for: fromKey)
    }
    StackingStore.shared.moveLayout(from: fromKey, to: toKey)

    // Each window becomes a parked window of the landing workspace, with the frame it will have there, so showing
    // that workspace puts it in place.
    let from = WindowSnapper.visibleFrame(containing: source.bounds) ?? source.bounds
    let to = WindowSnapper.visibleFrame(containing: target.bounds) ?? target.bounds
    for id in moving {
      guard var member = members[id],
        let frame = member.parkedFrame ?? WindowMover.frame(of: member.element)
      else { continue }
      member.parkedFrame = Self.translate(frame, from: from, to: to)
      member.display = target.uuid
      member.workspace = landing
      members[id] = member
    }
    if let remembered = lastFocused.removeValue(forKey: fromKey) { lastFocused[toKey] = remembered }

    if activeIndex(target.uuid) == landing {
      move(park: [], unpark: moving)
    } else {
      switchTo(landing, on: target, showOSD: false)
    }
    if let back = previous[source.uuid], back != index {
      switchTo(back, on: source, showOSD: false)
    }
    save()
    SpaceCatalog.shared.refresh()
    NotificationCenter.default.post(name: .virtualWorkspaceDidChange, object: nil)
    let title = names.name(for: toKey) ?? "Workspace \(landing + 1)"
    return (true, "\(title) → \(target.name)")
  }

  /// `frame` in `from`, put at the same fractions of `to`.
  nonisolated static func translate(_ frame: CGRect, from: CGRect, to: CGRect) -> CGRect {
    guard from.width > 0, from.height > 0 else { return frame }
    let scaleX = to.width / from.width
    let scaleY = to.height / from.height
    return CGRect(
      x: (to.minX + (frame.minX - from.minX) * scaleX).rounded(),
      y: (to.minY + (frame.minY - from.minY) * scaleY).rounded(),
      width: (frame.width * scaleX).rounded(),
      height: (frame.height * scaleY).rounded())
  }

  // MARK: - A new workspace from picked windows

  /// Gives `windows` a workspace of their own on the display of the first one, names it, and shows it. It takes the
  /// first unused workspace there (no windows, no name, no layout, not showing), or adds one if there is none.
  /// Windows from other displays come along, keeping their place relative to the screen.
  func newWorkspace(with windows: [WindowMover.Target], named name: String) -> (ok: Bool, message: String) {
    guard !switching else { return (false, "A workspace switch is under way.") }
    reconcile()
    let ids = windows.map(\.windowID).filter { members[$0] != nil }
    let screens = Self.screens()
    guard let first = ids.first, let display = members[first]?.display,
      let screen = screens.first(where: { $0.uuid == display })
    else { return (false, "Cubicle can't move those windows to a workspace.") }

    let occupied = Set(members.values.filter { $0.display == display }.map(\.workspace))
    let used = Set((0..<count).filter { index in
      let key = Self.key(display, index)
      return SpaceNameStore.shared.name(for: key) != nil || !StackingStore.shared.bindings(on: key).isEmpty
    })
    guard
      let index = Self.unusedWorkspace(
        count: count, occupied: occupied, used: used, showing: activeIndex(display))
    else { return (false, "There's no workspace to use.") }
    if index == count { count += 1 }

    let key = Self.key(display, index)
    SpaceNameStore.shared.setName(name, for: key)
    // A window showing on this display simply changes workspace and the switch leaves it where it is. One from
    // another display becomes a parked window of the new workspace, so the switch brings it over.
    let to = WindowSnapper.visibleFrame(containing: screen.bounds) ?? screen.bounds
    for id in ids {
      guard var member = members[id] else { continue }
      if member.display != display, let from = screens.first(where: { $0.uuid == member.display }),
        let frame = member.parkedFrame ?? WindowMover.frame(of: member.element)
      {
        member.parkedFrame = Self.translate(
          frame, from: WindowSnapper.visibleFrame(containing: from.bounds) ?? from.bounds, to: to)
      }
      member.display = display
      member.workspace = index
      members[id] = member
    }
    lastFocused[key] = first
    switchTo(index, on: screen, showOSD: false)
    save()
    SpaceCatalog.shared.refresh()
    NotificationCenter.default.post(name: .virtualWorkspaceDidChange, object: nil)
    let title = SpaceNameStore.shared.name(for: key) ?? "Workspace \(index + 1)"
    return (true, "\(title) (\(ids.count) window\(ids.count == 1 ? "" : "s"))")
  }

  /// The first workspace that has no windows, isn't `used` (named, or with a layout) and isn't showing; otherwise
  /// `count`, meaning one more.
  nonisolated static func unusedWorkspace(count: Int, occupied: Set<Int>, used: Set<Int>, showing: Int) -> Int? {
    (0..<count).first { !occupied.contains($0) && !used.contains($0) && $0 != showing } ?? count
  }

  // MARK: - Sending

  /// Moves a window to workspace `index` on its display. It disappears at once if that workspace isn't showing.
  func send(_ window: WindowMover.Target, toIndex index: Int) -> (ok: Bool, message: String) {
    guard (0..<count).contains(index) else { return (false, "There is no workspace \(index + 1).") }
    reconcile()
    guard var member = members[window.windowID] else {
      return (false, "\(window.appName)'s window can't be moved to a workspace.")
    }
    let title = SpaceNameStore.shared.name(for: Self.key(member.display, index)) ?? "Workspace \(index + 1)"
    guard member.workspace != index else { return (true, "\(window.appName) is already on \(title).") }
    member.workspace = index
    members[window.windowID] = member
    if index == activeIndex(member.display) {
      move(park: [], unpark: [window.windowID])
    } else {
      move(park: [window.windowID], unpark: [])
    }
    save()
    NotificationCenter.default.post(name: .virtualWorkspaceDidChange, object: nil)
    return (true, "\(window.appName) → \(title)")
  }

  // MARK: - Parking

  /// One window's part of a move, made on the main thread and carried out on another.
  private struct Job: @unchecked Sendable {
    enum Action {
      /// Off the display: its bounds, the other displays' bounds, and the frame saved already if it's parked.
      case park(bounds: CGRect, others: [CGRect], saved: CGRect?)
      case unpark(CGRect)
    }
    let id: UInt32
    let pid: pid_t
    let element: AXUIElement
    let action: Action
  }

  private enum Outcome {
    /// Off screen; the frame to put it back to.
    case parked(CGRect)
    case unparked
    /// Left alone (minimized or full screen), or Accessibility failed.
    case skipped
  }

  /// Parks and unparks windows in two phases, so the desktop never shows between them: first every incoming window
  /// is put back (front-most first) and Cubicle waits for them all, then `between` runs (focus), and only then do the
  /// outgoing windows leave. Within a phase each app's windows move on a thread of their own, since Accessibility
  /// waits on the app; letting the two phases race is what made AeroSpace flicker more when it went parallel
  /// (AeroSpace #1305; Tessel measured 12/12 glitchy switches before this ordering, 0/12 after, tessel #33).
  private func move(park parking: [UInt32], unpark unparking: [UInt32], between: () -> Void = {}) {
    let screens = Self.screens()
    FullScreen.shared.willShow(unparking)
    var incoming: [Job] = []
    for id in Self.frontToBack(unparking) {
      guard let member = members[id], let frame = member.parkedFrame else { continue }
      incoming.append(Job(id: id, pid: member.pid, element: member.element, action: .unpark(frame)))
    }
    record(Self.run(incoming))
    between()
    var outgoing: [Job] = []
    for id in parking {
      guard let member = members[id],
        let screen = screens.first(where: { $0.uuid == member.display }) ?? screens.first
      else { continue }
      let others = screens.filter { $0.uuid != screen.uuid }.map(\.bounds)
      outgoing.append(
        Job(
          id: id, pid: member.pid, element: member.element,
          action: .park(bounds: screen.bounds, others: others, saved: member.parkedFrame)))
    }
    record(Self.run(outgoing))
  }

  private func record(_ outcomes: [(UInt32, Outcome)]) {
    for (id, outcome) in outcomes {
      switch outcome {
      case .parked(let frame): members[id]?.parkedFrame = frame
      case .unparked: members[id]?.parkedFrame = nil
      case .skipped: break
      }
    }
  }

  /// Runs the jobs, one thread per app, and returns when all are done. Grouping keeps each app's jobs in order.
  nonisolated private static func run(_ jobs: [Job]) -> [(UInt32, Outcome)] {
    guard !jobs.isEmpty else { return [] }
    var order: [pid_t] = []
    var byApp: [pid_t: [Job]] = [:]
    for job in jobs {
      if byApp[job.pid] == nil { order.append(job.pid) }
      byApp[job.pid, default: []].append(job)
    }
    let groups = order.map { byApp[$0]! }
    let lock = NSLock()
    nonisolated(unsafe) var results: [(UInt32, Outcome)] = []
    DispatchQueue.concurrentPerform(iterations: groups.count) { index in
      let outcomes = withoutEnhancedUserInterface(groups[index][0].pid) { groups[index].map { ($0.id, perform($0)) } }
      lock.lock()
      results.append(contentsOf: outcomes)
      lock.unlock()
    }
    return results
  }

  /// With AXEnhancedUserInterface on (VoiceOver mode, which Chrome, Electron and others turn on), apps animate
  /// Accessibility moves and can drop a size written just before a position. AeroSpace, yabai and Rift switch it off
  /// around their writes and back on after.
  nonisolated private static func withoutEnhancedUserInterface<T>(_ pid: pid_t, _ body: () -> T) -> T {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    let attribute = "AXEnhancedUserInterface" as CFString
    guard bool(app, attribute as String) else { return body() }
    AXUIElementSetAttributeValue(app, attribute, kCFBooleanFalse)
    defer { AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue) }
    return body()
  }

  nonisolated private static func perform(_ job: Job) -> Outcome {
    AXUIElementSetMessagingTimeout(job.element, 0.5)
    switch job.action {
    case .unpark(let target):
      setPosition(job.element, target.origin)
      // Parking doesn't resize, so the size is usually right already; writing it anyway costs a round trip.
      if let now = frame(of: job.element), now.size != target.size {
        setSize(job.element, target.size)
        setPosition(job.element, target.origin)
      }
      // An app that ignored the move (busy, or Accessibility timed out) stays parked, to be tried again. Apps
      // clamp a little (below the menu bar), so only a window far from where it should be counts.
      if let now = frame(of: job.element), abs(now.minX - target.minX) > 60 || abs(now.minY - target.minY) > 60 {
        return .skipped
      }
      return .unparked
    case .park(let bounds, let others, let saved):
      guard !bool(job.element, kAXMinimizedAttribute), !bool(job.element, "AXFullScreen"),
        let current = frame(of: job.element)
      else { return .skipped }
      setPosition(job.element, parkingSpot(for: current.size, bounds: bounds, others: others))
      return .parked(saved ?? current)
    }
  }

  /// Just off the display's bottom corner, leaving a pixel on screen (macOS pulls a window that is wholly off screen
  /// back on). The corner is one with no other display beyond it.
  nonisolated private static func parkingSpot(for size: CGSize, bounds: CGRect, others: [CGRect]) -> CGPoint {
    let candidates = [
      CGPoint(x: bounds.maxX - 1, y: bounds.maxY - 1),
      CGPoint(x: bounds.minX - size.width + 1, y: bounds.maxY - 1),
    ]
    return candidates.first { point in
      let rect = CGRect(origin: point, size: size).insetBy(dx: 2, dy: 2)
      return !others.contains { $0.intersects(rect) }
    } ?? candidates[0]
  }

  /// Moves any of these windows that sits (almost) entirely off screen, as a parked window does, back inside the
  /// usable area of its display, keeping its size.
  private func rescueStranded(_ ids: [UInt32]) {
    let screens = Self.screens()
    let bounds = screens.map(\.bounds)
    let byID = Dictionary(currentWindows().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for id in ids {
      guard let window = byID[id], let frame = WindowMover.frame(of: window.element),
        Self.looksParked(frame, screens: bounds)
      else { continue }
      let display = members[id].flatMap { member in screens.first { $0.uuid == member.display } }
        ?? screens.first { $0.bounds.intersects(frame) } ?? screens.first
      guard let display else { continue }
      let usable = WindowSnapper.visibleFrame(containing: display.bounds) ?? display.bounds
      Self.setPosition(window.element, Self.rescued(frame, into: usable).origin)
      members[id]?.parkedFrame = nil
      NSLog("Cubicle: brought back a window left off screen (%u)", id)
    }
  }

  /// Whether `frame` shows less than a sliver on every display, as a parked window does.
  nonisolated static func looksParked(_ frame: CGRect, screens: [CGRect]) -> Bool {
    !screens.contains { screen in
      let overlap = screen.intersection(frame)
      return !overlap.isNull && overlap.width >= 40 && overlap.height >= 40
    }
  }

  /// `frame` moved the least distance to sit inside `usable`, or at its top-left if it's bigger.
  nonisolated static func rescued(_ frame: CGRect, into usable: CGRect) -> CGRect {
    func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { max(low, min(value, high)) }
    return CGRect(
      x: clamp(frame.minX, usable.minX, max(usable.minX, usable.maxX - frame.width)),
      y: clamp(frame.minY, usable.minY, max(usable.minY, usable.maxY - frame.height)),
      width: frame.width, height: frame.height)
  }

  func isParked(_ id: UInt32) -> Bool {
    members[id]?.parkedFrame != nil
  }

  /// Whether the window is on a workspace that's showing (a window Cubicle doesn't manage counts as showing).
  func isShowing(_ id: UInt32) -> Bool {
    guard let member = members[id] else { return true }
    return member.workspace == activeIndex(member.display) && member.parkedFrame == nil
  }

  // MARK: - Learning windows

  private struct LiveWindow {
    let id: UInt32
    let pid: pid_t
    let element: AXUIElement
  }

  /// Adopts windows Cubicle hasn't seen into the workspace showing where they are (a window that appeared on
  /// screen was opened there), forgets closed ones, and re-parks any parked window its app pulled back on screen.
  func reconcile() {
    let screens = Self.screens()
    var seen = Set<UInt32>()
    var strayed: [UInt32] = []
    var adopted: [UInt32] = []
    for window in currentWindows() {
      seen.insert(window.id)
      if var member = members[window.id] {
        member.element = window.element
        members[window.id] = member
        if member.workspace != activeIndex(member.display), member.parkedFrame != nil,
          let frame = WindowMover.frame(of: window.element), Self.isVisible(frame, on: screens)
        {
          strayed.append(window.id)
        }
        continue
      }
      guard let frame = WindowMover.frame(of: window.element) else { continue }
      let center = CGPoint(x: frame.midX, y: frame.midY)
      guard let screen = screens.first(where: { $0.bounds.contains(center) })
        ?? screens.first(where: { $0.bounds.intersects(frame) }) ?? screens.first
      else { continue }
      members[window.id] = Member(
        element: window.element, pid: window.pid, display: screen.uuid, workspace: activeIndex(screen.uuid))
      adopted.append(window.id)
    }
    members = members.filter { seen.contains($0.key) }
    move(park: strayed, unpark: [])
    // Showing windows that are still off screen: an unpark that didn't take is tried again, and a window left in a
    // parking corner when Cubicle last stopped without unparking (a crash, or a kill) is brought back on screen.
    let showing = members.filter { $0.value.workspace == activeIndex($0.value.display) }
    let retry = showing.filter { $0.value.parkedFrame != nil }.map(\.key)
    if !retry.isEmpty { move(park: [], unpark: retry) }
    rescueStranded(showing.filter { $0.value.parkedFrame == nil }.map(\.key))
    if gathering { gather(adopted, screens: screens) }
    // A display that went away: its windows join the main display's workspaces.
    if let main = screens.first {
      let known = Set(screens.map(\.uuid))
      for (id, member) in members where !known.contains(member.display) {
        members[id]?.display = main.uuid
      }
    }
  }

  /// New windows of an app bound to a workspace go to that workspace, on whichever display it is, and are parked
  /// if it isn't showing. A window already on one of its app's bound workspaces stays; otherwise the first binding
  /// wins. Ignored apps, workspaces with stacking paused, and apps with window bindings (which pick out single
  /// windows Cubicle could misjudge here) are left alone. If you're looking at the window, you go with it.
  private func gather(_ ids: [UInt32], screens: [Screen]) {
    let store = StackingStore.shared
    var parking: [UInt32] = []
    var showing: [UInt32] = []
    for id in ids {
      guard var member = members[id],
        let bundleID = NSRunningApplication(processIdentifier: member.pid)?.bundleIdentifier,
        !store.isIgnored(bundleID)
      else { continue }
      let bindings = store.settings.bindings.filter { $0.bundleID == bundleID }
      guard !bindings.isEmpty, !bindings.contains(where: \.isWindowBinding) else { continue }
      let homes = bindings.compactMap { Self.workspace(forKey: $0.spaceKey, on: screens, count: count) }
      guard let home = homes.first,
        !homes.contains(where: { $0.display == member.display && $0.index == member.workspace }),
        !store.isPaused(Self.key(home.display, home.index)),
        let frame = WindowMover.frame(of: member.element)
      else { continue }
      if home.display != member.display,
        let from = screens.first(where: { $0.uuid == member.display }),
        let to = screens.first(where: { $0.uuid == home.display })
      {
        member.parkedFrame = Self.translate(
          frame, from: WindowSnapper.visibleFrame(containing: from.bounds) ?? from.bounds,
          to: WindowSnapper.visibleFrame(containing: to.bounds) ?? to.bounds)
      } else {
        member.parkedFrame = frame
      }
      member.display = home.display
      member.workspace = home.index
      members[id] = member
      if home.index == activeIndex(home.display) { showing.append(id) } else { parking.append(id) }
    }
    guard !parking.isEmpty || !showing.isEmpty else { return }
    move(park: parking, unpark: showing)
    save()
    NotificationCenter.default.post(name: .virtualWorkspaceDidChange, object: nil)
    // Outside this pass, which may be part of a switch.
    DispatchQueue.main.async { [weak self] in self?.followFocus(NSWorkspace.shared.frontmostApplication) }
  }

  /// The display and workspace a name key stands for, if that display is connected.
  nonisolated static func workspace(forKey key: String, on screens: [Screen], count: Int)
    -> (display: String, index: Int)?
  {
    let parts = key.split(separator: ":")
    guard parts.count == 3, parts[0] == "workspace", let number = Int(parts[2]), (1...count).contains(number),
      let screen = screens.first(where: { $0.uuid.lowercased() == parts[1] })
    else { return nil }
    return (screen.uuid, number - 1)
  }

  private func currentWindows() -> [LiveWindow] {
    NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }.flatMap { app -> [LiveWindow] in
      let element = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(element, 0.5)
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
        let windows = value as? [AXUIElement]
      else { return [] }
      return windows.compactMap { window in
        guard Self.string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
          let id = WindowServer.windowID(of: window)
        else { return nil }
        return LiveWindow(id: id, pid: app.processIdentifier, element: window)
      }
    }
  }

  // MARK: - Helpers

  private static func screenUnderCursor() -> Screen? {
    let point = CGEvent(source: nil)?.location ?? .zero
    let screens = screens()
    return screens.first { $0.bounds.contains(point) } ?? screens.first
  }

  /// More than a sliver of the window shows on some display.
  private static func isVisible(_ frame: CGRect, on screens: [Screen]) -> Bool {
    screens.contains { screen in
      let overlap = screen.bounds.intersection(frame)
      return !overlap.isNull && overlap.width > 4 && overlap.height > 4
    }
  }

  /// `ids` in the window server's stacking order, front-most first; unknown ones last.
  private static func frontToBack(_ ids: [UInt32]) -> [UInt32] {
    guard ids.count > 1,
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return ids }
    var rank: [UInt32: Int] = [:]
    for (index, entry) in list.enumerated() {
      if let number = entry[kCGWindowNumber as String] as? NSNumber { rank[number.uint32Value] = index }
    }
    return ids.sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) }
  }

  /// The front-most of `ids` by the window server's stacking order.
  private static func frontmost(of ids: [UInt32]) -> UInt32? {
    guard !ids.isEmpty,
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return ids.first }
    let wanted = Set(ids)
    for entry in list {
      if let number = entry[kCGWindowNumber as String] as? NSNumber, wanted.contains(number.uint32Value) {
        return number.uint32Value
      }
    }
    return ids.first
  }

  nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  nonisolated private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
    return (value as? Bool) ?? false
  }

  nonisolated private static func frame(of element: AXUIElement) -> CGRect? {
    var position: CFTypeRef?
    var size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
      let position, let size
    else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
  }

  nonisolated private static func setPosition(_ element: AXUIElement, _ point: CGPoint) {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else { return }
    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
  }

  nonisolated private static func setSize(_ element: AXUIElement, _ size: CGSize) {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return }
    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
  }

  // MARK: - Saved state

  /// Written after every change, so a crash or a rebuild doesn't lose where windows belong or strand a parked
  /// window: the next launch puts it back.
  private struct State: Codable {
    struct Window: Codable {
      let id: UInt32
      let pid: pid_t
      let display: String
      let workspace: Int
      let parkedFrame: CGRect?
    }
    var active: [String: Int]
    var windows: [Window]

    static var url: URL? {
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Cubicle", isDirectory: true)
        .appendingPathComponent("virtual-workspaces.json")
    }

    static func load() -> State? {
      guard let url, let data = try? Data(contentsOf: url) else { return nil }
      return try? JSONDecoder().decode(State.self, from: data)
    }
  }

  private func save() {
    guard let url = State.url else { return }
    let state = State(
      active: active,
      windows: members.map { id, member in
        State.Window(
          id: id, pid: member.pid, display: member.display, workspace: member.workspace,
          parkedFrame: member.parkedFrame)
      })
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(state).write(to: url, options: .atomic)
    } catch {
      print("Cubicle could not save virtual workspaces: \(error.localizedDescription)")
    }
  }
}
