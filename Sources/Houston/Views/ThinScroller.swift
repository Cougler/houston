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

/// No scroller at all — for scroll views whose position is shown some
/// other way (the chat transcript's jump-dot rail). Scrolling itself is
/// untouched; only the indicator goes.
final class HiddenScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style
    ) -> CGFloat { 0 }

    override func draw(_ dirtyRect: NSRect) {}
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {}
}

extension View {
    /// Replaces the enclosing scroll view's vertical scroller with
    /// `ThinScroller`. Attach to the ScrollView's *content* — the
    /// installer resolves the scroll view via `enclosingScrollView`.
    func thinScrollbar() -> some View {
        background(ScrollerInstaller(hidden: false))
    }

    /// Removes the enclosing scroll view's vertical scroller entirely.
    func hiddenScrollbar() -> some View {
        background(ScrollerInstaller(hidden: true))
    }
}

private struct ScrollerInstaller: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.wantsHiddenScroller = hidden
        return view
    }
    func updateNSView(_ view: InstallerView, context: Context) {}

    final class InstallerView: NSView {
        var wantsHiddenScroller = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The enclosing scroll view isn't wired up until after this
            // pass settles.
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        private func install() {
            guard let scroll = enclosingScrollView else { return }
            if wantsHiddenScroller {
                guard !(scroll.verticalScroller is HiddenScroller) else { return }
                scroll.verticalScroller = HiddenScroller()
            } else {
                guard !(scroll.verticalScroller is ThinScroller) else { return }
                scroll.verticalScroller = ThinScroller()
            }
        }
    }
}
