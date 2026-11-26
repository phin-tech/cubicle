import AppKit
import ServiceManagement

final class GeneralSettingsViewController: NSViewController {
  private let gapField = NSTextField(string: "0")

  private let showOSDCheckbox = NSButton(
    checkboxWithTitle: "Show on-screen display when switching workspaces", target: nil, action: nil)
  private let osdDurationPopup = NSPopUpButton()
  private let osdDurationLabel = NSTextField(labelWithString: "Duration:")
  private let swipeCheckbox = NSButton(
    checkboxWithTitle: "Swipe between workspaces with three or four fingers", target: nil, action: nil)
  private let launchAtLoginCheckbox = NSButton(
    checkboxWithTitle: "Launch at login", target: nil, action: nil)
  private let hideMenuBarIconCheckbox = NSButton(
    checkboxWithTitle: "Hide menu bar icon", target: nil, action: nil)
  private let showNameInMenuBarCheckbox = NSButton(
    checkboxWithTitle: "Show the workspace's name in the menu bar", target: nil, action: nil)

  private let cliButton = NSButton(title: "Install 'cubicle' command", target: nil, action: nil)
  private let alfredButton = NSButton(title: "Add the Workflow to Alfred", target: nil, action: nil)
  private let cliStatusLabel = NSTextField(labelWithString: "")
  private let cliExecutable = CLIInstaller.bundledExecutable()
  private let autoUpdateCheckbox = NSButton(
    checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
  private let betaUpdatesCheckbox = NSButton(
    checkboxWithTitle: "Include beta versions", target: nil, action: nil)
  private let checkNowButton = NSButton(title: "Check for Updates…", target: nil, action: nil)

  private let durationPresets = [100, 200, 300, 500, 750, 1000]

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
  }

  private func setupUI() {
    guard let formView = view as? FormView else { return }

    if formView.hasRows { return }

    // Targets/Actions
    showOSDCheckbox.target = self
    showOSDCheckbox.action = #selector(showOSDChanged)
    osdDurationPopup.target = self
    osdDurationPopup.action = #selector(osdDurationChanged)
    launchAtLoginCheckbox.target = self
    launchAtLoginCheckbox.action = #selector(launchAtLoginChanged)
    hideMenuBarIconCheckbox.target = self
    hideMenuBarIconCheckbox.action = #selector(hideMenuBarIconChanged)
    showNameInMenuBarCheckbox.target = self
    showNameInMenuBarCheckbox.action = #selector(showNameInMenuBarChanged)
    swipeCheckbox.target = self
    swipeCheckbox.action = #selector(swipeChanged)

    // Populate data
    for duration in durationPresets { osdDurationPopup.addItem(withTitle: "\(duration)ms") }

    // System
    let systemLabel = NSTextField(labelWithString: "System:")
    formView.addRow(label: systemLabel, control: launchAtLoginCheckbox)
    formView.addRow(label: nil, control: hideMenuBarIconCheckbox)
    formView.addRow(label: nil, control: showNameInMenuBarCheckbox)
    formView.addRow(label: nil, control: swipeCheckbox)
    formView.addSectionSpacing()

    formView.addRow(label: NSTextField(labelWithString: "Window Moves:"), control: NSTextField(
      labelWithString: "Click bindings and shortcuts for moving windows are in Keyboard."))
    gapField.target = self
    gapField.action = #selector(gapChanged)
    let gapFormatter = NumberFormatter()
    gapFormatter.minimum = 0
    gapFormatter.maximum = NSNumber(value: WindowSnapper.maximumGap)
    gapFormatter.allowsFloats = false
    gapField.formatter = gapFormatter
    gapField.widthAnchor.constraint(equalToConstant: 70).isActive = true
    gapField.integerValue = WindowSnapper.gap
    let gapRow = NSStackView(views: [gapField, NSTextField(labelWithString: "points between snapped windows (0–100)")])
    gapRow.spacing = 8
    formView.addRow(label: NSTextField(labelWithString: "Snap gap:"), control: gapRow)
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

    // Alfred: the workflow is bundled in the app; opening it has Alfred offer to import it (or update it).
    let alfredWorkflow = Bundle.main.url(forResource: "Cubicle", withExtension: "alfredworkflow")
    let alfredInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: OnboardingModel.alfredBundleID) != nil
    alfredButton.target = self
    alfredButton.action = #selector(alfredButtonClicked)
    alfredButton.isEnabled = alfredWorkflow != nil && alfredInstalled
    let alfredStatus = NSTextField(wrappingLabelWithString:
      alfredWorkflow == nil ? "Only available when running from Cubicle.app."
        : !alfredInstalled ? "Alfred isn't installed."
        : "Type cb in Alfred for Cubicle's menu, and @ and a name to jump to a workspace. Needs the Powerpack. "
          + "Add it again after an update to get the newest workflow.")
    alfredStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    alfredStatus.textColor = .secondaryLabelColor
    alfredStatus.preferredMaxLayoutWidth = 340
    formView.addRow(label: NSTextField(labelWithString: "Alfred:"), control: alfredButton)
    formView.addRow(label: nil, control: alfredStatus)
    formView.addSectionSpacing()

