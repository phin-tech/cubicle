import CubicleIPC
import Foundation

let usage = """
  Usage: cubicle <command>

  Commands:
    list [--here] [--json] [query]
                        List Spaces (* marks the current one). --here limits it to the display under the
                        cursor; a query keeps only fuzzy matches, best first.
    list --alfred [query]
                        Same as --here, printed as Alfred Script Filter JSON (the current Space is left out)
    go <name|number>    Switch to a Space by fuzzy name or one-based number
    send [--quick-drag|--via-display|--via-virtual] [--stay] <name|number>  Move the focused window to a Space on its display, and go with it (experimental)
    left | right        Switch one Space left or right
    snap <action> [--app <name>|--window <id>|--previous]
                        Move and resize a window: left-half, right-half, top-half, bottom-half, top-left,
                        top-right, bottom-left, bottom-right, maximize, center or restore. It acts on the
                        focused window (from Alfred or Raycast, the window you were in before), or on
                        another app's front window, a window by id, or the app you were in before this one.
    windows [--json]    List the windows on the current Space, with the ids --window takes
    actions [--json|--alfred] [query]
                        List the window commands; --alfred prints them for Alfred's "w" keyword
    gap [points]        Show or set the gap kept between snapped windows (0-100, default 0)
    grid                Open the Space grid
    new-space           Add a Space (Mission Control opens briefly)
    help                Show this help

  Commands run inside the Cubicle app, which holds the Accessibility permission, so this tool
  needs none of its own. Cubicle is started in the background if it is not already running.
  """

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

/// The enclosing .app, found by walking up from this executable (it lives in Cubicle.app/Contents/Helpers).
func appBundleURL() -> URL? {
  var url = Bundle.main.executableURL?.resolvingSymlinksInPath()
  while let current = url, current.path != "/" {
    if current.pathExtension == "app" { return current }
    url = current.deletingLastPathComponent()
  }
  return nil
}

func launchApp() -> Bool {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  if let app = appBundleURL() {
    process.arguments = ["-g", app.path]
  } else {
    process.arguments = ["-g", "-b", "tech.phin.Cubicle"]
  }
  do {
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
  } catch {
    return false
  }
}

/// Sends a request, starting Cubicle first if needed. `failure` decides how errors are reported.
func send(_ request: CubicleRequest, failure: (String) -> Never = fail) -> CubicleResponse {
  // Moving a window waits for animated Space switches.
  let timeout = ["send", "mc-dump"].contains(request.command) ? 15 : 5
  do {
    return try CubicleIPC.send(request, timeout: timeout)
  } catch CubicleIPCError.notRunning {
    guard launchApp() else { failure("Cubicle is not running and could not be started.") }
    for _ in 0..<25 {
      usleep(200_000)
      if let response = try? CubicleIPC.send(request, timeout: timeout) { return response }
    }
    failure("Timed out waiting for Cubicle to start.")
  } catch {
    failure("cubicle: \(error.localizedDescription)")
  }
}

/// Pulls `--app <name>`, `--window <id>` and `--previous` out of `arguments`; returns the request fields and the
/// words left over.
func windowTarget(_ arguments: [String]) -> (app: String?, window: UInt32?, previous: Bool, rest: [String]) {
  var app: String?
  var window: UInt32?
  var previous = false
  var rest: [String] = []
  var iterator = arguments.makeIterator()
  while let argument = iterator.next() {
    switch argument {
    case "--app":
      guard let value = iterator.next() else { fail("--app needs an app name or bundle id.") }
      app = value
    case "--window":
      guard let value = iterator.next(), let id = UInt32(value) else {
        fail("--window needs a window id (see cubicle windows).")
      }
      window = id
    case "--previous":
      previous = true
    default:
      if argument.hasPrefix("--") { fail("Unknown option '\(argument)'.\n\n\(usage)") }
      rest.append(argument)
    }
  }
  return (app, window, previous, rest)
}

func printJSON<T: Encodable>(_ value: T) {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
    print(text)
  }
}

func printWindows(_ windows: [CubicleWindowEntry]) {
  guard !windows.isEmpty else {
    print("No windows on this Space.")
    return
  }
  let width = windows.map { String($0.id).count }.max() ?? 1
  for window in windows {
    let marker = window.isFocused ? "*" : " "
    let id = String(window.id).padding(toLength: width, withPad: " ", startingAt: 0)
    let title = window.title.isEmpty || window.title == window.app ? window.app : "\(window.app) — \(window.title)"
    let size = "\(Int(window.width))×\(Int(window.height)) at \(Int(window.x)),\(Int(window.y))"
    print("\(marker) \(id)  \(title)  (\(size)\(window.isMinimized ? ", minimized" : ""))")
  }
}

func printSpaces(_ spaces: [CubicleSpaceEntry]) {
  var lastDisplay: String?
  for space in spaces {
    if space.display != lastDisplay {
      if lastDisplay != nil { print("") }
      print(space.display)
      lastDisplay = space.display
    }
    let marker = space.isCurrent ? "*" : " "
    print("  \(marker) \(space.index)  \(space.name ?? "(unnamed)")")
  }
}

// MARK: - Alfred

struct AlfredItem: Encodable {
  var title: String
  var subtitle: String
  var arg: String?
  var valid: Bool
}

func printAlfred(_ items: [AlfredItem]) {
  struct Output: Encodable { var items: [AlfredItem] }
  if let data = try? JSONEncoder().encode(Output(items: items)), let text = String(data: data, encoding: .utf8) {
    print(text)
  }
}

