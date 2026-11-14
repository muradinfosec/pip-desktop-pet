// Pip on the desktop: a small transparent window that floats above every app.
//
// Drag to move, click to pat, right-click (or the menu bar icon) for the menu.
// Press Control-Option-P anywhere to talk to Pip: it listens, then answers in
// its bubble and out loud through the `claude` command (Claude Code's CLI).
//
// Optional: anything that writes ~/.claude/pip-pet/status.json (see the
// README) can tell Pip what it is doing, and Pip acts it out.

import AVFoundation
import Carbon
import Cocoa
import ServiceManagement
import Speech
import WebKit

let pipFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/pip-pet")
let statusURL = pipFolder.appendingPathComponent("status.json")
let askURL = pipFolder.appendingPathComponent("ask.json")
let shortcutLabel = "⌃⌥P"

// Pip itself (the drawing, its emotions and everything it does) is pet.html,
// shipped in the app's Resources. PIP_PAGE names another copy while developing.
let pageURL: URL? = {
  if let path = ProcessInfo.processInfo.environment["PIP_PAGE"] { return URL(fileURLWithPath: path) }
  return Bundle.main.url(forResource: "pet", withExtension: "html")
}()
let isDebug = ProcessInfo.processInfo.environment["PIP_DEBUG"] != nil

// ---------- the window ----------

