import AppKit
import Combine

private final class FlippedStackView: NSStackView {
  override var isFlipped: Bool { true }
}

/// Settings → Stacking: each Space's layout (its bindings and pause switch), the global pause, and the ignore
/// list. Bindings are made from the ⌃⌥⌘-click window menu or `cubicle bind`; here they are reviewed and removed.
final class StackingSettingsViewController: NSViewController {
  private let store: StackingStore
  private let stack = FlippedStackView()
  private let pauseEverywhere = NSButton(checkboxWithTitle: "Pause stacking everywhere", target: nil, action: nil)
  private let ignorePopUp = NSPopUpButton(frame: .zero, pullsDown: true)
  private var cancellables = Set<AnyCancellable>()

  init(store: StackingStore = .shared) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 550, height: 350))
    let description = NSTextField(wrappingLabelWithString:
      "Bind an app or window to a zone from the ⌃⌥⌘-click window menu or `cubicle bind`. Its windows on that "
      + "Space stack in the zone, now and when they open later.")
    description.textColor = .secondaryLabelColor
    description.translatesAutoresizingMaskIntoConstraints = false

    pauseEverywhere.target = self
    pauseEverywhere.action = #selector(pauseEverywhereChanged(_:))
    pauseEverywhere.translatesAutoresizingMaskIntoConstraints = false

    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = stack

    ignorePopUp.target = self
    ignorePopUp.action = #selector(ignoreApp(_:))
    ignorePopUp.translatesAutoresizingMaskIntoConstraints = false
    ignorePopUp.menu?.delegate = self

    for subview in [description, pauseEverywhere, scroll, ignorePopUp] { view.addSubview(subview) }
    NSLayoutConstraint.activate([
      description.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
      description.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      description.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      pauseEverywhere.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 12),
      pauseEverywhere.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      scroll.topAnchor.constraint(equalTo: pauseEverywhere.bottomAnchor, constant: 12),
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      scroll.bottomAnchor.constraint(equalTo: ignorePopUp.topAnchor, constant: -12),
      stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      ignorePopUp.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      ignorePopUp.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
    ])
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    store.$settings.combineLatest(SpaceCatalog.shared.$displays)
      .receive(on: RunLoop.main)
      .sink { [weak self] settings, displays in self?.show(settings, displays) }
      .store(in: &cancellables)
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    SpaceCatalog.shared.refresh()
  }

  private func show(_ settings: StackingSettings, _ displays: [SpaceDisplay]) {
    pauseEverywhere.state = settings.pausedEverywhere ? .on : .off
    for item in stack.arrangedSubviews {
      stack.removeArrangedSubview(item)
      item.removeFromSuperview()
    }

    var shown = Set<String>()
    for display in displays {
      if displays.count > 1 { add(heading(display.name)) }
      for space in display.spaces {
        guard let key = space.identity.key else { continue }
        shown.insert(key)
        let title = SpaceNameStore.shared.name(for: key).map { "Space \(space.index + 1): \($0)" }
          ?? "Space \(space.index + 1)"
        let pause = NSButton(checkboxWithTitle: "Paused", target: self, action: #selector(pauseChanged(_:)))
        pause.identifier = NSUserInterfaceItemIdentifier(key)
        pause.state = settings.pausedSpaces.contains(key) ? .on : .off
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        add(row([label, pause]))
        showBindings(settings.bindings.filter { $0.spaceKey == key })
      }
    }

    // Bindings saved for Spaces that have since been removed stay until removed here.
    let orphans = settings.bindings.filter { !shown.contains($0.spaceKey) }
    if !orphans.isEmpty {
      add(heading("Spaces that no longer exist"))
      showBindings(orphans)
    }

    add(heading("Ignored apps"))
    if settings.ignored.isEmpty { add(secondary("None. Sheets, dialogs and full-screen windows are always left alone.")) }
    for (bundleID, name) in settings.ignored.sorted(by: { $0.value < $1.value }) {
      let remove = removeButton(#selector(unignore(_:)), bundleID)
      add(row([NSTextField(labelWithString: name), remove]))
    }
    rebuildIgnoreMenu()
  }

  private func showBindings(_ bindings: [StackBinding]) {
    if bindings.isEmpty {
      add(secondary("    No bindings"))
      return
    }
    for binding in bindings {
      let zone = NSTextField(labelWithString: binding.zone?.displayName ?? "Space only")
      zone.textColor = .secondaryLabelColor
      zone.widthAnchor.constraint(equalToConstant: 150).isActive = true
      let name = NSTextField(labelWithString: binding.label)
      name.lineBreakMode = .byTruncatingTail
      name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let spacer = NSView()
      spacer.widthAnchor.constraint(equalToConstant: 12).isActive = true
      add(row([spacer, zone, name, removeButton(#selector(removeBinding(_:)), binding.id.uuidString)]))
    }
  }

  // MARK: - Building rows

  private func add(_ view: NSView) {
    stack.addArrangedSubview(view)
  }

  private func heading(_ title: String) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    return label
  }

  private func secondary(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.textColor = .secondaryLabelColor
    return label
  }

  private func row(_ views: [NSView]) -> NSStackView {
    let row = NSStackView(views: views)
    row.spacing = 8
    row.alignment = .centerY
    return row
  }

  private func removeButton(_ action: Selector, _ identifier: String) -> NSButton {
    let button = NSButton(
      image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")!, target: self,
      action: action)
    button.isBordered = false
    button.identifier = NSUserInterfaceItemIdentifier(identifier)
    return button
  }

  // MARK: - Ignore list

  /// "Ignore an App…" then each running app that isn't already ignored.
  private func rebuildIgnoreMenu() {
    ignorePopUp.removeAllItems()
    ignorePopUp.addItem(withTitle: "Ignore an App…")
    let apps = NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        && $0.bundleIdentifier.map { !store.isIgnored($0) } == true
    }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    for app in apps {
      ignorePopUp.addItem(withTitle: app.localizedName ?? app.bundleIdentifier!)
      ignorePopUp.lastItem?.representedObject = app.bundleIdentifier
    }
  }

  // MARK: - Actions

  @objc private func pauseEverywhereChanged(_ sender: NSButton) {
    store.setPausedEverywhere(sender.state == .on)
  }

  @objc private func pauseChanged(_ sender: NSButton) {
    guard let key = sender.identifier?.rawValue else { return }
    store.setPaused(sender.state == .on, spaceKey: key)
  }

  @objc private func removeBinding(_ sender: NSButton) {
    guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
    store.removeBinding(id)
  }

  @objc private func unignore(_ sender: NSButton) {
    guard let bundleID = sender.identifier?.rawValue else { return }
    store.setIgnored(false, bundleID: bundleID, appName: store.settings.ignored[bundleID] ?? bundleID)
  }

  @objc private func ignoreApp(_ sender: NSPopUpButton) {
    guard let bundleID = sender.selectedItem?.representedObject as? String else { return }
    store.setIgnored(true, bundleID: bundleID, appName: sender.selectedItem?.title ?? bundleID)
  }
}

extension StackingSettingsViewController: NSMenuDelegate {
  /// Apps launched since the pane was drawn show up when the menu opens.
  func menuNeedsUpdate(_ menu: NSMenu) {
    rebuildIgnoreMenu()
  }
}
