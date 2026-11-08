import AppKit
import SwiftUI

/// The first-run walkthrough window. It opens automatically until you finish it once, and "Welcome to Cubicle…" in
/// the menu bar menu opens it again.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
  static let shared = OnboardingWindowController()
  static let completedKey = "onboardingCompleted"

  static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

  /// Called when you press Done, for example to point at the menu bar icon.
  var onFinish: (() -> Void)?

  private var window: NSWindow?
  private var model: OnboardingModel?

  func showIfFirstRun() {
    guard !Self.isCompleted else { return }
    show()
  }

  func show() {
    if window == nil { createWindow() }
    guard let window, let model else { return }
    model.step = .welcome
    model.start()
    // A menu bar app is not frontmost, so bring it forward or the window opens behind everything.
    NSApp.activate(ignoringOtherApps: true)
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  private func createWindow() {
    let model = OnboardingModel()
    model.onFinish = { [weak self] in
      self?.window?.close()
      self?.onFinish?()
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = "Welcome to Cubicle"
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentView = NSHostingView(rootView: OnboardingView(model: model))
    self.window = window
    self.model = model
  }

  func windowWillClose(_ notification: Notification) {
    model?.stop()
  }
}
