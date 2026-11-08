import AppKit
import ApplicationServices
import Combine
import ISS
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
  @Published private(set) var isAddingSpace = false
  @Published private(set) var cliStatus: CLIInstaller.Status = .notInstalled
  @Published private(set) var rearrangesSpaces = true
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
    rearrangesSpaces = Self.readRearrangesSpaces()
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
    guard let (cells, info) = SpaceGridWindow.currentCells() else {
      if !rows.isEmpty { rows = [] }
      return
    }
    let displayID = stringFromCStringBuffer(info.displayID)
    let fresh = cells.map { cell -> OnboardingSpaceRow in
      let key = SpaceCatalog.shared.identity(displayIdentifier: displayID, index: UInt32(cell.index))?.key
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

  func addSpace() {
    guard !isAddingSpace else { return }
    isAddingSpace = true
    notice = nil
    SpaceCreator.addSpace { [weak self] result in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isAddingSpace = false
        switch result {
        case .success: self.notice = "Added a Space."
        case .failure(let failure): self.notice = failure.message
        }
        self.refreshSpaces()
        // The Dock needs a moment before the new Space shows up in the catalog.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refreshSpaces() }
      }
    }
  }

  func openMissionControl() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
  }

  /// "Automatically rearrange Spaces based on most recent use" shuffles Spaces under you, which breaks "Space 2"
  /// meaning the same Space twice. macOS has it on by default.
  static func readRearrangesSpaces() -> Bool {
    (CFPreferencesCopyAppValue("mru-spaces" as CFString, "com.apple.dock" as CFString) as? Bool) ?? true
  }

  func turnOffRearranging() {
    for arguments in [["/usr/bin/defaults", "write", "com.apple.dock", "mru-spaces", "-bool", "false"],
      ["/usr/bin/killall", "Dock"]]
    {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: arguments[0])
      process.arguments = Array(arguments.dropFirst())
      try? process.run()
      process.waitUntilExit()
    }
    rearrangesSpaces = Self.readRearrangesSpaces()
  }

  // MARK: - Shortcuts

  func shortcut(for identifier: HotkeyIdentifier) -> HotkeyCombination {
    HotkeyStore.shared.combination(for: identifier)
  }

  /// Applies a recorded shortcut unless another action already uses it.
  func setShortcut(_ combination: HotkeyCombination, for identifier: HotkeyIdentifier) {
    let store = HotkeyStore.shared
    if let other = HotkeyConflict.identifier(using: combination, among: store.assignments, excluding: identifier) {
      NSSound.beep()
      shortcutNotice = "\(combination.displayString) is already used for \"\(other.displayName)\"."
      return
    }
    shortcutNotice = nil
    store.update(combination, for: identifier)
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
