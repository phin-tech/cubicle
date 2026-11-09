import AppKit
import Carbon

final class ShortcutRecorderControl: NSView {
  /// `.key` records a keyboard shortcut. `.click` records modifiers held while clicking, for the send-window menu.
  enum Mode { case key, click }

  private static weak var activeRecorder: ShortcutRecorderControl?

  static func cancelActiveRecording() {
    activeRecorder?.isRecording = false
  }

  var isEnabled = true {
    didSet {
      needsDisplay = true
      alphaValue = isEnabled ? 1.0 : 0.5
    }
  }

  var isRecording = false {
    didSet {
      needsDisplay = true
      if isRecording {
        keyPressed = false
        HotKeyManager.shared.unregisterAll()
        WindowClickMenu.shared.isPaused = true
        startEventTapRecording()
        Self.activeRecorder = self
      } else {
        stopEventTapRecording()
        WindowClickMenu.shared.isPaused = false
        if Self.activeRecorder === self {
          Self.activeRecorder = nil
        }
        // Re-register all hotkeys after recording ends
        if let appDelegate = NSApp.delegate as? AppDelegate {
          appDelegate.reregisterAllHotkeys()
        }
      }
    }
  }

  private var keyPressed = false

  var currentShortcut: HotkeyCombination? {
    didSet {
      needsDisplay = true
    }
  }

  var onRecordingComplete: ((HotkeyCombination) -> Void)?
  var onRecordingCancelled: (() -> Void)?

  var mode = Mode.key
  var currentClick: ClickBinding? {
    didSet { needsDisplay = true }
  }
  var onClickRecorded: ((ClickBinding) -> Void)?

  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { true }

  private func startEventTapRecording() {
    GlobalEventTapRecorder.shared.startRecording(
      onKeyPress: { [weak self] event in
        self?.handleKeyEvent(event)
      },
      onMouseClick: { [weak self] type, flags in
        self?.handleClick(type, flags)
      }
    )
  }

  private func stopEventTapRecording() {
    GlobalEventTapRecorder.shared.stopRecording()
  }

  /// A click cancels a key recording. In click mode it records, unless no modifiers are held (cancel) or too few
  /// (beep and keep listening).
  private func handleClick(_ type: CGEventType, _ flags: CGEventFlags) {
    guard mode == .click, let binding = ClickBinding(eventType: type, flags: flags), binding.modifiers != 0 else {
      isRecording = false
      onRecordingCancelled?()
      return
    }
    guard binding.isValid else { return NSSound.beep() }
    isRecording = false
    onClickRecorded?(binding)
  }

  private func handleKeyEvent(_ event: NSEvent) {
    // A click recording only listens for clicks; Escape cancels it.
    if mode == .click {
      if event.keyCode == UInt16(kVK_Escape) {
        isRecording = false
        onRecordingCancelled?()
      } else if !event.isARepeat {
        NSSound.beep()
      }
      return
    }

    // Ignore additional key presses after first key
    guard !keyPressed else {
      NSSound.beep()
      return
    }

    keyPressed = true

    // Handle escape
    if event.keyCode == UInt16(kVK_Escape) {
      isRecording = false
      onRecordingCancelled?()
      return
    }

    // Try to create combination
    guard let combination = HotkeyCombination.from(event: event), combination.isValid else {
      NSSound.beep()
      keyPressed = false
      return
    }

    isRecording = false
    onRecordingComplete?(combination)
    // Hotkeys will be re-registered when store updates
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    // Draw background
    if isRecording {
      NSColor.selectedControlColor.withAlphaComponent(0.3).setFill()
    } else {
      NSColor.controlBackgroundColor.setFill()
    }

    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
    path.fill()

    // Draw border
    NSColor.separatorColor.setStroke()
    path.lineWidth = 1
    path.stroke()

    // Draw text
    let text: String
    switch mode {
    case .key: text = isRecording ? "Press keys..." : (currentShortcut?.displayString ?? "Click to record")
    case .click: text = isRecording ? "Hold keys and click…" : (currentClick?.displayString ?? "Click to record")
    }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13),
      .foregroundColor: NSColor.labelColor,
    ]

    let textSize = text.size(withAttributes: attributes)
    let textRect = NSRect(
      x: (bounds.width - textSize.width) / 2,
      y: (bounds.height - textSize.height) / 2,
      width: textSize.width,
      height: textSize.height
    )

    text.draw(in: textRect, withAttributes: attributes)
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    
    // Check accessibility permissions before starting recording
    if !AXIsProcessTrusted() {
      showAccessibilityAlert()
      return
    }

    // Stop any other active recorder
    if let activeRecorder = Self.activeRecorder, activeRecorder !== self {
      activeRecorder.isRecording = false
    }

    if !isRecording {
      isRecording = true
    }
  }

  private func showAccessibilityAlert() {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "Accessibility Permission Required"
    alert.informativeText =
      "\(Constants.appName) needs Accessibility permissions to record keyboard shortcuts.\n\nPlease enable it in System Settings > Privacy & Security > Accessibility."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Cancel")

    let response = alert.runModal()

    if response == .alertFirstButtonReturn {
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
      {
        NSWorkspace.shared.open(url)
      }
    }
  }
}
