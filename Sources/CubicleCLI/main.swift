import CubicleIPC
import Foundation

let usage = """
  Usage: cubicle <command>

  Commands:
    list [--json]       List the Spaces on every display (* marks the current one)
    go <name|number>    Switch to a Space by fuzzy name or one-based number
    left | right        Switch one Space left or right
    grid                Open the Space grid
    help                Show this help

  Commands run inside the Cubicle app, which holds the Accessibility permission, so this tool
  needs none of its own. Cubicle is started in the background if it is not already running.
  """

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

/// The enclosing .app, found by walking up from this executable (it lives in Cubicle.app/Contents/MacOS).
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

func send(_ request: CubicleRequest) -> CubicleResponse {
  do {
    return try CubicleIPC.send(request)
  } catch CubicleIPCError.notRunning {
    guard launchApp() else { fail("Cubicle is not running and could not be started.") }
    for _ in 0..<25 {
      usleep(200_000)
      if let response = try? CubicleIPC.send(request) { return response }
    }
    fail("Timed out waiting for Cubicle to start.")
  } catch {
    fail("cubicle: \(error.localizedDescription)")
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

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
  print(usage)
  exit(1)
}
let rest = arguments.dropFirst()

switch command {
case "help", "-h", "--help":
  print(usage)

case "list":
  let response = send(CubicleRequest(command: "list"))
  guard response.ok, let spaces = response.spaces else { fail(response.message ?? "list failed") }
  if rest.contains("--json") {
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

case "left", "right", "grid":
  let response = send(CubicleRequest(command: command))
  guard response.ok else { fail(response.message ?? "\(command) failed") }

default:
  fail("Unknown command '\(command)'.\n\n\(usage)")
}
