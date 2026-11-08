import Foundation

/// Installs the `cubicle` command bundled in the app as a symlink, like VS Code's "Install 'code' command".
/// It links into ~/.local/bin so no administrator password is needed, and it never replaces a real file.
enum CLIInstaller {
  enum Status: Equatable {
    case notInstalled
    /// The link exists and points at this app's copy.
    case installed
    /// The link points at a different copy of the tool (for example a build folder or an older install).
    case pointsElsewhere(String)
    /// The link points at something that no longer exists.
    case broken(String)
    /// A regular file or folder is in the way; it is left alone.
    case blocked
  }

  enum InstallError: Error, LocalizedError, Equatable {
    case blocked(String)

    var errorDescription: String? {
      switch self {
      case .blocked(let path): return "\(path) already exists and is not a link, so it was left alone."
      }
    }
  }

  static var defaultLinkURL: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/cubicle")
  }

  /// The `cubicle` executable inside the running app bundle, or nil when not running from a bundle.
  static func bundledExecutable(in bundle: Bundle = .main) -> URL? {
    let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/cubicle")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  static func status(link: URL, executable: URL) -> Status {
    let fileManager = FileManager.default
    // attributesOfItem describes the link itself rather than what it points at.
    guard let attributes = try? fileManager.attributesOfItem(atPath: link.path) else { return .notInstalled }
    guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
      let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path)
    else { return .blocked }

    let target = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
    guard fileManager.fileExists(atPath: target.path) else { return .broken(destination) }
    let same = target.resolvingSymlinksInPath().path == executable.resolvingSymlinksInPath().path
    return same ? .installed : .pointsElsewhere(destination)
  }

  /// Creates or updates the link. Throws `.blocked` if a real file is in the way.
  static func install(link: URL, executable: URL) throws {
    if status(link: link, executable: executable) == .blocked { throw InstallError.blocked(link.path) }
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
      try fileManager.removeItem(at: link)
    }
    try fileManager.createSymbolicLink(at: link, withDestinationURL: executable)
  }

  /// Removes the link. Throws `.blocked` rather than deleting something that is not a link.
  static func uninstall(link: URL) throws {
    let fileManager = FileManager.default
    guard (try? fileManager.attributesOfItem(atPath: link.path)) != nil else { return }
    guard (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil else {
      throw InstallError.blocked(link.path)
    }
    try fileManager.removeItem(at: link)
  }
}
