import AppKit
import Carbon
import CubicleIPC
import Foundation

enum OptionKeyKind: String, Codable {
  case any
  case right
}

struct HotkeyCombination: Codable, Equatable {
  var keyCode: UInt32
  var modifiers: UInt32
  var displayKey: String
  var keyEquivalent: String
  var optionKeyKind: OptionKeyKind

  init(
    keyCode: UInt32, modifiers: UInt32, displayKey: String, keyEquivalent: String,
    optionKeyKind: OptionKeyKind = .any
  ) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.displayKey = displayKey
    self.keyEquivalent = keyEquivalent
    self.optionKeyKind = optionKeyKind
  }

  var displayString: String {
    let modifierSymbols = HotkeyCombination.symbols(for: modifiers, optionKeyKind: optionKeyKind)
    return modifierSymbols + displayKey
  }

  var cocoaModifierFlags: NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
    if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
    if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
    if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
    return flags
  }

  var isValid: Bool {
    !displayKey.isEmpty
  }

  var registrationModifiers: UInt32 {
    modifiers
  }

  func matches(eventModifierFlags flags: UInt64) -> Bool {
    guard modifiers == HotkeyModifierState.carbonMask(fromRawFlags: flags) else {
      return false
    }

    if optionKeyKind == .right {
      return HotkeyModifierState.isRightOptionPressed(rawFlags: flags)
    }

    if modifiers & UInt32(optionKey) != 0 {
      return !HotkeyModifierState.isRightOptionPressed(rawFlags: flags)
    }

    return true
  }

  enum CodingKeys: String, CodingKey {
    case keyCode
    case modifiers
    case displayKey
    case keyEquivalent
    case optionKeyKind
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    keyCode = try container.decode(UInt32.self, forKey: .keyCode)
    modifiers = try container.decode(UInt32.self, forKey: .modifiers)
    displayKey = try container.decode(String.self, forKey: .displayKey)
    keyEquivalent = try container.decode(String.self, forKey: .keyEquivalent)
    optionKeyKind = try container.decodeIfPresent(OptionKeyKind.self, forKey: .optionKeyKind) ?? .any
  }

  static let defaultLeft = HotkeyCombination(
    keyCode: UInt32(kVK_LeftArrow),
    modifiers: HotkeyCombination.defaultModifierMask,
    displayKey: "←",
    keyEquivalent: HotkeyCombination.arrowKeyEquivalent(.leftArrow)
  )

  static let defaultRight = HotkeyCombination(
    keyCode: UInt32(kVK_RightArrow),
    modifiers: HotkeyCombination.defaultModifierMask,
    displayKey: "→",
    keyEquivalent: HotkeyCombination.arrowKeyEquivalent(.rightArrow)
  )

  static let defaultLastSpace = HotkeyCombination(
    keyCode: UInt32(kVK_ANSI_KeypadPlus),
    modifiers: HotkeyCombination.defaultModifierMask,
    displayKey: "↩",
    keyEquivalent: "-" 
  )

  static let defaultShowGrid = HotkeyCombination(
    keyCode: UInt32(kVK_Space),
    modifiers: UInt32(cmdKey | optionKey | controlKey),
    displayKey: "Space",
    keyEquivalent: " "
  )

  static let defaultSendWindow = HotkeyCombination(
    keyCode: UInt32(kVK_Space),
    modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey),
    displayKey: "Space",
    keyEquivalent: " "
  )

  /// Rectangle's default keys: ⌃⌥ plus arrows for halves, U I J K for quarters, Return, C and Delete. F is
  /// Cubicle's own, for Full Screen.
  static func defaultSnap(_ action: SnapAction) -> HotkeyCombination {
    let keyCode: Int
    let displayKey: String
    let keyEquivalent: String
    switch action {
    case .leftHalf: (keyCode, displayKey, keyEquivalent) = (kVK_LeftArrow, "←", arrowKeyEquivalent(.leftArrow))
    case .rightHalf: (keyCode, displayKey, keyEquivalent) = (kVK_RightArrow, "→", arrowKeyEquivalent(.rightArrow))
    case .topHalf: (keyCode, displayKey, keyEquivalent) = (kVK_UpArrow, "↑", arrowKeyEquivalent(.upArrow))
    case .bottomHalf: (keyCode, displayKey, keyEquivalent) = (kVK_DownArrow, "↓", arrowKeyEquivalent(.downArrow))
    case .topLeft: (keyCode, displayKey, keyEquivalent) = (kVK_ANSI_U, "U", "u")
    case .topRight: (keyCode, displayKey, keyEquivalent) = (kVK_ANSI_I, "I", "i")
    case .bottomLeft: (keyCode, displayKey, keyEquivalent) = (kVK_ANSI_J, "J", "j")
    case .bottomRight: (keyCode, displayKey, keyEquivalent) = (kVK_ANSI_K, "K", "k")
    case .maximize: (keyCode, displayKey, keyEquivalent) = (kVK_Return, "↩", "\r")
    case .fullScreen: (keyCode, displayKey, keyEquivalent) = (kVK_ANSI_F, "F", "f")
    case .center: (keyCode, displayKey, keyEquivalent) = (kVK_ANSI_C, "C", "c")
    case .restore:
      (keyCode, displayKey, keyEquivalent) = (kVK_Delete, "⌫", String(Character(UnicodeScalar(NSBackspaceCharacter)!)))
    }
    return HotkeyCombination(
      keyCode: UInt32(keyCode), modifiers: UInt32(controlKey | optionKey), displayKey: displayKey,
      keyEquivalent: keyEquivalent)
  }

  /// ⌃⌥] and ⌃⌥[ cycle a stack, ⌃⌥⇧ arrows swap stacks, ⌃⌥P pauses (off until turned on).
  static func defaultStacking(_ identifier: HotkeyIdentifier) -> HotkeyCombination {
    let keyCode: Int
    let displayKey: String
    let keyEquivalent: String
    var modifiers = controlKey | optionKey
    switch identifier {
    case .cycleNext: (keyCode, displayKey, keyEquivalent) = (kVK_ANSI_RightBracket, "]", "]")
    case .cyclePrevious: (keyCode, displayKey, keyEquivalent) = (kVK_ANSI_LeftBracket, "[", "[")
    case .swapLeft: (keyCode, displayKey, keyEquivalent) = (kVK_LeftArrow, "←", arrowKeyEquivalent(.leftArrow))
    case .swapRight: (keyCode, displayKey, keyEquivalent) = (kVK_RightArrow, "→", arrowKeyEquivalent(.rightArrow))
    case .swapUp: (keyCode, displayKey, keyEquivalent) = (kVK_UpArrow, "↑", arrowKeyEquivalent(.upArrow))
    case .swapDown: (keyCode, displayKey, keyEquivalent) = (kVK_DownArrow, "↓", arrowKeyEquivalent(.downArrow))
    default: (keyCode, displayKey, keyEquivalent) = (kVK_ANSI_P, "P", "p")
    }
    if identifier.swapDirection != nil { modifiers |= shiftKey }
    return HotkeyCombination(
      keyCode: UInt32(keyCode), modifiers: UInt32(modifiers), displayKey: displayKey, keyEquivalent: keyEquivalent)
  }

  static func defaultForSpace(_ number: Int) -> HotkeyCombination {
    let keyCode: UInt32
    let displayKey: String
    let keyEquivalent: String

    switch number {
    case 1:
      keyCode = UInt32(kVK_ANSI_1)
      displayKey = "1"
      keyEquivalent = "1"
    case 2:
      keyCode = UInt32(kVK_ANSI_2)
      displayKey = "2"
      keyEquivalent = "2"
    case 3:
      keyCode = UInt32(kVK_ANSI_3)
      displayKey = "3"
      keyEquivalent = "3"
    case 4:
      keyCode = UInt32(kVK_ANSI_4)
      displayKey = "4"
      keyEquivalent = "4"
    case 5:
      keyCode = UInt32(kVK_ANSI_5)
      displayKey = "5"
      keyEquivalent = "5"
    case 6:
      keyCode = UInt32(kVK_ANSI_6)
      displayKey = "6"
      keyEquivalent = "6"
    case 7:
      keyCode = UInt32(kVK_ANSI_7)
      displayKey = "7"
      keyEquivalent = "7"
    case 8:
      keyCode = UInt32(kVK_ANSI_8)
      displayKey = "8"
      keyEquivalent = "8"
    case 9:
      keyCode = UInt32(kVK_ANSI_9)
      displayKey = "9"
      keyEquivalent = "9"
    case 10:
      keyCode = UInt32(kVK_ANSI_0)
      displayKey = "0"
      keyEquivalent = "0"
    case 11...16:
      let functionKey = number - 11
      let functionKeyCodes = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3),
        UInt32(kVK_F4), UInt32(kVK_F5), UInt32(kVK_F6),
      ]
      keyCode = functionKeyCodes[functionKey]
      displayKey = "F\(functionKey + 1)"
      keyEquivalent = String(Character(UnicodeScalar(NSF1FunctionKey + functionKey)!))
    default: fatalError("Invalid space number")
    }

    return HotkeyCombination(
      keyCode: keyCode,
      modifiers: defaultModifierMask,
      displayKey: displayKey,
      keyEquivalent: keyEquivalent
    )
  }

  static func from(event: NSEvent) -> HotkeyCombination? {
    let modifiers = event.modifierFlags.carbonMask
    let keyCode = UInt32(event.keyCode)
    let optionKeyKind = HotkeyModifierState.optionKeyKind(
      fromRawFlags: UInt64(event.modifierFlags.rawValue))
    
    // Handle arrow keys
    if let special = event.specialKey, let symbol = arrowSymbol(for: special) {
      return HotkeyCombination(
        keyCode: keyCode,
        modifiers: modifiers,
        displayKey: symbol,
        keyEquivalent: arrowKeyEquivalent(special),
        optionKeyKind: optionKeyKind
      )
    }
    
    // Handle special keys (Enter, F-keys, etc.)
    if let (displayKey, keyEquiv) = specialKeyInfo(for: Int(event.keyCode)) {
      return HotkeyCombination(
        keyCode: keyCode,
        modifiers: modifiers,
        displayKey: displayKey,
        keyEquivalent: keyEquiv,
        optionKeyKind: optionKeyKind
      )
    }

    guard let characters = event.charactersIgnoringModifiers, let first = characters.first,
          first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol else {
      return nil
    }

    let upper = String(first).uppercased()
    return HotkeyCombination(
      keyCode: keyCode,
      modifiers: modifiers,
      displayKey: upper,
      keyEquivalent: String(first).lowercased(),
      optionKeyKind: optionKeyKind
    )
  }

  static func arrowSymbol(for specialKey: NSEvent.SpecialKey) -> String? {
    switch specialKey {
    case .leftArrow: return "←"
    case .rightArrow: return "→"
    case .upArrow: return "↑"
    case .downArrow: return "↓"
    default: return nil
    }
  }
  
  private static func specialKeyInfo(for keyCode: Int) -> (displayKey: String, keyEquivalent: String)? {
    switch keyCode {
    // Enter/Return
    case kVK_Return:
      return ("↩", String(Character(UnicodeScalar(NSCarriageReturnCharacter)!)))
    case kVK_ANSI_KeypadEnter:
      return ("⌅", String(Character(UnicodeScalar(NSEnterCharacter)!)))
    // Tab
    case kVK_Tab:
      return ("⇥", String(Character(UnicodeScalar(NSTabCharacter)!)))
    // Delete/Backspace
    case kVK_Delete:
      return ("⌫", String(Character(UnicodeScalar(NSBackspaceCharacter)!)))
    case kVK_ForwardDelete:
      return ("⌦", String(Character(UnicodeScalar(NSDeleteCharacter)!)))
    // Space
    case kVK_Space:
      return ("Space", " ")
    // F-keys
    case kVK_F1:
      return ("F1", String(Character(UnicodeScalar(NSF1FunctionKey)!)))
    case kVK_F2:
      return ("F2", String(Character(UnicodeScalar(NSF2FunctionKey)!)))
    case kVK_F3:
      return ("F3", String(Character(UnicodeScalar(NSF3FunctionKey)!)))
    case kVK_F4:
      return ("F4", String(Character(UnicodeScalar(NSF4FunctionKey)!)))
    case kVK_F5:
      return ("F5", String(Character(UnicodeScalar(NSF5FunctionKey)!)))
    case kVK_F6:
      return ("F6", String(Character(UnicodeScalar(NSF6FunctionKey)!)))
    case kVK_F7:
      return ("F7", String(Character(UnicodeScalar(NSF7FunctionKey)!)))
    case kVK_F8:
      return ("F8", String(Character(UnicodeScalar(NSF8FunctionKey)!)))
    case kVK_F9:
      return ("F9", String(Character(UnicodeScalar(NSF9FunctionKey)!)))
    case kVK_F10:
      return ("F10", String(Character(UnicodeScalar(NSF10FunctionKey)!)))
    case kVK_F11:
      return ("F11", String(Character(UnicodeScalar(NSF11FunctionKey)!)))
    case kVK_F12:
      return ("F12", String(Character(UnicodeScalar(NSF12FunctionKey)!)))
    // Home/End/Page
    case kVK_Home:
      return ("↖", String(Character(UnicodeScalar(NSHomeFunctionKey)!)))
    case kVK_End:
      return ("↘", String(Character(UnicodeScalar(NSEndFunctionKey)!)))
    case kVK_PageUp:
      return ("⇞", String(Character(UnicodeScalar(NSPageUpFunctionKey)!)))
    case kVK_PageDown:
      return ("⇟", String(Character(UnicodeScalar(NSPageDownFunctionKey)!)))
    default:
      return nil
    }
  }

  private static func arrowKeyEquivalent(_ specialKey: NSEvent.SpecialKey) -> String {
    switch specialKey {
    case .leftArrow:
      return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    case .rightArrow:
      return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
    case .upArrow:
      return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    case .downArrow:
      return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    default:
      return ""
    }
  }

  static func symbols(for modifiers: UInt32, optionKeyKind: OptionKeyKind = .any) -> String {
    var result = ""
    if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
    if modifiers & UInt32(optionKey) != 0 {
      result += optionKeyKind == .right ? "AltGr" : "⌥"
    }
    if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
    if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
    return result
  }

  private static var defaultModifierMask: UInt32 {
    UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
  }
}