    // OSD
    let osdLabel = NSTextField(labelWithString: "On-Screen Display:")
    showOSDCheckbox.title = "Show for"
    
    let osdContainer = NSStackView()
    osdContainer.orientation = .horizontal
    osdContainer.spacing = 8
    osdContainer.addArrangedSubview(showOSDCheckbox)
    osdContainer.addArrangedSubview(osdDurationPopup)
    osdContainer.addArrangedSubview(NSTextField(labelWithString: "when switching workspaces"))
    
    formView.addRow(label: osdLabel, control: osdContainer)
  }

  private func loadSettings() {
    let showOSD = defaults.bool(forKey: "showOSD")
    showOSDCheckbox.state = showOSD ? .on : .off

    let durationMs = defaults.object(forKey: "osdDurationMs") as? Int ?? 200
    if let index = durationPresets.firstIndex(of: durationMs) {
      osdDurationPopup.selectItem(at: index)
    } else {
      osdDurationPopup.selectItem(at: 1)
    }

    osdDurationPopup.isEnabled = showOSD

    hideMenuBarIconCheckbox.state = defaults.bool(forKey: "hideMenuBarIcon") ? .on : .off
    showNameInMenuBarCheckbox.state = MenuBarLabel.isEnabled ? .on : .off
    swipeCheckbox.state = SwipeSwitcher.isEnabledSetting ? .on : .off
    if UpdateChecker.isAvailable {
      autoUpdateCheckbox.state = UpdateChecker.shared.automaticChecks ? .on : .off
      betaUpdatesCheckbox.state = UpdateChecker.shared.betaUpdates ? .on : .off
    }
    launchAtLoginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
  }

  @objc private func gapChanged(_ sender: NSTextField) {
    WindowSnapper.gap = sender.integerValue
    sender.integerValue = WindowSnapper.gap
  }

  @objc private func showOSDChanged(_ sender: NSButton) {
    let isEnabled = sender.state == .on
    defaults.set(isEnabled, forKey: "showOSD")
    osdDurationPopup.isEnabled = isEnabled
  }

  @objc private func osdDurationChanged(_ sender: NSPopUpButton) {
    let index = sender.indexOfSelectedItem
    guard index >= 0 && index < durationPresets.count else { return }
    let duration = durationPresets[index]
    defaults.set(duration, forKey: "osdDurationMs")
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

  @objc private func alfredButtonClicked(_ sender: NSButton) {
    guard let url = Bundle.main.url(forResource: "Cubicle", withExtension: "alfredworkflow") else { return }
    NSWorkspace.shared.open(url)
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

  @objc private func swipeChanged(_ sender: NSButton) {
    SwipeSwitcher.isEnabledSetting = sender.state == .on
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
