import AppKit
import ApplicationServices
import Combine
import CubicleIPC

/// Runs stacking (see CONTEXT.md) on the live windows: watches apps through Accessibility, keeps every stacked
/// window in its zone, notices windows moved by hand, and carries out cycle, swap, bind and pause.
///
/// It only ever arranges windows already on a Space that is showing (ADR 0001): Accessibility can't see the
/// others, and pulling windows across Spaces is something the user asks for.
@MainActor
final class StackManager {
  static let shared = StackManager()

  struct Outcome: Error {
    var ok: Bool
    var message: String
  }

  private let store = StackingStore.shared
  private var membership = StackMembership()

  private struct Known {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let opened: Int
    /// Where Cubicle last put the window while it was in a stack; nil while it isn't stacked.
    var lastSet: CGRect?
    var lastSetAt = Date.distantPast
  }

  private var known: [UInt32: Known] = [:]
  private var nextOpened = 0
  private var observers: [pid_t: AXObserver] = [:]
  private var pendingApply: DispatchWorkItem?
  private var pendingChecks: [UInt32: DispatchWorkItem] = [:]
  /// Moves before this are the system's (a display was added or removed), not the user's.
  private var quietUntil = Date.distantPast
  private var started = false
  private var cancellables = Set<AnyCancellable>()

  // MARK: - Starting

