import CubicleIPC
import Foundation

/// `cubicle alfred [query]`: everything the Alfred workflow shows, as Script Filter JSON. The workflow itself is a
/// fixed shim (a keyword that runs this, and a script that runs what the chosen item says), so the menu, its
/// sections and what each item does all live here, next to the commands they run.
///
/// The query is read as a path: nothing (or a word that isn't a section) shows the sections plus matching windows;
/// `windows …`, `go …`, `send …`, `snap …`, `stashed …`, `stack …` and `remove …` open a section; `window <id> …` is
/// what can be done with one window, and `stashed-window <id> …` with one stashed window. Tab (autocomplete) walks down the path. An item's `arg` is a `cubicle` command line, one argument per
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
    Section(word: "stashed", title: "Stashed Windows", subtitle: "Open, unstash, move or rename a window tucked against an edge", opens: true),
    Section(word: "stack", title: "Stacking", subtitle: "Next or previous window in the stack, swap zones, pause or resume", opens: true),
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
    case "stashed": return stashed(matching: rest)
    case "stashed-window":
      guard let id = words.dropFirst().first.flatMap({ UInt32($0) }) else { return stashed(matching: "") }
      return actions(forStashed: id, query: words.dropFirst(2).joined(separator: " "))
    case "stack": return stacking(matching: rest)
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
    items += StashEdge.allCases
      .compactMap { edge in score("stash \(edge.rawValue) edge", trimmed).map { (edge, $0) } }
      .map { edge, _ in
        AlfredItem(
          title: edge.displayName, subtitle: "Tuck \(name(of: window)) against the edge, behind a Tab",
          arg: "stash\t\(edge.rawValue)\t--window\t\(id)", valid: true)
      }
    items.append(AlfredItem(
      title: trimmed.isEmpty ? "New Workspace" : "New Workspace “\(trimmed)”",
      subtitle: trimmed.isEmpty ? "Type a name first, or leave it numbered" : "Put \(name(of: window)) on it and go there",
      arg: "new-workspace\t\(trimmed)\t--window\t\(id)", valid: true))
    return items
  }

  /// The stashed windows that match, after Open Next and Unstash All.
  private static func stashed(matching query: String) -> [AlfredItem] {
    let response = request(CubicleRequest(command: "stashed"))
    guard let stashed = response.stashed else { return [error(response.message)] }
    guard !stashed.isEmpty else {
      return [AlfredItem(
        title: "No windows are stashed", subtitle: "Snap › Stash Left, Right or Top tucks the window you were in away",
        arg: nil, valid: false, autocomplete: "snap stash ")]
    }
    var items = stashed
      .compactMap { entry in score("\(entry.name ?? "") \(entry.app) \(entry.title) \(entry.edge)", query).map { (entry, $0) } }
      .sorted { $0.1 > $1.1 }
      .map { entry, _ in
        AlfredItem(
          title: name(of: entry), subtitle: "\(place(of: entry))  ·  ↩ open it  ·  ⇥ more",
          arg: "open-stashed\t--window\t\(entry.id)", valid: true, autocomplete: "stashed-window \(entry.id) ")
      }
    let extras = [
      (words: "open next", item: AlfredItem(
        title: "Open the Next Stashed Window", subtitle: "Again for the one after; after the last, it tucks away",
        arg: "open-stashed\tnext", valid: true)),
      (words: "unstash all", item: AlfredItem(
        title: "Unstash All", subtitle: "Put every stashed window back where it was", arg: "unstash\t--all", valid: true)),
    ]
    items += extras.filter { query.isEmpty || score($0.words, query) != nil }.map(\.item)
    return items.isEmpty ? [AlfredItem(title: "No stashed window matches", subtitle: query, arg: nil, valid: false)] : items
  }

  /// One stashed window: open it, unstash it, move its Tab to another edge, or name its Tab `query`.
  private static func actions(forStashed id: UInt32, query: String) -> [AlfredItem] {
    let response = request(CubicleRequest(command: "stashed"))
    guard let entry = response.stashed?.first(where: { $0.id == id }) else {
      return [AlfredItem(
        title: "That window isn't stashed any more", subtitle: "Go back and pick another", arg: nil, valid: false,
        autocomplete: "stashed ")]
    }
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let window = "--window\t\(id)"
    var choices: [(words: String, item: AlfredItem)] = [
      ("open", AlfredItem(title: "Open \(name(of: entry))", subtitle: "Bring it out and keep it out", arg: "open-stashed\t\(window)", valid: true)),
      ("unstash", AlfredItem(title: "Unstash", subtitle: "Back where it was, on the workspace showing", arg: "unstash\t\(window)", valid: true)),
    ]
    for edge in StashEdge.allCases where edge.rawValue != entry.edge {
      choices.append(("move \(edge.rawValue) edge", AlfredItem(
        title: "Move to the \(edge.rawValue.capitalized) Edge", subtitle: "Its Tab goes there", arg: "stash\t\(edge.rawValue)\t\(window)",
        valid: true)))
    }
    var items = choices.filter { trimmed.isEmpty || score($0.words, trimmed) != nil }.map(\.item)
    if trimmed.isEmpty {
      items.append(AlfredItem(
        title: "Rename Its Tab", subtitle: entry.name == nil ? "Type a name" : "Type a name; ↩ with none goes back to the app's name",
        arg: "rename-tab\t\t\(window)", valid: entry.name != nil))
    } else {
      items.append(AlfredItem(
        title: "Name Its Tab “\(trimmed)”", subtitle: "Shown instead of the app's name", arg: "rename-tab\t\(trimmed)\t\(window)",
        valid: true))
    }
    return items
  }

  /// The stacking commands, for the window you were in or the workspace under the cursor.
  private static func stacking(matching query: String) -> [AlfredItem] {
    let commands: [(String, String, String)] = [
      ("Next Window in the Stack", "Bring the next window in its zone's stack to the front", "cycle\tnext"),
      ("Previous Window in the Stack", "Bring the previous one to the front", "cycle\tprev"),
      ("Swap with the Zone on the Left", "Swap the window's stack with its neighbour's", "swap\tleft"),
      ("Swap with the Zone on the Right", "Swap the window's stack with its neighbour's", "swap\tright"),
      ("Swap with the Zone Above", "Swap the window's stack with its neighbour's", "swap\tup"),
      ("Swap with the Zone Below", "Swap the window's stack with its neighbour's", "swap\tdown"),
      ("Pause Stacking Here", "On the workspace under the cursor", "pause"),
      ("Resume Stacking Here", "On the workspace under the cursor", "resume"),
    ]
    let items = commands
      .compactMap { command in score(command.0, query).map { (command, $0) } }
      .sorted { $0.1 > $1.1 }
      .map { command, _ in AlfredItem(title: command.0, subtitle: command.1, arg: command.2, valid: true) }
    return items.isEmpty ? [AlfredItem(title: "No stacking command matches", subtitle: query, arg: nil, valid: false)] : items
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

  private static func name(of entry: CubicleStashedEntry) -> String {
    if let name = entry.name { return name }
    return entry.title.isEmpty || entry.title == entry.app ? entry.app : "\(entry.app) — \(entry.title)"
  }

  private static func place(of entry: CubicleStashedEntry) -> String {
    var parts = ["\(entry.edge.capitalized) edge"]
    if entry.isOut { parts.append("out") }
    if let badge = entry.badge { parts.append("badge \(badge)") }
    return parts.joined(separator: " · ")
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
