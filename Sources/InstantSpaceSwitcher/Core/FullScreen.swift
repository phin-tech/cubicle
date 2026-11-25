import AppKit
import ApplicationServices

/// Cubicle's full screen (see CONTEXT.md): a window covers its whole display while it stays on its workspace, and the
/// menu bar and Dock auto-hide while any such window is on a workspace that's showing. macOS's own full screen would
/// give the window a Space of its own, outside Cubicle's workspaces.
///
/// Apps won't let a window sit under a menu bar that's showing (they clamp it below), and they push it down when the
/// menu bar comes back. So the menu bar is hidden before a full-screen window is put in place or shown, and stays
/// hidden while one is showing, even when another window is in front.
@MainActor
final class FullScreen {
  static let shared = FullScreen()

  private static let windowsKey = "fullScreenWindows"
  private static let savedChromeKey = "fullScreenSavedChrome"
  /// How long apps take to hear that the menu bar hides; measured about 36 ms on macOS 27.
  private static let settleTime: useconds_t = 50_000

  /// The full-screen windows. Saved, since window IDs outlive a Cubicle restart.
  private var windows: Set<UInt32> {
    didSet { UserDefaults.standard.set(windows.map { Int($0) }, forKey: Self.windowsKey) }
  }
  private var timer: Timer?
  /// Windows shown since the last update, which get put back to the full display rather than judged moved by hand.
  private var justShown: Set<UInt32> = []
  /// When Cubicle last put full-screen windows in place; frames are trusted again a second later.
  private var lastFill = Date.distantPast

  private init() {
    windows = Set((UserDefaults.standard.array(forKey: Self.windowsKey) as? [Int] ?? []).map { UInt32($0) })
  }

  // MARK: - Starting and stopping

  /// Puts back the menu bar and Dock settings a crash left changed. Call before the workspaces start.
  func start() {
    showChrome()
  }

  /// Called once the workspaces have started, so they know which windows are showing.
  func didStartWorkspaces() {
    NotificationCenter.default.addObserver(forName: .virtualWorkspaceDidChange, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { FullScreen.shared.update() }
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { FullScreen.shared.update() }
    }
    update()
  }

  /// Gives the user back their own menu bar and Dock settings.
  func stop() {
    timer?.invalidate()
    timer = nil
    showChrome()
  }

  // MARK: - Entering and leaving

  func contains(_ id: UInt32) -> Bool { windows.contains(id) }

  /// Makes `id` a full-screen window and hides the menu bar and Dock, waiting until apps know, so the window can be
  /// put under where the menu bar was.
  func enter(_ id: UInt32) {
    windows.insert(id)
    lastFill = Date()
    hideChrome()
  }

  /// `id` is no longer full screen. Returns whether the menu bar came back, so a snap that follows knows the usable
  /// area is about to shrink.
  @discardableResult
  func leave(_ id: UInt32) -> Bool {
    guard windows.remove(id) != nil else { return false }
    let wasHidden = chromeHidden
    update()
    return wasHidden && !chromeHidden
  }

  /// The workspaces are about to show these windows: if any is full screen, hide the menu bar first so their apps
  /// don't push them below it.
  func willShow(_ ids: [UInt32]) {
    let shown = ids.filter(windows.contains)
    guard !shown.isEmpty else { return }
    hideChrome()
    justShown.formUnion(shown)
  }

  // MARK: - Keeping up

