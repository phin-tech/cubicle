import AppKit
import SwiftUI

/// The existing AppKit shortcut recorder (the one Settings > Keyboard uses), for the walkthrough's SwiftUI pages.
/// Click it, then press the keys you want; Esc cancels. Recording needs the Accessibility permission, so it is
/// disabled until that is granted.
struct ShortcutRecorderView: NSViewRepresentable {
  var combination: HotkeyCombination
  var isEnabled: Bool
  var onChange: (HotkeyCombination) -> Void

  func makeNSView(context: Context) -> ShortcutRecorderControl {
    let control = ShortcutRecorderControl(frame: NSRect(x: 0, y: 0, width: 170, height: 24))
    control.onRecordingComplete = { onChange($0) }
    return control
  }

  func updateNSView(_ control: ShortcutRecorderControl, context: Context) {
    control.currentShortcut = combination
    control.isEnabled = isEnabled
    control.onRecordingComplete = { onChange($0) }
  }
}
