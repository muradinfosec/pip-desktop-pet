// Pip doing things for you, through the `claude` command (Claude Code's CLI).
//
// Pip runs `claude -p` with streamed JSON in and out. Claude can read files,
// search and look things up freely. Anything that runs a command, changes a
// file, or uses a connector (email, Jira, Confluence…) comes back as a
// permission request, and Pip asks you first: Allow or Deny in its bubble, or
// "yes" / "no" by voice. How much Pip may do is the Computer Access setting.

import Foundation

enum ComputerAccess: String, CaseIterable {
  case off, read, ask

  var title: String {
    switch self {
    case .off: return "Just Chat"
    case .read: return "Read Files Only"
    case .ask: return "Do Things, Ask Me First"
    }
  }

  static var current: ComputerAccess {
    get { ComputerAccess(rawValue: UserDefaults.standard.string(forKey: "computerAccess") ?? "") ?? .ask }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "computerAccess") }
  }
}

/// Tools that only look: Pip lets these through without asking.
func isLookOnly(_ tool: String) -> Bool {
  let builtIn: Set<String> = ["Read", "Glob", "Grep", "LS", "WebSearch", "WebFetch", "TodoWrite", "ToolSearch", "NotebookRead", "Skill", "Agent", "Task"]
  if builtIn.contains(tool) { return true }
  guard tool.hasPrefix("mcp__") else { return false }
  // A connector's tool that only reads: its name starts with a reading verb.
  let action = (tool.components(separatedBy: "__").last ?? "").lowercased()
  let verbs = ["get", "list", "search", "read", "fetch", "find", "lookup", "query", "view", "describe", "show", "browser_snapshot", "browser_take_screenshot"]
  return verbs.contains { action.hasPrefix($0) }
}

protocol PipAgentHost: AnyObject {
  func agentDoing(activity: String, line: String)
  func agentNeedsApproval(question: String, spoken: String, detail: String)
  func agentFinished(said: String, reply: String, remember: Bool)
}

final class PipAgent {
  weak var host: PipAgentHost?
  private var process: Process?
  private var input: FileHandle?
  private var buffer = Data()
  private var lastText = ""
  private var pending: (id: String, input: Any)?
  private var approvalTimer: Timer?
  private var killer: DispatchWorkItem?
  private var said = ""
  private var isFinished = true

  var isRunning: Bool { !isFinished }
  var isWaitingForApproval: Bool { pending != nil }

  static func claudePath() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let places = [
      "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
      "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude",
    ]
    return places.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  static func instructions(_ access: ComputerAccess, sessions: String) -> String {
    var out = """
      You are Pip, a small, friendly pet that lives on the user's Mac desktop and helps them.
      The user talks to you by voice, and your final reply is read aloud: one to three short sentences
      in plain words, with no markdown, lists, code or emoji, in the language the user spoke.
      Your working directory is the user's home folder.

      """
    switch access {
    case .off:
      out += "You have no tools: you can't see their files or screen, run commands or reach other services."
    case .read:
      out += "You can read files, search, and look things up in connected services (use ToolSearch to find their tools), but you can't run commands, change files or send anything. If they ask for that, tell them to switch Computer Access to \"Do Things, Ask Me First\" in Pip's menu."
    case .ask:
      out += """
        You can read files, run shell commands, change files and use the user's connected services
        (such as email, Jira or Confluence). The user approves every command, file change and connector
        action before it happens, so go ahead and try what the task needs; if they deny something, don't
        retry it, just say what you would have done. Never delete or overwrite anything unless they clearly
        asked. Before sending anything to other people, make sure it says exactly what they asked for.
        Connected services load on demand: use ToolSearch to find their tools (for example "Jira",
        "Confluence", "Gmail", "Slack") before saying you can't do something. If a service needs
        authorizing, tell the user to connect it in their claude.ai connector settings.
        """
    }
    if access != .off, !sessions.isEmpty { out += "\n\n" + sessions }
    return out
  }

