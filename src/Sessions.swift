// Every Claude Code session, as Pip sees it, from three places:
//
// 1. Each session's conversation file in ~/.claude/projects/, which Claude
//    Code appends to as it works: Pip reads the last lines of the recently
//    changed ones to tell what each session is doing. No setup needed.
// 2. The Claude desktop app's record of each Code-tab session, for its title.
// 3. Optionally, a hook (`Pip --hook`) on every prompt, tool call,
//    notification and stop, which adds what files can't show: a session
//    waiting for your approval. "Watch All Claude Sessions" in Pip's menu adds
//    or removes it in ~/.claude/settings.json, keeping a backup first.
//
// Regular claude.ai chats aren't on this Mac, so Pip can't see those.

import Foundation

let sessionsFolder = pipFolder.appendingPathComponent("sessions")
let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
let hookMarker = "# pip-pet"
let hookEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]

// ---------- the hook, run by Claude Code ----------

/// What a session is doing in a few words, from the tool it is about to use.
func describeTool(_ tool: String, _ input: [String: Any]) -> (mood: String, activity: String, line: String) {
  func text(_ key: String) -> String { (input[key] as? String) ?? "" }
  func short(_ s: String, _ room: Int = 44) -> String {
    let one = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return one.count > room ? String(one.prefix(room - 1)) + "…" : one
  }
  func file(_ key: String) -> String { (text(key) as NSString).lastPathComponent.isEmpty ? "a file" : (text(key) as NSString).lastPathComponent }

  switch tool {
  case "AskUserQuestion": return ("waiting", "", "I have a question for you!")
  case "ExitPlanMode": return ("waiting", "", "My plan is ready for your OK.")
  case "Bash": return ("working", "run", text("description").isEmpty ? "Running \(short(text("command"), 30))" : short(text("description")))
  case "Read": return ("working", "read", "Reading \(file("file_path"))")
  case "Edit", "MultiEdit": return ("working", "edit", "Editing \(file("file_path"))")
  case "NotebookEdit": return ("working", "edit", "Editing \(file("notebook_path"))")
  case "Write": return ("working", "write", "Writing \(file("file_path"))")
  case "Grep", "Glob": return ("working", "search", "Searching the code")
  case "WebSearch": return ("working", "web", "Searching the web for “\(short(text("query"), 28))”")
  case "WebFetch": return ("working", "web", "Reading a web page")
  case "Agent", "Task": return ("working", "helper", "Sent a helper: \(short(text("description"), 30))")
  case "Skill": return ("working", "read", "Reading up on \(short(text("skill"), 30))")
  case "TodoWrite": return ("working", "plan", "Updating the plan")
  default: break
  }
  if tool.hasPrefix("mcp__") {
    let parts = tool.components(separatedBy: "__")
    let server = (parts.count > 1 ? parts[1] : "").replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "_", with: " ")
    let action = (parts.count > 2 ? parts[2] : "a tool").replacingOccurrences(of: "_", with: " ")
    if tool.contains("update_plan") || tool.contains("wrap_up") { return ("working", "plan", "Updating the plan") }
    let isWeb = server.lowercased().contains("browser") || server.lowercased().contains("chrome") || action.lowercased().contains("search")
    return ("working", isWeb ? "web" : "tool", short("Using \(server.isEmpty ? "" : server + ": ")\(action)", 44))
  }
  return ("working", "tool", "Using \(tool)")
}

