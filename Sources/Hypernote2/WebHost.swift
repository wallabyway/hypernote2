import AppKit
import HypernoteCore
import ServiceManagement
import SwiftUI
import WebKit

/// Owns the controller and the single WKWebView that hosts the web UI.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let controller = AppController()
    let webView: WKWebView
    @Published var isRecording = false
    @Published var isPaused = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let bridge = Bridge()

    private init() {
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "native")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = bridge
        #if DEBUG
        webView.isInspectable = true
        #endif

        bridge.model = self
        controller.onEvent = { [weak self] name, payload in self?.send(event: name, payload: payload) }
        controller.onRecordingChange = { [weak self] recording in self?.isRecording = recording }
        controller.onPauseChange = { [weak self] paused in self?.isPaused = paused }
        loadUI()

        // Re-registering moves an enabled login item to this copy of the app, so it keeps
        // working after the app is reinstalled or moved (e.g. from ./build into /Applications).
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.register() }

        // The user can also toggle the login item in System Settings; re-read it whenever a menu opens.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshLaunchAtLogin() }
        }
    }

    private func loadUI() {
        let fm = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("web"),
            ProcessInfo.processInfo.environment["HYPERNOTE_WEB"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("web"),
        ].compactMap { $0 }
        guard let dir = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("index.html").path) })
        else {
            webView.loadHTMLString("<h3 style='font-family:-apple-system'>Hypernote2: web assets not found.</h3>", baseURL: nil)
            return
        }
        webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
    }

    /// Registers or removes the app as a login item (System Settings → General → Login Items).
    func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            send(event: "toast", payload: ["kind": "error",
                "message": "Couldn't change Launch at Login: \(error.localizedDescription). Try moving Hypernote2.app to /Applications."])
        }
        if enabled && service.status == .requiresApproval {
            send(event: "toast", payload: ["kind": "warning",
                "message": "Approve Hypernote2 in System Settings → General → Login Items."])
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func send(event: String, payload: [String: Any]) {
        let message: [String: Any] = ["name": event, "payload": payload]
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__nativeEvent && window.__nativeEvent(\(json))")
    }
}

/// JS → Swift: `await webkit.messageHandlers.native.postMessage({cmd, args})`.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    weak var model: AppModel?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else {
            replyHandler(nil, "Malformed message")
            return
        }
        let args = body["args"] as? [String: Any] ?? [:]

        Task { @MainActor in
            guard let model = self.model else { replyHandler(nil, "App not ready"); return }
            if cmd == "dragWindow" {
                if let event = NSApp.currentEvent { model.webView.window?.performDrag(with: event) }
                replyHandler(NSNull(), nil)
                return
            }
            do {
                replyHandler(try await model.controller.handle(command: cmd, args: args), nil)
            } catch {
                replyHandler(nil, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Links in notes open in the default browser, never inside the app.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

struct WebHostView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
