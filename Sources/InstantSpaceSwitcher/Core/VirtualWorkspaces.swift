import AppKit
import ApplicationServices
import ISS

extension Notification.Name {
  /// Posted after a virtual workspace switch or a window is sent to another workspace.
  static let virtualWorkspaceDidChange = Notification.Name("VirtualWorkspaceDidChange")
}

/// Virtual workspaces: Cubicle's own workspaces in place of native Spaces (experimental branch).
///
/// macOS keeps one Space per display. Every display has a fixed number of workspaces; each window belongs to one
/// workspace on one display. Switching parks the outgoing workspace's windows just off the display's corner (by
/// writing their Accessibility position, as AeroSpace and Spaceman do) and puts the incoming ones back. Because
/// every window stays on the one native Space, moving a window to another workspace is instant and Accessibility
/// can always see it.
///
/// `SpaceCatalog` presents these workspaces as if they were Spaces, so the grid, names, menu, CLI and stacks keep
/// working unchanged.
@MainActor
final class VirtualWorkspaces {
  static let shared = VirtualWorkspaces()

  /// The whole app runs on virtual workspaces on this branch. A toggle back to native Spaces would flip this.
  static let enabled = true

  /// Workspaces per display (1 to 16, one per Space hotkey). `cubicle new-space` adds one.
  var count: Int {
    get { min(max(UserDefaults.standard.object(forKey: Self.countKey) as? Int ?? 9, 1), 16) }
    set {
      UserDefaults.standard.set(min(max(newValue, 1), 16), forKey: Self.countKey)
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
  private var members: [UInt32: Member] = [:]
  private var active: [String: Int] = [:]
  private var previous: [String: Int] = [:]
  private var lastFocused: [String: UInt32] = [:]
  /// Displays in the order first seen, so each workspace's fake Space ID stays put while Cubicle runs.
  private var displayOrder: [String] = []
  private var switching = false
  private var activationObserver: Any?

  // MARK: - Starting and stopping

  /// Restores the saved state: windows that still exist go back to their workspaces, and anything a crash left
  /// parked on a workspace that's no longer showing stays parked; everything else is adopted where it is.
  func start() {
    guard Self.enabled else { return }
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
    for (id, member) in members {
      if member.workspace == activeIndex(member.display) { unpark(id) } else { park(id) }
    }
    save()
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
    guard Self.enabled else { return }
    if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    let parked = members.filter { $0.value.parkedFrame != nil }.map(\.key)
    for id in parked { unpark(id) }
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
  static func key(_ display: String, _ index: Int) -> String {
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
  func menuBarInfo() -> ISSSpaceInfo? {
    guard let screen = Self.screens().first else { return nil }
    var info = ISSSpaceInfo()
    info.currentIndex = UInt32(activeIndex(screen.uuid))
    info.spaceCount = UInt32(count)
    withUnsafeMutableBytes(of: &info.displayID) { buffer in
      let bytes = Array(screen.uuid.utf8.prefix(buffer.count - 1))
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    return info
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
  func stepUnderCursor(_ direction: ISSDirection) -> Bool {
    guard let screen = Self.screenUnderCursor() else { return false }
    let target = activeIndex(screen.uuid) + (direction == ISSDirectionLeft ? -1 : 1)
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
    for id in outgoing { park(id) }
    for id in incoming { unpark(id) }
    previous[display] = current
    active[display] = index

    focusAfterSwitch(display: display, index: index, incoming: incoming)
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

  private func focusAfterSwitch(display: String, index: Int, incoming: [UInt32]) {
    let remembered = lastFocused[Self.key(display, index)]
    let target = remembered.flatMap { incoming.contains($0) ? $0 : nil } ?? Self.frontmost(of: incoming)
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
    if index == activeIndex(member.display) { unpark(window.windowID) } else { park(window.windowID) }
    save()
    NotificationCenter.default.post(name: .virtualWorkspaceDidChange, object: nil)
    return (true, "\(window.appName) → \(title)")
  }

  // MARK: - Parking

  /// Moves a window just off its display's bottom corner, leaving a pixel on screen (macOS pulls a window that is
  /// wholly off screen back on). The corner is one with no other display beyond it.
  private func park(_ id: UInt32) {
    guard var member = members[id], !Self.isMinimized(member.element), !Self.isFullScreen(member.element),
      let frame = WindowMover.frame(of: member.element),
      let screen = Self.screens().first(where: { $0.uuid == member.display }) ?? Self.screens().first
    else { return }
    if member.parkedFrame == nil { member.parkedFrame = frame }
    members[id] = member
    let others = Self.screens().filter { $0.uuid != screen.uuid }.map(\.bounds)
    let bounds = screen.bounds
    let candidates = [
      CGPoint(x: bounds.maxX - 1, y: bounds.maxY - 1),
      CGPoint(x: bounds.minX - frame.width + 1, y: bounds.maxY - 1),
    ]
    let spot = candidates.first { point in
      let rect = CGRect(origin: point, size: frame.size).insetBy(dx: 2, dy: 2)
      return !others.contains { $0.intersects(rect) }
    } ?? candidates[0]
    Self.setPosition(member.element, spot)
  }

  private func unpark(_ id: UInt32) {
    guard var member = members[id], let frame = member.parkedFrame else { return }
    Self.setPosition(member.element, frame.origin)
    Self.setSize(member.element, frame.size)
    Self.setPosition(member.element, frame.origin)
    member.parkedFrame = nil
    members[id] = member
  }

  func isParked(_ id: UInt32) -> Bool {
    members[id]?.parkedFrame != nil
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
    guard Self.enabled else { return }
    let screens = Self.screens()
    var seen = Set<UInt32>()
    for window in currentWindows() {
      seen.insert(window.id)
      if var member = members[window.id] {
        member.element = window.element
        members[window.id] = member
        if member.workspace != activeIndex(member.display), member.parkedFrame != nil,
          let frame = WindowMover.frame(of: window.element), Self.isVisible(frame, on: screens)
        {
          park(window.id)
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
    }
    members = members.filter { seen.contains($0.key) }
    // A display that went away: its windows join the main display's workspaces.
    if let main = screens.first {
      let known = Set(screens.map(\.uuid))
      for (id, member) in members where !known.contains(member.display) {
        members[id]?.display = main.uuid
      }
    }
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

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
    return (value as? Bool) ?? false
  }

  private static func isMinimized(_ element: AXUIElement) -> Bool { bool(element, kAXMinimizedAttribute) }
  private static func isFullScreen(_ element: AXUIElement) -> Bool { bool(element, "AXFullScreen") }

  private static func setPosition(_ element: AXUIElement, _ point: CGPoint) {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else { return }
    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
  }

  private static func setSize(_ element: AXUIElement, _ size: CGSize) {
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