/// Reads one hook event from stdin and records it. Never fails loudly and
/// never blocks Claude: any problem just means Pip misses one update.
func runHook() -> Never {
  // Pip's own answers run through `claude` too; they are not a session to show.
  if ProcessInfo.processInfo.environment["PIP_AGENT"] != nil { exit(0) }
  let data = FileHandle.standardInput.readDataToEndOfFile()
  guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
    let sessionId = event["session_id"] as? String, !sessionId.isEmpty,
    let name = event["hook_event_name"] as? String
  else { exit(0) }

  let safeId = sessionId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
  let file = sessionsFolder.appendingPathComponent("\(safeId).json")
  if name == "SessionEnd" {
    try? FileManager.default.removeItem(at: file)
    exit(0)
  }

  var record = ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
  let cwd = (event["cwd"] as? String) ?? (record["cwd"] as? String) ?? ""
  record["sessionId"] = sessionId
  record["cwd"] = cwd
  record["project"] = (cwd as NSString).lastPathComponent
  if let transcript = event["transcript_path"] as? String { record["transcript"] = transcript }

  switch name {
  case "SessionStart":
    record["mood"] = "idle"; record["activity"] = ""; record["line"] = "Ready"
  case "UserPromptSubmit":
    record["mood"] = "thinking"; record["activity"] = ""; record["line"] = "Thinking…"
    if let prompt = event["prompt"] as? String {
      let one = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      record["prompt"] = one.count > 120 ? String(one.prefix(119)) + "…" : one
    }
  case "PreToolUse":
    let said = describeTool((event["tool_name"] as? String) ?? "", (event["tool_input"] as? [String: Any]) ?? [:])
    record["mood"] = said.mood; record["activity"] = said.activity; record["line"] = said.line
  case "PostToolUse":
    record["mood"] = "thinking"; record["activity"] = ""; record["line"] = "Thinking…"
  case "Notification":
    let message = (event["message"] as? String) ?? "Claude needs you"
    // Idle reminders ("waiting for your input") are not a request; leave the state alone.
    if message.lowercased().contains("waiting for your input") { break }
    record["mood"] = "waiting"; record["activity"] = ""; record["line"] = message
  case "Stop":
    record["mood"] = "done"; record["activity"] = ""; record["line"] = "All done! Your turn."
  default:
    exit(0)
  }
  record["updatedAt"] = Date().timeIntervalSince1970 * 1000

  try? FileManager.default.createDirectory(at: sessionsFolder, withIntermediateDirectories: true)
  if let out = try? JSONSerialization.data(withJSONObject: record) {
    try? out.write(to: file, options: .atomic)
  }
  exit(0)
}

// ---------- reading them back ----------

struct ClaudeSession {
  var id: String
  var title = ""
  var project: String
  var cwd: String
  var mood: String
  var activity: String
  var line: String
  var prompt: String
  var transcript: String
  var updatedAt: Double  // ms since 1970

  var ageSeconds: Double { Date().timeIntervalSince1970 - updatedAt / 1000 }

  /// What to call it: the desktop app's title, else the project folder.
  var label: String {
    let name = title.isEmpty ? project : title
    return name.count > 34 ? String(name.prefix(33)) + "…" : name
  }

  /// How much this session wants Pip's attention right now.
  var urgency: Int {
    switch mood {
    case "waiting": return 4
    case "oops": return 3
    case "working", "thinking", "talking": return 2
    case "done": return ageSeconds < 90 ? 1 : 0
    default: return 0
    }
  }

  var stateWord: String {
    switch mood {
    case "waiting": return "needs you"
    case "working": return "working"
    case "thinking": return "thinking"
    case "oops": return "hit a snag"
    case "done": return "done"
    case "talking": return "talking"
    case "sleeping": return "napping"
    default: return "idle"
    }
  }
}

func session(from record: [String: Any]) -> ClaudeSession? {
  guard let id = record["sessionId"] as? String else { return nil }
  let cwd = (record["cwd"] as? String) ?? ""
  return ClaudeSession(
    id: id,
    project: (record["project"] as? String) ?? (cwd as NSString).lastPathComponent,
    cwd: cwd,
    mood: (record["mood"] as? String) ?? "idle",
    activity: (record["activity"] as? String) ?? "",
    line: (record["line"] as? String) ?? "",
    prompt: (record["prompt"] as? String) ?? "",
    transcript: (record["transcript"] as? String) ?? "",
    updatedAt: (record["updatedAt"] as? Double) ?? 0)
}

