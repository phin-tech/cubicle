import AppKit
import ISS
import ServiceManagement

final class GeneralSettingsViewController: NSViewController {
  private let windowClickMenuCheckbox = NSButton(
    checkboxWithTitle: "⌃⌥⌘-click a window to send it to another Space", target: nil, action: nil)
  private let stagingPopup = NSPopUpButton()
  private var screenObserver: NSObjectProtocol?
  private let stagingShutdownCheckbox = NSButton(
    checkboxWithTitle: "Automatically turn off staging display when idle", target: nil, action: nil)
  private let stagingTimeoutField = NSTextField(string: "10")
  private let stagingTimeoutLabel = NSTextField(labelWithString: "Turn off after:")

  private let showOSDCheckbox = NSButton(
    checkboxWithTitle: "Show on-screen display when switching spaces", target: nil, action: nil)
  private let osdDurationPopup = NSPopUpButton()
  private let osdDurationLabel = NSTextField(labelWithString: "Duration:")
  private let overlayDetectionCheckbox = NSButton(
    checkboxWithTitle: "Enable Mission Control/Exposé detection (experimental)", target: nil, action: nil)
  private let showOSDInMissionControlCheckbox = NSButton(
    checkboxWithTitle: "Show on-screen display in Mission Control", target: nil, action: nil)
  private let swipeOverrideCheckbox = NSButton(
    checkboxWithTitle: "Override swipe gesture", target: nil, action: nil)
  private let animationSpeedPopup = NSPopUpButton()
  private let animationSpeedLabel = NSTextField(labelWithString: "Animation Speed:")
  private let launchAtLoginCheckbox = NSButton(
    checkboxWithTitle: "Launch at login", target: nil, action: nil)
  private let hideMenuBarIconCheckbox = NSButton(
    checkboxWithTitle: "Hide menu bar icon", target: nil, action: nil)
  private let showNameInMenuBarCheckbox = NSButton(
    checkboxWithTitle: "Show the Space's name in the menu bar", target: nil, action: nil)

