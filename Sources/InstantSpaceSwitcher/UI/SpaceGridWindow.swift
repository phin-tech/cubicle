import AppKit
import ISS

struct SpaceGridCell: Equatable {
  let index: Int
  let title: String
  let hasCustomName: Bool
}

enum SpaceGridDirection {
  case left, right, up, down
}

/// Pure layout and navigation rules for the grid, kept free of AppKit so they can be unit tested.
enum SpaceGridLayout {
  static func columns(for count: Int) -> Int {
    guard count > 0 else { return 1 }
    return max(1, Int(ceil(Double(count).squareRoot())))
  }

  static func rows(for count: Int) -> Int {
    guard count > 0 else { return 0 }
    return (count + columns(for: count) - 1) / columns(for: count)
  }

  /// Moves the selection in reading order; a move that would leave the grid keeps the selection.
  static func move(_ selected: Int, _ direction: SpaceGridDirection, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let columns = columns(for: count)
    let next: Int
    switch direction {
    case .left: next = selected - 1
    case .right: next = selected + 1
    case .up: next = selected - columns
    case .down: next = selected + columns
    }
    return (0..<count).contains(next) ? next : selected
  }

  /// Maps a typed digit ("1"..."9") to a cell index, or nil when that Space does not exist.
  static func index(forDigit digit: Character, count: Int) -> Int? {
    guard let value = digit.wholeNumberValue, value >= 1, value - 1 < count else { return nil }
    return value - 1
  }

  private static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  /// How well `title` matches `query` (nil when it does not match):
  /// 3 = prefix, 2 = substring, 1 = the query's letters appear in order ("ino" matches "innopts").
  static func score(_ title: String, query: String) -> Int? {
    let needle = fold(query.trimmingCharacters(in: .whitespaces))
    guard !needle.isEmpty else { return 0 }
    let haystack = fold(title)
    if haystack.hasPrefix(needle) { return 3 }
    if haystack.contains(needle) { return 2 }
    var remaining = haystack[...]
    for character in needle where !character.isWhitespace {
      guard let found = remaining.firstIndex(of: character) else { return nil }
      remaining = remaining[remaining.index(after: found)...]
    }
    return 1
  }

  /// Indices (in cell order) of cells matching `query`, fuzzily. An empty query matches every cell.
  /// `excluding` drops one cell, used to ignore the Space you are already on, but only while searching.
  static func matches(in cells: [SpaceGridCell], query: String, excluding: Int? = nil) -> [Int] {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return cells.map(\.index) }
    return cells.filter { $0.index != excluding && score($0.title, query: query) != nil }.map(\.index)
  }

  /// The best-ranked of `matches` (ties go to the earliest cell).
  static func bestMatch(in cells: [SpaceGridCell], query: String, among matches: [Int]) -> Int? {
    var best: (index: Int, score: Int)?
    for index in matches {
      guard let score = score(cells[index].title, query: query) else { continue }
      if best == nil || score > best!.score { best = (index, score) }
    }
    return best?.index
  }

  /// Indices into `titles` that match `query`, best first (ties keep their original order).
  /// An empty query returns every index in order.
  static func ranked(titles: [String], query: String) -> [Int] {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return Array(titles.indices) }
    return titles.indices
      .compactMap { index in score(titles[index], query: query).map { (index, $0) } }
      .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
      .map { $0.0 }
  }

  /// Steps through `matches` cyclically from `selected`; an unmatched selection jumps to the first match.
  static func step(from selected: Int, by delta: Int, among matches: [Int]) -> Int {
    guard !matches.isEmpty else { return selected }
    guard let position = matches.firstIndex(of: selected) else { return matches[0] }
    let next = (position + delta) % matches.count
    return matches[next < 0 ? next + matches.count : next]
  }
}

