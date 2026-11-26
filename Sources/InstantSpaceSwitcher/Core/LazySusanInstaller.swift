import AppKit
import CubicleIPC

/// Adds Cubicle's group to Lazy Susan: writes it to a file and opens `lazysusan://install?file=…`. Lazy Susan asks
/// the user first, and replaces the copy from an earlier install, so the same call is also "Update".
enum LazySusanInstaller {
  static var isInstalled: Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: LazySusan.bundleID) != nil
  }

  /// Left in place after installing: Lazy Susan may read it a moment later, once it has launched.
  static var groupFileURL: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/Cubicle/LazySusan/Cubicle.json")
  }

  enum InstallError: Error, LocalizedError {
    case noCLI
    case couldNotOpen

    var errorDescription: String? {
      switch self {
      case .noCLI: return "Only available when running from Cubicle.app."
      case .couldNotOpen: return "Lazy Susan didn't open the install link."
      }
    }
  }

  static func install() throws {
    guard let cli = CLIInstaller.bundledExecutable() else { throw InstallError.noCLI }
    let file = groupFileURL
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let json = LazySusan.json(LazySusan.installGroup(cli: cli.resolvingSymlinksInPath().path))
    try Data((json + "\n").utf8).write(to: file, options: .atomic)
    guard let url = LazySusan.installURL(forFile: file.path), NSWorkspace.shared.open(url) else {
      throw InstallError.couldNotOpen
    }
  }
}