/// Modifier keys plus a mouse button: what opens the send-window menu over a window.
struct ClickBinding: Codable, Equatable {
  enum Button: String, Codable {
    case left, right
    /// Either button; the default, so trackpads without secondary click work.
    case any
  }

  var modifiers: UInt32  // Carbon mask, as HotkeyCombination uses
  var button: Button

  static let `default` = ClickBinding(
    modifiers: UInt32(controlKey | optionKey | cmdKey), button: .any)

  var displayString: String {
    let click: String
    switch button {
    case .left: click = "Click"
    case .right: click = "Right-click"
    case .any: click = "Click"
    }
    return HotkeyCombination.symbols(for: modifiers) + " " + click
  }

  /// At least two modifiers, so a plain click, ⇧-click (extend a selection), ⌃-click (right-click) or ⌘-click is
  /// never swallowed.
  var isValid: Bool { modifiers.nonzeroBitCount >= 2 }

  /// Recorded clicks name the button that was pressed.
  init?(eventType: CGEventType, flags: CGEventFlags) {
    switch eventType {
    case .leftMouseDown: button = .left
    case .rightMouseDown: button = .right
    default: return nil
    }
    modifiers = HotkeyModifierState.carbonMask(fromRawFlags: flags.rawValue)
  }

  init(modifiers: UInt32, button: Button) {
    self.modifiers = modifiers
    self.button = button
  }