  func start(said: String, history: [(said: String, reply: String)], sessions: String) {
    stop()
    guard let claude = PipAgent.claudePath() else {
      host?.agentFinished(said: said, reply: "I can't find the claude command on this Mac, so I can only answer while Claude Code is open.", remember: false)
      return
    }
    self.said = said
    lastText = ""
    buffer = Data()
    isFinished = false

    var prompt = ""
    if !history.isEmpty {
      prompt += "Earlier in this chat:\n"
      for turn in history.suffix(5) { prompt += "User: \(turn.said)\nPip: \(turn.reply)\n" }
      prompt += "\n"
    }
    prompt += "The user just said out loud: \"\(said)\"\n"
    prompt += "(This came from speech recognition, so some words may be misheard. Go by what they most likely meant; if it's truly unclear, ask them in one short question.)"

    let access = ComputerAccess.current
    var args = [
      "-p", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose",
      "--model", "haiku", "--no-session-persistence", "--max-turns", "20",
      "--permission-prompt-tool", "stdio",
      "--append-system-prompt", PipAgent.instructions(access, sessions: sessions),
    ]
    switch access {
    case .off: args += ["--tools", "", "--strict-mcp-config"]
    case .read: args += ["--tools", "Read,Glob,Grep,WebSearch,WebFetch,ToolSearch"]
    case .ask: break
    }

    let run = Process()
    run.executableURL = URL(fileURLWithPath: claude)
    run.arguments = args
    run.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
    env["PIP_AGENT"] = "1"  // so Pip's own run isn't shown as one of your sessions
    run.environment = env
    let inPipe = Pipe(), outPipe = Pipe()
    run.standardInput = inPipe
    run.standardOutput = outPipe
    run.standardError = outPipe

    outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      DispatchQueue.main.async { self?.receive(chunk) }
    }
    run.terminationHandler = { [weak self] _ in
      DispatchQueue.main.async { self?.ended() }
    }

    do {
      try run.run()
    } catch {
      isFinished = true
      host?.agentFinished(said: said, reply: "I couldn't start the claude command.", remember: false)
      return
    }
    process = run
    input = inPipe.fileHandleForWriting
    send(["type": "user", "message": ["role": "user", "content": prompt]])
    host?.agentDoing(activity: "", line: "Hmm, let me see…")

