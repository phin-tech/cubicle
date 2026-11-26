import AppKit
import ScreenCaptureKit
import SwiftUI

/// Pictures of stashed windows for their previews. A tucked window is parked off the display, so it's captured on
/// its own rather than from the screen. This needs Screen Recording; without it, previews show the app's icon.
enum StashPeek {
  /// Asks for Screen Recording, once, when previews are turned on.
  static func requestAccess() {
    if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
  }

  @available(macOS 14.0, *)
  static func picture(of id: UInt32) async -> CGImage? {
    guard CGPreflightScreenCaptureAccess(),
      let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
      let window = content.windows.first(where: { $0.windowID == id })
    else { return nil }
    let configuration = SCStreamConfiguration()
    // About twice the preview's width is plenty for a Retina display.
    let scale = min(1, 600 / max(window.frame.width, 1))
    configuration.width = max(1, Int(window.frame.width * scale))
    configuration.height = max(1, Int(window.frame.height * scale))
    configuration.showsCursor = false
    return try? await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
  }
}

/// The panel a preview shows in: over other windows, on every workspace, never taking the keyboard or the mouse.
final class StashPeekPanel: NSPanel {
  private let host = NSHostingView(rootView: StashPeekView(picture: nil, icon: nil, title: "", badge: nil))

  init() {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    ignoresMouseEvents = true
    title = "Cubicle stash preview"
    contentView = host
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// `frame` is in Cocoa's bottom-left-origin coordinates.
  func show(_ view: StashPeekView, frame: CGRect) {
    appearance = StashAppearance.current.nsAppearance
    host.rootView = view
    setFrame(frame, display: true)
    if !isVisible { orderFrontRegardless() }
  }
}

struct StashPeekView: View {
  let picture: CGImage?
  let icon: NSImage?
  let title: String
  let badge: String?

  static let width: CGFloat = 280
  private static let header: CGFloat = 22
  private static let padding: CGFloat = 8

  /// The preview's size for a window of `size`: a fixed width, and the window's shape, not too tall.
  static func size(for size: CGSize) -> CGSize {
    let height = min(220, max(80, width * size.height / max(size.width, 1)))
    return CGSize(width: width + padding * 2, height: height + header + padding * 3)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Self.padding) {
      HStack(spacing: 6) {
        if let icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
        if let badge { StashBadge(text: badge) }
      }
      .frame(height: Self.header)
      Group {
        if let picture {
          Image(decorative: picture, scale: 2).resizable().aspectRatio(contentMode: .fit)
        } else {
          ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
            if let icon { Image(nsImage: icon).resizable().frame(width: 48, height: 48).opacity(0.8) }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .padding(Self.padding)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.15), lineWidth: 0.5))
  }
}