  func matches(eventType: CGEventType, flags: CGEventFlags) -> Bool {
    let pressed: Button
    switch eventType {
    case .leftMouseDown: pressed = .left
    case .rightMouseDown: pressed = .right
    default: return false
    }
    return (button == .any || button == pressed)
      && HotkeyModifierState.carbonMask(fromRawFlags: flags.rawValue) == modifiers
  }
}

enum HotkeyModifierState {
  private static let deviceRightOptionMask: UInt64 = 0x00000040

  static func optionKeyKind(fromRawFlags flags: UInt64) -> OptionKeyKind {
    isRightOptionPressed(rawFlags: flags) ? .right : .any
  }

  static func isRightOptionPressed(rawFlags flags: UInt64) -> Bool {
    flags & deviceRightOptionMask != 0
  }

  static func carbonMask(fromRawFlags flags: UInt64) -> UInt32 {
    NSEvent.ModifierFlags(rawValue: UInt(flags)).carbonMask
  }
}

enum HotkeyIdentifier: String, CaseIterable {
  case left
  case right
  case space1, space2, space3, space4, space5
  case space6, space7, space8, space9, space10
  case space11, space12, space13, space14, space15, space16
  case lastSpace
  case showGrid
  case sendWindow
  case snapLeftHalf, snapRightHalf, snapTopHalf, snapBottomHalf
  case snapTopLeft, snapTopRight, snapBottomLeft, snapBottomRight
  case snapMaximize, snapFullScreen, snapCenter, snapRestore
  case cycleNext, cyclePrevious
  case swapLeft, swapRight, swapUp, swapDown
  case togglePause
  case moveWorkspaceToNextDisplay
  case newWorkspaceFromWindows
  case stashLeft, stashRight, stashTop
  case stashNext

