import Foundation

/// Lazy Susan (tech.phin.LazySusan, a fork of Leader Key) is a keyboard launcher: a leader shortcut, then nested keys
/// that run commands. Cubicle plugs into it two ways (the contract is Lazy Susan's docs/integrations.md):
///
/// - `cubicle leader <list>` prints items for a dynamic group (`"source"`), filled each time the group is entered.
/// - Settings installs a "Cubicle" group: it writes `installGroup` to a file and opens `lazysusan://install?file=…`.
///
/// Lazy Susan runs commands non-interactively with the user's login shell (which may be fish), where PATH may not
/// have ~/.local/bin, so every command starts with the CLI's absolute path, double-quoted.
public enum LazySusan {
  public static let bundleID = "tech.phin.LazySusan"
  /// The key the installed group sits under at the top level of Lazy Susan's config.
  public static let groupKey = "c"

  /// One item in Lazy Susan's config format. Exactly one of `value`, `actions` and `source` is set.
  public struct Item: Codable, Equatable {
    /// One character. Left out, Lazy Susan picks one (1–9, 0, then a–z).
    public var key: String?
    /// `command` or `group`.
    public var type: String
    public var label: String
    public var value: String?
    public var actions: [Item]?
    /// A command whose output (an array of items) fills the group each time it is entered.
    public var source: String?

    public static func command(_ key: String?, _ label: String, _ value: String) -> Item {
      Item(key: key, type: "command", label: label, value: value)
    }

    public static func group(_ key: String, _ label: String, _ actions: [Item]) -> Item {
      Item(key: key, type: "group", label: label, actions: actions)
    }

    public static func dynamic(_ key: String, _ label: String, source: String) -> Item {
      Item(key: key, type: "group", label: label, source: source)
    }
  }

  /// The lists `cubicle leader` prints.
  public static let lists = ["go", "send", "windows", "stashed"]

  /// `path` as one word in sh, zsh, bash and fish: double quotes, with `\`, `"` and `$` escaped (the characters all
  /// of them treat specially inside double quotes).
  public static func quoted(_ path: String) -> String {
    var escaped = ""
    for character in path {
      if character == "\\" || character == "\"" || character == "$" { escaped.append("\\") }
      escaped.append(character)
    }
    return "\"\(escaped)\""
  }

  /// A workspace's number as its key: 1–9, and 0 for the tenth. Later ones get a key from Lazy Susan.
  static func key(forWorkspace index: Int) -> String? {
    switch index {
    case 1...9: return String(index)
    case 10: return "0"
    default: return nil
    }
  }

  static func title(of space: CubicleSpaceEntry) -> String {
    let name = space.name?.trimmingCharacters(in: .whitespaces) ?? ""
    return name.isEmpty ? "Workspace \(space.index)" : name
  }

  /// `leader go`: switch to each workspace, keyed by its number.
  public static func goItems(_ spaces: [CubicleSpaceEntry], cli: String) -> [Item] {
    spaces.map { .command(key(forWorkspace: $0.index), title(of: $0), "\(quoted(cli)) go \($0.index)") }
  }

  /// `leader send`: send the window you were in to each other workspace, keyed by its number.
  public static func sendItems(_ spaces: [CubicleSpaceEntry], cli: String) -> [Item] {
    spaces.filter { !$0.isCurrent }.map {
      .command(key(forWorkspace: $0.index), title(of: $0), "\(quoted(cli)) send \($0.index)")
    }
  }

  /// `leader windows`: go to a window, wherever it is. Keys are left to Lazy Susan.
  public static func windowItems(_ windows: [CubicleWindowEntry], cli: String) -> [Item] {
    // Windows Cubicle hasn't placed on a workspace are kept: focus still goes to them.
    windows
      .enumerated()
      .sorted { a, b in
        if a.element.display != b.element.display { return (a.element.display ?? "") < (b.element.display ?? "") }
        let (x, y) = (a.element.workspace ?? .max, b.element.workspace ?? .max)
        return x != y ? x < y : a.offset < b.offset
      }
      .map(\.element)
      .map { window in
        let name = window.title.isEmpty || window.title == window.app ? window.app : "\(window.app) — \(window.title)"
        let place = window.workspaceName.map { " (\($0))" } ?? window.workspace.map { " (Workspace \($0))" } ?? ""
        return .command(nil, name + place, "\(quoted(cli)) focus --window \(window.id)")
      }
  }

  /// `leader stashed`: bring a stashed window out and keep it out. Keys are left to Lazy Susan.
  public static func stashedItems(_ stashed: [CubicleStashedEntry], cli: String) -> [Item] {
    stashed.map { entry in
      let name = entry.name ?? (entry.title.isEmpty || entry.title == entry.app ? entry.app : "\(entry.app) — \(entry.title)")
      return .command(nil, name, "\(quoted(cli)) open-stashed --window \(entry.id)")
    }
  }

  /// The group Settings installs into Lazy Susan, under `groupKey`.
  public static func installGroup(cli: String) -> Item {
    let cubicle = quoted(cli)
    func snap(_ key: String, _ action: SnapAction) -> Item {
      .command(key, action.displayName, "\(cubicle) snap \(action.rawValue)")
    }
    return .group(groupKey, "Cubicle", [
      .dynamic("g", "Go to", source: "\(cubicle) leader go"),
      .dynamic("s", "Send window to", source: "\(cubicle) leader send"),
      .dynamic("w", "Windows", source: "\(cubicle) leader windows"),
      .dynamic("o", "Open stashed window", source: "\(cubicle) leader stashed"),
      .command("h", "Workspace left", "\(cubicle) left"),
      .command("l", "Workspace right", "\(cubicle) right"),
      .command("n", "New workspace", "\(cubicle) new-space"),
      .command("r", "Rename workspace", "\(cubicle) rename -- {input}"),
      .command("t", "Rename Tab", "\(cubicle) rename-tab -- {input}"),
      .command("v", "Workspace grid", "\(cubicle) grid"),
      .group("a", "Snap", [
        snap("h", .leftHalf), snap("l", .rightHalf), snap("k", .topHalf), snap("j", .bottomHalf),
        snap("m", .maximize), snap("f", .fullScreen), snap("c", .center), snap("r", .restore),
      ]),
    ])
  }

  public static func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return "[]" }
    return String(decoding: data, as: UTF8.self)
  }

  /// `lazysusan://install?file=<path>`, with the path percent-encoded so `&`, `=`, `+` and the like survive.
  public static func installURL(forFile path: String) -> URL? {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+?#")
    guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
    return URL(string: "lazysusan://install?file=\(encoded)")
  }
}
