import Cocoa
import WebKit
import ServiceManagement

// File-based diagnostics so we can debug without depending on the unified log.
private let diagLogPath = "/tmp/anooki-app.log"

private func diag(_ message: String) {
    NSLog("[Anooki] %@", message)
    let line = "\(Date()) [pid \(getpid())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: diagLogPath) {
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: diagLogPath)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    } else {
        try? data.write(to: URL(fileURLWithPath: diagLogPath))
    }
}

// Distributed notification that Dock posts on Tahoe when the hot corner is
// configured for "Start Screen Saver". Also fired by other system code paths
// that want to start a screensaver.
private let kScreenSaverActionNotification = Notification.Name("com.apple.screensaver.action")
private let kScreenSaverDidLaunchNotification = Notification.Name("com.apple.screensaver.didlaunch")
private let kScreenSaverWillStopNotification = Notification.Name("com.apple.screensaver.willstop")

// User-default keys.
private let kIdleThresholdKey = "AnookiIdleThresholdSeconds"
private let kIdleDisabled = -1

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var overlayWindows: [OverlayWindow] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?

    // Idle detection
    private var idleCheckTimer: Timer?
    private var idleThreshold: TimeInterval {
        get {
            let stored = UserDefaults.standard.integer(forKey: kIdleThresholdKey)
            // Default: 300s = 5 min. 0 (unset) → use default. -1 → disabled.
            if stored == 0 { return 300 }
            if stored == kIdleDisabled { return -1 }
            return TimeInterval(stored)
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: kIdleThresholdKey)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        diag("applicationDidFinishLaunching")

        setupStatusItem()
        setupDistributedNotifications()
        startIdleMonitoring()

        diag("Anooki listening. Idle threshold = \(idleThresholdLabel()).")
    }

    func applicationWillTerminate(_ notification: Notification) {
        diag("applicationWillTerminate")
        dismissOverlay()
    }

    // MARK: - Status item (menu bar fallback trigger)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "A"
            button.toolTip = "Anooki"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let startItem = NSMenuItem(title: "Start Anooki Now",
                                   action: #selector(startFromMenu), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)
        menu.addItem(NSMenuItem.separator())

        // Idle-activation submenu.
        let idleParent = NSMenuItem(title: "Start when idle…", action: nil, keyEquivalent: "")
        let idleMenu = NSMenu()
        let choices: [(label: String, seconds: Int)] = [
            ("Off", kIdleDisabled),
            ("1 minute", 60),
            ("3 minutes", 180),
            ("5 minutes", 300),
            ("10 minutes", 600),
            ("15 minutes", 900),
            ("30 minutes", 1800),
        ]
        let currentSeconds = Int(idleThreshold)
        for choice in choices {
            let mi = NSMenuItem(title: choice.label,
                                action: #selector(selectIdleThreshold(_:)),
                                keyEquivalent: "")
            mi.target = self
            mi.representedObject = choice.seconds
            mi.state = (choice.seconds == currentSeconds) ? .on : .off
            idleMenu.addItem(mi)
        }
        idleParent.submenu = idleMenu
        menu.addItem(idleParent)

        // Open at login.
        let loginItem = NSMenuItem(title: "Open at Login",
                                   action: #selector(toggleOpenAtLogin),
                                   keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isRegisteredAsLoginItem() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Anooki",
                                  action: #selector(quitFromMenu), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
    }

    @objc private func startFromMenu() {
        diag("triggered from status menu")
        showOverlay()
    }

    @objc private func quitFromMenu() {
        diag("quit from status menu")
        NSApp.terminate(nil)
    }

    @objc private func selectIdleThreshold(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        idleThreshold = TimeInterval(seconds)
        diag("idle threshold set to \(idleThresholdLabel())")
        // Reset the timer so the new threshold takes effect immediately.
        stopIdleMonitoring()
        startIdleMonitoring()
        refreshMenu()
    }

    @objc private func toggleOpenAtLogin() {
        if isRegisteredAsLoginItem() {
            do {
                try SMAppService.mainApp.unregister()
                diag("unregistered from login items")
            } catch {
                diag("unregister failed: \(error.localizedDescription)")
            }
        } else {
            do {
                try SMAppService.mainApp.register()
                diag("registered as login item")
            } catch {
                diag("register failed: \(error.localizedDescription)")
            }
        }
        refreshMenu()
    }

    private func isRegisteredAsLoginItem() -> Bool {
        return SMAppService.mainApp.status == .enabled
    }

    private func idleThresholdLabel() -> String {
        let t = Int(idleThreshold)
        if t < 0 { return "off" }
        if t < 60 { return "\(t)s" }
        return "\(t / 60)m"
    }

    // MARK: - Idle monitoring

    private func startIdleMonitoring() {
        guard idleThreshold > 0 else {
            diag("idle monitoring disabled")
            return
        }
        // Poll once a second. Cheap; CGEventSource call is just a syscall.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleCheckTimer = timer
        diag("idle monitoring started (threshold=\(idleThresholdLabel()))")
    }

    private func stopIdleMonitoring() {
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
    }

    private func checkIdle() {
        guard idleThreshold > 0 else { return }
        guard overlayWindows.isEmpty else { return } // already shown
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)
        if idle >= idleThreshold {
            diag("idle \(Int(idle))s >= threshold \(Int(idleThreshold))s — activating")
            lockSessionIfPossible()
            showOverlay()
        }
    }

    /// Invokes the user-session lock the same way Apple's screensaver does
    /// when "Require password after screen saver" is enabled. Cosmetically
    /// our overlay covers the lock screen, but dismissing it reveals the
    /// password prompt — matching the original Anooki screensaver UX.
    private func lockSessionIfPossible() {
        let path = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            diag("CGSession helper not found — skipping lock")
            return
        }
        let proc = Process()
        proc.launchPath = path
        proc.arguments = ["-suspend"]
        do {
            try proc.run()
            diag("session lock requested (CGSession -suspend)")
        } catch {
            diag("CGSession lock failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Distributed notification (hot-corner trigger)

    private func setupDistributedNotifications() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            self,
            selector: #selector(handleScreenSaverAction(_:)),
            name: kScreenSaverActionNotification,
            object: nil
        )
        dnc.addObserver(
            self,
            selector: #selector(handleScreenSaverWillStop(_:)),
            name: kScreenSaverWillStopNotification,
            object: nil
        )
        // Some Tahoe paths fire didlaunch — treat it the same as action.
        dnc.addObserver(
            self,
            selector: #selector(handleScreenSaverAction(_:)),
            name: kScreenSaverDidLaunchNotification,
            object: nil
        )
        diag("subscribed to com.apple.screensaver.{action,didlaunch,willstop}")
    }

    @objc private func handleScreenSaverAction(_ note: Notification) {
        diag("DN received: \(note.name.rawValue) userInfo=\(note.userInfo ?? [:])")
        showOverlay()
    }

    @objc private func handleScreenSaverWillStop(_ note: Notification) {
        diag("DN received: willstop — dismissing overlay")
        dismissOverlay()
    }

    // MARK: - Overlay management

    private func showOverlay() {
        // If we're already shown, ignore re-triggers.
        guard overlayWindows.isEmpty else {
            diag("showOverlay ignored — already visible")
            return
        }

        diag("showOverlay on \(NSScreen.screens.count) screen(s)")

        // One overlay window per attached display.
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            window.onDismissRequested = { [weak self] in self?.dismissOverlay() }
            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
        }

        NSCursor.hide()
        installEventMonitors()
    }

    private func dismissOverlay() {
        guard !overlayWindows.isEmpty else { return }
        diag("dismissOverlay")
        removeEventMonitors()
        NSCursor.unhide()
        for window in overlayWindows {
            window.tearDown()
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }

    private func installEventMonitors() {
        // Delay monitor installation by 500ms so the mouse-up that dismissed
        // the menu (or the mouse arriving at the hot corner) doesn't
        // instantly close the overlay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            guard !self.overlayWindows.isEmpty else { return }

            let dismiss: (NSEvent) -> Void = { [weak self] _ in self?.dismissOverlay() }

            let mask: NSEvent.EventTypeMask = [
                .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel
            ]

            self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: dismiss)
            self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                dismiss(event)
                return event
            }
            diag("event monitors armed")
        }
    }

    private func removeEventMonitors() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor  { NSEvent.removeMonitor(l)  }
        globalMonitor = nil
        localMonitor = nil
    }
}

