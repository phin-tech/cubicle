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
/// (see issue #43 for why other displays cannot be targeted yet).
@MainActor
final class SpaceGridWindow {
  static let shared = SpaceGridWindow()
  private var panel: SpaceGridPanel?

  private init() {}

  var isVisible: Bool { panel?.isVisible ?? false }

  func toggle() {
    if isVisible { close() } else { show() }
  }

  func close() {
    panel?.orderOut(nil)
    panel = nil
  }

  func show() {
    var info = ISSSpaceInfo()
    guard iss_get_space_info(&info), info.spaceCount > 0 else {
      NSSound.beep()
      return
    }

    SpaceCatalog.shared.refresh()
    let displayID = stringFromCStringBuffer(info.displayID)
    let count = Int(info.spaceCount)
    let cells = (0..<count).map { index -> SpaceGridCell in
      let identity = SpaceCatalog.shared.identity(displayIdentifier: displayID, index: UInt32(index))
      let name = SpaceNameStore.shared.name(for: identity?.key)
      return SpaceGridCell(index: index, title: name ?? String(index + 1), hasCustomName: name != nil)
    }

    let screen = Self.screen(for: info.screenID) ?? NSScreen.main
    guard let screen else { return }

    close()
    let view = SpaceGridView(cells: cells, currentIndex: Int(info.currentIndex))
    view.onActivate = { [weak self] index in self?.activate(index) }
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

  private func activate(_ index: Int) {
    close()
    DispatchQueue.main.async {
      if !iss_switch_to_index(UInt32(index)) { NSSound.beep() }
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
  var onActivate: ((Int) -> Void)? {
    get { cellsView.onActivate }
    set { cellsView.onActivate = newValue }
  }
  var onCancel: (() -> Void)? {
    get { cellsView.onCancel }
    set { cellsView.onCancel = newValue }
  }

  init(cells: [SpaceGridCell], currentIndex: Int) {
    cellsView = SpaceGridCellsView(cells: cells, currentIndex: currentIndex)
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
  var onActivate: ((Int) -> Void)?
  var onCancel: (() -> Void)?

  private let cells: [SpaceGridCell]
  private let currentIndex: Int
  private var selected: Int
  private var query = ""
  private var matchIndices: [Int]
  private let headerHeight: CGFloat = 30
  private let padding: CGFloat = 20
  private let gap: CGFloat = 12
  private let cellSize = NSSize(width: 150, height: 90)

  init(cells: [SpaceGridCell], currentIndex: Int) {
    self.cells = cells
    self.currentIndex = currentIndex
    self.selected = cells.indices.contains(currentIndex) ? currentIndex : 0
    self.matchIndices = cells.map(\.index)
    super.init(frame: .zero)
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
    let text = query.isEmpty ? "Type to search  ·  1–9 to jump" : "Search: \(query)"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14, weight: .regular),
      .foregroundColor: NSColor.white.withAlphaComponent(query.isEmpty ? 0.45 : 0.95),
    ]
    NSAttributedString(string: text, attributes: attributes)
      .draw(at: NSPoint(x: padding, y: padding - 6))
  }

  private func setQuery(_ newQuery: String) {
    query = newQuery
    matchIndices = SpaceGridLayout.matches(in: cells, query: query, excluding: currentIndex)
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

  private func activateSelected() {
    if matchIndices.contains(selected) { onActivate?(selected) } else { NSSound.beep() }
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
    case 36, 76: activateSelected()
    case 49:
      if searching { setQuery(query + " ") } else { activateSelected() }
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
          onActivate?(index)
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
      if matchIndices.contains(index) { onActivate?(index) }
    } else {
      onCancel?()
    }
  }
}