  /// Forgets closed windows and ones moved off the full display by hand, and hides the menu bar and Dock while a
  /// full-screen window is showing and shows them otherwise. A window that has just been shown is put back to the
  /// full display instead, since its app may have clamped it below the menu bar before hearing it hides.
  func update() {
    let live = Set(
      (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
        .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    var kept = windows.intersection(live)
    let showing = kept.filter { VirtualWorkspaces.shared.isShowing($0) }
    if !showing.isEmpty, hideChrome() { justShown.formUnion(showing) }
    let settled = Date().timeIntervalSince(lastFill) > 1
    for id in showing where !justShown.contains(id) && settled {
      if case .success(let window) = WindowSnapper.resolve(.window(id)),
        let screen = WindowSnapper.screenFrame(containing: window.frame),
        !SnapGeometry.roughlyEqual(window.frame, screen)
      {
        kept.remove(id)
      }
    }
    if kept != windows { windows = kept }
    if !windows.contains(where: { VirtualWorkspaces.shared.isShowing($0) }) { showChrome() }
    let filling = justShown.intersection(windows)
    justShown = []
    if !filling.isEmpty {
      lastFill = Date()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { FullScreen.shared.fill(filling) }
    }
    // Closing a full-screen window doesn't activate an app, so keep checking while there are any.
    if windows.isEmpty {
      timer?.invalidate()
      timer = nil
    } else if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        MainActor.assumeIsolated { FullScreen.shared.update() }
      }
    }
  }

  private func fill(_ ids: Set<UInt32>) {
    lastFill = Date()
    for id in ids where windows.contains(id) && VirtualWorkspaces.shared.isShowing(id) {
      guard case .success(let window) = WindowSnapper.resolve(.window(id)),
        let screen = WindowSnapper.screenFrame(containing: window.frame),
        !SnapGeometry.roughlyEqual(window.frame, screen)
      else { continue }
      WindowSnapper.setFrame(screen, of: window)
    }
  }

  // MARK: - The menu bar and Dock

  private var chromeHidden: Bool { UserDefaults.standard.dictionary(forKey: Self.savedChromeKey) != nil }

  /// Turns on auto-hide for the menu bar and Dock, saving the user's own settings first. Returns whether it changed
  /// anything.
  @discardableResult
  private func hideChrome() -> Bool {
    guard !chromeHidden else { return false }
    let menuBar = Self.menuBarAutoHides()
    let dock = Dock.autoHides()
    UserDefaults.standard.set(["menuBar": menuBar, "dock": dock ?? false], forKey: Self.savedChromeKey)
    if !menuBar { Self.setMenuBarAutoHides(true) }
    if dock == false { Dock.setAutoHides(true) }
    usleep(Self.settleTime)
    return true
  }

  /// Puts the menu bar and Dock back as the user had them.
  private func showChrome() {
    guard let saved = UserDefaults.standard.dictionary(forKey: Self.savedChromeKey) else { return }
    UserDefaults.standard.removeObject(forKey: Self.savedChromeKey)
    if saved["menuBar"] as? Bool == false { Self.setMenuBarAutoHides(false) }
    if saved["dock"] as? Bool == false { Dock.setAutoHides(false) }
  }

  /// System Settings > Control Centre > Automatically hide and show the menu bar, "Always".
  private static func menuBarAutoHides() -> Bool {
    CFPreferencesCopyValue(
      "_HIHideMenuBar" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
      as? Bool ?? false
  }

  private static func setMenuBarAutoHides(_ hide: Bool) {
    CFPreferencesSetValue(
      "_HIHideMenuBar" as CFString, hide ? kCFBooleanTrue : nil, kCFPreferencesAnyApplication,
      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    DistributedNotificationCenter.default().postNotificationName(
      NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil,
      deliverImmediately: true)
  }

  /// The Dock's auto-hide, through HIServices' CoreDock calls (what the Dock's own setting uses).
  private enum Dock {
    private typealias Get = @convention(c) () -> Bool
    private typealias Set = @convention(c) (Bool) -> Void
    private static let get = symbol("CoreDockGetAutoHideEnabled", as: Get.self)
    private static let set = symbol("CoreDockSetAutoHideEnabled", as: Set.self)

    static func autoHides() -> Bool? { get?() }
    static func setAutoHides(_ hide: Bool) { set?(hide) }

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
      guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
      return unsafeBitCast(pointer, to: type)
    }
  }
}
