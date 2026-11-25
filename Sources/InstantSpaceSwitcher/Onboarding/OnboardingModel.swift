import AppKit
import ApplicationServices
import Combine
import SwiftUI

struct OnboardingSpaceRow: Identifiable, Equatable {
  let index: Int
  /// Nil when macOS gives no stable identity for the Space, so it cannot be named.
  let key: String?
  var name: String
  var id: Int { index }
}

/// State and actions behind the walkthrough. Everything reflects the real system (permission, Spaces, the CLI link)
/// and is polled while the window is open, so a step ticks itself when you finish it in another window.
@MainActor
final class OnboardingModel: ObservableObject {
  @Published var step: OnboardingStep = .welcome
  @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
  @Published private(set) var rows: [OnboardingSpaceRow] = []
  @Published private(set) var cliStatus: CLIInstaller.Status = .notInstalled
  /// macOS Spaces beyond the first on any display. Cubicle can't see windows on them.
  @Published private(set) var extraMacSpaces = 0
  @Published var notice: String?
  @Published var shortcutNotice: String?

  var onFinish: (() -> Void)?
  private var timer: Timer?
  private var storeObserver: AnyCancellable?

  init() {
    // The shortcut boxes and the text that quotes the shortcuts follow the store as you record.
    storeObserver = HotkeyStore.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
  }

  static let alfredBundleID = "com.runningwithcrayons.Alfred"
  static let accessibilitySettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

  var alfredWorkflowURL: URL? { Bundle.main.url(forResource: "Cubicle", withExtension: "alfredworkflow") }
  var alfredInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.alfredBundleID) != nil }
  var cliExecutable: URL? { CLIInstaller.bundledExecutable() }

  var gridShortcut: String { HotkeyStore.shared.combination(for: .showGrid).displayString }
  var leftShortcut: String { HotkeyStore.shared.combination(for: .left).displayString }
  var rightShortcut: String { HotkeyStore.shared.combination(for: .right).displayString }

  // MARK: - Lifecycle

  func start() {
    refreshAll()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  func finish() {
    UserDefaults.standard.set(true, forKey: OnboardingWindowController.completedKey)
    stop()
    onFinish?()
  }

  private func poll() {
    accessibilityGranted = AXIsProcessTrusted()
    switch step {
    case .spaces, .names: refreshSpaces()
    case .tools: refreshTools()
    default: break
    }
  }

  private func refreshAll() {
    accessibilityGranted = AXIsProcessTrusted()
    refreshSpaces()
    refreshTools()
    extraMacSpaces = WindowServer.extraMacSpaces()
  }

  // MARK: - Accessibility

  func openAccessibilitySettings() {
    NSWorkspace.shared.open(Self.accessibilitySettingsURL)
  }

  func askForAccessibility() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  // MARK: - Spaces

  /// Rows for the display under the cursor. Names are only replaced when the set of Spaces changes, so a field
  /// you are typing in is never overwritten.
  func refreshSpaces() {
    guard let spaces = SpaceCatalog.shared.spacesUnderCursor() else {
      if !rows.isEmpty { rows = [] }
      return
    }
    let fresh = SpaceGridWindow.cells(for: spaces).map { cell -> OnboardingSpaceRow in
      let key = spaces.display.spaces[cell.index].identity.key
      return OnboardingSpaceRow(index: cell.index, key: key, name: cell.hasCustomName ? cell.title : "")
    }
    if fresh.map({ [String($0.index), $0.key ?? ""] }) != rows.map({ [String($0.index), $0.key ?? ""] }) {
      rows = fresh
    }
  }

  func rename(_ row: OnboardingSpaceRow, to name: String) {
    guard let key = row.key, SpaceNameStore.shared.setName(name, for: key) else { return }
    if let position = rows.firstIndex(where: { $0.index == row.index }) { rows[position].name = name }
  }

  /// Every display gets one more workspace.
  func addWorkspace() {
    VirtualWorkspaces.shared.addWorkspaceEverywhere()
    notice = "Each display now has one more workspace."
    refreshSpaces()
  }

  func openMissionControl() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
  }

  // MARK: - Shortcuts

  func shortcut(for identifier: HotkeyIdentifier) -> HotkeyCombination {
    HotkeyStore.shared.combination(for: identifier)
  }

  /// Applies a recorded shortcut unless another action already uses it.
  func setShortcut(_ combination: HotkeyCombination, for identifier: HotkeyIdentifier) {
    let store = HotkeyStore.shared
    if let other = store.conflict(combination, for: identifier) {
      NSSound.beep()
      shortcutNotice = "\(combination.displayString) is already used for \"\(other.displayName)\"."
      return
    }
    shortcutNotice = nil
    store.update(combination, for: identifier)
  }

  var snapShortcutsEnabled: Bool { HotkeyStore.shared.snapShortcutsEnabled }

  func setSnapShortcutsEnabled(_ enabled: Bool) {
    objectWillChange.send()
    HotkeyStore.shared.setSnapShortcutsEnabled(enabled)
  }

  func resetShortcut(_ identifier: HotkeyIdentifier) {
    setShortcut(identifier.defaultCombination, for: identifier)
  }

  // MARK: - Grid

  func openGrid() {
    SpaceGridWindow.shared.show()
  }

  // MARK: - Tools

  func refreshTools() {
    guard let executable = cliExecutable else {
      cliStatus = .notInstalled
      return
    }
    cliStatus = CLIInstaller.status(link: CLIInstaller.defaultLinkURL, executable: executable)
  }

  func toggleCLI() {
    guard let executable = cliExecutable else { return }
    let link = CLIInstaller.defaultLinkURL
    do {
      if CLIInstaller.status(link: link, executable: executable) == .installed {
        try CLIInstaller.uninstall(link: link)
      } else {
        try CLIInstaller.install(link: link, executable: executable)
      }
      notice = nil
    } catch {
      notice = error.localizedDescription
    }
    refreshTools()
  }

  func openAlfredWorkflow() {
    guard let url = alfredWorkflowURL else { return }
    NSWorkspace.shared.open(url)
  }
}
