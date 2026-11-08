import AppKit
import SwiftUI

struct OnboardingView: View {
  @ObservedObject var model: OnboardingModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        content
          .padding(24)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      footer
    }
    .frame(width: 560, height: 520)
  }

  // MARK: - Chrome

  private var header: some View {
    HStack(spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 40, height: 40)
      Text(model.step.title)
        .font(.title2.bold())
      Spacer()
      Text("Step \(model.step.position) of \(OnboardingStep.count)")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
  }

  private var footer: some View {
    HStack {
      if !model.step.isFirst {
        Button("Back") { go(model.step.previous) }
      }
      Spacer()
      if model.step == .accessibility && !model.accessibilityGranted {
        Button("Skip for now") { go(model.step.next) }
      }
      if model.step.isLast {
        Button("Done") { model.finish() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      } else {
        Button(model.step.isFirst ? "Get started" : "Next") { go(model.step.next) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!model.step.canAdvance(accessibilityGranted: model.accessibilityGranted))
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
  }

  private func go(_ step: OnboardingStep?) {
    guard let step else { return }
    model.notice = nil
    model.step = step
    model.refreshSpaces()
    model.refreshTools()
  }

  @ViewBuilder
  private var content: some View {
    switch model.step {
    case .welcome: welcome
    case .accessibility: accessibility
    case .spaces: spaces
    case .names: names
    case .grid: grid
    case .tools: tools
    case .finish: finish
    }
  }

  // MARK: - Pages

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Spaces, without the wait.")
        .font(.title3.bold())
      Text(
        "macOS lets you keep separate desktops, called Spaces, but switching between them is slow and you can't tell "
          + "them apart. Cubicle makes switching instant, lets you name your Spaces, and gives you a grid you can "
          + "search by typing.")
      Text("This takes about a minute. You can skip any step, and reopen this from the menu bar icon.")
        .foregroundStyle(.secondary)
    }
  }

  private var accessibility: some View {
    VStack(alignment: .leading, spacing: 14) {
      statusRow(
        ok: model.accessibilityGranted,
        good: "Cubicle has the Accessibility permission.",
        bad: "Cubicle needs the Accessibility permission.")
      Text(
        "To switch Spaces for you, Cubicle sends the same swipe your trackpad would. macOS only allows that for apps "
          + "you've approved under Privacy & Security > Accessibility.")
      if !model.accessibilityGranted {
        Text("Open System Settings, find Cubicle in the list and switch it on. This page updates by itself.")
          .foregroundStyle(.secondary)
        HStack {
          Button("Open System Settings") { model.openAccessibilitySettings() }
            .buttonStyle(.borderedProminent)
          Button("Show the prompt again") { model.askForAccessibility() }
        }
      }
    }
  }

  private var spaces: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(
        model.rows.isEmpty
          ? "Cubicle can't see your Spaces yet."
          : "You have \(model.rows.count) Space\(model.rows.count == 1 ? "" : "s") on this display.")
        .font(.title3.bold())
      Text("A Space is a separate desktop with its own windows. One for mail and chat, one for code, one for "
        + "everything else works well.")
      HStack {
        Button {
          model.addSpace()
        } label: {
          if model.isAddingSpace {
            ProgressView().controlSize(.small)
          } else {
            Label("Add a Space", systemImage: "plus.rectangle.on.rectangle")
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isAddingSpace || !model.accessibilityGranted)
        Button("Open Mission Control") { model.openMissionControl() }
      }
      if !model.accessibilityGranted {
        Text("Adding a Space presses the + in Mission Control for you, which needs the Accessibility permission "
          + "from the previous step.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let notice = model.notice {
        Text(notice).font(.callout).foregroundStyle(.secondary)
      }
      if model.rearrangesSpaces {
        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Label("macOS is set to rearrange your Spaces", systemImage: "exclamationmark.triangle")
              .font(.headline)
            Text(
              "\"Automatically rearrange Spaces based on most recent use\" moves Spaces around under you, so "
                + "\"Space 2\" stops meaning the same Space. It's on by default.")
              .font(.callout)
            Button("Turn it off (restarts the Dock)") { model.turnOffRearranging() }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(4)
        }
      }
    }
  }

  private var names: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Names show up in the grid, the menu bar and search, so you can jump by name instead of by number.")
      if model.rows.isEmpty {
        Text("No Spaces to name yet. Go back and add one.").foregroundStyle(.secondary)
      } else {
        VStack(spacing: 8) {
          ForEach(model.rows) { row in
            HStack {
              Text("\(row.index + 1)")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 28)
              TextField(
                "Space \(row.index + 1)",
                text: Binding(get: { row.name }, set: { model.rename(row, to: $0) })
              )
              .textFieldStyle(.roundedBorder)
              .disabled(row.key == nil)
            }
          }
        }
        Text("Try Main, Code, Mail. You can change these any time in Settings > Spaces.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var grid: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Press \(model.gridShortcut) any time to open the grid.")
        .font(.title3.bold())
      Text("Arrow keys move, Return jumps, and Esc closes. Or just start typing a name: \"ino\" finds \"Innopts\", "
        + "and the Space you're already on is left out.")
      Button("Try it now") { model.openGrid() }
        .buttonStyle(.borderedProminent)
      Divider()
      Text("Choose your shortcuts").font(.headline)
      if !model.accessibilityGranted {
        Text("Grant the Accessibility permission (step 2) first. Recording a shortcut needs it.")
          .font(.callout)
          .foregroundStyle(.orange)
      }
      shortcutRow("Open the grid", .showGrid)
      shortcutRow("Move one Space left", .left)
      shortcutRow("Move one Space right", .right)
      Text("Click a box, then press the keys you want. Esc cancels. Every shortcut, including jumping straight to "
        + "Space 1 to 16, is in Settings > Keyboard.")
        .font(.callout)
        .foregroundStyle(.secondary)
      if let notice = model.shortcutNotice {
        Text(notice).font(.callout).foregroundStyle(.red)
      }
    }
  }

  private var tools: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Text("The cubicle command").font(.headline)
          Text("Switch Spaces from a terminal or a script: cubicle go code, cubicle list, cubicle left.")
            .font(.callout)
          HStack {
            Button(cliButtonTitle) { model.toggleCLI() }
              .disabled(model.cliExecutable == nil)
            Text(cliStatusText)
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
      }
      if model.alfredInstalled && model.alfredWorkflowURL != nil {
        GroupBox {
          VStack(alignment: .leading, spacing: 8) {
            Text("Alfred").font(.headline)
            Text("Type @ and part of a Space's name in Alfred to jump to it. Needs the Alfred Powerpack.")
              .font(.callout)
            Button("Add the workflow to Alfred") { model.openAlfredWorkflow() }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(4)
        }
      }
      if let notice = model.notice {
        Text(notice).font(.callout).foregroundStyle(.red)
      }
    }
  }

  private var finish: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Cubicle lives in your menu bar.")
        .font(.title3.bold())
      Text("Click its icon for the menu. It shows the current Space's number, and its name if you gave it one.")
      VStack(alignment: .leading, spacing: 6) {
        Label("\(model.gridShortcut)  opens the grid", systemImage: "square.grid.2x2")
        Label("Settings > Spaces  names your Spaces", systemImage: "textformat")
        Label("Welcome to Cubicle…  in the menu reopens this", systemImage: "questionmark.circle")
      }
    }
  }

  // MARK: - Pieces

  private func shortcutRow(_ title: String, _ identifier: HotkeyIdentifier) -> some View {
    HStack {
      Text(title).frame(width: 170, alignment: .leading)
      ShortcutRecorderView(
        combination: model.shortcut(for: identifier), isEnabled: model.accessibilityGranted
      ) { model.setShortcut($0, for: identifier) }
        .frame(width: 170, height: 24)
      Button("Reset") { model.resetShortcut(identifier) }
        .disabled(model.shortcut(for: identifier) == identifier.defaultCombination)
    }
  }

  private func statusRow(ok: Bool, good: String, bad: String) -> some View {
    Label(ok ? good : bad, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
      .font(.headline)
      .foregroundStyle(ok ? Color.green : Color.orange)
  }

  private var cliButtonTitle: String {
    switch model.cliStatus {
    case .installed: return "Remove the command"
    case .pointsElsewhere, .broken: return "Update the command"
    default: return "Install the command"
    }
  }

  private var cliStatusText: String {
    let path = (CLIInstaller.defaultLinkURL.path as NSString).abbreviatingWithTildeInPath
    switch model.cliStatus {
    case .notInstalled: return "Links \(path)"
    case .installed: return "Installed at \(path)"
    case .pointsElsewhere: return "\(path) points at another copy"
    case .broken: return "\(path) is out of date"
    case .blocked: return "\(path) already exists and is not a link"
    }
  }
}