/// Every session Pip knows about, from the hooks and from the Pip mod's own
/// status file, newest record per session. Sessions quiet for over two hours
/// are left out, and one that stopped reporting mid-task counts as idle.
func readSessions() -> [ClaudeSession] {
  var byId: [String: ClaudeSession] = [:]
  for one in sessionScanner.scan() { byId[one.id] = one }
  let titles = sessionScanner.titles
  let files = (try? FileManager.default.contentsOfDirectory(at: sessionsFolder, includingPropertiesForKeys: nil)) ?? []
  var records: [[String: Any]] = files.filter { $0.pathExtension == "json" }.compactMap {
    (try? Data(contentsOf: $0)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
  }
  if let data = try? Data(contentsOf: statusURL), var mod = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
    mod["sessionId"] != nil
  {
    if mod["project"] == nil { mod["project"] = "this session" }
    records.append(mod)
  }
  for record in records {
    guard var one = session(from: record) else { continue }
    if one.ageSeconds > 2 * 3600 { continue }
    if ["working", "thinking"].contains(one.mood), one.ageSeconds > 15 * 60 { one.mood = "idle"; one.line = "Quiet for a while" }
    if let known = byId[one.id], known.updatedAt >= one.updatedAt {
      if known.project == "this session", !one.project.isEmpty { byId[one.id]?.project = one.project }
      continue
    }
    if let known = byId[one.id], one.project == "this session" { one.project = known.project }
    if let known = byId[one.id], one.transcript.isEmpty { one.transcript = known.transcript }
    byId[one.id] = one
  }
  for (id, title) in titles where byId[id] != nil { byId[id]?.title = title }
  return byId.values.sorted { ($0.urgency, $0.updatedAt) > ($1.urgency, $1.updatedAt) }
}

/// A few lines about every session, for Pip's own answers.
func sessionsSummary(_ sessions: [ClaudeSession]) -> String {
  guard !sessions.isEmpty else { return "" }
  let formatter = RelativeDateTimeFormatter()
  var out = "The user's Claude Code sessions right now (most urgent first):\n"
  for s in sessions.prefix(12) {
    let when = formatter.localizedString(for: Date(timeIntervalSince1970: s.updatedAt / 1000), relativeTo: Date())
    out += "- \(s.title.isEmpty ? "" : "\"\(s.title)\" in ")\(s.project.isEmpty ? "a session" : s.project) (\(s.cwd)): \(s.stateWord), \"\(s.line)\", \(when)"
    if !s.prompt.isEmpty { out += "; last asked: \"\(s.prompt)\"" }
    if !s.transcript.isEmpty { out += "; transcript: \(s.transcript)" }
    out += "\n"
  }
  out += "Each transcript is that session's full conversation as JSON lines; read the end of it when the user asks what a session is doing or did."
  return out
}

// ---------- reading sessions from their conversation files ----------

let projectsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
let desktopSessionsFolder = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

/// What one conversation file last showed, and how far Pip has read it.
private struct FileState {
  var offset: UInt64 = 0          // bytes read so far; new lines start here
  var size: UInt64 = 0
  var cwd = ""
  var prompt = ""
  var title = ""
  var kind = "none"               // the last thing that happened (see `apply`)
  var tool = ""
  var toolInput: [String: Any] = [:]
  var at: Double = 0              // when it happened, ms since 1970
}

final class SessionScanner {
  private var files: [String: FileState] = [:]
  private var lastList = Date.distantPast
  private var known: [URL] = []
  private var lastTitleScan = Date.distantPast
  private(set) var titles: [String: String] = [:]

  /// Every session whose conversation saw real activity in the last two
  /// hours. Each file is followed from where Pip last stopped reading, so a
  /// busy session costs only its new lines, however long it has grown.
  func scan() -> [ClaudeSession] {
    let now = Date()
    if now.timeIntervalSince(lastTitleScan) > 5 { lastTitleScan = now; readTitles() }
    if now.timeIntervalSince(lastList) > 3 { lastList = now; known = listRecent(now) }
    var result: [ClaudeSession] = []
    for file in known {
      var state = files[file.path] ?? FileState()
      follow(file, &state)
      files[file.path] = state
      if let one = session(file, state), one.ageSeconds < 2 * 3600 { result.append(one) }
    }
    return result
  }