  /// Off until you turn it on: moving windows is experimental, and the snap and stacking keys would take over ⌃⌥
  /// keys other apps use.
  var enabledByDefault: Bool {
    self == .newWorkspaceFromWindows || isStash
      || (self != .sendWindow && !Self.windowIdentifiers.contains(self))
  }

  /// The stacking shortcuts (cycle, swap, pause).
  var isStacking: Bool {
    switch self {
    case .cycleNext, .cyclePrevious, .swapLeft, .swapRight, .swapUp, .swapDown, .togglePause: return true
    default: return false
    }
  }

  var swapDirection: Zone.Direction? {
    switch self {
    case .swapLeft: return .left
    case .swapRight: return .right
    case .swapUp: return .up
    case .swapDown: return .down
    default: return nil
    }
  }

  /// The snap this shortcut runs, for the snap shortcuts.
  var snapAction: SnapAction? {
    switch self {
    case .snapLeftHalf: return .leftHalf
    case .snapRightHalf: return .rightHalf
    case .snapTopHalf: return .topHalf
    case .snapBottomHalf: return .bottomHalf
    case .snapTopLeft: return .topLeft
    case .snapTopRight: return .topRight
    case .snapBottomLeft: return .bottomLeft
    case .snapBottomRight: return .bottomRight
    case .snapMaximize: return .maximize
    case .snapFullScreen: return .fullScreen
    case .snapCenter: return .center
    case .snapRestore: return .restore
    default: return nil
    }
  }

  static var snapIdentifiers: [HotkeyIdentifier] { allCases.filter { $0.snapAction != nil } }

  /// The edge this shortcut stashes the focused window against, for the stash shortcuts.
  var stashEdge: StashEdge? {
    switch self {
    case .stashLeft: return .left
    case .stashRight: return .right
    case .stashTop: return .top
    default: return nil
    }
  }

  /// The stash shortcuts: the three edges and bringing out the next stashed window.
  var isStash: Bool { stashEdge != nil || self == .stashNext }

  /// The window shortcuts, kept in one dictionary: the snaps and the stacking ones.
  static var windowIdentifiers: [HotkeyIdentifier] {
    allCases.filter {
      $0.snapAction != nil || $0.isStacking || $0.isStash || $0 == .moveWorkspaceToNextDisplay
        || $0 == .newWorkspaceFromWindows
    }
  }

