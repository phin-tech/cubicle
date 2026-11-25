import AppKit
import Combine
import CubicleIPC

private final class FlippedStackView: NSStackView {
  override var isFlipped: Bool { true }
}

/// Settings → Stash: how Tabs look, the stash shortcuts, the windows stashed now (moved or unstashed from here), and
/// the note colours chosen for apps.
final class StashSettingsViewController: NSViewController {
  private let stack = FlippedStackView()
  private let lookPopUp = NSPopUpButton()
  private let shortcuts = NSTextField(labelWithString: "")
  private var observers: [NSObjectProtocol] = []
  private var cancellables = Set<AnyCancellable>()

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: 380))
    let description = NSTextField(wrappingLabelWithString:
      "Stash a window against the left, right or top edge. It tucks away behind a Tab there, on every workspace; "
      + "hover the Tab to pop it out, click to keep it out, drag the Tab along the edge to move it, and right-click "
      + "it for more.")
    description.textColor = .secondaryLabelColor

    for look in StashTabLook.allCases { lookPopUp.addItem(withTitle: look.displayName) }
    lookPopUp.target = self
    lookPopUp.action = #selector(lookChanged(_:))
    shortcuts.textColor = .secondaryLabelColor

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = stack

    let lookRow = row([NSTextField(labelWithString: "Tabs:"), lookPopUp])
    let shortcutsRow = row([NSTextField(labelWithString: "Shortcuts:"), shortcuts])
    for subview in [description, lookRow, shortcutsRow, scroll] as [NSView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      description.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
      description.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      description.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      lookRow.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 14),
      lookRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      shortcutsRow.topAnchor.constraint(equalTo: lookRow.bottomAnchor, constant: 8),
      shortcutsRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      scroll.topAnchor.constraint(equalTo: shortcutsRow.bottomAnchor, constant: 16),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
      stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
    ])
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    for name in [Stash.didChange, UserDefaults.didChangeNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.showSoon() }
      })
    }
    HotkeyStore.shared.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.showSoon() }
      .store(in: &cancellables)
    show()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    show()
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  /// Redraws on the next turn of the run loop, once: a pop-up whose action stashed a window isn't pulled down
  /// mid-action, and a burst of changes redraws once.
  private var showPending = false
  private func showSoon() {
    guard !showPending else { return }
    showPending = true
    DispatchQueue.main.async { [weak self] in
      self?.showPending = false
      self?.show()
    }
  }

  private func show() {
    lookPopUp.selectItem(at: StashTabLook.allCases.firstIndex(of: Stash.shared.look) ?? 0)
    let store = HotkeyStore.shared
    shortcuts.stringValue = [HotkeyIdentifier.stashLeft, .stashRight, .stashTop].map { id in
      let keys = store.isEnabled(id) ? store.combination(for: id).displayString : "off"
      return "\(id.stashEdge!.rawValue.capitalized) \(keys)"
    }.joined(separator: "   ") + "   (change them in Keyboard)"

    for item in stack.arrangedSubviews {
      stack.removeArrangedSubview(item)
      item.removeFromSuperview()
    }
    showStashed()
    showColours()
  }

  private func showStashed() {
    let windows = Stash.shared.stashed
    let unstashAll = NSButton(title: "Unstash All", target: self, action: #selector(unstashAll))
    unstashAll.isEnabled = !windows.isEmpty
    add(row([heading("Stashed windows"), unstashAll]))
    if windows.isEmpty { add(secondary("None. Stash the window in front with its shortcut or `cubicle stash right`.")) }
    for window in windows {
      let icon = NSImageView(image: window.app?.icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!)
      icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
      icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
      let name = NSTextField(labelWithString: window.title)
      name.lineBreakMode = .byTruncatingTail
      name.toolTip = window.title
      name.widthAnchor.constraint(equalToConstant: 190).isActive = true

      let edge = NSPopUpButton()
      for each in StashEdge.allCases { edge.addItem(withTitle: each.rawValue.capitalized) }
      edge.selectItem(at: StashEdge.allCases.firstIndex(of: window.edge) ?? 0)
      edge.tag = Int(window.id)
      edge.target = self
      edge.action = #selector(edgeChanged(_:))

      let slot = NSPopUpButton()
      for each in StashSlot.allCases { slot.addItem(withTitle: each.displayName(on: window.edge)) }
      if let current = window.slot {
        slot.selectItem(at: StashSlot.allCases.firstIndex(of: current) ?? 1)
      } else {
        // Dragged somewhere between: shown as such, and picking a slot moves it there.
        slot.addItem(withTitle: "Where You Dragged It")
        slot.selectItem(at: StashSlot.allCases.count)
      }
      slot.tag = Int(window.id)
      slot.target = self
      slot.action = #selector(slotChanged(_:))

      let unstash = NSButton(title: "Unstash", target: self, action: #selector(unstash(_:)))
      unstash.tag = Int(window.id)
      add(row([icon, name, edge, slot, unstash]))
    }
  }

  private func showColours() {
    add(spacer())
    add(heading("Note colours"))
    let chosen = (UserDefaults.standard.dictionary(forKey: StashNoteColor.overridesKey) as? [String: String] ?? [:])
      .compactMapValues(StashNoteColor.init(rawValue:))
    if chosen.isEmpty {
      add(secondary("Sticky notes take their colour from the app's icon. Right-click a note to choose another."))
      return
    }
    for (bundleID, colour) in chosen.sorted(by: { Self.appName($0.key) < Self.appName($1.key) }) {
      let swatch = NSView()
      swatch.wantsLayer = true
      swatch.layer?.backgroundColor = colour.color.cgColor
      swatch.layer?.cornerRadius = 3
      swatch.layer?.borderWidth = 0.5
      swatch.layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor
      swatch.widthAnchor.constraint(equalToConstant: 14).isActive = true
      swatch.heightAnchor.constraint(equalToConstant: 14).isActive = true
      let name = NSTextField(labelWithString: "\(Self.appName(bundleID)): \(colour.displayName)")
      let reset = NSButton(title: "Use the Icon's Colour", target: self, action: #selector(resetColour(_:)))
      reset.identifier = NSUserInterfaceItemIdentifier(bundleID)
      add(row([swatch, name, reset]))
    }
  }

  private static func appName(_ bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
  }

  // MARK: - Building rows

  private func add(_ view: NSView) { stack.addArrangedSubview(view) }

  private func heading(_ title: String) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    return label
  }

  private func secondary(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.textColor = .secondaryLabelColor
    label.preferredMaxLayoutWidth = 500
    return label
  }

  private func spacer() -> NSView {
    let view = NSView()
    view.heightAnchor.constraint(equalToConstant: 6).isActive = true
    return view
  }

  private func row(_ views: [NSView]) -> NSStackView {
    let row = NSStackView(views: views)
    row.spacing = 8
    row.alignment = .centerY
    return row
  }

  // MARK: - Actions

  @objc private func lookChanged(_ sender: NSPopUpButton) {
    guard StashTabLook.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
    UserDefaults.standard.set(StashTabLook.allCases[sender.indexOfSelectedItem].rawValue, forKey: StashTabLook.defaultsKey)
  }

  @objc private func edgeChanged(_ sender: NSPopUpButton) {
    guard StashEdge.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
    Stash.shared.move(UInt32(sender.tag), to: StashEdge.allCases[sender.indexOfSelectedItem])
  }

  @objc private func slotChanged(_ sender: NSPopUpButton) {
    guard StashSlot.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
    Stash.shared.move(UInt32(sender.tag), to: StashSlot.allCases[sender.indexOfSelectedItem])
  }

  @objc private func unstash(_ sender: NSButton) {
    _ = Stash.shared.unstash(UInt32(sender.tag))
  }

  @objc private func unstashAll() {
    Stash.shared.unstashAll()
  }

  @objc private func resetColour(_ sender: NSButton) {
    guard let bundleID = sender.identifier?.rawValue else { return }
    StashNoteColor.choose(nil, for: bundleID)
    Stash.shared.refresh()
  }
}
