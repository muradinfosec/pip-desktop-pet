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
    // A background-task notice arrives as a prompt too; it isn't what you asked.
    if let prompt = event["prompt"] as? String, !prompt.hasPrefix("<"), !prompt.hasPrefix("[SYSTEM NOTIFICATION") {
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
  var background = 0     // background tasks still running

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

/// Every session Pip knows about: read from the conversations, with the
/// hooks' records on top when they are newer. Sessions quiet for over twelve
/// hours are left out, and one that stopped mid-task counts as idle.
func readSessions() -> [ClaudeSession] {
  var byId: [String: ClaudeSession] = [:]
  for one in sessionScanner.scan() { byId[one.id] = one }
  // Chats in the Claude app, asked of claude.ai (ClaudeWeb.swift).
  for one in ClaudeWeb.shared.sessions() { byId[one.id] = one }
  let titles = sessionScanner.titles
  let files = (try? FileManager.default.contentsOfDirectory(at: sessionsFolder, includingPropertiesForKeys: nil)) ?? []
  var records: [[String: Any]] = files.filter { $0.pathExtension == "json" }.compactMap {
    (try? Data(contentsOf: $0)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
  }
  // A status file a script wrote by hand (see the README) counts as one more
  // thing to show while it is fresh. One that names a session is the old Pip
  // mod's: its session is already read from the conversation itself, and a
  // stale copy must never outrank what is really happening.
  if let data = try? Data(contentsOf: statusURL), var manual = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
    manual["sessionId"] == nil, manual["mood"] != nil
  {
    let written = (try? FileManager.default.attributesOfItem(atPath: statusURL.path))?[.modificationDate] as? Date
    let at = (manual["updatedAt"] as? Double) ?? (written?.timeIntervalSince1970 ?? 0) * 1000
    if Date().timeIntervalSince1970 - at / 1000 < 600 {
      manual["sessionId"] = "status-file"; manual["updatedAt"] = at
      records.append(manual)
    }
  }
  for record in records {
    guard var one = session(from: record) else { continue }
    if one.ageSeconds > watchWindow { continue }
    if one.ageSeconds > (one.mood == "working" ? 60 * 60 : one.mood == "thinking" ? 15 * 60 : .infinity) { one.mood = "idle"; one.line = "Quiet for a while" }
    // The hook says "done" when a turn ends, even while background work it
    // started still runs; the conversation knows better.
    let settled = one.mood == "done" || one.mood == "idle"
    if let known = byId[one.id], known.updatedAt >= one.updatedAt || (known.background > 0 && settled) {
      if known.project == "this session", !one.project.isEmpty { byId[one.id]?.project = one.project }
      continue
    }
    if let known = byId[one.id], one.project == "this session" { one.project = known.project }
    if let known = byId[one.id], one.transcript.isEmpty { one.transcript = known.transcript }
    byId[one.id] = one
  }
  for (id, title) in titles where byId[id] != nil { byId[id]?.title = title }
  // After a restart Claude continues a conversation in a new file and leaves
  // the old one behind. The desktop app knows which is current: a file that
  // carries the same title but isn't the one the app points to is the old copy.
  let current = Set(titles.values)
  for (id, one) in byId where titles[id] == nil && !one.title.isEmpty && current.contains(one.title) {
    byId.removeValue(forKey: id)
  }
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

/// How far back Pip keeps a session in view: twelve hours.
let watchWindow: Double = 12 * 3600
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
  var thought = ""                // what Claude last thought, when the file holds it
  /// Background commands, monitors and helpers still running, by task id,
  /// with the time (ms since 1970) after which Pip stops believing in them.
  var background: [String: (kind: String, what: String, since: Double, until: Double)] = [:]
  /// What each recent tool call said it would do, by call id, so a task that
  /// goes to the background keeps its description.
  var calls: [String: String] = [:]

  func running(_ now: Double) -> [(kind: String, what: String, since: Double, until: Double)] {
    background.values.filter { $0.until > now }.sorted { $0.since < $1.since }
  }
}

final class SessionScanner {
  private var files: [String: FileState] = [:]
  private var lastList = Date.distantPast
  private var known: [URL] = []
  private var lastTitleScan = Date.distantPast
  private(set) var titles: [String: String] = [:]

  /// Every session whose conversation saw real activity in the last twelve
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
      if let one = session(file, state), one.ageSeconds < watchWindow { result.append(one) }
    }
    return result
  }

  /// Conversation files changed in the last twelve hours.
  private func listRecent(_ now: Date) -> [URL] {
    let fm = FileManager.default
    var out: [URL] = []
    for folder in (try? fm.contentsOfDirectory(at: projectsFolder, includingPropertiesForKeys: nil)) ?? [] {
      for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      where file.pathExtension == "jsonl" {
        if let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
          now.timeIntervalSince(changed) < watchWindow
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
          var noted = ""  // Claude's own note of the last prompt: a fallback, as it can lag behind
          for entry in entries[..<last].reversed() {
            if noted.isEmpty, entry["type"] as? String == "last-prompt", let p = entry["lastPrompt"] as? String { noted = p }
            if state.prompt.isEmpty, isMessage(entry), entry["type"] as? String == "user" {
              let typed = typedText((entry["message"] as? [String: Any])?["content"])
              if !typed.isEmpty, !typed.hasPrefix("[Request interrupted") { state.prompt = typed }
            }
            if state.cwd.isEmpty, let cwd = entry["cwd"] as? String { state.cwd = cwd }
            if state.title.isEmpty, entry["type"] as? String == "custom-title", let t = entry["customTitle"] as? String { state.title = t }
          }
          // The request itself can be megabytes further back; look once more.
          if state.prompt.isEmpty, start > 0, chunk < 16 * 1024 * 1024 {
            state = FileState()
            chunk *= 4
            continue
          }
          // Background tasks started before the last message may still run.
          for entry in entries[..<last] { track(entry, &state) }
          entries = Array(entries[last...])
          for entry in entries { apply(entry, &state) }
          if state.prompt.isEmpty { state.prompt = noted }
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

  /// What the person typed in a message: its first text that isn't a note the
  /// app added around it (those start with a tag such as <system-reminder>).
  private func typedText(_ content: Any?) -> String {
    // Notes the app adds (<system-reminder>, <task-notification>, system
    // notices) aren't what the person typed.
    func typed(_ text: String) -> Bool {
      let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return !t.isEmpty && !t.hasPrefix("<") && !t.hasPrefix("[SYSTEM NOTIFICATION")
    }
    if let text = content as? String { return typed(text) ? text : "" }
    let texts = (content as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    return texts.first(where: typed) ?? ""
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
    track(entry, &state)
    switch type {
    case "last-prompt":
      if state.prompt.isEmpty, let p = entry["lastPrompt"] as? String { state.prompt = p }
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
      let typed = typedText(content)
      let hasText = content is String || blocks.contains { $0["type"] as? String == "text" }
      if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
        state.kind = "tool-result"
      } else if typed.hasPrefix("[Request interrupted") {
        state.kind = "interrupted"
      } else if hasText {
        state.kind = "prompt"
        if !typed.isEmpty { state.prompt = typed }
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
      } else if let block = blocks.last(where: { $0["type"] as? String == "thinking" }) {
        state.kind = "thinking"
        state.thought = thoughtLine(block["thinking"] as? String ?? "")
      } else {
        return
      }
    }
    state.at = at
  }

  /// Notes background work starting and ending. Claude reports a start in the
  /// tool's result ("Command running in background with ID: …") and an end in
  /// a <task-notification> that carries a <status>. Only text that begins with
  /// these counts, so a conversation that merely quotes them changes nothing.
  private func track(_ entry: [String: Any], _ state: inout FileState) {
    let type = entry["type"] as? String ?? ""
    guard entry["isSidechain"] as? Bool != true else { return }
    let content = (entry["message"] as? [String: Any])?["content"]
    if type == "assistant" {
      // Remember what each call that may go to the background is for.
      for block in content as? [[String: Any]] ?? [] where block["type"] as? String == "tool_use" {
        guard let id = block["id"] as? String, let name = block["name"] as? String,
          ["Bash", "Monitor", "Agent", "Task"].contains(name) else { continue }
        let input = block["input"] as? [String: Any] ?? [:]
        let said = (input["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if state.calls.count > 100 { state.calls.removeAll() }
        state.calls[id] = !said.isEmpty ? said : name == "Bash" ? "running \(input["command"] as? String ?? "a command")" : ""
      }
      return
    }
    guard type == "user" || type == "queue-operation" else { return }
    var notes: [String] = [], results: [(call: String, text: String)] = []
    if let text = entry["content"] as? String { notes.append(text) }
    if let text = content as? String { notes.append(text) }
    for block in content as? [[String: Any]] ?? [] {
      switch block["type"] as? String {
      case "text": if let text = block["text"] as? String { notes.append(text) }
      case "tool_result":
        let call = block["tool_use_id"] as? String ?? ""
        if let text = block["content"] as? String { results.append((call, text)) }
        for part in block["content"] as? [[String: Any]] ?? [] { if let text = part["text"] as? String { results.append((call, text)) } }
      default: break
      }
    }
    let at = time(entry) ?? Date().timeIntervalSince1970 * 1000
    let hours2 = 2 * 3600 * 1000.0
    for (call, text) in results {
      let what = state.calls.removeValue(forKey: call) ?? ""
      if let id = word(after: "Command running in background with ID: ", in: text, atStart: true) {
        state.background[id] = ("command", what, at, at + hours2)
      } else if let id = word(after: "Monitor started (task ", in: text, atStart: true) {
        let minutes = word(after: "expires in ", in: text, atStart: false).flatMap { Double($0.prefix { $0.isNumber }) }
        state.background[id] = ("monitor", what, at, minutes.map { at + ($0 + 1) * 60 * 1000 } ?? at + hours2)
      } else if text.hasPrefix("Async agent launched"), let id = word(after: "agentId: ", in: text, atStart: false) {
        state.background[id] = ("helper", what, at, at + hours2)
      } else if let id = word(after: "{\"message\":\"Successfully stopped task: ", in: text, atStart: true)
        ?? word(after: "<tool_use_error>Task ", in: text, atStart: true)
      {
        state.background[id] = nil
      }
    }
    for text in notes where text.hasPrefix("<task-notification>") {
      for one in text.components(separatedBy: "<task-notification>") where one.contains("<status>") {
        for piece in one.components(separatedBy: "<task-id>").dropFirst() {
          if let end = piece.range(of: "</task-id>") { state.background[String(piece[..<end.lowerBound])] = nil }
        }
      }
    }
  }

  /// The id-like word right after `prefix` in `text`.
  private func word(after prefix: String, in text: String, atStart: Bool) -> String? {
    guard let found = atStart ? (text.hasPrefix(prefix) ? text.range(of: prefix) : nil) : text.range(of: prefix) else { return nil }
    let id = text[found.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    return id.isEmpty ? nil : String(id)
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
    case "prompt", "tool-result":
      (one.mood, one.line) = ("thinking", "Thinking…")
    case "thinking":
      // Claude's own thinking, when the conversation holds it (it can also
      // be kept private, and then Pip just says it's thinking).
      (one.mood, one.line) = ("thinking", state.thought.isEmpty ? "Thinking…" : "💭 " + state.thought)
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
    // A reply that ends the turn while background work still runs: Claude
    // isn't done, it is waiting for that work to report back.
    let busy = state.running(Date().timeIntervalSince1970 * 1000)
    if !busy.isEmpty, one.mood == "done" {
      let helpers = busy.filter { $0.kind == "helper" }.count
      one.mood = "working"
      one.background = busy.count
      one.activity = helpers == busy.count ? "helper" : "run"
      // Say what each task is, in the words Claude gave it.
      func named(_ task: (kind: String, what: String, since: Double, until: Double), _ room: Int) -> String {
        let flat = task.what.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let what = flat.count > room ? String(flat.prefix(room - 1)) + "…" : flat
        switch task.kind {
        case "monitor": return what.isEmpty ? "watching for results" : "watching \(lowerFirst(what))"
        case "helper": return what.isEmpty ? "a helper at work" : "helper: \(what)"
        default: return what.isEmpty ? "a command" : what
        }
      }
      let items = busy.prefix(3).map { named($0, busy.count > 1 ? 48 : 90) }
      let more = busy.count > 3 ? " · and \(busy.count - 3) more" : ""
      one.line = "In the background: " + items.joined(separator: " · ") + more
      return one
    }
    // Nothing new for a long while in the middle of a task: it ended without
    // a reply, or it is waiting on something Pip can't see.
    // A tool can run for a long time (a build, a helper agent), so a working
    // session stays working for an hour; a silent "thinking" one for 15 minutes.
    if busy.isEmpty, age > (one.mood == "working" ? 60 * 60 : one.mood == "thinking" ? 15 * 60 : .infinity) { (one.mood, one.activity, one.line) = ("idle", "", "Quiet for a while") }
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

/// "Fork rerun" → "fork rerun", but leaves names such as "README" alone.
func lowerFirst(_ s: String) -> String {
  guard let first = s.first, first.isUppercase, !(s.dropFirst().first?.isUppercase ?? false) else { return s }
  return first.lowercased() + s.dropFirst()
}

/// Claude's thinking, made fit for the bubble: one paragraph, no markdown,
/// cut at a sentence end near 240 characters.
func thoughtLine(_ raw: String) -> String {
  var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  // A bold heading on its own line becomes "Heading: …".
  if text.hasPrefix("**"), let end = text.range(of: "**", range: text.index(text.startIndex, offsetBy: 2)..<text.endIndex),
    text[end.upperBound...].first?.isNewline == true
  {
    text = text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound] + ": " + text[end.upperBound...]
  }
  text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
  text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  guard text.count > 240 else { return text }
  let head = String(text.prefix(240))
  if let end = head.lastIndex(where: { ".!?".contains($0) }), head.distance(from: head.startIndex, to: end) > 80 {
    return String(head[...end])
  }
  return String(head.prefix(239)) + "…"
}