/// A summoned overlay showing the Spaces of the display under the cursor.
///
/// `iss_switch_to_index` acts on the display under the cursor, so the grid is limited to that display
/// (see issue #43 for why other displays cannot be targeted yet). In send mode it shows the Spaces of the
/// focused window's display instead, and picking one moves the window there.
@MainActor
final class SpaceGridWindow {
  static let shared = SpaceGridWindow()
  private var panel: SpaceGridPanel?

  private init() {}

  var isVisible: Bool { panel?.isVisible ?? false }

  func toggle() {
    if isVisible { close() } else { show() }
  }

  /// Opens the grid in send mode for the focused window, or closes the grid.
  func toggleSend() {
    if isVisible { return close() }
    guard AXIsProcessTrusted() else { return Self.report("Accessibility is not granted to Cubicle.") }
    guard let window = WindowMover.focusedWindow() else { return Self.report("Could not find the focused window.") }
    guard let spaces = WindowSender.spaces(for: window) else {
      return Self.report("Could not read the Spaces on the window's display.")
    }
    present(spaces, sending: window)
  }

  func close() {
    panel?.orderOut(nil)
    panel = nil
  }

  func show() {
    guard let spaces = SpaceCatalog.shared.spacesUnderCursor() else {
      NSSound.beep()
      return
    }
    present(spaces, sending: nil)
  }

  /// `sending` is the window send mode moves; without it, the grid switches Spaces, and ⇧Return sends the
  /// focused window instead.
  private func present(_ spaces: DisplaySpaces, sending: WindowMover.Target?) {
    let screen = Self.screen(for: spaces.screenID) ?? NSScreen.main
    guard let screen else { return }

    close()
    let view = SpaceGridView(
      cells: Self.cells(for: spaces), currentIndex: spaces.currentIndex, sendingName: sending?.displayName)
    view.onActivate = { [weak self] index, send in
      guard let self else { return }
      self.close()
      if send {
        self.send(sending, toIndex: index, spaces: spaces)
      } else {
        DispatchQueue.main.async {
          if !iss_switch_to_index(UInt32(index)) { NSSound.beep() }
        }
      }
    }
    view.onCancel = { [weak self] in self?.close() }

    let size = view.preferredSize(maximum: screen.visibleFrame.insetBy(dx: 40, dy: 40).size)
    let panel = SpaceGridPanel(
      contentRect: NSRect(
        x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
        width: size.width, height: size.height))
    panel.onResignKey = { [weak self] in self?.close() }
    view.frame = NSRect(origin: .zero, size: size)
    panel.contentView = view
    self.panel = panel
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(view.cellsView)
  }

  /// The grid's panel doesn't activate Cubicle, so the focused window is still the one you were using.
  private func send(_ window: WindowMover.Target?, toIndex index: Int, spaces: DisplaySpaces) {
    guard AXIsProcessTrusted() else { return Self.report("Accessibility is not granted to Cubicle.", screenID: spaces.screenID) }
    guard let window = window ?? WindowMover.focusedWindow() else {
      return Self.report("Could not find the focused window.", screenID: spaces.screenID)
    }
    // The index means a Space on the grid's display.
    if spaces.screenID != 0, !CGDisplayBounds(spaces.screenID).contains(window.anchor) {
      return Self.report("\(window.appName) is on another display.", screenID: spaces.screenID)
    }
    WindowSender.sendShowingProgress(window, toIndex: index, screenID: spaces.screenID)
  }

  private static func report(_ message: String, screenID: UInt32 = 0) {
    NSSound.beep()
    OSDWindow.shared.show(message: message, screenID: screenID, force: true, duration: 2.5)
  }

  /// A display's Spaces as grid cells, named where you named them.
  static func cells(for spaces: DisplaySpaces) -> [SpaceGridCell] {
    spaces.display.spaces.enumerated().map { index, space in
      let name = SpaceNameStore.shared.name(for: space.identity.key)
      return SpaceGridCell(index: index, title: name ?? String(index + 1), hasCustomName: name != nil)
    }
  }

  private static func screen(for id: UInt32) -> NSScreen? {
    if id != 0 {
      return NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
      }
    }
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
  }
}

