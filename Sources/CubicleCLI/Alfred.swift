import CubicleIPC
import Foundation

/// `cubicle alfred [query]`: everything the Alfred workflow shows, as Script Filter JSON. The workflow itself is a
/// fixed shim (a keyword that runs this, and a script that runs what the chosen item says), so the menu, its
/// sections and what each item does all live here, next to the commands they run.
///
/// The query is read as a path: nothing (or a word that isn't a section) shows the sections plus matching windows;
/// `windows …`, `go …`, `send …`, `snap …` and `remove …` open a section; `window <id> …` is what can be done with
/// one window. Tab (autocomplete) walks down the path. An item's `arg` is a `cubicle` command line, one argument per
/// tab, which the workflow's run script splits and runs.
enum AlfredMenu {
  private struct Section {
    let word: String
    let title: String
    let subtitle: String
    /// Opens a list (autocomplete) rather than running something.
    let opens: Bool
    var arg: String? = nil
  }

  private static let sections: [Section] = [
    Section(word: "windows", title: "Windows", subtitle: "Every window on every workspace: go to one, or send it somewhere", opens: true),
    Section(word: "go", title: "Go to Workspace", subtitle: "Switch the display under the cursor", opens: true),
    Section(word: "send", title: "Send Window", subtitle: "Move the window you were in to another workspace", opens: true),
    Section(word: "snap", title: "Snap Window", subtitle: "Halves, quarters, maximize, full screen, center, restore, stash", opens: true),
    Section(word: "new", title: "New Workspace from Windows…", subtitle: "Click windows, then name their workspace", opens: false, arg: "pick-workspace"),
    Section(word: "add", title: "Add a Workspace", subtitle: "One more on the display under the cursor", opens: false, arg: "new-space"),
    Section(word: "rename", title: "Rename This Workspace", subtitle: "Type the new name", opens: true),
    Section(word: "remove", title: "Remove a Workspace", subtitle: "Its windows join the workspace before it", opens: true),
    Section(word: "move", title: "Move Workspace to Next Display", subtitle: "With its windows, name and bindings", opens: false, arg: "move-workspace"),
    Section(word: "grid", title: "Workspace Grid", subtitle: "Open the grid", opens: false, arg: "grid"),
  ]

  static func items(for query: String) -> [AlfredItem] {
    let words = query.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    let opened = query.contains(" ") ? words.first?.lowercased() : nil
    let rest = words.dropFirst().joined(separator: " ")
    switch opened {
    case "windows": return windows(matching: rest)
    case "window":
      guard let id = words.dropFirst().first.flatMap({ UInt32($0) }) else { return top(query) }
      return actions(forWindow: id, query: words.dropFirst(2).joined(separator: " "))
    case "go": return workspaces(matching: rest, includingCurrent: false, title: { $0 }) { "go\t\($0.index)" }
    case "send":
      return workspaces(matching: rest, includingCurrent: false, title: { "Send to \($0)" }) { "send\t\($0.index)" }
    case "remove":
      return workspaces(matching: rest, includingCurrent: true, title: { "Remove \($0)" }) { "remove-space\t\($0.index)" }
    case "snap": return snaps(matching: rest)
    case "rename": return rename(to: rest)
    default: return top(query)
    }
  }

  // MARK: - Sections