  private let cliButton = NSButton(title: "Install 'cubicle' command", target: nil, action: nil)
  private let cliStatusLabel = NSTextField(labelWithString: "")
  private let cliExecutable = CLIInstaller.bundledExecutable()
  private let autoUpdateCheckbox = NSButton(
    checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
  private let betaUpdatesCheckbox = NSButton(
    checkboxWithTitle: "Include beta versions", target: nil, action: nil)
  private let checkNowButton = NSButton(title: "Check for Updates…", target: nil, action: nil)

  private let durationPresets = [100, 200, 300, 500, 750, 1000]
  private let animationSpeedOptions = ["Normal", "Fast", "Faster", "Fastest", "Instant"]
  private let animationSpeedValues: [Double] = [40.0, 50.0, 60.0, 80.0, 2000.0]

  private let defaults = UserDefaults.standard

  override func loadView() {
    self.view = FormView()
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    setupUI()
    loadSettings()
    refreshCLIStatus()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    refreshCLIStatus()
    refreshStagingDisplays()
    screenObserver = screenObserver ?? NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshStagingDisplays() }
    }
  }

  private func setupUI() {
    guard let formView = view as? FormView else { return }

    if formView.hasRows { return }

    // Targets/Actions
    showOSDCheckbox.target = self
    showOSDCheckbox.action = #selector(showOSDChanged)
    osdDurationPopup.target = self
    osdDurationPopup.action = #selector(osdDurationChanged)
    overlayDetectionCheckbox.target = self
    overlayDetectionCheckbox.action = #selector(overlayDetectionChanged)
    showOSDInMissionControlCheckbox.target = self
    showOSDInMissionControlCheckbox.action = #selector(showOSDInMissionControlChanged)
    swipeOverrideCheckbox.target = self
    swipeOverrideCheckbox.action = #selector(swipeOverrideChanged)
    animationSpeedPopup.target = self
    animationSpeedPopup.action = #selector(animationSpeedChanged)
    launchAtLoginCheckbox.target = self
    launchAtLoginCheckbox.action = #selector(launchAtLoginChanged)
    hideMenuBarIconCheckbox.target = self
    hideMenuBarIconCheckbox.action = #selector(hideMenuBarIconChanged)
    showNameInMenuBarCheckbox.target = self
    showNameInMenuBarCheckbox.action = #selector(showNameInMenuBarChanged)

    // Populate data
    for duration in durationPresets { osdDurationPopup.addItem(withTitle: "\(duration)ms") }
    for speed in animationSpeedOptions { animationSpeedPopup.addItem(withTitle: speed) }

    // System
    let systemLabel = NSTextField(labelWithString: "System:")
    formView.addRow(label: systemLabel, control: launchAtLoginCheckbox)
    formView.addRow(label: nil, control: hideMenuBarIconCheckbox)
    formView.addRow(label: nil, control: showNameInMenuBarCheckbox)
    formView.addRow(label: nil, control: swipeOverrideCheckbox)

    let experimentalTitle = NSMutableAttributedString(string: "Enable Mission Control/Exposé detection\n")
    let sublabel = NSAttributedString(
      string: "Experimental—may be flaky",
      attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor
      ])
    experimentalTitle.append(sublabel)
    overlayDetectionCheckbox.attributedTitle = experimentalTitle
    
    formView.addRow(label: nil, control: overlayDetectionCheckbox)
    formView.addSectionSpacing()

    stagingShutdownCheckbox.target = self
    stagingShutdownCheckbox.action = #selector(stagingShutdownChanged)
    stagingTimeoutField.target = self
    stagingTimeoutField.action = #selector(stagingTimeoutChanged)
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 3600
    formatter.allowsFloats = false
    stagingTimeoutField.formatter = formatter
    stagingTimeoutField.widthAnchor.constraint(equalToConstant: 70).isActive = true
    stagingTimeoutField.toolTip = "1–3600 seconds. Each completed move restarts the countdown."
    let timeoutRow = NSStackView(views: [stagingTimeoutField, NSTextField(labelWithString: "seconds (1–3600)")])
    timeoutRow.spacing = 8
    windowClickMenuCheckbox.target = self
    windowClickMenuCheckbox.action = #selector(windowClickMenuChanged)
    formView.addRow(label: NSTextField(labelWithString: "Window Moves:"), control: windowClickMenuCheckbox)
    stagingPopup.target = self
    stagingPopup.action = #selector(stagingDisplayChanged)
    formView.addRow(label: NSTextField(labelWithString: "Stage windows on:"), control: stagingPopup)
    let stagingDisplayHint = NSTextField(
      wrappingLabelWithString: "A moving window waits here while its own display switches. A spare real display "
        + "avoids creating the virtual one; windows on it fall back to the virtual display.")
    stagingDisplayHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    stagingDisplayHint.textColor = .secondaryLabelColor
    stagingDisplayHint.preferredMaxLayoutWidth = 360
    formView.addRow(label: nil, control: stagingDisplayHint)
    formView.addRow(label: nil, control: stagingShutdownCheckbox)
    formView.addRow(label: stagingTimeoutLabel, control: timeoutRow)
    let stagingHint = NSTextField(labelWithString: "Turn off automatic shutdown to keep repeated moves fast.")
    stagingHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    stagingHint.textColor = .secondaryLabelColor
    formView.addRow(label: nil, control: stagingHint)
    formView.addSectionSpacing()

    // Updates (Sparkle; not in the SwiftPM development build)
    if UpdateChecker.isAvailable {
      autoUpdateCheckbox.target = self
      autoUpdateCheckbox.action = #selector(autoUpdateChanged)
      betaUpdatesCheckbox.target = self
      betaUpdatesCheckbox.action = #selector(betaUpdatesChanged)
      checkNowButton.target = self
      checkNowButton.action = #selector(checkNowClicked)
      formView.addRow(label: NSTextField(labelWithString: "Updates:"), control: autoUpdateCheckbox)
      formView.addRow(label: nil, control: betaUpdatesCheckbox)
      formView.addRow(label: nil, control: checkNowButton)
      formView.addSectionSpacing()
    }

    // Command line tool
    cliButton.target = self
    cliButton.action = #selector(cliButtonClicked)
    cliStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    cliStatusLabel.textColor = .secondaryLabelColor
    formView.addRow(label: NSTextField(labelWithString: "Command Line:"), control: cliButton)
    formView.addRow(label: nil, control: cliStatusLabel)
    formView.addSectionSpacing()

    // Animation Speed
    let animationLabel = NSTextField(labelWithString: "Animation Speed:")
    formView.addRow(label: animationLabel, control: animationSpeedPopup)
    formView.addSectionSpacing()

    // OSD
    let osdLabel = NSTextField(labelWithString: "On-Screen Display:")
    showOSDCheckbox.title = "Show for"
    showOSDInMissionControlCheckbox.title = "Show in Mission Control"
    
    let osdContainer = NSStackView()
    osdContainer.orientation = .horizontal
    osdContainer.spacing = 8
    osdContainer.addArrangedSubview(showOSDCheckbox)
    osdContainer.addArrangedSubview(osdDurationPopup)
    osdContainer.addArrangedSubview(NSTextField(labelWithString: "when switching spaces"))
    
    formView.addRow(label: osdLabel, control: osdContainer)
    formView.addRow(label: nil, control: showOSDInMissionControlCheckbox)
  }

  private func loadSettings() {
    windowClickMenuCheckbox.state = WindowClickMenu.isEnabledSetting ? .on : .off
    stagingShutdownCheckbox.state = VirtualDisplaySession.automaticShutdown ? .on : .off
    stagingTimeoutField.integerValue = VirtualDisplaySession.idleSeconds
    refreshStagingDisplays()

    let showOSD = defaults.bool(forKey: "showOSD")
    showOSDCheckbox.state = showOSD ? .on : .off

    let durationMs = defaults.object(forKey: "osdDurationMs") as? Int ?? 200
    if let index = durationPresets.firstIndex(of: durationMs) {
      osdDurationPopup.selectItem(at: index)
    } else {
      osdDurationPopup.selectItem(at: 1)
    }

    osdDurationPopup.isEnabled = showOSD
    overlayDetectionCheckbox.state = defaults.object(forKey: "overlayDetectionEnabled") as? Bool ?? true ? .on : .off
    let overlayDetectionEnabled = overlayDetectionCheckbox.state == .on
    showOSDInMissionControlCheckbox.isEnabled = showOSD && overlayDetectionEnabled
    showOSDInMissionControlCheckbox.state = defaults.bool(forKey: "showOSDInMissionControl") ? .on : .off

    hideMenuBarIconCheckbox.state = defaults.bool(forKey: "hideMenuBarIcon") ? .on : .off
    showNameInMenuBarCheckbox.state = MenuBarLabel.isEnabled ? .on : .off
    if UpdateChecker.isAvailable {
      autoUpdateCheckbox.state = UpdateChecker.shared.automaticChecks ? .on : .off
      betaUpdatesCheckbox.state = UpdateChecker.shared.betaUpdates ? .on : .off
    }
    swipeOverrideCheckbox.state = defaults.bool(forKey: "swipeOverride") ? .on : .off

    let animationSpeedValue = defaults.double(forKey: "gestureSpeed")
    if animationSpeedValue > 0 {
      if let index = animationSpeedValues.firstIndex(where: { $0 == animationSpeedValue }) {
        animationSpeedPopup.selectItem(at: index)
      } else {
        animationSpeedPopup.selectItem(at: 4)
      }
    } else {
      animationSpeedPopup.selectItem(at: 4)
    }

    launchAtLoginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
  }

  @objc private func windowClickMenuChanged(_ sender: NSButton) {
    WindowClickMenu.isEnabledSetting = sender.state == .on
  }

  /// Lists the virtual display and every connected real one, keeping a picked display that is unplugged.
  private func refreshStagingDisplays() {
    stagingPopup.removeAllItems()
    stagingPopup.addItem(withTitle: "Virtual display (created when needed)")
    let displays = StagingDisplay.realDisplays()
    if !displays.isEmpty { stagingPopup.menu?.addItem(.separator()) }
    for display in displays {
      stagingPopup.addItem(withTitle: display.choice.name)
      stagingPopup.lastItem?.representedObject = display.choice.uuid
    }
    if let choice = StagingDisplay.choice {
      if !displays.contains(where: { $0.choice.uuid == choice.uuid }) {
        stagingPopup.addItem(withTitle: "\(choice.name) (not connected)")
        stagingPopup.lastItem?.representedObject = choice.uuid
      }
      stagingPopup.selectItem(at: stagingPopup.indexOfItem(withRepresentedObject: choice.uuid))
    } else {
      stagingPopup.selectItem(at: 0)
    }
    updateStagingControls()
  }

  /// The idle settings belong to the virtual display, so they only apply while it is the one in use.
  private func updateStagingControls() {
    let virtual = StagingDisplay.connectedChoiceID == nil
    stagingShutdownCheckbox.isEnabled = virtual
    stagingTimeoutField.isEnabled = virtual && VirtualDisplaySession.automaticShutdown
    stagingTimeoutLabel.textColor = stagingTimeoutField.isEnabled ? .labelColor : .disabledControlTextColor
  }

  @objc private func stagingDisplayChanged(_ sender: NSPopUpButton) {
    if let uuid = sender.selectedItem?.representedObject as? String {
      let name = StagingDisplay.realDisplays().first { $0.choice.uuid == uuid }?.choice.name
        ?? StagingDisplay.choice?.name ?? "Display"
      StagingDisplay.choice = StagingDisplay.Choice(uuid: uuid, name: name)
    } else {
      StagingDisplay.choice = nil
    }
    updateStagingControls()
  }

  @objc private func stagingShutdownChanged(_ sender: NSButton) {
    VirtualDisplaySession.automaticShutdown = sender.state == .on
    updateStagingControls()
  }

  @objc private func stagingTimeoutChanged(_ sender: NSTextField) {
    VirtualDisplaySession.idleSeconds = sender.integerValue
    sender.integerValue = VirtualDisplaySession.idleSeconds
  }

  @objc private func showOSDChanged(_ sender: NSButton) {
    let isEnabled = sender.state == .on
    defaults.set(isEnabled, forKey: "showOSD")
    osdDurationPopup.isEnabled = isEnabled
    let overlayDetectionEnabled = overlayDetectionCheckbox.state == .on
    showOSDInMissionControlCheckbox.isEnabled = isEnabled && overlayDetectionEnabled
  }

  @objc private func overlayDetectionChanged(_ sender: NSButton) {
    let isEnabled = sender.state == .on
    defaults.set(isEnabled, forKey: "overlayDetectionEnabled")
    let showOSDEnabled = showOSDCheckbox.state == .on
    showOSDInMissionControlCheckbox.isEnabled = showOSDEnabled && isEnabled
    iss_set_overlay_detection_enabled(isEnabled)
  }

  @objc private func showOSDInMissionControlChanged(_ sender: NSButton) {
    defaults.set(sender.state == .on, forKey: "showOSDInMissionControl")
  }

  @objc private func osdDurationChanged(_ sender: NSPopUpButton) {
    let index = sender.indexOfSelectedItem
    guard index >= 0 && index < durationPresets.count else { return }
    let duration = durationPresets[index]
    defaults.set(duration, forKey: "osdDurationMs")
  }

  @objc private func swipeOverrideChanged(_ sender: NSButton) {
    let isEnabled = sender.state == .on
    defaults.set(isEnabled, forKey: "swipeOverride")
    iss_set_swipe_override(isEnabled)
  }

  @objc private func animationSpeedChanged(_ sender: NSPopUpButton) {
    let index = sender.indexOfSelectedItem
    guard index >= 0 && index < animationSpeedOptions.count else { return }

    var velocity: Double
    if index < animationSpeedValues.count {
      velocity = animationSpeedValues[index]
    } else {
      velocity = 2000.0
    }

    defaults.set(velocity, forKey: "gestureSpeed")
    iss_set_gesture_speed(velocity)
  }

  @objc private func autoUpdateChanged(_ sender: NSButton) {
    UpdateChecker.shared.automaticChecks = sender.state == .on
  }

  @objc private func betaUpdatesChanged(_ sender: NSButton) {
    UpdateChecker.shared.betaUpdates = sender.state == .on
  }

  @objc private func checkNowClicked(_ sender: NSButton) {
    UpdateChecker.shared.checkForUpdates()
  }

  private func refreshCLIStatus() {
    let link = CLIInstaller.defaultLinkURL
    let path = (link.path as NSString).abbreviatingWithTildeInPath
    guard let executable = cliExecutable else {
      cliButton.title = "Install 'cubicle' command"
      cliButton.isEnabled = false
      setCLIStatus("Only available when running from Cubicle.app.", isError: false)
      return
    }

    cliButton.isEnabled = true
    switch CLIInstaller.status(link: link, executable: executable) {
    case .notInstalled:
      cliButton.title = "Install 'cubicle' command"
      setCLIStatus("Links \(path). Add that folder to your PATH if the command isn't found.", isError: false)
    case .installed:
      cliButton.title = "Remove 'cubicle' command"
      setCLIStatus("Installed at \(path).", isError: false)
    case .pointsElsewhere:
      cliButton.title = "Update 'cubicle' command"
      setCLIStatus("\(path) points at a different copy of Cubicle.", isError: false)
    case .broken:
      cliButton.title = "Update 'cubicle' command"
      setCLIStatus("\(path) points at a file that no longer exists.", isError: false)
    case .blocked:
      cliButton.title = "Install 'cubicle' command"
      cliButton.isEnabled = false
      setCLIStatus("\(path) already exists and is not a link, so it was left alone.", isError: true)
    }
  }

  private func setCLIStatus(_ text: String, isError: Bool) {
    cliStatusLabel.stringValue = text
    cliStatusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
  }

  @objc private func cliButtonClicked(_ sender: NSButton) {
    guard let executable = cliExecutable else { return }
    let link = CLIInstaller.defaultLinkURL
    do {
      if CLIInstaller.status(link: link, executable: executable) == .installed {
        try CLIInstaller.uninstall(link: link)
      } else {
        try CLIInstaller.install(link: link, executable: executable)
      }
      refreshCLIStatus()
    } catch {
      setCLIStatus(error.localizedDescription, isError: true)
    }
  }

  @objc private func showNameInMenuBarChanged(_ sender: NSButton) {
    // The menu bar controller refreshes itself when defaults change.
    defaults.set(sender.state == .on, forKey: MenuBarLabel.defaultsKey)
  }

  @objc private func hideMenuBarIconChanged(_ sender: NSButton) {
    let hide = sender.state == .on
    defaults.set(hide, forKey: "hideMenuBarIcon")
    (NSApp.delegate as? AppDelegate)?.setMenuBarIconVisible(!hide)
  }

  @objc private func launchAtLoginChanged(_ sender: NSButton) {
    let shouldEnable = sender.state == .on

    do {
      if shouldEnable {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      NSSound.beep()
      sender.state = shouldEnable ? .off : .on

      let alert = NSAlert()
      alert.messageText = "Failed to \(shouldEnable ? "enable" : "disable") launch at login"
      alert.informativeText = error.localizedDescription
      alert.alertStyle = .warning
      alert.runModal()
    }
  }
}