private final class SpaceGridPanel: NSPanel {
  var onResignKey: (() -> Void)?

  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    hidesOnDeactivate = false
    acceptsMouseMovedEvents = true
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func resignKey() {
    super.resignKey()
    onResignKey?()
  }
}

final class SpaceGridView: NSVisualEffectView {
  fileprivate let cellsView: SpaceGridCellsView
  var onActivate: ((Int, Bool) -> Void)? {
    get { cellsView.onActivate }
    set { cellsView.onActivate = newValue }
  }
  var onCancel: (() -> Void)? {
    get { cellsView.onCancel }
    set { cellsView.onCancel = newValue }
  }

  init(cells: [SpaceGridCell], currentIndex: Int, sendingName: String? = nil) {
    cellsView = SpaceGridCellsView(cells: cells, currentIndex: currentIndex, sendingName: sendingName)
    super.init(frame: .zero)
    material = .hudWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 18
    layer?.masksToBounds = true
    addSubview(cellsView)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func preferredSize(maximum: NSSize) -> NSSize {
    cellsView.preferredSize(maximum: maximum)
  }

  override func layout() {
    super.layout()
    cellsView.frame = bounds
  }
}

final class SpaceGridCellsView: NSView {
  /// The chosen Space, and whether to send the window there rather than switch.
  var onActivate: ((Int, Bool) -> Void)?
  var onCancel: (() -> Void)?

  private let cells: [SpaceGridCell]
  private let currentIndex: Int
  /// Set in send mode: the window being sent. Its own Space can't be picked.
  private let sendingName: String?
  private var sendMode: Bool { sendingName != nil }
  private var selected: Int
  private var query = ""
  private var matchIndices: [Int]
  private let headerHeight: CGFloat = 30
  private let padding: CGFloat = 20
  private let gap: CGFloat = 12
  private let cellSize = NSSize(width: 150, height: 90)

  init(cells: [SpaceGridCell], currentIndex: Int, sendingName: String? = nil) {
    self.cells = cells
    self.currentIndex = currentIndex
    self.sendingName = sendingName
    self.selected = cells.indices.contains(currentIndex) ? currentIndex : 0
    self.matchIndices = cells.map(\.index)
    super.init(frame: .zero)
    if sendMode {
      matchIndices.removeAll { $0 == currentIndex }
      if cells.count > 1 { selected = (currentIndex + 1) % cells.count }
    }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  func preferredSize(maximum: NSSize) -> NSSize {
    let columns = CGFloat(SpaceGridLayout.columns(for: cells.count))
    let rows = CGFloat(SpaceGridLayout.rows(for: cells.count))
    let width = 2 * padding + columns * cellSize.width + (columns - 1) * gap
    let height = 2 * padding + headerHeight + rows * cellSize.height + (rows - 1) * gap
    return NSSize(width: min(width, maximum.width), height: min(height, maximum.height))
  }

  private func rect(for index: Int) -> NSRect {
    let columns = SpaceGridLayout.columns(for: cells.count)
    let column = index % columns
    let row = index / columns
    return NSRect(
      x: padding + CGFloat(column) * (cellSize.width + gap),
      y: padding + headerHeight + CGFloat(row) * (cellSize.height + gap),
      width: cellSize.width, height: cellSize.height)
  }

  private func index(at point: NSPoint) -> Int? {
    cells.indices.first { rect(for: $0).contains(point) }
  }

  override func draw(_ dirtyRect: NSRect) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingTail

    drawHeader()

    for cell in cells {
      let frame = rect(for: cell.index)
      let path = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
      let isSelected = cell.index == selected
      let isMatch = matchIndices.contains(cell.index)

      (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.85)
        : NSColor.white.withAlphaComponent(isMatch ? 0.08 : 0.03))
        .setFill()
      path.fill()

      if cell.index == currentIndex {
        NSColor.white.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 2
        path.stroke()
      }

      let font = NSFont.systemFont(ofSize: cell.hasCustomName ? 17 : 34, weight: .medium)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.white.withAlphaComponent(isMatch ? 1 : 0.25),
        .paragraphStyle: paragraph,
      ]
      let text = NSAttributedString(string: cell.title, attributes: attributes)
      let inset = frame.insetBy(dx: 10, dy: 8)
      let height = min(inset.height, ceil(text.boundingRect(
        with: NSSize(width: inset.width, height: inset.height),
        options: [.usesLineFragmentOrigin]).height))
      text.draw(
        with: NSRect(x: inset.minX, y: inset.midY - height / 2, width: inset.width, height: height),
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
  }