  /// The shortcuts Settings and the walkthrough turn on and off together. Pause has its own switch: it changes
  /// what Cubicle does rather than acting once.
  static var windowShortcutGroup: [HotkeyIdentifier] {
    windowIdentifiers.filter {
      ![.togglePause, .moveWorkspaceToNextDisplay, .newWorkspaceFromWindows].contains($0) && !$0.isStash
    }
  }

  var displayName: String {
    switch self {
    case .left: return "Switch to workspace on the left"
    case .right: return "Switch to workspace on the right"
    case .space1: return "Switch to workspace 1"
    case .space2: return "Switch to workspace 2"
    case .space3: return "Switch to workspace 3"
    case .space4: return "Switch to workspace 4"
    case .space5: return "Switch to workspace 5"
    case .space6: return "Switch to workspace 6"
    case .space7: return "Switch to workspace 7"
    case .space8: return "Switch to workspace 8"
    case .space9: return "Switch to workspace 9"
    case .space10: return "Switch to workspace 10"
    case .space11: return "Switch to workspace 11"
    case .space12: return "Switch to workspace 12"
    case .space13: return "Switch to workspace 13"
    case .space14: return "Switch to workspace 14"
    case .space15: return "Switch to workspace 15"
    case .space16: return "Switch to workspace 16"
    case .lastSpace: return "Switch to last used workspace"
    case .showGrid: return "Show workspace grid"
    case .sendWindow: return "Send window to workspace…"
    case .cycleNext: return "Stack: next window"
    case .cyclePrevious: return "Stack: previous window"
    case .swapLeft: return "Stack: swap with zone on the left"
    case .swapRight: return "Stack: swap with zone on the right"
    case .swapUp: return "Stack: swap with zone above"
    case .swapDown: return "Stack: swap with zone below"
    case .togglePause: return "Stack: pause or resume this workspace"
    case .moveWorkspaceToNextDisplay: return "Move workspace to the next display"
    case .newWorkspaceFromWindows: return "New workspace from picked windows…"
    case .stashLeft, .stashRight, .stashTop: return "\(stashEdge!.displayName) (or unstash)"
    case .stashNext: return "Open the next stashed window"
    default: return "Snap window: \(snapAction!.displayName)"
    }
  }
}

final class HotkeyStore: ObservableObject {
  static let shared = HotkeyStore()

  @Published private(set) var leftHotkey: HotkeyCombination
  @Published private(set) var rightHotkey: HotkeyCombination
  @Published private(set) var space1Hotkey: HotkeyCombination
  @Published private(set) var space2Hotkey: HotkeyCombination
  @Published private(set) var space3Hotkey: HotkeyCombination
  @Published private(set) var space4Hotkey: HotkeyCombination
  @Published private(set) var space5Hotkey: HotkeyCombination
  @Published private(set) var space6Hotkey: HotkeyCombination
  @Published private(set) var space7Hotkey: HotkeyCombination
  @Published private(set) var space8Hotkey: HotkeyCombination
  @Published private(set) var space9Hotkey: HotkeyCombination
  @Published private(set) var space10Hotkey: HotkeyCombination
  @Published private(set) var space11Hotkey: HotkeyCombination
  @Published private(set) var space12Hotkey: HotkeyCombination
  @Published private(set) var space13Hotkey: HotkeyCombination
  @Published private(set) var space14Hotkey: HotkeyCombination
  @Published private(set) var space15Hotkey: HotkeyCombination
  @Published private(set) var space16Hotkey: HotkeyCombination
  @Published private(set) var spaceLastSpaceHotkey: HotkeyCombination
  @Published private(set) var showGridHotkey: HotkeyCombination
  @Published private(set) var sendWindowHotkey: HotkeyCombination
  /// The snap shortcuts, keyed by identifier (there are too many to give each its own property).
  @Published private(set) var snapHotkeys: [HotkeyIdentifier: HotkeyCombination] = [:]
  @Published private(set) var enabledStates: [HotkeyIdentifier: Bool] = [:]

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    leftHotkey = defaults.hotkey(forKey: DefaultsKey.left.rawValue) ?? .defaultLeft
    rightHotkey = defaults.hotkey(forKey: DefaultsKey.right.rawValue) ?? .defaultRight
    space1Hotkey = defaults.hotkey(forKey: DefaultsKey.space1.rawValue) ?? .defaultForSpace(1)
    space2Hotkey = defaults.hotkey(forKey: DefaultsKey.space2.rawValue) ?? .defaultForSpace(2)
    space3Hotkey = defaults.hotkey(forKey: DefaultsKey.space3.rawValue) ?? .defaultForSpace(3)
    space4Hotkey = defaults.hotkey(forKey: DefaultsKey.space4.rawValue) ?? .defaultForSpace(4)
    space5Hotkey = defaults.hotkey(forKey: DefaultsKey.space5.rawValue) ?? .defaultForSpace(5)
    space6Hotkey = defaults.hotkey(forKey: DefaultsKey.space6.rawValue) ?? .defaultForSpace(6)
    space7Hotkey = defaults.hotkey(forKey: DefaultsKey.space7.rawValue) ?? .defaultForSpace(7)
    space8Hotkey = defaults.hotkey(forKey: DefaultsKey.space8.rawValue) ?? .defaultForSpace(8)
    space9Hotkey = defaults.hotkey(forKey: DefaultsKey.space9.rawValue) ?? .defaultForSpace(9)
    space10Hotkey = defaults.hotkey(forKey: DefaultsKey.space10.rawValue) ?? .defaultForSpace(10)
    space11Hotkey = defaults.hotkey(forKey: DefaultsKey.space11.rawValue) ?? .defaultForSpace(11)
    space12Hotkey = defaults.hotkey(forKey: DefaultsKey.space12.rawValue) ?? .defaultForSpace(12)
    space13Hotkey = defaults.hotkey(forKey: DefaultsKey.space13.rawValue) ?? .defaultForSpace(13)
    space14Hotkey = defaults.hotkey(forKey: DefaultsKey.space14.rawValue) ?? .defaultForSpace(14)
    space15Hotkey = defaults.hotkey(forKey: DefaultsKey.space15.rawValue) ?? .defaultForSpace(15)
    space16Hotkey = defaults.hotkey(forKey: DefaultsKey.space16.rawValue) ?? .defaultForSpace(16)
    spaceLastSpaceHotkey = defaults.hotkey(forKey: DefaultsKey.lastSpace.rawValue) ?? .defaultLastSpace
    showGridHotkey = defaults.hotkey(forKey: DefaultsKey.showGrid.rawValue) ?? .defaultShowGrid
    sendWindowHotkey = defaults.hotkey(forKey: DefaultsKey.sendWindow.rawValue) ?? .defaultSendWindow

