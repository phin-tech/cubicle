import Combine
import CubicleIPC
import Foundation

// The stacking model (see CONTEXT.md: Zone, Stack, Binding, Pulled-out window, Ignored app, Paused stacking).
// Everything here is plain data and pure functions; `StackManager` feeds it live windows and applies the result.

// MARK: - Saved settings

/// How a window binding recognises its window again after the app restarts: by its document, else its title,
/// else its place in the app's window order on that Space.
struct WindowMatch: Codable, Equatable {
  var document: String?
  var title: String?
  var index: Int
}

/// A saved rule placing an app's windows, or one window (`window` set), on a Space, optionally in a zone.
struct StackBinding: Codable, Equatable, Identifiable {
  var id = UUID()
  var spaceKey: String
  var bundleID: String
  /// For showing the binding; the bundle ID is what matches.
  var appName: String
  var zone: Zone?
  var window: WindowMatch?

  var isWindowBinding: Bool { window != nil }

  /// "Safari", or "Safari — Notes.md" for a window binding.
  var label: String {
    guard let window else { return appName }
    let name = window.title.flatMap { $0.isEmpty ? nil : $0 }
      ?? window.document.map { URL(string: $0)?.lastPathComponent ?? $0 }
      ?? "window \(window.index + 1)"
    return "\(appName) — \(name)"
  }
}

struct StackingSettings: Codable, Equatable {
  /// In binding order, which is also the order bound apps come in their stack's cycle.
  var bindings: [StackBinding] = []
  /// Bundle ID → app name.
  var ignored: [String: String] = [:]
  var pausedSpaces: Set<String> = []
  var pausedEverywhere = false
}

/// The saved bindings, ignore list and pauses.
final class StackingStore: ObservableObject {
  static let shared = StackingStore()
  private static let defaultsKey = "stacking"

  @Published private(set) var settings: StackingSettings
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    settings = defaults.data(forKey: Self.defaultsKey)
      .flatMap { try? JSONDecoder().decode(StackingSettings.self, from: $0) } ?? StackingSettings()
  }

  private func save(_ change: (inout StackingSettings) -> Void) {
    var updated = settings
    change(&updated)
    guard updated != settings else { return }
    settings = updated
    if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: Self.defaultsKey) }
  }

  func bindings(on spaceKey: String) -> [StackBinding] {
    settings.bindings.filter { $0.spaceKey == spaceKey }
  }

  func appBinding(on spaceKey: String, bundleID: String) -> StackBinding? {
    settings.bindings.first { $0.spaceKey == spaceKey && $0.bundleID == bundleID && !$0.isWindowBinding }
  }

  /// Binds an app on a Space. An app has one app binding per Space, so binding it again replaces it (and puts it
  /// last in the binding order).
  @discardableResult
  func bindApp(on spaceKey: String, bundleID: String, appName: String, zone: Zone?) -> StackBinding {
    let binding = StackBinding(spaceKey: spaceKey, bundleID: bundleID, appName: appName, zone: zone)
    save { settings in
      settings.bindings.removeAll { $0.spaceKey == spaceKey && $0.bundleID == bundleID && !$0.isWindowBinding }
      settings.bindings.append(binding)
    }
    return binding
  }

  /// Binds one window. `replacing` is the window binding that currently holds that window, if any.
  @discardableResult
  func bindWindow(
    on spaceKey: String, bundleID: String, appName: String, match: WindowMatch, zone: Zone?, replacing: UUID?
  ) -> StackBinding {
    let binding = StackBinding(
      spaceKey: spaceKey, bundleID: bundleID, appName: appName, zone: zone, window: match)
    save { settings in
      if let replacing { settings.bindings.removeAll { $0.id == replacing } }
      settings.bindings.append(binding)
    }
    return binding
  }

  func removeBinding(_ id: UUID) {
    save { $0.bindings.removeAll { $0.id == id } }
  }

  func isIgnored(_ bundleID: String) -> Bool { settings.ignored[bundleID] != nil }

  func setIgnored(_ ignored: Bool, bundleID: String, appName: String) {
    save { settings in
      settings.ignored[bundleID] = ignored ? appName : nil
      // An ignored app cannot be bound.
      if ignored { settings.bindings.removeAll { $0.bundleID == bundleID } }
    }
  }

  /// True when stacking is paused on this Space, on its own or everywhere.
  func isPaused(_ spaceKey: String) -> Bool {
    settings.pausedEverywhere || settings.pausedSpaces.contains(spaceKey)
  }

  func setPaused(_ paused: Bool, spaceKey: String) {
    save { settings in
      if paused { settings.pausedSpaces.insert(spaceKey) } else { settings.pausedSpaces.remove(spaceKey) }
    }
  }

  func setPausedEverywhere(_ paused: Bool) {
    save { $0.pausedEverywhere = paused }
  }

  /// A workspace moved to another display: its bindings and its pause go with it. An app binding there for the
  /// same app gives way, since an app has one app binding per workspace.
  /// Forgets a removed workspace's bindings (window bindings too) and its pause.
  func removeLayout(_ key: String) {
    save { settings in
      settings.bindings.removeAll { $0.spaceKey == key }
      settings.pausedSpaces.remove(key)
    }
  }

  func moveLayout(from old: String, to new: String) {
    guard old != new else { return }
    save { settings in
      let moving = Set(settings.bindings.filter { $0.spaceKey == old && !$0.isWindowBinding }.map(\.bundleID))
      settings.bindings.removeAll { $0.spaceKey == new && !$0.isWindowBinding && moving.contains($0.bundleID) }
      for index in settings.bindings.indices where settings.bindings[index].spaceKey == old {
        settings.bindings[index].spaceKey = new
      }
      if settings.pausedSpaces.remove(old) != nil { settings.pausedSpaces.insert(new) }
    }
  }
}