  /// The sections that match, then windows that match.
  private static func top(_ query: String) -> [AlfredItem] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let menu = sections
      .compactMap { section in score("\(section.word) \(section.title)", trimmed).map { (section, $0) } }
      .sorted { $0.1 > $1.1 }
      .map { section, _ in
        AlfredItem(
          title: section.title, subtitle: section.subtitle, arg: section.arg, valid: !section.opens,
          autocomplete: section.opens ? "\(section.word) " : nil)
      }
    guard !trimmed.isEmpty else { return menu }
    return menu + windows(matching: trimmed).prefix(12).filter(\.valid)
  }

  private static func windows(matching query: String) -> [AlfredItem] {
    let response = request(CubicleRequest(command: "windows"))
    guard let windows = response.windows else { return [error(response.message)] }
    let ranked = windows
      .filter { $0.workspace != nil }
      .compactMap { window in score(haystack(window), query).map { (window, $0) } }
      .sorted { a, b in
        if a.1 != b.1 { return a.1 > b.1 }
        // Then by where they are: display, then workspace number.
        if a.0.display != b.0.display { return (a.0.display ?? "") < (b.0.display ?? "") }
        return (a.0.workspace ?? 0) < (b.0.workspace ?? 0)
      }
      .map { window, _ in
        AlfredItem(
          title: name(of: window), subtitle: "\(place(of: window))  ·  ↩ go to it  ·  ⇥ send it somewhere",
          arg: "focus\t--window\t\(window.id)", valid: true, autocomplete: "window \(window.id) ")
      }
    return ranked.isEmpty ? [AlfredItem(title: "No window matches", subtitle: query, arg: nil, valid: false)] : ranked
  }

  /// One window: go to it, send it to a workspace on its display, or give it a new workspace named `query`.
  private static func actions(forWindow id: UInt32, query: String) -> [AlfredItem] {
    let response = request(CubicleRequest(command: "windows"))
    guard let windows = response.windows else { return [error(response.message)] }
    guard let window = windows.first(where: { $0.id == id }) else {
      return [AlfredItem(title: "That window has closed", subtitle: "Go back and pick another", arg: nil, valid: false, autocomplete: "windows ")]
    }
    let list = request(CubicleRequest(command: "list"))
    let spaces = (list.spaces ?? []).filter { $0.display == window.display && $0.index != window.workspace }
    let trimmed = query.trimmingCharacters(in: .whitespaces)

    var items: [AlfredItem] = []
    if trimmed.isEmpty {
      items.append(AlfredItem(
        title: "Go to \(name(of: window))", subtitle: place(of: window), arg: "focus\t--window\t\(id)", valid: true))
    }
    items += spaces
      .compactMap { space in score("\(space.name ?? "") workspace \(space.index)", trimmed).map { (space, $0) } }
      .sorted { $0.1 > $1.1 }
      .map { space, _ in
        AlfredItem(
          title: "Send to \(title(of: space))", subtitle: "\(name(of: window)) → \(space.display) · Workspace \(space.index)",
          arg: "send\t\(space.index)\t--window\t\(id)", valid: true)
      }
    items.append(AlfredItem(
      title: trimmed.isEmpty ? "New Workspace" : "New Workspace “\(trimmed)”",
      subtitle: trimmed.isEmpty ? "Type a name first, or leave it numbered" : "Put \(name(of: window)) on it and go there",
      arg: "new-workspace\t\(trimmed)\t--window\t\(id)", valid: true))
    return items
  }

  private static func workspaces(
    matching query: String, includingCurrent: Bool, title makeTitle: (String) -> String,
    arg: (CubicleSpaceEntry) -> String
  ) -> [AlfredItem] {
    let response = request(CubicleRequest(command: "list", here: true))
    guard let spaces = response.spaces else { return [error(response.message)] }
    let items = spaces
      .filter { includingCurrent || !$0.isCurrent }
      .compactMap { space in score("\(space.name ?? "") workspace \(space.index)", query).map { (space, $0) } }
      .sorted { $0.1 > $1.1 }
      .map { space, _ in
        AlfredItem(
          title: makeTitle(title(of: space)),
          subtitle: "\(space.display) · Workspace \(space.index)\(space.isCurrent ? " · showing" : "")",
          arg: arg(space), valid: true)
      }
    return items.isEmpty ? [AlfredItem(title: "No workspace matches", subtitle: query, arg: nil, valid: false)] : items
  }

  private static func rename(to name: String) -> [AlfredItem] {
    let response = request(CubicleRequest(command: "list", here: true))
    let current = response.spaces?.first(where: \.isCurrent)
    let now = current.map { title(of: $0) } ?? "this workspace"
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      return [AlfredItem(
        title: "Rename \(now)", subtitle: "Type a name; ↩ with none goes back to the number",
        arg: "rename\t", valid: current?.name != nil)]
    }
    return [AlfredItem(title: "Rename \(now) to “\(trimmed)”", subtitle: "The workspace showing under the cursor", arg: "rename\t\(trimmed)", valid: true)]
  }

  private static func snaps(matching query: String) -> [AlfredItem] {
    let items = SnapAction.matching(query).map {
      AlfredItem(title: $0.displayName, subtitle: "Snap the window you were in", arg: "snap\t\($0.rawValue)", valid: true)
    } + StashEdge.matching(query).map {
      AlfredItem(title: $0.displayName, subtitle: "Tuck the window you were in against the edge (again to unstash)",
        arg: "stash\t\($0.rawValue)", valid: true)
    }
    return items.isEmpty ? [AlfredItem(title: "No window command matches", subtitle: query, arg: nil, valid: false)] : items
  }

  // MARK: - Helpers

  private static func request(_ request: CubicleRequest) -> CubicleResponse {
    send(request) { message in
      printAlfred([AlfredItem(title: "Cubicle error", subtitle: message, arg: nil, valid: false)])
      exit(0)
    }
  }

  private static func error(_ message: String?) -> AlfredItem {
    AlfredItem(title: "Cubicle error", subtitle: message ?? "Unknown error", arg: nil, valid: false)
  }

  private static func name(of window: CubicleWindowEntry) -> String {
    window.title.isEmpty || window.title == window.app ? window.app : "\(window.app) — \(window.title)"
  }

  private static func title(of space: CubicleSpaceEntry) -> String {
    space.name ?? "Workspace \(space.index)"
  }

  private static func place(of window: CubicleWindowEntry) -> String {
    let workspace = window.workspaceName.map { "\($0) (\(window.workspace ?? 0))" } ?? "Workspace \(window.workspace ?? 0)"
    var parts = [workspace]
    if let display = window.display { parts.append(display) }
    if window.isShowing == true { parts.append("showing") }
    if window.isMinimized { parts.append("minimized") }
    return parts.joined(separator: " · ")
  }

  private static func haystack(_ window: CubicleWindowEntry) -> String {
    [window.app, window.title, window.workspaceName ?? "", "workspace \(window.workspace ?? 0)"].joined(separator: " ")
  }

  /// How well `text` matches `query`, higher is better; nil when it doesn't. Every word of the query has to be
  /// found: at the start of a word, inside one, or as letters in order.
  static func score(_ text: String, _ query: String) -> Int? {
    let haystack = fold(text)
    var total = 0
    for word in fold(query).split(separator: " ").map(String.init) {
      if haystack.hasPrefix(word) || haystack.contains(" " + word) {
        total += 3
      } else if haystack.contains(word) {
        total += 2
      } else if inOrder(word, haystack) {
        total += 1
      } else {
        return nil
      }
    }
    return total
  }

  private static func inOrder(_ needle: String, _ haystack: String) -> Bool {
    var remaining = haystack[...]
    for character in needle {
      guard let found = remaining.firstIndex(of: character) else { return false }
      remaining = remaining[remaining.index(after: found)...]
    }
    return true
  }

  private static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}