final class PetView: WKWebView {
  weak var owner: AppDelegate?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // A press that moves carries Pip (it dangles and its leaves trail behind);
  // one that doesn't is a pat.
  override func mouseDown(with event: NSEvent) {
    guard let window = window, let owner = owner else { return }
    let startMouse = NSEvent.mouseLocation
    let startOrigin = window.frame.origin
    var lastMouse = startMouse
    var lastTime = event.timestamp
    var isCarried = false
    owner.isDragging = true
    defer { owner.isDragging = false }

    while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
      if next.type == .leftMouseUp { break }
      let mouse = NSEvent.mouseLocation
      let dx = mouse.x - startMouse.x, dy = mouse.y - startMouse.y
      if !isCarried && hypot(dx, dy) > 3 {
        isCarried = true
        owner.js("grab()")
      }
      guard isCarried else { continue }
      window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
      let dt = max(next.timestamp - lastTime, 0.004)
      owner.js("drag(\(Int((mouse.x - lastMouse.x) / dt)), \(Int(-(mouse.y - lastMouse.y) / dt)))")
      lastMouse = mouse
      lastTime = next.timestamp
    }
    if isCarried {
      owner.js("drop()")
      window.saveFrame(usingName: "PipPanel")
    } else {
      owner.js("pat()")
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? { owner?.buildMenu() }
}

// ---------- the app ----------

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSMenuDelegate,
  AVSpeechSynthesizerDelegate
{
  var hitRects: [NSRect] = []  // where Pip and its bubble are, in the view's own coordinates
  var isDragging = false
  var isHovering = false
  var lastPointer = NSPoint(x: -9999, y: -9999)
  var pointerTick = 0
  var statusItem: NSStatusItem!

  var panel: NSPanel!
  var view: PetView!
  var lastStamp: Date?
  var isLoaded = false
  var sessionId: String?
  var spokenReplyId: String?
  var history: [(said: String, reply: String)] = []
  var startedAt = Date().timeIntervalSince1970 * 1000

  // dictation
  let audio = AVAudioEngine()
  let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  var request: SFSpeechAudioBufferRecognitionRequest?
  var task: SFSpeechRecognitionTask?
  var heard = ""
  var quietTimer: Timer?
  var isListening = false

  // voice
  let voice = AVSpeechSynthesizer()
  var speaksAnswers: Bool {
    get { UserDefaults.standard.object(forKey: "speaksAnswers") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "speaksAnswers") }
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    let size = NSSize(width: 260, height: 300)
    panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.hidesOnDeactivate = false

    if panel.setFrameUsingName("PipPanel") {
      panel.setContentSize(size)
    } else if let screen = NSScreen.main {
      let area = screen.visibleFrame
      panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 24, y: area.minY + 24))
    }
    panel.setFrameAutosaveName("PipPanel")

    let config = WKWebViewConfiguration()
    config.userContentController.add(self, name: "hit")
    config.userContentController.add(self, name: "log")
    view = PetView(frame: NSRect(origin: .zero, size: size), configuration: config)
    view.setValue(false, forKey: "drawsBackground")
    view.navigationDelegate = self
    view.owner = self
    if let url = pageURL {
      view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    voice.delegate = self
    panel.contentView = view
    panel.orderFrontRegardless()
    if isDebug { NSLog("window: %d", panel.windowNumber) }

    registerShortcut()
    setUpOpenAtLogin()
    setUpMenuBar()
    Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
    panel.ignoresMouseEvents = true
    let follow = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.followPointer() }
    RunLoop.main.add(follow, forMode: .common)
  }

  // Only Pip and its bubble take clicks; the empty space around them lets
  // every click through to whatever is underneath.
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.name == "log" {
      if isDebug { NSLog("page: %@", "\(message.body)") }
      return
    }
    guard let parts = message.body as? [[Double]] else { return }
    let height = view.bounds.height
    hitRects = parts.compactMap { part in
      guard part.count == 4 else { return nil }
      return NSRect(x: part[0], y: height - part[1] - part[3], width: part[2], height: part[3])
    }
    if isDebug { NSLog("clickable: %@ of %@", "\(hitRects)", "\(view.bounds)") }
  }

  func followPointer() {
    guard !isDragging else { return }
    let mouse = NSEvent.mouseLocation
    let inWindow = panel.convertPoint(fromScreen: mouse)
    let isOverPip = panel.isVisible && hitRects.contains { $0.insetBy(dx: -4, dy: -4).contains(inWindow) }
    if panel.ignoresMouseEvents == isOverPip {
      panel.ignoresMouseEvents = !isOverPip
    }
    guard isLoaded, panel.isVisible else { return }
    if isOverPip != isHovering {
      isHovering = isOverPip
      js("hover(\(isOverPip))")
    }
    // Pip's eyes follow the pointer: where it is from Pip's face, y down.
    pointerTick += 1
    if pointerTick % 2 == 0, abs(mouse.x - lastPointer.x) + abs(mouse.y - lastPointer.y) > 2 {
      lastPointer = mouse
      let face = NSPoint(x: panel.frame.midX, y: panel.frame.minY + 68)
      js("pointerAt(\(Int(mouse.x - face.x)), \(Int(face.y - mouse.y)))")
    }
  }

  // Pip's mouth moves while its voice is speaking.
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { js("speaking(true)") }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { js("speaking(false)") }
  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { js("speaking(false)") }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isLoaded = true
    lastStamp = nil
    poll()

    // For trying Pip without a microphone:
    //   open ~/Applications/Pip.app --args --ask "how are you?"        (session first)
    //   open ~/Applications/Pip.app --args --ask-alone "how are you?"  (no session)
    //   open ~/Applications/Pip.app --args --eval "pat()"              (run a page call)
    let args = CommandLine.arguments
    //   open ~/Applications/Pip.app --args --say "hello"               (hear Pip's voice)
    if let at = args.firstIndex(of: "--say"), at + 1 < args.count {
      let text = args[at + 1]
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.js("answered(\(self.quoted(text)))"); self.speak(text) }
    }
    if let at = args.firstIndex(of: "--eval"), at + 1 < args.count {
      let call = args[at + 1]
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.js(call) }
    }
    for flag in ["--ask", "--ask-alone"] {
      if let at = args.firstIndex(of: flag), at + 1 < args.count {
        let said = args[at + 1]
        js("asking(\(quoted(said)))")
        flag == "--ask" ? ask(said) : answerAlone(said)
      }
    }
  }

  func js(_ call: String) { view.evaluateJavaScript(call) }

  func quoted(_ text: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [text])
    let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(array.dropFirst().dropLast())
  }

  // ---------- reading the mod's status ----------

  func poll() {
    guard isLoaded,
      let stamp = (try? FileManager.default.attributesOfItem(atPath: statusURL.path))?[.modificationDate] as? Date,
      stamp != lastStamp,
      let data = try? Data(contentsOf: statusURL),
      let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let json = String(data: data, encoding: .utf8)
    else { return }
    lastStamp = stamp
    sessionId = status["sessionId"] as? String
    js("show(\(json))")

    if let reply = status["reply"] as? [String: Any],
      let id = reply["id"] as? String, id != spokenReplyId,
      let text = reply["text"] as? String,
      let at = reply["at"] as? Double, at > startedAt - 1000
    {
      spokenReplyId = id
      js("settle()")
      speak(text)
    }
  }

  // ---------- the shortcut ----------

  func registerShortcut() {
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x5049_5021), id: 1)  // "PIP!"
    RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
      DispatchQueue.main.async { delegate.toggleListening() }
      return noErr
    }, 1, &spec, nil, nil)
  }

  @objc func toggleListening() {
    if !isListening { panel.orderFrontRegardless() }
    isListening ? finishListening(send: true) : startListening()
  }

  // ---------- the menu bar icon and the shared menu ----------

  // The menu bar's menu is filled fresh each time it opens.
  func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

  func setUpMenuBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem.button?.image = menuBarImage()
    statusItem.button?.toolTip = "Pip"
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
    if ProcessInfo.processInfo.environment["PIP_DEBUG"] != nil {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        NSLog("menu bar icon: visible %d, at %@", self.statusItem.isVisible ? 1 : 0, "\(self.statusItem.button?.window?.frame ?? .zero)")
      }
    }
  }

  // A small template silhouette of Pip: round body, two leaves on a stem.
  func menuBarImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      NSColor.black.set()
      NSBezierPath(ovalIn: NSRect(x: 2.5, y: 1.5, width: 13, height: 11.5)).fill()
      let stem = NSBezierPath()
      stem.move(to: NSPoint(x: 9, y: 12.5)); stem.line(to: NSPoint(x: 9, y: 15))
      stem.lineWidth = 1.3; stem.stroke()
      let left = NSBezierPath()
      left.move(to: NSPoint(x: 9, y: 14.6))
      left.curve(to: NSPoint(x: 4.6, y: 15.6), controlPoint1: NSPoint(x: 7.8, y: 16.6), controlPoint2: NSPoint(x: 5.6, y: 16.8))
      left.curve(to: NSPoint(x: 9, y: 14.6), controlPoint1: NSPoint(x: 6.2, y: 14.4), controlPoint2: NSPoint(x: 7.8, y: 14.2))
      left.fill()
      let right = NSBezierPath()
      right.move(to: NSPoint(x: 9, y: 14.8))
      right.curve(to: NSPoint(x: 13.6, y: 16.2), controlPoint1: NSPoint(x: 10.4, y: 17), controlPoint2: NSPoint(x: 12.6, y: 17.2))
      right.curve(to: NSPoint(x: 9, y: 14.8), controlPoint1: NSPoint(x: 12, y: 14.8), controlPoint2: NSPoint(x: 10.4, y: 14.4))
      right.fill()
      // eyes cut out of the body
      NSGraphicsContext.current?.compositingOperation = .clear
      NSBezierPath(ovalIn: NSRect(x: 5.6, y: 6.6, width: 1.9, height: 2.6)).fill()
      NSBezierPath(ovalIn: NSRect(x: 10.5, y: 6.6, width: 1.9, height: 2.6)).fill()
      return true
    }
    image.isTemplate = true
    return image
  }

  func buildMenu() -> NSMenu {
    let menu = NSMenu()
    fill(menu)
    return menu
  }

  func fill(_ menu: NSMenu) {
    menu.removeAllItems()
    func add(_ title: String, _ action: Selector, on: Bool? = nil) {
      let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      item.target = self
      if let on = on { item.state = on ? .on : .off }
    }
    if let line = currentLine, !line.isEmpty {
      let said = menu.addItem(withTitle: line.count > 60 ? String(line.prefix(59)) + "…" : line, action: nil, keyEquivalent: "")
      said.isEnabled = false
      menu.addItem(.separator())
    }
    add(panel.isVisible ? "Hide Pip" : "Show Pip", #selector(toggleShown))
    add("Move Pip to the Corner", #selector(moveToCorner))
    add(isListening ? "Stop Listening (\(shortcutLabel))" : "Talk to Pip (\(shortcutLabel))", #selector(toggleListening))
    add("Pat Pip", #selector(patPip))
    menu.addItem(.separator())
    add("Speak Answers", #selector(toggleSpeaking), on: speaksAnswers)
    add("Pet Voice", #selector(togglePetVoice), on: usesPetVoice)
    add("Open at Login", #selector(toggleOpenAtLogin), on: opensAtLogin)
    menu.addItem(.separator())
    add("Open Claude", #selector(openClaude))
    add("Quit Pip", #selector(quit))
  }

  var currentLine: String? {
    guard let data = try? Data(contentsOf: statusURL),
      let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return nil }
    return status["line"] as? String
  }

  @objc func toggleShown() {
    if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
  }

  @objc func moveToCorner() {
    guard let area = NSScreen.main?.visibleFrame else { return }
    panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 24, y: area.minY + 24))
    panel.orderFrontRegardless()
  }

  @objc func patPip() {
    panel.orderFrontRegardless()
    js("pat()")
  }

  @objc func openClaude() {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
      NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
  }

  @objc func quit() { NSApp.terminate(nil) }

  // ---------- open at login ----------

  var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

  // The first launch adds Pip to Login Items; after that it is the person's
  // choice, from the menu or System Settings → General → Login Items.
  func setUpOpenAtLogin() {
    let defaults = UserDefaults.standard
    if !defaults.bool(forKey: "didSetUpOpenAtLogin") {
      defaults.set(true, forKey: "didSetUpOpenAtLogin")
      try? SMAppService.mainApp.register()
    }
    if ProcessInfo.processInfo.environment["PIP_DEBUG"] != nil {
      NSLog("open at login: %d (status %d)", opensAtLogin ? 1 : 0, SMAppService.mainApp.status.rawValue)
    }
  }

  @objc func toggleOpenAtLogin() {
    do {
      if opensAtLogin {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
    } catch {
      js("settle(\(quoted("macOS wouldn't change that. Try System Settings → General → Login Items.")))")
    }
  }

  @objc func toggleSpeaking() {
    speaksAnswers.toggle()
    if !speaksAnswers { voice.stopSpeaking(at: .immediate) }
  }

  // ---------- dictation ----------

  func startListening() {
    SFSpeechRecognizer.requestAuthorization { speech in
      AVCaptureDevice.requestAccess(for: .audio) { mic in
        DispatchQueue.main.async {
          guard speech == .authorized, mic else {
            self.js("settle(\(self.quoted("I can't hear you. Allow Pip to use the microphone and speech recognition in System Settings → Privacy & Security.")))")
            return
          }
          self.beginRecognition()
        }
      }
    }
  }

  func beginRecognition() {
    guard !isListening, let recognizer = recognizer, recognizer.isAvailable else {
      js("settle(\(quoted("Speech recognition isn't available right now.")))")
      return
    }
    voice.stopSpeaking(at: .immediate)
    heard = ""

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    self.request = request

    let input = audio.inputNode
    let format = input.outputFormat(forBus: 0)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      request.append(buffer)
    }
    audio.prepare()
    do {
      try audio.start()
    } catch {
      js("settle(\(quoted("I couldn't open the microphone.")))")
      return
    }

    isListening = true
    js("listening()")
    NSSound(named: "Tink")?.play()
    waitForQuiet(seconds: 8)  // give up if nothing is said

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async {
        guard let self = self, self.isListening else { return }
        if let result = result {
          self.heard = result.bestTranscription.formattedString
          self.js("listening(\(self.quoted(self.heard)))")
          if result.isFinal { self.finishListening(send: true); return }
          self.waitForQuiet(seconds: 1.6)  // a pause ends the question
        } else if error != nil {
          self.finishListening(send: true)
        }
      }
    }
  }

  func waitForQuiet(seconds: TimeInterval) {
    quietTimer?.invalidate()
    quietTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      self?.finishListening(send: true)
    }
  }

  func finishListening(send: Bool) {
    guard isListening else { return }
    isListening = false
    quietTimer?.invalidate()
    audio.stop()
    audio.inputNode.removeTap(onBus: 0)
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil

    let said = heard.trimmingCharacters(in: .whitespacesAndNewlines)
    guard send, !said.isEmpty else {
      js("settle(\(quoted("I didn't catch that. Press \(shortcutLabel) and try again.")))")
      return
    }
    NSSound(named: "Pop")?.play()
    js("asking(\(quoted(said)))")
    ask(said)
  }

  func ask(_ said: String) {
    var question: [String: Any] = [
      "id": UUID().uuidString,
      "text": said,
      "at": Date().timeIntervalSince1970 * 1000,
    ]
    if let sessionId = sessionId { question["to"] = sessionId }
    let id = question["id"] as! String
    do {
      try FileManager.default.createDirectory(at: pipFolder, withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: question).write(to: askURL, options: .atomic)
    } catch {
      answerAlone(said)
      return
    }
    // A running session claims the question within a second. If none does
    // (Claude is closed, or the session that last fed Pip has ended), Pip
    // claims it and answers on its own.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      guard let self = self, self.isUnclaimed(id) else { return }
      try? JSONSerialization.data(withJSONObject: ["id": id, "handled": true, "by": "desktop"]).write(to: askURL, options: .atomic)
      self.answerAlone(said)
    }
    // Never stay stuck thinking.
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in self?.js("if (local === 'asking') settle()") }
  }

  func isUnclaimed(_ id: String) -> Bool {
    guard let data = try? Data(contentsOf: askURL),
      let ask = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return false }
    return ask["id"] as? String == id && ask["handled"] as? Bool != true
  }

  // ---------- answering without a session ----------

  let alonePrompt = """
    You are Pip, a small, friendly pet that lives on the user's Mac desktop and keeps them company.
    Chat, answer questions and give quick advice. Reply in one to three short sentences that sound
    natural when read aloud, in the language the user spoke. Use plain words only: no markdown, lists,
    code or emoji. You cannot see the user's screen or files and you have no tools.
    """

  func claudePath() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let places = [
      "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
      "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude",
    ]
    return places.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  func answerAlone(_ said: String) {
    guard let claude = claudePath() else {
      finishAnswer(said, "I can't find the claude command on this Mac, so I can only answer while Claude Code is open.", remember: false)
      return
    }
    var prompt = ""
    if !history.isEmpty {
      prompt += "Earlier in this chat:\n"
      for turn in history.suffix(5) { prompt += "User: \(turn.said)\nPip: \(turn.reply)\n" }
      prompt += "\n"
    }
    prompt += "The user just said out loud: \"\(said)\""

    DispatchQueue.global(qos: .userInitiated).async {
      let run = Process()
      run.executableURL = URL(fileURLWithPath: claude)
      run.arguments = [
        "-p", "--model", "haiku", "--tools", "", "--no-session-persistence",
        "--output-format", "text", "--system-prompt", self.alonePrompt,
      ]
      run.currentDirectoryURL = pipFolder
      var env = ProcessInfo.processInfo.environment
      env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
      run.environment = env
      let input = Pipe(), output = Pipe()
      run.standardInput = input
      run.standardOutput = output
      run.standardError = output

      var text = ""
      do {
        try run.run()
        input.fileHandleForWriting.write(prompt.data(using: .utf8)!)
        try? input.fileHandleForWriting.close()
        let killer = DispatchWorkItem { if run.isRunning { run.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        run.waitUntilExit()
        killer.cancel()
        text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      } catch {
        text = ""
      }

      let isSignedOut = text.localizedCaseInsensitiveContains("authenticate") || text.localizedCaseInsensitiveContains("/login")
        || text.localizedCaseInsensitiveContains("not logged in")
      DispatchQueue.main.async {
        if isSignedOut {
          self.finishAnswer(said, "I need you to sign me in first. Open Terminal and run: claude auth login", remember: false)
        } else if run.terminationStatus != 0 || text.isEmpty {
          self.finishAnswer(said, "Sorry, I couldn't think of an answer just now.", remember: false)
        } else {
          self.finishAnswer(said, text, remember: true)
        }
      }
    }
  }

  func finishAnswer(_ said: String, _ reply: String, remember: Bool) {
    if remember {
      history.append((said, reply))
      if history.count > 10 { history.removeFirst(history.count - 10) }
    }
    js("answered(\(quoted(reply)))")
    speak(reply)
  }

  // ---------- speaking ----------

  var usesPetVoice: Bool {
    get { UserDefaults.standard.object(forKey: "usesPetVoice") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "usesPetVoice") }
  }

  var systemVoice: AVSpeechSynthesisVoice? {
    AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))
      ?? AVSpeechSynthesisVoice(language: "en-US")
  }

  // The voice Pip's own is made from: the best natural voice this Mac has in
  // the person's language (novelty voices left out), a lighter one preferred.
  lazy var petBaseVoice: AVSpeechSynthesisVoice? = {
    let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    let language = String(locale.prefix(2))
    func score(_ voice: AVSpeechSynthesisVoice) -> Int {
      var points = voice.quality.rawValue * 100
      if !voice.identifier.contains("super-compact") { points += 40 }
      if voice.language == locale { points += 20 }
      if voice.gender == .female { points += 10 }
      if voice.identifier == systemVoice?.identifier { points += 5 }
      return points
    }
    return AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.identifier.hasPrefix("com.apple.voice.") && $0.language.hasPrefix(language) }
      .max { score($0) < score($1) } ?? systemVoice
  }()

  func speak(_ text: String) {
    guard speaksAnswers else { return }
    voice.stopSpeaking(at: .immediate)
    let line = AVSpeechUtterance(string: text)
    if usesPetVoice {
      // High and quick, like a small creature: about 325 Hz on Samantha,
      // whose own voice sits near 175 Hz, and 15% faster than normal.
      line.voice = petBaseVoice
      line.pitchMultiplier = 1.85
      line.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
    } else {
      line.voice = systemVoice
    }
    if isDebug { NSLog("speaking with %@, pitch %.2f, rate %.2f", line.voice?.identifier ?? "none", line.pitchMultiplier, line.rate) }
    voice.speak(line)
  }

  @objc func togglePetVoice() {
    usesPetVoice.toggle()
    speak(usesPetVoice ? "This is my pet voice!" : "This is my normal voice.")
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