  /// Conversation files changed in the last two hours.
  private func listRecent(_ now: Date) -> [URL] {
    let fm = FileManager.default
    var out: [URL] = []
    for folder in (try? fm.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: nil)) ?? [] {
      for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      where file.pathExtension == "jsonl" {
        if let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
          now.timeIntervalSince(changed) < 2 * 3600
        {
          out.append(file)
        }
      }
    }
    return out
  }

  /// Reads what was added since last time. The first time, or when the file
  /// was rewritten, it reads backwards until it finds the last real message,
  /// since a long session can end with megabytes of bookkeeping.
  private func follow(_ file: URL, _ state: inout FileState) {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    if size == state.size { return }
    if size < state.offset || state.offset == 0 {
      state = FileState()
      var start = size
      var chunk: UInt64 = 512 * 1024
      while true {
        start = size > chunk ? size - chunk : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var entries = lines(data, dropFirst: start > 0)
        if let last = entries.lastIndex(where: { isMessage($0) }) {
          // Older lines may still hold the prompt and the folder.
          for entry in entries[..<last].reversed() {
            if state.prompt.isEmpty, entry["type"] as? String == "last-prompt", let p = entry["lastPrompt"] as? String { state.prompt = p }
            if state.cwd.isEmpty, let cwd = entry["cwd"] as? String { state.cwd = cwd }
            if state.title.isEmpty, entry["type"] as? String == "custom-title", let t = entry["customTitle"] as? String { state.title = t }
          }
          entries = Array(entries[last...])
          for entry in entries { apply(entry, &state) }
          break
        }
        if start == 0 || chunk >= 32 * 1024 * 1024 {
          for entry in entries { apply(entry, &state) }
          break
        }
        chunk *= 4
      }
      state.offset = size
      state.size = size
      return
    }
    try? handle.seek(toOffset: state.offset)
    let data = (try? handle.readToEnd()) ?? Data()
    // Keep a line still being written for next time.
    guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
    let complete = data.prefix(through: lastNewline)
    for entry in lines(complete, dropFirst: false) { apply(entry, &state) }
    state.offset += UInt64(complete.count)
    state.size = size
  }

  private func lines(_ data: Data, dropFirst: Bool) -> [[String: Any]] {
    var parts = data.split(separator: 0x0A, omittingEmptySubsequences: true)
    if dropFirst, !parts.isEmpty { parts.removeFirst() }  // likely cut in half
    return parts.compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
  }

  private func isMessage(_ entry: [String: Any]) -> Bool {
    let type = entry["type"] as? String
    guard type == "user" || type == "assistant" else { return false }
    return entry["isSidechain"] as? Bool != true && entry["isMeta"] as? Bool != true
      && entry["isCompactSummary"] as? Bool != true && entry["isVisibleInTranscriptOnly"] as? Bool != true
  }

  private static let isoWithFraction: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private func time(_ entry: [String: Any]) -> Double? {
    guard let stamp = entry["timestamp"] as? String else { return nil }
    let date = SessionScanner.isoWithFraction.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
    return date.map { $0.timeIntervalSince1970 * 1000 }
  }

  /// One line of a conversation: messages move the state on, bookkeeping
  /// only fills in the prompt, title and folder, and never counts as activity.
  private func apply(_ entry: [String: Any], _ state: inout FileState) {
    let type = entry["type"] as? String ?? ""
    if let cwd = entry["cwd"] as? String { state.cwd = cwd }
    switch type {
    case "last-prompt":
      if let p = entry["lastPrompt"] as? String { state.prompt = p }
      return
    case "custom-title":
      if let t = entry["customTitle"] as? String { state.title = t }
      return
    case "system":
      // The end of a turn, when stop hooks ran.
      if (entry["subtype"] as? String) == "stop_hook_summary", entry["isSidechain"] as? Bool != true {
        if state.kind == "text" || state.kind == "thinking" { state.kind = "stop" }
        if let at = time(entry) { state.at = at }
      }
      return
    default:
      break
    }
    guard isMessage(entry) else { return }
    let at = time(entry) ?? state.at
    let content = (entry["message"] as? [String: Any])?["content"]
    let blocks = content as? [[String: Any]] ?? []
    if type == "user" {
      let typed = (content as? String) ?? blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
      if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
        state.kind = "tool-result"
      } else if typed.hasPrefix("[Request interrupted") {
        state.kind = "interrupted"
      } else if !typed.isEmpty {
        state.kind = "prompt"
        if !typed.hasPrefix("<") { state.prompt = typed }
      } else {
        return
      }
    } else {
      if let use = blocks.last(where: { $0["type"] as? String == "tool_use" }) {
        state.kind = "tool"
        state.tool = use["name"] as? String ?? ""
        state.toolInput = use["input"] as? [String: Any] ?? [:]
      } else if blocks.contains(where: { $0["type"] as? String == "text" }) {
        state.kind = "text"
      } else if blocks.contains(where: { $0["type"] as? String == "thinking" }) {
        state.kind = "thinking"
      } else {
        return
      }
    }
    state.at = at
  }

  /// What the session is doing now, from what last happened and how long ago.
  private func session(_ file: URL, _ state: FileState) -> ClaudeSession? {
    guard state.kind != "none" else { return nil }
    let cwd = state.cwd
    var one = ClaudeSession(
      id: file.deletingPathExtension().lastPathComponent,
      project: cwd.isEmpty ? file.deletingLastPathComponent().lastPathComponent : (cwd as NSString).lastPathComponent,
      cwd: cwd, mood: "idle", activity: "", line: "Ready", prompt: "", transcript: file.path, updatedAt: state.at)
    one.title = state.title
    let flat = state.prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    one.prompt = flat.count > 120 ? String(flat.prefix(119)) + "…" : flat
    let age = one.ageSeconds
    switch state.kind {
    case "prompt", "tool-result", "thinking":
      (one.mood, one.line) = ("thinking", "Thinking…")
    case "tool":
      let said = describeTool(state.tool, state.toolInput)
      (one.mood, one.activity, one.line) = (said.mood, said.activity, said.line)
    case "text":
      // A reply with no tool after it: done, unless more is on its way.
      (one.mood, one.line) = age < 6 ? ("thinking", "Writing…") : ("done", "All done! Your turn.")
    case "stop":
      (one.mood, one.line) = ("done", "All done! Your turn.")
    case "interrupted":
      (one.mood, one.line) = ("idle", "Stopped.")
    default:
      break
    }
    // Nothing new for a long while in the middle of a task: it ended without
    // a reply, or it is waiting on something Pip can't see.
    if ["thinking", "working"].contains(one.mood), age > 15 * 60 { (one.mood, one.activity, one.line) = ("idle", "", "Quiet for a while") }
    return one
  }

  /// The desktop app's title for each of its Code sessions, by session id.
  private func readTitles() {
    var out: [String: String] = [:]
    let fm = FileManager.default
    guard let walker = fm.enumerator(at: desktopSessionsFolder, includingPropertiesForKeys: nil) else { return }
    for case let file as URL in walker where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
      guard let data = try? Data(contentsOf: file),
        let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        record["isArchived"] as? Bool != true,
        let id = record["cliSessionId"] as? String,
        let title = record["title"] as? String, !title.isEmpty
      else { continue }
      out[id] = title
    }
    titles = out
  }
}