// MARK: - OverlayWindow

final class OverlayWindow: NSWindow, WKNavigationDelegate {

    var onDismissRequested: (() -> Void)?
    private var webView: WKWebView?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        self.isOpaque = true
        self.backgroundColor = .black
        // Sit above pretty much everything except the dock/cursor managed
        // overlays. NSScreenSaverWindowLevel is the right level.
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        self.ignoresMouseEvents = false
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false
        self.hidesOnDeactivate = false

        setupWebView()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Custom scheme handler so Ruffle's WASM loader sees real HTTP 200
        // responses (file:// status=0 breaks Ruffle).
        if let handler = BundleSchemeHandler(bundle: .main) {
            config.setURLSchemeHandler(handler, forURLScheme: BundleSchemeHandler.scheme)
        }

        let userContent = WKUserContentController()
        let bridgeJS = """
        (function () {
          function send(level, args) {
            try {
              window.webkit.messageHandlers.anooki.postMessage(
                level + ': ' + Array.from(args).map(function (a) {
                  try { return typeof a === 'string' ? a : JSON.stringify(a); }
                  catch (e) { return String(a); }
                }).join(' ')
              );
            } catch (e) {}
          }
          ['log','warn','error','info'].forEach(function (k) {
            var orig = console[k];
            console[k] = function () { send(k, arguments); orig && orig.apply(console, arguments); };
          });
          window.addEventListener('error', function (e) {
            send('error', ['window.onerror', e.message, (e.filename||'') + ':' + (e.lineno||0)]);
          });
        })();
        """
        userContent.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        userContent.add(JSConsoleBridge(), name: "anooki")
        config.userContentController = userContent

