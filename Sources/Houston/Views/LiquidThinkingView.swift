import SwiftUI
import WebKit

/// The chat's "Thinking…" indicator: a liquid-chrome blob (WebGL
/// raymarch, from ~/Documents/liquid-thinking.html) hosted in a
/// transparent WKWebView. Bundled as `Resources/liquid-thinking.html`,
/// trimmed to the component; it fills this view's square and hides its
/// own label — the token count is SwiftUI text beside it.
///
/// A web view, not a Metal port, on purpose: the component's handoff
/// notes prescribe exactly this for SwiftUI hosts, and the shader is
/// ~40 lines of GLSL that would have to be re-verified pixel for pixel
/// in MSL. The element pauses itself when the document is hidden and
/// honors reduced motion, so an off-screen indicator costs nothing.
struct LiquidThinkingView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let web = TransparentWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Transparent page background — `drawsBackground` is the private
        // but long-stable key WKWebView honors on macOS; without it the
        // blob sits on a white square.
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        if let url = Bundle.module.url(forResource: "liquid-thinking", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// Lets the pointer through for hover/ripple but never steals focus
    /// from the composer — a decorative status must not become the
    /// first responder.
    private final class TransparentWebView: WKWebView {
        override var acceptsFirstResponder: Bool { false }
        override func becomeFirstResponder() -> Bool { false }
    }
}