let sessionScanner = SessionScanner()

// ---------- adding and removing the hooks ----------

func hookCommand() -> String {
  let path = Bundle.main.executablePath ?? "\(NSHomeDirectory())/Applications/Pip.app/Contents/MacOS/Pip"
  return "\"\(path)\" --hook \(hookMarker)"
}

func readSettings() -> [String: Any]? {
  guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
  guard let data = try? Data(contentsOf: settingsURL) else { return nil }
  if data.isEmpty { return [:] }
  return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func areHooksInstalled() -> Bool {
  guard let hooks = readSettings()?["hooks"] as? [String: Any] else { return false }
  return hookEvents.allSatisfy { event in
    ((hooks[event] as? [[String: Any]]) ?? []).contains { group in
      ((group["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains(hookMarker) == true }
    }
  }
}

/// Adds Pip's hooks to (or removes them from) the user's Claude Code settings,
/// leaving every other setting and hook as it was. Returns why it failed.
@discardableResult
func setHooksInstalled(_ on: Bool) -> String? {
  guard var settings = readSettings() else { return "~/.claude/settings.json isn't valid JSON, so I left it alone." }
  var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
  for event in hookEvents {
    var groups = (hooks[event] as? [[String: Any]]) ?? []
    // Take out any earlier Pip hook (an older app path, say), keep the rest.
    groups = groups.compactMap { group in
      var group = group
      let kept = ((group["hooks"] as? [[String: Any]]) ?? []).filter { ($0["command"] as? String)?.contains(hookMarker) != true }
      if kept.isEmpty { return nil }
      group["hooks"] = kept
      return group
    }
    if on {
      var group: [String: Any] = ["hooks": [["type": "command", "command": hookCommand(), "timeout": 5]]]
      if event == "PreToolUse" || event == "PostToolUse" { group["matcher"] = "*" }
      groups.append(group)
    }
    if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
  }
  if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }

  do {
    try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.pip-backup")
    if FileManager.default.fileExists(atPath: settingsURL.path), !FileManager.default.fileExists(atPath: backup.path) {
      try FileManager.default.copyItem(at: settingsURL, to: backup)
    }
    let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
    try data.write(to: settingsURL, options: .atomic)
  } catch {
    return "I couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
  }
  if !on { try? FileManager.default.removeItem(at: sessionsFolder) }
  return nil
}