// MARK: - Live state

/// A window Cubicle can see, as the planner needs it.
struct LiveWindow: Equatable {
  var id: UInt32
  var bundleID: String
  var document: String?
  var title: String
  /// When Cubicle first saw it; orders an app's windows "in the order they opened".
  var opened: Int
}

/// Which windows the user put somewhere other than their binding says: snapped into a zone, or pulled out.
/// Lives only while Cubicle runs; window numbers don't survive a restart anyway.
struct StackMembership: Equatable {
  /// Windows snapped (or swapped) into a zone other than their binding's.
  private(set) var snapped: [UInt32: Zone] = [:]
  /// The order windows were snapped in, which is their order at the end of a stack.
  private(set) var snappedOrder: [UInt32] = []
  /// Windows taken out of every zone: moved or resized by hand, centred or restored.
  private(set) var floating: Set<UInt32> = []

  /// The window was snapped into `zone`. Snapping a bound window back into its own zone puts it home.
  mutating func join(_ id: UInt32, zone: Zone, home: Zone?) {
    floating.remove(id)
    snappedOrder.removeAll { $0 == id }
    if zone == home {
      snapped[id] = nil
    } else {
      snapped[id] = zone
      snappedOrder.append(id)
    }
  }

  /// The window left its zone (hand move, Center, Restore). It stays out until it closes or is snapped again.
  mutating func pullOut(_ id: UInt32) {
    snapped[id] = nil
    snappedOrder.removeAll { $0 == id }
    floating.insert(id)
  }

  /// Swaps two zones' stacks on the Space `plan` describes: every window trades places, keeping its cycle order.
  /// Like a snap, this changes no binding: a bound window that lands outside its own zone is held there until it
  /// closes or is moved by hand, and one that lands in its own zone is simply home again.
  mutating func swap(_ a: Zone, _ b: Zone, in plan: StackPlan) {
    let first = plan.stacks[a] ?? []
    let second = plan.stacks[b] ?? []
    for id in first { join(id, zone: b, home: plan.home[id]?.zone) }
    for id in second { join(id, zone: a, home: plan.home[id]?.zone) }
  }

  /// The window closed.
  mutating func forget(_ id: UInt32) {
    snapped[id] = nil
    snappedOrder.removeAll { $0 == id }
    floating.remove(id)
  }
}

// MARK: - Planning