    for identifier in HotkeyIdentifier.windowIdentifiers {
      snapHotkeys[identifier] =
        defaults.hotkey(forKey: "hotkey.\(identifier.rawValue)") ?? identifier.defaultCombination
    }

    for identifier in HotkeyIdentifier.allCases {
      let key = "enabled.\(identifier.rawValue)"
      enabledStates[identifier] = defaults.object(forKey: key) as? Bool ?? identifier.enabledByDefault
    }
    // Cycle and swap arrived after the snaps: start them on if the snaps already are, so the one switch that
    // covers them all still reads as on.
    let snapsOn = enabledStates[.snapLeftHalf] ?? false
    for identifier in HotkeyIdentifier.windowShortcutGroup
    where identifier.isStacking && defaults.object(forKey: "enabled.\(identifier.rawValue)") == nil {
      enabledStates[identifier] = snapsOn
    }
  }

  func update(_ combination: HotkeyCombination, for identifier: HotkeyIdentifier) {
    switch identifier {
    case .left:
      guard combination != leftHotkey else { return }
      leftHotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.left.rawValue)
    case .right:
      guard combination != rightHotkey else { return }
      rightHotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.right.rawValue)
    case .space1:
      guard combination != space1Hotkey else { return }
      space1Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space1.rawValue)
    case .space2:
      guard combination != space2Hotkey else { return }
      space2Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space2.rawValue)
    case .space3:
      guard combination != space3Hotkey else { return }
      space3Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space3.rawValue)
    case .space4:
      guard combination != space4Hotkey else { return }
      space4Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space4.rawValue)
    case .space5:
      guard combination != space5Hotkey else { return }
      space5Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space5.rawValue)
    case .space6:
      guard combination != space6Hotkey else { return }
      space6Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space6.rawValue)
    case .space7:
      guard combination != space7Hotkey else { return }
      space7Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space7.rawValue)
    case .space8:
      guard combination != space8Hotkey else { return }
      space8Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space8.rawValue)
    case .space9:
      guard combination != space9Hotkey else { return }
      space9Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space9.rawValue)
    case .space10:
      guard combination != space10Hotkey else { return }
      space10Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space10.rawValue)
    case .space11:
      guard combination != space11Hotkey else { return }
      space11Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space11.rawValue)
    case .space12:
      guard combination != space12Hotkey else { return }
      space12Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space12.rawValue)
    case .space13:
      guard combination != space13Hotkey else { return }
      space13Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space13.rawValue)
    case .space14:
      guard combination != space14Hotkey else { return }
      space14Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space14.rawValue)
    case .space15:
      guard combination != space15Hotkey else { return }
      space15Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space15.rawValue)
    case .space16:
      guard combination != space16Hotkey else { return }
      space16Hotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.space16.rawValue)
    case .lastSpace:
      guard combination != spaceLastSpaceHotkey else { return }
      spaceLastSpaceHotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.lastSpace.rawValue)
    case .showGrid:
      guard combination != showGridHotkey else { return }
      showGridHotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.showGrid.rawValue)
    case .sendWindow:
      guard combination != sendWindowHotkey else { return }
      sendWindowHotkey = combination
      defaults.setHotkey(combination, forKey: DefaultsKey.sendWindow.rawValue)
    default:
      guard combination != snapHotkeys[identifier] else { return }
      snapHotkeys[identifier] = combination
      defaults.setHotkey(combination, forKey: "hotkey.\(identifier.rawValue)")
    }
  }

  func resetToDefaults() {
    leftHotkey = .defaultLeft
    rightHotkey = .defaultRight
    space1Hotkey = .defaultForSpace(1)
    space2Hotkey = .defaultForSpace(2)
    space3Hotkey = .defaultForSpace(3)
    space4Hotkey = .defaultForSpace(4)
    space5Hotkey = .defaultForSpace(5)
    space6Hotkey = .defaultForSpace(6)
    space7Hotkey = .defaultForSpace(7)
    space8Hotkey = .defaultForSpace(8)
    space9Hotkey = .defaultForSpace(9)
    space10Hotkey = .defaultForSpace(10)
    space11Hotkey = .defaultForSpace(11)
    space12Hotkey = .defaultForSpace(12)
    space13Hotkey = .defaultForSpace(13)
    space14Hotkey = .defaultForSpace(14)
    space15Hotkey = .defaultForSpace(15)
    space16Hotkey = .defaultForSpace(16)
    spaceLastSpaceHotkey = .defaultLastSpace
    showGridHotkey = .defaultShowGrid
    sendWindowHotkey = .defaultSendWindow

    defaults.setHotkey(leftHotkey, forKey: DefaultsKey.left.rawValue)
    defaults.setHotkey(rightHotkey, forKey: DefaultsKey.right.rawValue)
    defaults.setHotkey(space1Hotkey, forKey: DefaultsKey.space1.rawValue)
    defaults.setHotkey(space2Hotkey, forKey: DefaultsKey.space2.rawValue)
    defaults.setHotkey(space3Hotkey, forKey: DefaultsKey.space3.rawValue)
    defaults.setHotkey(space4Hotkey, forKey: DefaultsKey.space4.rawValue)
    defaults.setHotkey(space5Hotkey, forKey: DefaultsKey.space5.rawValue)
    defaults.setHotkey(space6Hotkey, forKey: DefaultsKey.space6.rawValue)
    defaults.setHotkey(space7Hotkey, forKey: DefaultsKey.space7.rawValue)
    defaults.setHotkey(space8Hotkey, forKey: DefaultsKey.space8.rawValue)
    defaults.setHotkey(space9Hotkey, forKey: DefaultsKey.space9.rawValue)
    defaults.setHotkey(space10Hotkey, forKey: DefaultsKey.space10.rawValue)
    defaults.setHotkey(space11Hotkey, forKey: DefaultsKey.space11.rawValue)
    defaults.setHotkey(space12Hotkey, forKey: DefaultsKey.space12.rawValue)
    defaults.setHotkey(space13Hotkey, forKey: DefaultsKey.space13.rawValue)
    defaults.setHotkey(space14Hotkey, forKey: DefaultsKey.space14.rawValue)
    defaults.setHotkey(space15Hotkey, forKey: DefaultsKey.space15.rawValue)
    defaults.setHotkey(space16Hotkey, forKey: DefaultsKey.space16.rawValue)
    defaults.setHotkey(spaceLastSpaceHotkey, forKey: DefaultsKey.lastSpace.rawValue)
    defaults.setHotkey(showGridHotkey, forKey: DefaultsKey.showGrid.rawValue)
    defaults.setHotkey(sendWindowHotkey, forKey: DefaultsKey.sendWindow.rawValue)

    var snaps: [HotkeyIdentifier: HotkeyCombination] = [:]
    for identifier in HotkeyIdentifier.windowIdentifiers {
      snaps[identifier] = identifier.defaultCombination
      defaults.setHotkey(identifier.defaultCombination, forKey: "hotkey.\(identifier.rawValue)")
    }
    snapHotkeys = snaps
  }

  func combination(for identifier: HotkeyIdentifier) -> HotkeyCombination {
    switch identifier {
    case .left: return leftHotkey
    case .right: return rightHotkey
    case .space1: return space1Hotkey
    case .space2: return space2Hotkey
    case .space3: return space3Hotkey
    case .space4: return space4Hotkey
    case .space5: return space5Hotkey
    case .space6: return space6Hotkey
    case .space7: return space7Hotkey
    case .space8: return space8Hotkey
    case .space9: return space9Hotkey
    case .space10: return space10Hotkey
    case .space11: return space11Hotkey
    case .space12: return space12Hotkey
    case .space13: return space13Hotkey
    case .space14: return space14Hotkey
    case .space15: return space15Hotkey
    case .space16: return space16Hotkey
    case .lastSpace: return spaceLastSpaceHotkey
    case .showGrid: return showGridHotkey
    case .sendWindow: return sendWindowHotkey
    default: return snapHotkeys[identifier] ?? identifier.defaultCombination
    }
  }

  func isEnabled(_ identifier: HotkeyIdentifier) -> Bool {
    return enabledStates[identifier] ?? identifier.enabledByDefault
  }

  func setEnabled(_ enabled: Bool, for identifier: HotkeyIdentifier) {
    enabledStates[identifier] = enabled
    let key = "enabled.\(identifier.rawValue)"
    defaults.set(enabled, forKey: key)
  }

  /// Turns every snap, cycle and swap shortcut on or off at once (Settings and the walkthrough offer them as one
  /// switch).
  func setSnapShortcutsEnabled(_ enabled: Bool) {
    var states = enabledStates
    for identifier in HotkeyIdentifier.windowShortcutGroup {
      states[identifier] = enabled
      defaults.set(enabled, forKey: "enabled.\(identifier.rawValue)")
    }
    enabledStates = states
  }

  var snapShortcutsEnabled: Bool { HotkeyIdentifier.windowShortcutGroup.allSatisfy(isEnabled) }

  private enum DefaultsKey: String {
    case left = "hotkey.left"
    case right = "hotkey.right"
    case space1 = "hotkey.space1"
    case space2 = "hotkey.space2"
    case space3 = "hotkey.space3"
    case space4 = "hotkey.space4"
    case space5 = "hotkey.space5"
    case space6 = "hotkey.space6"
    case space7 = "hotkey.space7"
    case space8 = "hotkey.space8"
    case space9 = "hotkey.space9"
    case space10 = "hotkey.space10"
    case space11 = "hotkey.space11"
    case space12 = "hotkey.space12"
    case space13 = "hotkey.space13"
    case space14 = "hotkey.space14"
    case space15 = "hotkey.space15"
    case space16 = "hotkey.space16"
    case lastSpace = "hotkey.lastSpace"
    case showGrid = "hotkey.showGrid"
    case sendWindow = "hotkey.sendWindow"
  }
}