        let wv = WKWebView(frame: contentView?.bounds ?? .zero, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = self
        contentView?.addSubview(wv)
        webView = wv

        guard let indexURL = URL(string: "\(BundleSchemeHandler.scheme)://\(BundleSchemeHandler.host)/index.html") else {
            diag("ERROR: failed to build custom-scheme index URL")
            return
        }
        diag("loading \(indexURL.absoluteString)")
        wv.load(URLRequest(url: indexURL))
    }

    func tearDown() {
        webView?.evaluateJavaScript("window.anookiStop && window.anookiStop()", completionHandler: nil)
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    override func keyDown(with event: NSEvent) {
        onDismissRequested?()
    }

    override func mouseDown(with event: NSEvent) {
        onDismissRequested?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onDismissRequested?()
    }

    override func otherMouseDown(with event: NSEvent) {
        onDismissRequested?()
    }

    // WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        diag("webView didFinish")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        diag("webView didFail: \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        diag("webView didFailProvisional: \(error.localizedDescription)")
    }
}

private final class JSConsoleBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String {
            diag("js: " + body)
        }
    }
}

// Serves bundle resources over a custom URL scheme (anooki://app/...) with
// proper HTTP-style status codes. Required because Ruffle's WASM loader uses
// fetch() and chokes on file:// status=0 responses on macOS WebKit.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "anooki"
    static let host = "app"

    private let resourcesURL: URL

    init?(bundle: Bundle = .main) {
        guard let url = bundle.resourceURL else { return nil }
        self.resourcesURL = url
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "Anooki", code: -1))
            return
        }

        // Resolve the resource path. anooki://app/foo/bar.js -> Resources/foo/bar.js
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = "index.html" }

        let fileURL = resourcesURL.appendingPathComponent(path)
        let resolved = fileURL.standardizedFileURL.path

        // Confine reads to the resources tree.
        let resourcesPath = resourcesURL.standardizedFileURL.path
        guard resolved.hasPrefix(resourcesPath) else {
            urlSchemeTask.didFailWithError(NSError(domain: "Anooki", code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Path escapes resources: \(path)"]))
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(Data())
            urlSchemeTask.didFinish()
            return
        }

        let mime = Self.mimeType(for: fileURL.pathExtension)
        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Cache-Control": "no-cache",
            // Required so Ruffle's WASM streaming compile works.
            "Cross-Origin-Embedder-Policy": "require-corp",
            "Cross-Origin-Opener-Policy": "same-origin"
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // We complete synchronously so there's nothing to cancel.
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js":          return "application/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "wasm":        return "application/wasm"
        case "swf":         return "application/x-shockwave-flash"
        case "json":        return "application/json; charset=utf-8"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg":         return "image/svg+xml"
        case "ico":         return "image/x-icon"
        case "map":         return "application/json"
        default:            return "application/octet-stream"
        }
    }
}
