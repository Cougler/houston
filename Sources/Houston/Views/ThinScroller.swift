import AppKit
import SwiftUI

/// A minimal scroller: a thin trackless knob that brightens under the
/// pointer. Swapped onto SwiftUI's backing NSScrollView by
/// `.thinScrollbar()` — SwiftUI offers no scroller styling of its own.
final class ThinScroller: NSScroller {
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style
    ) -> CGFloat { 10 }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    // No track — the knob floats alone.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0 else { return }
        let width: CGFloat = hovered ? 5 : 3
        let capsule = NSRect(
            x: bounds.maxX - width - 3, y: knob.minY,
            width: width, height: knob.height
        )
        NSColor.labelColor
            .withAlphaComponent(hovered ? 0.55 : 0.25)
            .setFill()
        NSBezierPath(
            roundedRect: capsule, xRadius: width / 2, yRadius: width / 2
        ).fill()
    }
}

extension View {
    /// Replaces the enclosing scroll view's vertical scroller with
    /// `ThinScroller`. Attach to the ScrollView's *content* — the
    /// installer resolves the scroll view via `enclosingScrollView`.
    func thinScrollbar() -> some View {
        background(ThinScrollerInstaller())
    }
}

private struct ThinScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> InstallerView { InstallerView() }
    func updateNSView(_ view: InstallerView, context: Context) {}

    final class InstallerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The enclosing scroll view isn't wired up until after this
            // pass settles.
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        private func install() {
            guard let scroll = enclosingScrollView,
                  !(scroll.verticalScroller is ThinScroller) else { return }
            scroll.verticalScroller = ThinScroller()
        }
    }
}
