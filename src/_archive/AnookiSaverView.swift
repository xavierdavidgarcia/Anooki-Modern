import ScreenSaver
import WebKit
import AppKit
import Foundation

// File-based diagnostics. Tahoe's screensaver sandbox sometimes suppresses
// NSLog/os_log, so we mirror to a tmp file we can read out-of-band.
private let diagLogPath = "/tmp/anooki-saver.log"

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

// Notification used by the lame-duck pattern: when a new view instance is
// created, it broadcasts this name and any older instance(s) listening will
// neuter themselves.
private let kAnookiNewInstance = Notification.Name("com.vier.anooki.NewInstance")

// macOS distributed notification fired when the screensaver is about to stop
// for real. stopAnimation() is NOT reliably called on Tahoe, so we listen
// for this and treat it as a hard stop.
private let kWillStopNotification = Notification.Name("com.apple.screensaver.willstop")

@objc(AnookiSaverView)
public final class AnookiSaverView: ScreenSaverView, WKNavigationDelegate {

    private var webView: WKWebView?
    private var lameDuck = false
    private var isStarted = false
    private var idleExitTimer: DispatchWorkItem?
    private var willStopObserver: NSObjectProtocol?

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        diag("init(frame:isPreview:) frame=\(NSStringFromRect(frame)) isPreview=\(isPreview)")

        // Tahoe ghost-instance check: legacyScreenSaver.appex spawns a zero-frame
        // instance that never becomes visible. Touching it triggers the
        // "black screen on start" bug for the real instance that follows.
        if #available(macOS 26.0, *) {
            if frame.equalTo(.zero) {
                diag("ghost instance (frame=zero) — skipping setup")
                return
            }
        }

        animationTimeInterval = 1.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        registerForLifecycleNotifications()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        diag("init(coder:)")
        animationTimeInterval = 1.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForLifecycleNotifications()
    }

    deinit {
        diag("deinit")
        NotificationCenter.default.removeObserver(self)
        if let obs = willStopObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
    }

    // MARK: - Lifecycle wiring (the Tahoe-specific dance)

    private func registerForLifecycleNotifications() {
        // Lame-duck: when another view instance announces itself, neuter ourselves.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleNewInstance(_:)),
            name: kAnookiNewInstance,
            object: nil
        )
        // Announce ourselves so any older lame-duck instance can stand down.
        NotificationCenter.default.post(name: kAnookiNewInstance, object: self)

        // willStop: distributed notification fired when the screensaver exits
        // for real. stopAnimation() is not reliable on Tahoe.
        willStopObserver = DistributedNotificationCenter.default().addObserver(
            forName: kWillStopNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            diag("willStop notification received")
            self?.stopAnimation()
        }
    }

    @objc private func handleNewInstance(_ note: Notification) {
        // Ignore the post we made ourselves.
        if let sender = note.object as AnyObject?, sender === self { return }
        diag("neutered by new instance")
        lameDuck = true
        // If we had started, tear down quietly without triggering the
        // 65-second exit (which belongs to the active instance).
        teardownWebView()
        removeFromSuperview()
        NotificationCenter.default.removeObserver(self)
        if let obs = willStopObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            willStopObserver = nil
        }
    }

    // MARK: - ScreenSaverView overrides

    public override var hasConfigureSheet: Bool { false }
    public override var configureSheet: NSWindow? { nil }

    public override func startAnimation() {
        guard !lameDuck else {
            diag("startAnimation suppressed (lame duck)")
            return
        }
        diag("startAnimation isPreview=\(isPreview) bounds=\(NSStringFromRect(bounds))")
        super.startAnimation()

        // Cancel any pending self-exit timer in case we're being reused.
        idleExitTimer?.cancel()
        idleExitTimer = nil

        // Create the WebView lazily here (NOT in init) — this is the
        // "black screen on start" workaround.
        if webView == nil {
            setupWebView()
        } else {
            // Already created (e.g. preview → real transition): reload.
            loadIndex()
        }

        isStarted = true
    }

    public override func stopAnimation() {
        super.stopAnimation()
        guard !lameDuck else { return }
        guard isStarted else { return }
        diag("stopAnimation — scheduling exit(0) in 65s")
        isStarted = false

        // Tell JS to stop playback so audio/WebGL/timers wind down.
        webView?.evaluateJavaScript("window.anookiStop && window.anookiStop()", completionHandler: nil)

        // Schedule a hard exit. Tahoe never kills legacyScreenSaver.appex
        // after a real stop, so the process accumulates. exit(0) ensures
        // the next invocation gets a fresh process.
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, !self.lameDuck else { return }
            diag("idle exit(0) firing")
            exit(0)
        }
        idleExitTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 65, execute: item)
    }

    public override func animateOneFrame() {
        // Intentionally empty. Ruffle drives its own animation loop inside
        // the WebView; animateOneFrame is unreliable on Tahoe anyway.
    }

    public override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    // MARK: - WebView

    private func setupWebView() {
        diag("setupWebView bounds=\(NSStringFromRect(bounds))")
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

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
            send('error', ['window.onerror', e.message, e.filename + ':' + e.lineno]);
          });
        })();
        """
        userContent.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        userContent.add(ConsoleBridge(), name: "anooki")
        config.userContentController = userContent

        let wv = WKWebView(frame: bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = self
        addSubview(wv)
        webView = wv
        diag("webView created frame=\(NSStringFromRect(wv.frame))")

        loadIndex()
    }

    private func loadIndex() {
        guard let webView = webView else { return }
        guard let bundle = Bundle(for: type(of: self)).resourceURL else {
            diag("ERROR: bundle resourceURL is nil")
            return
        }
        let indexURL = bundle.appendingPathComponent("index.html")
        let exists = FileManager.default.fileExists(atPath: indexURL.path)
        diag("loading \(indexURL.path) exists=\(exists)")
        webView.loadFileURL(indexURL, allowingReadAccessTo: bundle)
    }

    private func teardownWebView() {
        webView?.stopLoading()
        webView?.evaluateJavaScript("window.anookiStop && window.anookiStop()", completionHandler: nil)
        webView?.removeFromSuperview()
        webView = nil
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        diag("provisional nav failed: \(error.localizedDescription)")
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        diag("navigation failed: \(error.localizedDescription)")
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        diag("webView didFinish loading")
    }
}

private final class ConsoleBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? String {
            diag("js: " + body)
        }
    }
}
