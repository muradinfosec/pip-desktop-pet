// Pip's own window onto claude.ai, for watching chats.
//
// A chat in the Claude app answers on claude.ai, and nothing on this Mac
// records it. So you sign in to claude.ai once, inside Pip, in this window,
// the way you would in a browser tab. Pip then asks claude.ai about your
// recent chats from that signed-in page. Your sign-in stays in WebKit's own
// storage for Pip: Pip's code never reads, copies or stores it, and talks to
// nobody but claude.ai.

import Cocoa
import WebKit

final class ClaudeWeb: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
  static let shared = ClaudeWeb()

  enum State { case starting, signedOut, signedIn }
  private(set) var state = State.starting
  private var web: WKWebView!
  private var window: NSWindow?
  private var busy = false
  private var lastAsk = Date.distantPast
  var onChange: (() -> Void)?

  /// The newest result of asking claude.ai, as plain data.
  private(set) var latest: [[String: Any]] = []
  private(set) var latestAt = Date.distantPast
  private var lastSummary = ""

  func start() {
    guard web == nil else { return }
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()   // keeps you signed in between launches
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: config)
    web.navigationDelegate = self
    web.uiDelegate = self
    web.load(URLRequest(url: URL(string: "https://claude.ai/")!))
    note("opening claude.ai")
  }

  /// Shows the sign-in page in a small window of its own.
  func showSignIn() {
    start()
    note("showing the sign-in window")
    if window == nil {
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      w.title = "Sign in to Claude for Pip"
      w.isReleasedWhenClosed = false
      w.delegate = self
      w.center()
      window = w
    }
    window?.contentView = web
    if state != .signedIn, web.url?.path.hasPrefix("/login") != true {
      web.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    // Keep the page alive without the window; it still answers Pip.
    window?.contentView = nil
  }

  // Sign-in with Google or single sign-on opens a pop-up that hands the
  // result back to the page that opened it, so it gets a real window.
  private var popups: [WKWebView: NSWindow] = [:]

  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
               for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
    popup.uiDelegate = self
    popup.navigationDelegate = self
    let w = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.title = "Sign in"
    w.isReleasedWhenClosed = false
    w.contentView = popup
    if let main = window { w.setFrameTopLeftPoint(NSPoint(x: main.frame.minX + 40, y: main.frame.maxY - 40)) } else { w.center() }
    w.makeKeyAndOrderFront(nil)
    popups[popup] = w
    note("opened a sign-in pop-up")
    return popup
  }

  func webViewDidClose(_ webView: WKWebView) {
    if let w = popups.removeValue(forKey: webView) { w.contentView = nil; w.close(); note("sign-in pop-up closed") }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    note("loaded \(webView.url?.host ?? "?")\(webView.url?.path ?? "")\(webView === web ? "" : " (pop-up)")")
    guard webView === web else { return }
    checkSignedIn()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    note("page failed: \(error.localizedDescription)")
    if webView === web { checkSignedIn() }
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    note("page didn't load: \(error.localizedDescription)")
    if webView === web { checkSignedIn() }
  }

  /// The last few things that happened, in ~/.claude/pip-pet/chats-status.txt,
  /// so a problem can be found without rebuilding Pip. Never holds page content.
  private var notes: [String] = []
  func note(_ text: String) {
    notes.append("\(Date()) \(text)")
    if notes.count > 30 { notes.removeFirst(notes.count - 30) }
    try? notes.joined(separator: "\n").write(to: pipFolder.appendingPathComponent("chats-status.txt"), atomically: true, encoding: .utf8)
  }

  private func checkSignedIn() {
    run("const r = await fetch('/api/organizations', {credentials: 'include'}); return r.status") { [weak self] value in
      guard let self else { return }
      let signed = (value as? NSNumber)?.intValue == 200
      let before = self.state
      self.note("signed-in check: \(value.map { "\($0)" } ?? "script failed") at \(self.web.url?.path ?? "?")")
      self.state = signed ? .signedIn : .signedOut
      if signed, self.window?.isVisible == true, self.web.url?.path.hasPrefix("/login") != true {
        self.window?.close()
      }
      if before != self.state { self.onChange?() }
      // Chats are on but nobody is signed in yet: open the window once.
      if before == .starting, self.state == .signedOut, UserDefaults.standard.bool(forKey: "watchChats") { self.showSignIn() }
    }
  }

  /// Runs a script in the page, apart from the page's own scripts, and hands
  /// back what it returns.
  func run(_ body: String, done: @escaping (Any?) -> Void) {
    guard let web else { done(nil); return }
    web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let value): done(value)
      case .failure(let error):
        self.note("script failed: \(error.localizedDescription.prefix(160))")
        done(nil)
      }
    }
  }

  /// Asks claude.ai for your recent chats now and then. Pip reads the answer
  /// from `latest`, so it never waits on the network.
  func tick() {
    guard UserDefaults.standard.bool(forKey: "watchChats") else { return }
    start()
    let gap = latest.contains { ($0["answering"] as? Bool) == true } ? 2.5 : 6.0
    guard !busy, state == .signedIn, Date().timeIntervalSince(lastAsk) > gap else {
      if state == .signedOut, Date().timeIntervalSince(lastAsk) > 30 { lastAsk = Date(); checkSignedIn() }
      return
    }
    busy = true
    lastAsk = Date()
    run(ClaudeWeb.chatsScript) { [weak self] value in
      guard let self else { return }
      self.busy = false
      if let text = value as? String, let data = text.data(using: .utf8),
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      {
        if reply["signedOut"] as? Bool == true { self.state = .signedOut; self.note("claude.ai says signed out"); self.onChange?(); return }
        if let error = reply["error"] as? String { self.note("asking for chats failed: \(error)") }
        self.latest = reply["chats"] as? [[String: Any]] ?? []
        self.latestAt = Date()
        let answering = self.latest.filter { $0["answering"] as? Bool == true }.map { "“\(($0["title"] as? String ?? "").prefix(30))” \($0["doing"] as? String ?? "")" }
        let summary = "chats: \(self.latest.count), answering: " + (answering.isEmpty ? "none" : answering.joined(separator: ", "))
        if summary != self.lastSummary { self.lastSummary = summary; self.note(summary) }
      }
    }
  }

  /// Your recent chats. For the two touched most recently it also reads the
  /// newest message: your question with no reply yet, or a reply that hasn't
  /// ended, means Claude is still answering. Returns only titles, times, the
  /// start of your question and what Claude is doing; never whole messages.
  static let chatsScript = """
    const get = async path => {
      const r = await fetch(path, {credentials: 'include'})
      if (r.status === 401) throw 'signed out'
      if (!r.ok) return null
      return r.json()
    }
    try {
      const orgs = await get('/api/organizations')
      if (!orgs) throw 'signed out'
      const chats = []
      for (const org of orgs.filter(o => (o.capabilities || []).includes('chat')).slice(0, 3)) {
        const list = await get(`/api/organizations/${org.uuid}/chat_conversations?limit=10`)
        for (const c of list || []) {
          const updated = Date.parse(c.updated_at) || 0
          const settled = c.last_settled_at ? Date.parse(c.last_settled_at) : 0
          chats.push({ id: c.uuid, org: org.uuid, title: c.name || '', updated, settled,
            answering: updated - settled > 2000 && Date.now() - updated < 30 * 60 * 1000 })
        }
      }
      chats.sort((a, b) => b.updated - a.updated)
      for (const chat of chats.slice(0, 2)) {
        if (Date.now() - chat.updated > 2 * 3600 * 1000) continue
        const c = await get(`/api/organizations/${chat.org}/chat_conversations/${chat.id}?tree=False&rendering_mode=messages&render_all_tools=true`)
        const messages = (c && c.chat_messages) || []
        const last = messages[messages.length - 1]
        if (!last) continue
        const human = [...messages].reverse().find(m => m.sender === 'human')
        const said = human && ((human.content || []).find(b => b.type === 'text') || {}).text
        if (said) chat.prompt = said.replace(/\\s+/g, ' ').slice(0, 140)
        const created = Date.parse(last.created_at) || 0
        if (last.sender === 'human') {
          chat.answering = Date.now() - created < 30 * 60 * 1000
          chat.doing = ''
        } else {
          chat.answering = !last.stop_reason && Date.now() - created < 30 * 60 * 1000
          const tools = (last.content || []).filter(b => b.type === 'tool_use')
          const open = (last.content || []).filter(b => !b.stop_timestamp).pop()
          const tool = tools.length ? tools[tools.length - 1].name || '' : ''
          chat.doing = chat.answering ? (open && open.type === 'tool_use' ? open.name || tool : open ? open.type : tool) : ''
          if (!chat.answering) chat.settled = Math.max(chat.settled, Date.parse(last.updated_at) || created)
        }
      }
      return JSON.stringify({ chats })
    } catch (e) {
      return JSON.stringify(e === 'signed out' ? { signedOut: true } : { error: String(e) })
    }
    """

  /// The chats as sessions Pip can show beside Claude Code's.
  func sessions() -> [ClaudeSession] {
    guard UserDefaults.standard.bool(forKey: "watchChats"), state == .signedIn else { return [] }
    let now = Date().timeIntervalSince1970 * 1000
    return latest.compactMap { chat in
      guard let id = chat["id"] as? String else { return nil }
      let updated = (chat["updated"] as? NSNumber)?.doubleValue ?? 0
      let settled = (chat["settled"] as? NSNumber)?.doubleValue ?? 0
      let answering = chat["answering"] as? Bool == true
      var one = ClaudeSession(
        id: "chat-" + id, project: "Claude chat", cwd: "", mood: "done", activity: "", line: "All done! Your turn.",
        prompt: chat["prompt"] as? String ?? "", transcript: "", updatedAt: max(updated, settled))
      one.title = chat["title"] as? String ?? ""
      if answering {
        let doing = (chat["doing"] as? String ?? "").lowercased()
        one.mood = "working"
        one.updatedAt = now
        switch true {
        case doing.contains("search"), doing.contains("fetch"), doing.contains("web"):
          (one.activity, one.line) = ("web", "Searching the web")
        case doing.contains("research"), doing.contains("compass"):
          (one.activity, one.line) = ("web", "Researching")
        case doing == "thinking":
          (one.activity, one.line) = ("", "Thinking it over…")
          one.mood = "thinking"
        case doing.contains("artifact"), doing.contains("create_file"), doing.contains("str_replace"):
          (one.activity, one.line) = ("write", "Making an artifact")
        case !doing.isEmpty && doing != "text":
          (one.activity, one.line) = ("run", "Using \(doing.replacingOccurrences(of: "_", with: " "))")
        default:
          (one.activity, one.line) = ("write", "Writing an answer…")
        }
      }
      return one
    }
  }
}