func alfredItems(for response: CubicleResponse) -> [AlfredItem] {
  guard response.ok, let spaces = response.spaces else {
    return [AlfredItem(title: "Cubicle error", subtitle: response.message ?? "Unknown error", arg: nil, valid: false)]
  }
  // No uid on purpose: Alfred would re-rank by past use and bury our best-match-first order.
  let items = spaces.filter { !$0.isCurrent }.map {
    AlfredItem(
      title: $0.name ?? "Space \($0.index)", subtitle: "\($0.display) · Space \($0.index)",
      arg: String($0.index), valid: true)
  }
  return items.isEmpty
    ? [AlfredItem(title: "No other Spaces match", subtitle: "Nothing to switch to on this display", arg: nil, valid: false)]
    : items
}

// MARK: - Commands

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
  print(usage)
  exit(1)
}
let rest = Array(arguments.dropFirst())

switch command {
case "help", "-h", "--help":
  print(usage)

case "list":
  var flags = Set<String>()
  var words: [String] = []
  for argument in rest {
    if argument.hasPrefix("--") { flags.insert(argument) } else { words.append(argument) }
  }
  if let unknown = flags.first(where: { !["--here", "--json", "--alfred"].contains($0) }) {
    fail("Unknown option '\(unknown)'.\n\n\(usage)")
  }
  let alfred = flags.contains("--alfred")
  let query = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
  let request = CubicleRequest(
    command: "list", here: (alfred || flags.contains("--here")) ? true : nil, query: query.isEmpty ? nil : query)

  if alfred {
    // Alfred needs valid JSON even when something goes wrong, so errors become an item, not stderr.
    let response = send(request) { message in
      printAlfred([AlfredItem(title: "Cubicle error", subtitle: message, arg: nil, valid: false)])
      exit(0)
    }
    printAlfred(alfredItems(for: response))
    break
  }

  let response = send(request)
  guard response.ok, let spaces = response.spaces else { fail(response.message ?? "list failed") }
  if flags.contains("--json") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(spaces), let text = String(data: data, encoding: .utf8) {
      print(text)
    }
  } else {
    printSpaces(spaces)
  }

case "go":
  let query = rest.joined(separator: " ")
  guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { fail("Usage: cubicle go <name|number>") }
  let response = send(CubicleRequest(command: "go", argument: query))
  guard response.ok else { fail(response.message ?? "go failed") }
  if let message = response.message { print(message) }

case "send":
  let query = rest.joined(separator: " ")
  guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { fail("Usage: cubicle send <name|number>") }
  let response = send(CubicleRequest(command: "send", argument: query))
  guard response.ok else { fail(response.message ?? "send failed") }
  if let message = response.message { print(message) }

case "new-space":
  let response = send(CubicleRequest(command: "new-space"))
  guard response.ok else { fail(response.message ?? "new-space failed") }
  if let message = response.message { print(message) }

case "mc-dump":
  let response = send(CubicleRequest(command: "mc-dump", argument: rest.first))
  print(response.message ?? "")

case "snap":
  let target = windowTarget(rest)
  guard let name = target.rest.first, target.rest.count == 1 else {
    fail("Usage: cubicle snap <action> [--app <name>|--window <id>|--previous]\nActions: "
      + SnapAction.allCases.map(\.rawValue).joined(separator: ", "))
  }
  guard SnapAction(name: name) != nil else {
    fail("Unknown snap '\(name)'. Actions: " + SnapAction.allCases.map(\.rawValue).joined(separator: ", "))
  }
  let response = send(
    CubicleRequest(
      command: "snap", argument: name, app: target.app, window: target.window,
      previous: target.previous ? true : nil))
  guard response.ok else { fail(response.message ?? "snap failed") }
  if let message = response.message { print(message) }

case "windows":
  if let unknown = rest.first(where: { $0 != "--json" }) { fail("Unknown option '\(unknown)'.\n\n\(usage)") }
  let response = send(CubicleRequest(command: "windows"))
  guard response.ok, let windows = response.windows else { fail(response.message ?? "windows failed") }
  if rest.contains("--json") { printJSON(windows) } else { printWindows(windows) }

case "actions":
  // Answered here: the list doesn't depend on the app's state.
  let flags = rest.filter { $0.hasPrefix("--") }
  if let unknown = flags.first(where: { !["--json", "--alfred"].contains($0) }) {
    fail("Unknown option '\(unknown)'.\n\n\(usage)")
  }
  let actions = SnapAction.matching(rest.filter { !$0.hasPrefix("--") }.joined(separator: " "))
  if flags.contains("--alfred") {
    let items = actions.map {
      AlfredItem(title: $0.displayName, subtitle: "Snap the window you were in · cubicle snap \($0.rawValue)",
        arg: "snap \($0.rawValue)", valid: true)
    }
    printAlfred(items.isEmpty
      ? [AlfredItem(title: "No window command matches", subtitle: "Try left, top, quarter, maximize, center or restore", arg: nil, valid: false)]
      : items)
  } else if flags.contains("--json") {
    struct Entry: Encodable { var command: String; var name: String; var title: String }
    printJSON(actions.map { Entry(command: "snap", name: $0.rawValue, title: $0.displayName) })
  } else {
    for action in actions { print("snap \(action.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) \(action.displayName)") }
  }

case "gap":
  guard rest.count <= 1 else { fail("Usage: cubicle gap [points]") }
  let response = send(CubicleRequest(command: "gap", argument: rest.first))
  guard response.ok else { fail(response.message ?? "gap failed") }
  if let message = response.message { print(rest.isEmpty ? "\(message) pt" : message) }

case "left", "right", "grid":
  let response = send(CubicleRequest(command: command))
  guard response.ok else { fail(response.message ?? "\(command) failed") }

default:
  fail("Unknown command '\(command)'.\n\n\(usage)")
}