extension UserDefaults {
  fileprivate func hotkey(forKey key: String) -> HotkeyCombination? {
    guard let data = data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(HotkeyCombination.self, from: data)
  }

  fileprivate func setHotkey(_ hotkey: HotkeyCombination, forKey key: String) {
    if let data = try? JSONEncoder().encode(hotkey) {
      set(data, forKey: key)
    }
  }
}

extension NSEvent.ModifierFlags {
  var carbonMask: UInt32 {
    var mask: UInt32 = 0
    if contains(.command) { mask |= UInt32(cmdKey) }
    if contains(.option) { mask |= UInt32(optionKey) }
    if contains(.control) { mask |= UInt32(controlKey) }
    if contains(.shift) { mask |= UInt32(shiftKey) }
    return mask
  }
}

/// Which action already uses a shortcut. Settings and the walkthrough both ask this before accepting a new one.
enum HotkeyConflict {
  static func identifier(
    using combination: HotkeyCombination, among assignments: [(HotkeyIdentifier, HotkeyCombination)],
    excluding identifier: HotkeyIdentifier
  ) -> HotkeyIdentifier? {
    assignments.first { $0.0 != identifier && $0.1 == combination }?.0
  }
}

extension HotkeyIdentifier {
  /// The shortcut this action has before you change it.
  var defaultCombination: HotkeyCombination {
    switch self {
    case .left: return .defaultLeft
    case .right: return .defaultRight
    case .lastSpace: return .defaultLastSpace
    case .showGrid: return .defaultShowGrid
    case .sendWindow: return .defaultSendWindow
    case .moveWorkspaceToNextDisplay:
      return HotkeyCombination(
        keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey | cmdKey), displayKey: "M",
        keyEquivalent: "m")
    case .newWorkspaceFromWindows:
      return HotkeyCombination(
        keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey | cmdKey), displayKey: "N",
        keyEquivalent: "n")
    case .stashLeft, .stashRight, .stashTop:
      // ⌃⌥⌘[ and ] for the sides, ⌃⌥⌘\ for the top.
      let (keyCode, key): (Int, String) =
        self == .stashLeft ? (kVK_ANSI_LeftBracket, "[") : self == .stashRight ? (kVK_ANSI_RightBracket, "]")
        : (kVK_ANSI_Backslash, "\\")
      return HotkeyCombination(
        keyCode: UInt32(keyCode), modifiers: UInt32(controlKey | optionKey | cmdKey), displayKey: key,
        keyEquivalent: key)
    case .stashNext:
      // ⌃⌥⌘', beside the stash keys.
      return HotkeyCombination(
        keyCode: UInt32(kVK_ANSI_Quote), modifiers: UInt32(controlKey | optionKey | cmdKey), displayKey: "'",
        keyEquivalent: "'")
    default:
      if let snapAction { return .defaultSnap(snapAction) }
      if isStacking { return .defaultStacking(self) }
      return .defaultForSpace(Int(rawValue.dropFirst("space".count)) ?? 1)
    }
  }
}

extension HotkeyStore {
  /// Every action with its current shortcut.
  var assignments: [(HotkeyIdentifier, HotkeyCombination)] {
    HotkeyIdentifier.allCases.map { ($0, combination(for: $0)) }
  }

  /// The action already using `combination`, if giving it to `identifier` (or turning `identifier` on with it)
  /// would make one key do two things. Only actions that are on count: a turned-off action keeps its shortcut
  /// but doesn't hold the key.
  func conflict(_ combination: HotkeyCombination, for identifier: HotkeyIdentifier) -> HotkeyIdentifier? {
    HotkeyConflict.identifier(
      using: combination, among: assignments.filter { isEnabled($0.0) }, excluding: identifier)
  }
}