  private func drawHeader() {
    let text: String
    if !query.isEmpty {
      text = "Search: \(query)"
    } else if let sendingName {
      text = "Send “\(sendingName)” to…"
    } else {
      text = "Type to search  ·  1–9 to jump  ·  ⇧↩ sends the window"
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14, weight: .regular),
      .foregroundColor: NSColor.white.withAlphaComponent(query.isEmpty && !sendMode ? 0.45 : 0.95),
      .paragraphStyle: paragraph,
    ]
    NSAttributedString(string: text, attributes: attributes)
      .draw(in: NSRect(x: padding, y: padding - 6, width: bounds.width - 2 * padding, height: headerHeight))
  }

  private func setQuery(_ newQuery: String) {
    query = newQuery
    matchIndices = SpaceGridLayout.matches(in: cells, query: query, excluding: currentIndex)
    if sendMode { matchIndices.removeAll { $0 == currentIndex } }
    if let best = SpaceGridLayout.bestMatch(in: cells, query: query, among: matchIndices) {
      selected = best
    }
    needsDisplay = true
  }

  private func select(_ index: Int) {
    guard index != selected else { return }
    selected = index
    needsDisplay = true
  }

  private func navigate(_ direction: SpaceGridDirection) {
    if query.isEmpty {
      select(SpaceGridLayout.move(selected, direction, count: cells.count))
    } else {
      let delta = (direction == .left || direction == .up) ? -1 : 1
      select(SpaceGridLayout.step(from: selected, by: delta, among: matchIndices))
    }
  }

  /// In send mode everything sends; elsewhere ⇧ does.
  private func activate(_ index: Int, shift: Bool = false) {
    if matchIndices.contains(index) { onActivate?(index, sendMode || shift) } else { NSSound.beep() }
  }

  override func keyDown(with event: NSEvent) {
    if !event.modifierFlags.intersection([.command, .control]).isEmpty {
      NSSound.beep()
      return
    }
    let searching = !query.isEmpty
    switch event.keyCode {
    case 123: navigate(.left)
    case 124: navigate(.right)
    case 125: navigate(.down)
    case 126: navigate(.up)
    case 36, 76: activate(selected, shift: event.modifierFlags.contains(.shift))
    case 49:
      if searching { setQuery(query + " ") } else { activate(selected) }
    case 51:
      if searching { setQuery(String(query.dropLast())) }
    case 53:
      if searching { setQuery("") } else { onCancel?() }
    default:
      guard let characters = event.characters, !characters.isEmpty,
        characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
      else {
        NSSound.beep()
        return
      }
      if !searching, let digit = characters.first, digit.isNumber {
        if let index = SpaceGridLayout.index(forDigit: digit, count: cells.count) {
          activate(index)
        } else {
          NSSound.beep()
        }
        return
      }
      setQuery(query + characters)
    }
  }

  override func mouseMoved(with event: NSEvent) {
    if let index = index(at: convert(event.locationInWindow, from: nil)), matchIndices.contains(index) {
      select(index)
    }
  }

  override func mouseDown(with event: NSEvent) {
    if let index = index(at: convert(event.locationInWindow, from: nil)) {
      if matchIndices.contains(index) { activate(index, shift: event.modifierFlags.contains(.shift)) }
    } else {
      onCancel?()
    }
  }
}
