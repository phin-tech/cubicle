import AppKit

/// How a virtual workspace switch hides its window moves (experimental; `cubicle switch-style` picks one).
enum SwitchStyle: String, CaseIterable {
  /// Nothing over the switch: the two-phase move (incoming windows first) does the work. The default.
  case none
  /// Cover the display with black while windows move, then fade it out.
  case black
  /// SLSDisableUpdate around the moves. Tessel measured it freezing nothing on macOS 27 (it only holds back
  /// Cubicle's own drawing); kept to compare.
  case freeze
  /// Both: the black cover, with SLSDisableUpdate under it.
  case blackFreeze = "black-freeze"

  static let defaultsKey = "virtualSwitchStyle"

  static var current: SwitchStyle {
    get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(SwitchStyle.init(rawValue:)) ?? .none }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
  }
}

/// Hides a workspace switch's window moves.
@MainActor
final class SwitchCover {
  static let shared = SwitchCover()
  private var covers: [CGDirectDisplayID: NSWindow] = [:]
  /// How long the black cover takes to fade away.
  private static let fade: TimeInterval = 0.12

  func cover(_ screen: VirtualWorkspaces.Screen, style: SwitchStyle, _ body: () -> Void) {
    switch style {
    case .none:
      body()
    case .freeze:
      WindowServer.withScreenUpdatesDisabled(body)
    case .black:
      withBlack(screen.id) { body() }
    case .blackFreeze:
      withBlack(screen.id) { WindowServer.withScreenUpdatesDisabled(body) }
    }
  }

  private func withBlack(_ displayID: CGDirectDisplayID, _ body: () -> Void) {
    guard let nsScreen = NSScreen.screens.first(where: {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
    }) else { return body() }
    let window = covers[displayID] ?? Self.makeCover()
    covers[displayID] = window
    window.setFrame(nsScreen.frame, display: false)
    window.alphaValue = 1
    window.orderFrontRegardless()
    window.display()
    CATransaction.flush()
    // Give the window server a frame to put the cover up before anything moves under it.
    usleep(17_000)
    body()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fade
      window.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated {
        if window.alphaValue == 0 { window.orderOut(nil) }
      }
    }
  }

  private static func makeCover() -> NSWindow {
    let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    window.backgroundColor = .black
    window.isOpaque = true
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.isReleasedWhenClosed = false
    // Above every app's window and the Dock. The OSD sits lower, but shows once the cover has faded.
    window.level = .screenSaver
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    window.animationBehavior = .none
    return window
  }
}
