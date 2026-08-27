import AppKit
import Foundation
import WebKit

/// State + WebKit plumbing behind one web-preview window: owns the
/// WKWebView, receives `inspect.js` messages, resolves reported sources to
/// project files, and routes prompts into the project's terminal pane.
@MainActor
final class WebPreviewModel: NSObject, ObservableObject {

    let server: DevServer
    let webView: WKWebView
    /// nil when the server's cwd is unknown — preview works, but there is
    /// no terminal to prompt and nowhere to anchor a comment list.
    let annotations: AnnotationStore?

    @Published var inspectMode = false {
        didSet { applyInspectMode() }
    }
    @Published private(set) var selection: InspectedElement?
    @Published private(set) var resolvedStructure: ResolvedSource?
    @Published private(set) var resolvedStyles: [ResolvedSource] = []
    @Published private(set) var resolvedScript: ResolvedSource?
    @Published private(set) var currentURL: String
    @Published private(set) var loadError: String?
    @Published var showAnnotations = false
    @Published var showPins = false {
        didSet { applyPins() }
    }

    /// `WKUserContentController` retains its message handler strongly —
    /// without this proxy the model → webView → configuration → controller
    /// → model cycle would leak the whole window's graph.
    private let messageProxy = WeakScriptMessageHandler()
    private static let handlerName = "houstonInspect"

    init(server: DevServer) {
        self.server = server
        self.currentURL = server.url
        // Shared per-project instance — saves from the App Inspector or
        // another preview window show up here immediately.
        self.annotations = server.cwd.map { AnnotationStores.store(for: $0) }

        let config = WKWebViewConfiguration()
        // The inspect script must beat the app's code to addEventListener;
        // main frame only — iframes are a deliberate v1 punt.
        if let url = Bundle.module.url(forResource: "inspect", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        } else {
            // Preview still works without inspect — never crash over a
            // missing resource.
            NSLog("Houston: inspect.js missing from bundle; inspect disabled")
        }
        config.userContentController.add(messageProxy, name: Self.handlerName)

        webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        messageProxy.delegate = self
        webView.navigationDelegate = self
        // Safari's Develop menu can attach to the preview — the only way to
        // debug inspect.js in situ. Costs nothing unless attached.
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true

        webView.load(URLRequest(url: URL(string: server.url)!))
    }

    /// Called by the window controller on close — belt-and-braces teardown
    /// alongside the weak proxy.
    func teardown() {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.handlerName)
        webView.stopLoading()
        webView.navigationDelegate = nil
        // The annotation store is shared (AnnotationStores) — never stop it.
    }

    // MARK: - Toolbar actions

    func reload() {
        loadError = nil
        if webView.url != nil {
            webView.reload()
        } else {
            webView.load(URLRequest(url: URL(string: server.url)!))
        }
    }

    func openInBrowser() {
        Actions.openExternal(currentURL)
    }

    func clearSelection() {
        selection = nil
        resolvedStructure = nil
        resolvedStyles = []
        resolvedScript = nil
        // Unpin the page highlight and let hover tracking resume.
        webView.evaluateJavaScript(
            "window.__houston && window.__houston.clearSelection()"
        )
    }

    // MARK: - Prompting

    /// The live flow: compose one complete prompt and submit it to the
    /// project's terminal pane.
    func send(instruction: String) {
        guard let selection else { return }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let prompt = ElementSourceResolver.composePrompt(
            element: selection,
            structure: resolvedStructure,
            styleFiles: resolvedStyles,
            scriptFile: resolvedScript,
            instruction: trimmed
        )
        deliver(prompt)
    }

    /// The comment flow: persist the note + captured element for later.
    func saveComment(_ text: String) {
        guard let selection, let annotations else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        annotations.add(comment: trimmed, element: selection)
        if showPins { applyPins() }
    }

    func sendAnnotation(_ id: String) {
        guard let cwd = server.cwd, let annotations,
              let item = annotations.items.first(where: { $0.id == id }) else { return }
        deliver(AnnotationPrompts.compose(item, projectRoot: cwd))
        annotations.markSent(id)
    }

    func sendAllOpen() {
        guard let cwd = server.cwd, let annotations else { return }
        let pending = annotations.open.filter { !$0.sent }
        guard !pending.isEmpty else { return }
        deliver(AnnotationPrompts.composeBatch(pending, projectRoot: cwd))
        for item in pending { annotations.markSent(item.id) }
    }

    private func deliver(_ prompt: String) {
        guard let cwd = server.cwd else { return }
        PromptDelivery.send(prompt, toProject: cwd)
    }

    // MARK: - Source resolution

    private func resolveSources(
        for element: InspectedElement
    ) -> (ResolvedSource?, [ResolvedSource], ResolvedSource?) {
        guard let cwd = server.cwd else { return (nil, [], nil) }
        return ElementSourceResolver.resolveSources(for: element, projectRoot: cwd)
    }

    // MARK: - JS bridge

    private func applyInspectMode() {
        let flag = inspectMode ? "true" : "false"
        webView.evaluateJavaScript(
            "window.__houston && window.__houston.setInspect(\(flag))"
        )
    }

    private func applyPins() {
        guard let annotations else { return }
        if showPins {
            // Numbers match the list's open-item order; only web captures
            // have a selector to pin, AX items keep their number unpinned.
            let entries = annotations.open.enumerated().compactMap { index, item in
                item.element.map { ["n": index + 1, "selector": $0.selector] as [String: Any] }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: entries),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "window.__houston && window.__houston.showPins(\(json))"
            )
        } else {
            webView.evaluateJavaScript(
                "window.__houston && window.__houston.hidePins()"
            )
        }
    }
}

// MARK: - WKScriptMessageHandler

extension WebPreviewModel: WKScriptMessageHandler {

    private struct Envelope: Decodable {
        let type: String
        let payload: InspectedElement?
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let body = message.body as? String,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(body.utf8))
        else { return }
        switch envelope.type {
        case "selected":
            guard let element = envelope.payload else { return }
            selection = element
            (resolvedStructure, resolvedStyles, resolvedScript) = resolveSources(for: element)
        case "inspectExited":
            // Escape in the page — un-toggle without re-sending setInspect.
            if inspectMode { inspectMode = false }
        default:
            break
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebPreviewModel: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url?.absoluteString ?? currentURL
        loadError = nil
        // The page's JS state reset — re-arm whatever was on.
        if inspectMode { applyInspectMode() }
        if showPins { applyPins() }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        loadError = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // A user-cancelled load (rapid reloads, policy .cancel) isn't a
        // server problem.
        guard nsError.code != NSURLErrorCancelled else { return }
        loadError = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // Keep the preview on this machine's dev servers; external links go
        // to the real browser.
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           let host = url.host?.lowercased(),
           !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
           !host.hasSuffix(".localhost") {
            Actions.openExternal(url.absoluteString)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

/// Forwards script messages while letting the model deallocate — see
/// `WebPreviewModel.messageProxy`.
@MainActor
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