/// Where every window on one Space belongs.
struct StackPlan: Equatable {
  /// Each zone's stack, in cycle order.
  var stacks: [Zone: [UInt32]] = [:]
  /// The binding that governs each bound window (a window binding wins over its app's binding).
  var home: [UInt32: StackBinding] = [:]

  func zone(of id: UInt32) -> Zone? {
    stacks.first { $0.value.contains(id) }?.key
  }

  /// The stack holding `id`.
  func stack(of id: UInt32) -> (zone: Zone, windows: [UInt32])? {
    stacks.first { $0.value.contains(id) }.map { ($0.key, $0.value) }
  }
}

enum StackPlanner {
  /// Works out one Space's stacks. `bindings` are that Space's, in binding order; `windows` are the windows on it.
  static func plan(
    windows: [LiveWindow], bindings: [StackBinding], ignored: Set<String>, membership: StackMembership
  ) -> StackPlan {
    let eligible = windows.filter { !ignored.contains($0.bundleID) }
    let windowBindings = assignWindowBindings(bindings.filter(\.isWindowBinding), to: eligible)
    let order = Dictionary(uniqueKeysWithValues: bindings.enumerated().map { ($0.element.id, $0.offset) })

    var plan = StackPlan()
    var bound: [Zone: [(rank: Int, opened: Int, id: UInt32)]] = [:]
    for window in eligible {
      let home = windowBindings[window.id]
        ?? bindings.first { !$0.isWindowBinding && $0.bundleID == window.bundleID }
      if let home { plan.home[window.id] = home }
      if membership.floating.contains(window.id) || membership.snapped[window.id] != nil { continue }
      guard let home, let zone = home.zone else { continue }
      bound[zone, default: []].append((order[home.id] ?? .max, window.opened, window.id))
    }
    for (zone, entries) in bound {
      plan.stacks[zone] = entries.sorted { ($0.rank, $0.opened) < ($1.rank, $1.opened) }.map(\.id)
    }
    let present = Set(eligible.map(\.id))
    for id in membership.snappedOrder where present.contains(id) {
      guard let zone = membership.snapped[id] else { continue }
      plan.stacks[zone, default: []].append(id)
    }
    return plan
  }

  /// Gives each window binding at most one window of its app, and each window at most one binding, in binding
  /// order: the window showing its document, else the one with its title, else the one at its place in the app's
  /// window order.
  static func assignWindowBindings(_ bindings: [StackBinding], to windows: [LiveWindow]) -> [UInt32: StackBinding] {
    var assigned: [UInt32: StackBinding] = [:]
    for binding in bindings {
      guard let match = binding.window else { continue }
      let ofApp = windows.filter { $0.bundleID == binding.bundleID }.sorted { $0.opened < $1.opened }
      let free = ofApp.filter { assigned[$0.id] == nil }
      let byDocument = match.document.flatMap { document in free.first { $0.document == document } }
      let byTitle = match.title.flatMap { title in title.isEmpty ? nil : free.first { $0.title == title } }
      let byIndex = ofApp.indices.contains(match.index) && assigned[ofApp[match.index].id] == nil
        ? ofApp[match.index] : nil
      if let window = byDocument ?? byTitle ?? byIndex { assigned[window.id] = binding }
    }
    return assigned
  }

  /// How a window binding made now would recognise `window` later.
  static func match(for window: LiveWindow, among windows: [LiveWindow]) -> WindowMatch {
    let ofApp = windows.filter { $0.bundleID == window.bundleID }.sorted { $0.opened < $1.opened }
    return WindowMatch(
      document: window.document, title: window.title.isEmpty ? nil : window.title,
      index: ofApp.firstIndex { $0.id == window.id } ?? 0)
  }

  /// The next (or previous) window in a stack after `id`, wrapping around.
  static func cycle(_ stack: [UInt32], from id: UInt32, forward: Bool) -> UInt32? {
    guard stack.count > 1, let index = stack.firstIndex(of: id) else { return nil }
    let next = (index + (forward ? 1 : stack.count - 1)) % stack.count
    return stack[next]
  }
}