  func start() {
    guard !started else { return }
    guard AXIsProcessTrusted() else {
      // Accessibility may be granted later, from the walkthrough or System Settings.
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
      return
    }
    started = true

    let center = NSWorkspace.shared.notificationCenter
    center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
      .sink { [weak self] notification in
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        MainActor.assumeIsolated {
          self?.observe(app)
          // Apps open their first windows a moment after launching.
          self?.scheduleApply(after: 1.0)
        }
      }.store(in: &cancellables)
    center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
      .sink { [weak self] notification in
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        MainActor.assumeIsolated { self?.appQuit(app.processIdentifier) }
      }.store(in: &cancellables)
    center.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleApply(after: 0.2) } }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        MainActor.assumeIsolated {
          self?.quietUntil = Date().addingTimeInterval(2)
          self?.scheduleApply(after: 1.5)
        }
      }.store(in: &cancellables)
    store.$settings.dropFirst().receive(on: RunLoop.main)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.scheduleApply(after: 0) } }
      .store(in: &cancellables)

    for app in Self.regularApps() { observe(app) }
    scheduleApply(after: 0)
  }

  // MARK: - Watching windows

  private func observe(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard observers[pid] == nil, app.activationPolicy == .regular,
      pid != ProcessInfo.processInfo.processIdentifier
    else { return }
    var observer: AXObserver?
    let callback: AXObserverCallback = { _, element, notification, _ in
      let name = notification as String
      MainActor.assumeIsolated { StackManager.shared.handle(name, element) }
    }
    guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.5)
    for notification in [
      kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
      kAXWindowDeminiaturizedNotification,
    ] {
      AXObserverAddNotification(observer, element, notification as CFString, nil)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    observers[pid] = observer
  }

  private func handle(_ notification: String, _ element: AXUIElement) {
    switch notification {
    case kAXWindowCreatedNotification, kAXWindowDeminiaturizedNotification:
      // Apps size a new window just after creating it, so give them a moment before placing it.
      scheduleApply(after: 0.3)
    case kAXWindowMovedNotification, kAXWindowResizedNotification:
      guard let id = WindowServer.windowID(of: element), known[id]?.lastSet != nil else { return }
      // Wait until the drag or resize stops, then see where it ended up.
      pendingChecks[id]?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.checkForHandMove(id) }
      pendingChecks[id] = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    case kAXUIElementDestroyedNotification:
      pruneClosedWindows()
    default:
      break
    }
  }

  /// A stacked window that is no longer where Cubicle put it was moved or resized by hand (or by macOS's own
  /// tiling): it leaves its stack.
  private func checkForHandMove(_ id: UInt32) {
    pendingChecks[id] = nil
    guard var window = known[id], let placed = window.lastSet,
      let frame = WindowMover.frame(of: window.element)
    else { return }
    if SnapGeometry.roughlyEqual(frame, placed) { return }
    // The system moved it (displays changed): put it back once things settle.
    if Date() < quietUntil {
      scheduleApply(after: 0.3)
      return
    }
    // The app adjusted its own frame right after being placed (terminals round to their cell grid): accept
    // that rather than fighting it.
    if Date().timeIntervalSince(window.lastSetAt) < 0.6 {
      window.lastSet = frame
      known[id] = window
      return
    }
    // Paused Spaces keep their layout; resuming puts the window back.
    if let key = spaceKey(of: id), store.isPaused(key) { return }
    membership.pullOut(id)
    window.lastSet = nil
    known[id] = window
  }

  private func appQuit(_ pid: pid_t) {
    if let observer = observers.removeValue(forKey: pid) {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
    for (id, window) in known where window.pid == pid {
      known[id] = nil
      membership.forget(id)
    }
  }

  private func pruneClosedWindows() {
    let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    let live = Set(info.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    for id in known.keys where !live.contains(id) {
      known[id] = nil
      membership.forget(id)
      pendingChecks.removeValue(forKey: id)?.cancel()
    }
  }

  // MARK: - Reading the Spaces that are showing

  /// The windows that can be stacked on each Space that is showing, keyed by Space. Learns new windows as it
  /// goes, numbering them in the order they are first seen.
  private func scan() -> [String: [UInt32]] {
    SpaceCatalog.shared.refresh()
    var showing: [UInt64: String] = [:]
    for display in SpaceCatalog.shared.displays {
      guard let current = display.currentSpaceID,
        let key = display.spaces.first(where: { $0.spaceID == current })?.identity.key
      else { continue }
      showing[current] = key
    }
    var result: [String: [UInt32]] = [:]
    for app in Self.regularApps() {
      observe(app)
      guard let bundleID = app.bundleIdentifier else { continue }
      for element in Self.windows(of: app.processIdentifier) where Self.isStackable(element) {
        guard let id = WindowServer.windowID(of: element),
          let key = showing[WindowServer.space(ofWindow: id)]
        else { continue }
        if known[id] == nil {
          known[id] = Known(element: element, pid: app.processIdentifier, bundleID: bundleID, opened: nextOpened)
          nextOpened += 1
          if let observer = observers[app.processIdentifier] {
            AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, nil)
          }
        }
        result[key, default: []].append(id)
      }
    }
    return result
  }

  private func liveWindows(_ ids: [UInt32]) -> [LiveWindow] {
    ids.compactMap { id in
      guard let window = known[id] else { return nil }
      return LiveWindow(
        id: id, bundleID: window.bundleID, document: Self.string(window.element, kAXDocumentAttribute),
        title: Self.string(window.element, kAXTitleAttribute) ?? "", opened: window.opened)
    }
  }

  private func plan(_ key: String, _ ids: [UInt32]) -> StackPlan {
    StackPlanner.plan(
      windows: liveWindows(ids), bindings: store.bindings(on: key), ignored: Set(store.settings.ignored.keys),
      membership: membership)
  }

  /// The Space a window is on, by the key bindings are saved under.
  func spaceKey(of id: UInt32) -> String? {
    let spaceID = WindowServer.space(ofWindow: id)
    guard spaceID != 0 else { return nil }
    for display in SpaceCatalog.shared.displays {
      if let space = display.spaces.first(where: { $0.spaceID == spaceID }) { return space.identity.key }
    }
    SpaceCatalog.shared.refresh()
    for display in SpaceCatalog.shared.displays {
      if let space = display.spaces.first(where: { $0.spaceID == spaceID }) { return space.identity.key }
    }
    return nil
  }

  /// The Space showing on the display under the cursor, which "this Space" means for pause and layout.
  func spaceKeyUnderCursor() -> String? {
    guard let spaces = SpaceCatalog.shared.spacesUnderCursor() else { return nil }
    return spaces.display.spaces[spaces.currentIndex].identity.key
  }

  // MARK: - Placing

  private func scheduleApply(after delay: TimeInterval) {
    pendingApply?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.apply() }
    pendingApply = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  /// Puts every stacked window on the showing Spaces in its zone.
  private func apply() {
    pendingApply = nil
    guard started, AXIsProcessTrusted() else { return }
    // Nothing to arrange: skip reading every app's windows on each Space switch.
    if store.settings.bindings.isEmpty && membership == StackMembership() { return }
    for (key, ids) in scan() where !store.isPaused(key) {
      place(plan(key, ids), ids)
    }
  }

  private func place(_ plan: StackPlan, _ ids: [UInt32]) {
    var stacked = Set<UInt32>()
    for (zone, stack) in plan.stacks {
      for id in stack {
        stacked.insert(id)
        guard var window = known[id], let target = WindowMover.target(for: window.element) else { continue }
        if let frame = WindowSnapper.place(target, in: zone) {
          window.lastSet = frame
          window.lastSetAt = Date()
          known[id] = window
        }
      }
    }
    // Windows that left every stack (a binding was removed) stay where they are.
    for id in ids where !stacked.contains(id) { known[id]?.lastSet = nil }
  }

  // MARK: - Snaps

  /// A snap moved `window`: a zone snap puts it in that zone's stack, Center and Restore let go of it. Ignored apps
  /// and paused Spaces only get the frame.
  func didSnap(_ window: WindowMover.Target, action: SnapAction, frame: CGRect) {
    guard started, let bundleID = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier,
      !store.isIgnored(bundleID), let key = spaceKey(of: window.windowID), !store.isPaused(key)
    else { return }
    let ids = scan()[key] ?? []
    guard ids.contains(window.windowID) else { return }
    if let zone = action.zone {
      membership.join(window.windowID, zone: zone, home: plan(key, ids).home[window.windowID]?.zone)
      known[window.windowID]?.lastSet = frame
      known[window.windowID]?.lastSetAt = Date()
    } else {
      membership.pullOut(window.windowID)
      known[window.windowID]?.lastSet = nil
    }
  }

  // MARK: - Commands

  /// Where a command stands: the window, its Space, and that Space's windows and plan.
  private struct Context {
    let target: WindowMover.Target
    let key: String
    let ids: [UInt32]
    let plan: StackPlan
  }

  private func context(_ selector: WindowSnapper.Selector) -> Result<Context, Outcome> {
    guard AXIsProcessTrusted() else { return .failure(Outcome(ok: false, message: "Accessibility is not granted to Cubicle.")) }
    start()
    let target: WindowMover.Target
    switch WindowSnapper.resolve(selector) {
    case .success(let window): target = window
    case .failure(let failure): return .failure(Outcome(ok: false, message: failure.message))
    }
    guard let key = spaceKey(of: target.windowID) else {
      return .failure(Outcome(ok: false, message: "Cubicle can't tell which Space \(target.displayName) is on."))
    }
    let ids = scan()[key] ?? []
    return .success(Context(target: target, key: key, ids: ids, plan: plan(key, ids)))
  }

  func cycle(forward: Bool, _ selector: WindowSnapper.Selector = .focused) -> Outcome {
    let context: Context
    switch self.context(selector) {
    case .success(let value): context = value
    case .failure(let outcome): return outcome
    }
    if store.isPaused(context.key) { return Outcome(ok: false, message: "Stacking is paused on this Space.") }
    guard let stack = context.plan.stack(of: context.target.windowID) else {
      return Outcome(ok: false, message: "\(context.target.displayName) is not in a stack.")
    }
    guard let next = StackPlanner.cycle(stack.windows, from: context.target.windowID, forward: forward) else {
      return Outcome(ok: true, message: "\(context.target.displayName) is the only window in \(stack.zone.displayName).")
    }
    focus(next)
    let name = known[next].flatMap { WindowMover.target(for: $0.element)?.displayName } ?? "the next window"
    return Outcome(ok: true, message: "\(stack.zone.displayName): \(name).")
  }

  enum SwapTarget {
    case direction(Zone.Direction)
    case zone(Zone)
  }

  func swap(_ swapTarget: SwapTarget, _ selector: WindowSnapper.Selector = .focused) -> Outcome {
    let context: Context
    switch self.context(selector) {
    case .success(let value): context = value
    case .failure(let outcome): return outcome
    }
    if store.isPaused(context.key) { return Outcome(ok: false, message: "Stacking is paused on this Space.") }
    guard let zone = context.plan.zone(of: context.target.windowID) else {
      return Outcome(ok: false, message: "\(context.target.displayName) is not in a stack.")
    }
    let other: Zone
    switch swapTarget {
    case .direction(let direction):
      guard let neighbour = zone.neighbour(direction) else {
        return Outcome(ok: false, message: "There is no zone \(direction.rawValue) of \(zone.displayName).")
      }
      other = neighbour
    case .zone(let chosen):
      guard chosen != zone else { return Outcome(ok: true, message: "\(context.target.displayName) is already in \(zone.displayName).") }
      other = chosen
    }
    membership.swap(zone, other, in: context.plan)
    place(plan(context.key, context.ids), context.ids)
    focus(context.target.windowID)
    return Outcome(ok: true, message: "Swapped \(zone.displayName) and \(other.displayName).")
  }

  /// Binds the app of the window `selector` picks (or, with `window`, just that window) on the window's Space.
  /// A nil zone binds it to the Space only.
  func bind(_ zone: Zone?, window bindWindow: Bool, _ selector: WindowSnapper.Selector = .focused) -> Outcome {
    let context: Context
    switch self.context(selector) {
    case .success(let value): context = value
    case .failure(let outcome): return outcome
    }
    let target = context.target
    guard let app = NSRunningApplication(processIdentifier: target.pid), let bundleID = app.bundleIdentifier else {
      return Outcome(ok: false, message: "\(target.appName) has no bundle ID, so it can't be bound.")
    }
    let appName = app.localizedName ?? bundleID
    if store.isIgnored(bundleID) {
      return Outcome(ok: false, message: "\(appName) is ignored. Run `cubicle unignore` first.")
    }
    let windows = liveWindows(context.ids)
    let place = zone.map { "\($0.displayName) on \(spaceName(context.key))" } ?? spaceName(context.key)
    if bindWindow {
      guard let live = windows.first(where: { $0.id == target.windowID }) else {
        return Outcome(ok: false, message: "\(target.displayName) can't be stacked.")
      }
      let current = context.plan.home[target.windowID]
      store.bindWindow(
        on: context.key, bundleID: bundleID, appName: appName, match: StackPlanner.match(for: live, among: windows),
        zone: zone, replacing: current?.isWindowBinding == true ? current?.id : nil)
      membership.forget(target.windowID)
    } else {
      store.bindApp(on: context.key, bundleID: bundleID, appName: appName, zone: zone)
      // Binding is a fresh instruction: the app's pulled-out windows go back in.
      for live in windows where live.bundleID == bundleID { membership.forget(live.id) }
    }
    apply()
    return Outcome(ok: true, message: "Bound \(bindWindow ? target.displayName : appName) to \(place).")
  }

  func unbind(window unbindWindow: Bool, _ selector: WindowSnapper.Selector = .focused) -> Outcome {
    let context: Context
    switch self.context(selector) {
    case .success(let value): context = value
    case .failure(let outcome): return outcome
    }
    let target = context.target
    if unbindWindow {
      guard let binding = context.plan.home[target.windowID], binding.isWindowBinding else {
        return Outcome(ok: false, message: "\(target.displayName) has no window binding here.")
      }
      store.removeBinding(binding.id)
      return Outcome(ok: true, message: "Unbound \(binding.label) from \(spaceName(context.key)).")
    }
    guard let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier,
      let binding = store.appBinding(on: context.key, bundleID: bundleID)
    else {
      return Outcome(ok: false, message: "\(target.appName) is not bound on \(spaceName(context.key)).")
    }
    store.removeBinding(binding.id)
    return Outcome(ok: true, message: "Unbound \(binding.appName) from \(spaceName(context.key)).")
  }

  func setIgnored(_ ignored: Bool, _ selector: WindowSnapper.Selector = .focused) -> Outcome {
    let app: NSRunningApplication?
    switch selector {
    case .app(let name): app = WindowSnapper.runningApp(named: name)
    default:
      if case .success(let target) = WindowSnapper.resolve(selector) {
        app = NSRunningApplication(processIdentifier: target.pid)
      } else {
        app = nil
      }
    }
    guard let app, let bundleID = app.bundleIdentifier else {
      // An app that isn't running can still be taken off the list by bundle ID.
      if !ignored, case .app(let name) = selector, store.isIgnored(name) {
        store.setIgnored(false, bundleID: name, appName: name)
        return Outcome(ok: true, message: "Stopped ignoring \(name).")
      }
      return Outcome(ok: false, message: "No running app to \(ignored ? "ignore" : "stop ignoring").")
    }
    let name = app.localizedName ?? bundleID
    store.setIgnored(ignored, bundleID: bundleID, appName: name)
    if ignored {
      for (id, window) in known where window.bundleID == bundleID {
        membership.forget(id)
        known[id]?.lastSet = nil
      }
    }
    return Outcome(ok: true, message: ignored ? "Ignoring \(name); its bindings were removed." : "Stopped ignoring \(name).")
  }

  /// Pauses or resumes the Space under the cursor, or (`everywhere`) every Space at once.
  func setPaused(_ paused: Bool, everywhere: Bool) -> Outcome {
    if everywhere {
      store.setPausedEverywhere(paused)
      return Outcome(ok: true, message: paused ? "Stacking paused everywhere." : "Stacking resumed everywhere.")
    }
    guard let key = spaceKeyUnderCursor() else {
      return Outcome(ok: false, message: "Cubicle can't tell which Space this is.")
    }
    store.setPaused(paused, spaceKey: key)
    var message = paused ? "Stacking paused on \(spaceName(key))." : "Stacking resumed on \(spaceName(key))."
    if !paused && store.settings.pausedEverywhere { message += " (It is still paused everywhere.)" }
    return Outcome(ok: true, message: message)
  }

  // MARK: - Describing

  /// The app binding and window binding that apply to a window on its Space, and whether its app is ignored.
  func bindings(for target: WindowMover.Target) -> (app: StackBinding?, window: StackBinding?, ignored: Bool) {
    guard let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier else {
      return (nil, nil, false)
    }
    if store.isIgnored(bundleID) { return (nil, nil, true) }
    guard case .success(let context) = context(.window(target.windowID)) else { return (nil, nil, false) }
    let home = context.plan.home[target.windowID]
    return (store.appBinding(on: context.key, bundleID: bundleID), home?.isWindowBinding == true ? home : nil, false)
  }

  /// A readable account of the bindings (and, for showing Spaces, the stacks) on this Space or every Space.
  func describeLayout(all: Bool) -> String {
    SpaceCatalog.shared.refresh()
    let showing = all ? scanIfStarted() : [:]
    var lines: [String] = []
    if store.settings.pausedEverywhere { lines.append("Stacking is paused everywhere.") }
    let keys: [String]
    if all {
      keys = SpaceCatalog.shared.displays.flatMap { $0.spaces.compactMap(\.identity.key) }
    } else {
      keys = spaceKeyUnderCursor().map { [$0] } ?? []
    }
    let current = all ? showing : (keys.first.map { key in [key: scanIfStarted()[key] ?? []] } ?? [:])
    for key in keys {
      let bindings = store.bindings(on: key)
      let ids = current[key]
      if all && bindings.isEmpty && ids == nil { continue }
      lines.append("\(spaceName(key))\(store.isPaused(key) ? " (paused)" : "")")
      if bindings.isEmpty { lines.append("  No bindings.") }
      for binding in bindings {
        let zone = binding.zone?.rawValue ?? "(Space only)"
        lines.append("  \(zone.padding(toLength: 13, withPad: " ", startingAt: 0)) \(binding.label)")
      }
      if let ids {
        let plan = plan(key, ids)
        for zone in Zone.allCases {
          guard let stack = plan.stacks[zone], !stack.isEmpty else { continue }
          let names = stack.compactMap { id in known[id].flatMap { WindowMover.target(for: $0.element)?.displayName } }
          lines.append("  Stack \(zone.rawValue): \(names.joined(separator: ", "))")
        }
      }
    }
    if !store.settings.ignored.isEmpty {
      lines.append("Ignored: " + store.settings.ignored.values.sorted().joined(separator: ", "))
    }
    return lines.isEmpty ? "No bindings." : lines.joined(separator: "\n")
  }

  private func scanIfStarted() -> [String: [UInt32]] {
    start()
    return started ? scan() : [:]
  }

  /// "Mail (Space 2)" or "Space 2".
  func spaceName(_ key: String) -> String {
    for display in SpaceCatalog.shared.displays {
      guard let space = display.spaces.first(where: { $0.identity.key == key }) else { continue }
      let number = "Space \(space.index + 1)"
      if let name = SpaceNameStore.shared.name(for: key), !name.isEmpty { return "\(name) (\(number))" }
      return number
    }
    return SpaceNameStore.shared.name(for: key) ?? "a Space that no longer exists"
  }

  // MARK: - Helpers

  /// Brings a window to the front and gives it focus.
  private func focus(_ id: UInt32) {
    guard let window = known[id] else { return }
    let app = AXUIElementCreateApplication(window.pid)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    NSRunningApplication(processIdentifier: window.pid)?.activate()
  }

  private static func regularApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
  }

  private static func windows(of pid: pid_t) -> [AXUIElement] {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.5)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
  }

  /// Standard windows only: sheets, dialogs, fixed-size panels, minimized and full-screen windows never stack.
  private static func isStackable(_ element: AXUIElement) -> Bool {
    guard string(element, kAXRoleAttribute) == kAXWindowRole as String,
      string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
      bool(element, kAXMinimizedAttribute) != true, bool(element, "AXFullScreen") != true
    else { return false }
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success else { return false }
    return settable.boolValue
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    if let url = value as? URL { return url.absoluteString }
    return value as? String
  }

  private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? Bool
  }
}