    let stopper = DispatchWorkItem { [weak self] in self?.stop(saying: "That took too long, so I stopped.") }
    killer = stopper
    DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: stopper)
  }

  /// Stops whatever Pip is doing; a pending approval is denied.
  func stop(saying reason: String? = nil) {
    guard let run = process, !isFinished else { return }
    if let reason = reason { finish(reason, remember: false) }
    isFinished = true
    approvalTimer?.invalidate()
    pending = nil
    if run.isRunning { run.terminate() }
  }

  // ---------- your answer to a permission request ----------

  func decide(allow: Bool, because note: String? = nil) {
    guard let request = pending else { return }
    pending = nil
    approvalTimer?.invalidate()
    let answer: [String: Any] =
      allow
      ? ["behavior": "allow", "updatedInput": request.input]
      : ["behavior": "deny", "message": note ?? "The user said no."]
    send(["type": "control_response", "response": ["subtype": "success", "request_id": request.id, "response": answer]])
  }

  /// Turns what was said while a request waits into an answer.
  func decide(byVoice said: String) {
    let words = said.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    let yes = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "allow", "go ahead", "do it", "approve", "fine", "please do"]
    let no = ["no", "nope", "don't", "do not", "deny", "stop", "cancel", "never", "nah"]
    if no.contains(where: { words == $0 || words.hasPrefix($0 + " ") }) {
      decide(allow: false)
    } else if yes.contains(where: { words == $0 || words.hasPrefix($0 + " ") || words.hasPrefix($0 + ",") }) {
      decide(allow: true)
    } else {
      decide(allow: false, because: "The user didn't approve this and said instead: \"\(said)\"")
    }
  }

  // ---------- reading what claude sends ----------

  private func send(_ message: [String: Any]) {
    guard let input = input, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    input.write(data + Data("\n".utf8))
  }

  private func receive(_ chunk: Data) {
    if chunk.isEmpty { return }
    buffer.append(chunk)
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer.subdata(in: buffer.startIndex..<newline)
      buffer.removeSubrange(buffer.startIndex...newline)
      if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
        handle(message)
      } else if let text = String(data: line, encoding: .utf8), !text.isEmpty {
        lastText = text  // a plain error line, such as a sign-in problem
      }
    }
  }

  private func handle(_ message: [String: Any]) {
    guard !isFinished else { return }
    switch message["type"] as? String {
    case "assistant":
      let content = ((message["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
      for block in content {
        if block["type"] as? String == "tool_use", let name = block["name"] as? String {
          let said = describeTool(name, (block["input"] as? [String: Any]) ?? [:])
          host?.agentDoing(activity: said.activity, line: said.line)
        } else if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
          lastText = text
        }
      }
    case "control_request":
      handleControl(message)
    case "result":
      let text = (message["result"] as? String) ?? lastText
      let isError = (message["is_error"] as? Bool) ?? false
      if isError || text.isEmpty {
        let subtype = (message["subtype"] as? String) ?? ""
        finish(subtype == "error_max_turns" ? "That was a big job and I ran out of steps. Ask me to keep going?" : explain(text), remember: false)
      } else {
        finish(text, remember: true)
      }
      try? input?.close()
    default:
      break
    }
  }

  private func handleControl(_ message: [String: Any]) {
    guard let id = message["request_id"] as? String, let request = message["request"] as? [String: Any] else { return }
    guard request["subtype"] as? String == "can_use_tool", let tool = request["tool_name"] as? String else {
      send(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Pip doesn't handle this request."]])
      return
    }
    let toolInput = request["input"] ?? [:]
    if isLookOnly(tool) {
      pending = (id, toolInput)
      decide(allow: true)
      return
    }
    pending = (id, toolInput)
    if ComputerAccess.current != .ask {
      decide(allow: false, because: "Pip's Computer Access setting doesn't allow this. Tell the user to switch it to \"Do Things, Ask Me First\" in Pip's menu.")
      return
    }
    let (question, spoken, detail) = describeRequest(tool, (toolInput as? [String: Any]) ?? [:], request["description"] as? String)
    host?.agentNeedsApproval(question: question, spoken: spoken, detail: detail)
    approvalTimer?.invalidate()
    approvalTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
      self?.decide(allow: false, because: "The user didn't answer in time.")
    }
  }

  /// The question Pip asks, what it says out loud, and the exact thing it would do.
  private func describeRequest(_ tool: String, _ input: [String: Any], _ description: String?) -> (String, String, String) {
    func clip(_ s: String, _ room: Int = 300) -> String { s.count > room ? String(s.prefix(room - 1)) + "…" : s }
    switch tool {
    case "Bash":
      return ("Can I run this command?", "Can I run a command?", clip((input["command"] as? String) ?? ""))
    case "Write":
      return ("Can I write this file?", "Can I write a file?", (input["file_path"] as? String) ?? "")
    case "Edit", "MultiEdit", "NotebookEdit":
      return ("Can I change this file?", "Can I change a file?", (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? "")
    default:
      break
    }
    if tool.hasPrefix("mcp__") {
      let parts = tool.components(separatedBy: "__")
      let server = (parts.count > 1 ? parts[1] : "a connector")
        .replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "_", with: " ")
      let action = (parts.count > 2 ? parts[2] : "").replacingOccurrences(of: "_", with: " ")
      let keys = ["to", "recipients", "subject", "title", "summary", "issueKey", "issueIdOrKey", "spaceId", "pageId", "channel", "cloudId", "name"]
      var lines = keys.compactMap { key -> String? in
        guard let value = input[key] else { return nil }
        return "\(key): \(clip("\(value)", 80))"
      }
      for key in ["body", "text", "content", "comment", "description", "message"] {
        if let value = input[key] as? String { lines.append("\(key): \(clip(value, 140))"); break }
      }
      if lines.isEmpty, let data = try? JSONSerialization.data(withJSONObject: input), let json = String(data: data, encoding: .utf8) {
        lines = [clip(json, 240)]
      }
      return ("Can I use \(server): \(action)?", "Can I use \(server)?", lines.joined(separator: "\n"))
    }
    let detail = description ?? ((try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
    return ("Can I use \(tool)?", "Can I use \(tool)?", clip(detail))
  }

  private func explain(_ text: String) -> String {
    let lower = text.lowercased()
    if lower.contains("authenticate") || lower.contains("/login") || lower.contains("not logged in") || lower.contains("oauth") {
      return "I need you to sign me in first. Open Terminal and run: claude auth login"
    }
    return "Sorry, something went wrong and I couldn't finish that."
  }

  private func finish(_ reply: String, remember: Bool) {
    guard !isFinished else { return }
    isFinished = true
    killer?.cancel()
    approvalTimer?.invalidate()
    pending = nil
    host?.agentFinished(said: said, reply: reply, remember: remember)
  }

  private func ended() {
    process?.standardOutput.flatMap { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
    if !isFinished { finish(lastText.isEmpty ? "Sorry, I couldn't finish that." : explain(lastText), remember: false) }
    process = nil
    input = nil
  }
}
