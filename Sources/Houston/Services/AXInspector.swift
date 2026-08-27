import AppKit
import ApplicationServices
import SwiftUI

/// System-wide element inspector: transparent overlays cover every screen,
/// hovering highlights the Accessibility element under the cursor in ANY
/// running app, and a click captures its AX facts into the App Inspector
/// popover (instruction → project terminal).
///
/// This uses the Accessibility permission READ-ONLY — it describes what the
/// user clicks and never synthesizes input. That is distinct from the
/// deleted AppleScript keystroke-synthesis path in CLAUDE.md's History;
/// don't confuse the two.
@MainActor
final class AXInspector: NSObject, NSPopoverDelegate {

    static let shared = AXInspector()

    private(set) var isActive = false

    private var overlays: [OverlayWindow] = []
    private var overlayWindowNumbers: Set<Int> = []
    private var eventMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var popover: NSPopover?
    private var anchorView: NSView?
    private var locked = false
    private var tearingDown = false
    private var lastHitPoint = NSPoint(x: -9999, y: -9999)
    private var hitTestScheduled = false
    /// Hover target, kept only to capture on click. AXUIElement is not
    /// Sendable — it never leaves the main actor.
    private var currentElement: AXUIElement?
    private var currentApp: NSRunningApplication?

    // MARK: - Lifecycle

    func begin() {
        guard !isActive else { return }
        guard AXIsProcessTrusted() else {
            requestPermission()
            return
        }
        isActive = true
        locked = false

        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            // Manually-managed borderless windows over-release on close()
            // without this.
            window.isReleasedWhenClosed = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            // Above the menu bar, so menubar/status UI is inspectable too.
            window.level = .screenSaver
            window.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
            ]
            window.animationBehavior = .none
            window.acceptsMouseMovedEvents = true
            window.contentView = HighlightView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.orderFrontRegardless()
            overlays.append(window)
            overlayWindowNumbers.insert(window.windowNumber)
        }

        // Key window + activation are what route keyDown (Escape) and
        // mouseMoved into our local monitor.
        NSApp.activate(ignoringOtherApps: true)
        overlayForCursor()?.makeKey()

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .keyDown]
        ) { event in
            // assumeIsolated's return must be Sendable — hand back a
            // consume verdict, not the NSEvent itself.
            let consumed = MainActor.assumeIsolated { AXInspector.shared.handle(event) }
            return consumed ? nil : event
        }

        // Displays coming or going invalidate every frame we hold — bail.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AXInspector.shared.end() }
        }

        scheduleHitTest()
    }

    func end() {
        guard isActive, !tearingDown else { return }
        tearingDown = true
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        // Order matters: close the popover BEFORE removing its anchor —
        // NSPopover misbehaves when its positioning view dies under it.
        if let popover {
            popover.delegate = nil
            popover.performClose(nil)
            self.popover = nil
        }
        anchorView?.removeFromSuperview()
        anchorView = nil
        overlays.forEach { $0.close() }
        overlays = []
        overlayWindowNumbers = []
        currentElement = nil
        currentApp = nil
        locked = false
        lastHitPoint = NSPoint(x: -9999, y: -9999)
        isActive = false
        tearingDown = false
    }

    // MARK: - Permission

    private func requestPermission() {
        // The system prompt only ever shows once; the alert carries the
        // instructions every later time. The literal spells out
        // kAXTrustedCheckOptionPrompt — the imported C global is a `var`
        // Swift 6 strict concurrency refuses to touch.
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        )

        let alert = NSAlert()
        alert.messageText = "Allow Houston to inspect apps?"
        alert.informativeText = """
        The App Inspector needs the Accessibility permission to read the \
        name and role of the UI element you click. Houston only reads \
        element info to describe what you click — it never controls apps \
        or synthesizes input.

        Enable Houston under System Settings → Privacy & Security → \
        Accessibility, then run Inspect an App again.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Events

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .mouseMoved:
            scheduleHitTest()
            return false
        case .keyDown:
            guard event.keyCode == 53 else { return false } // Escape
            end()
            return true
        case .leftMouseDown:
            guard let window = event.window,
                  overlayWindowNumbers.contains(window.windowNumber) else { return false }
            lockAndPresent()
            return true
        default:
            return false
        }
    }

    // MARK: - Hit testing

    private func scheduleHitTest() {
        guard !locked, !hitTestScheduled else { return }
        let point = NSEvent.mouseLocation
        guard hypot(point.x - lastHitPoint.x, point.y - lastHitPoint.y) >= 2 else { return }
        hitTestScheduled = true
        // Debounced, and the location is re-read at fire time — each test
        // is blocking AX IPC, never run it per raw mouseMoved.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.hitTestScheduled = false
            guard self.isActive, !self.locked else { return }
            self.hitTest(at: NSEvent.mouseLocation)
        }
    }

    private func hitTest(at cocoaPoint: NSPoint) {
        lastHitPoint = cocoaPoint
        let cgPoint = Self.cgPoint(fromCocoa: cocoaPoint)

        // Walk candidate windows front-to-back until an app's AX tree gives
        // a hit whose frame actually contains the point. Measured on this
        // machine: Notification Center and the Dock each keep an invisible
        // FULL-SCREEN window (alpha 1) above every normal window, and their
        // AX hit-test answers any point with their AXMenuBar — a single
        // "first window wins" pick made every hover target the menu bar.
        for pid in Self.candidatePIDs(at: cgPoint, excluding: overlayWindowNumbers) {
            guard let (element, frame) = Self.validatedHit(pid: pid, at: cgPoint) else {
                continue
            }
            currentElement = element
            currentApp = NSRunningApplication(processIdentifier: pid)

            var label = Self.axString(element, kAXRoleDescriptionAttribute)
                ?? InspectedAXElement.deAX(Self.axString(element, kAXRoleAttribute) ?? "element")
            if let title = Self.axString(element, kAXTitleAttribute), !title.isEmpty {
                label += " “\(title.count > 40 ? title.prefix(40) + "…" : title[...])”"
            }
            if let appName = currentApp?.localizedName {
                label += " — \(appName)"
            }
            updateHighlight((frame, label))
            return
        }
        currentElement = nil
        currentApp = nil
        updateHighlight(nil)
    }

    /// Owning pids of the windows under the point, front-to-back, deduped,
    /// capped (each candidate costs AX IPC). Bounds/pid/alpha/layer need no
    /// extra permission (window *names* would need Screen Recording — never
    /// read them). The menu-bar-owning app is appended as the last resort:
    /// the visible menu bar's contents belong to it, and its window is
    /// owned by the window server (skipped).
    private static func candidatePIDs(at cgPoint: CGPoint, excluding ours: Set<Int>) -> [pid_t] {
        var pids: [pid_t] = []
        let screenAreas = NSScreen.screens.map { $0.frame.width * $0.frame.height }
        if let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] {
            for entry in list {
                guard pids.count < 6,
                      let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue,
                      !ours.contains(number),
                      ((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                      // The window server's cursor/shield/menu-bar windows
                      // would eat every hit.
                      (entry[kCGWindowOwnerName as String] as? String) != "Window Server",
                      let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict),
                      bounds.contains(cgPoint),
                      let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      !pids.contains(pid)
                else { continue }
                // Skip service overlays: a non-normal-layer window covering
                // (most of) a whole screen is never the thing to inspect —
                // that's Notification Center's and the Dock's backstops.
                // Small raised windows (status items, floating panels) stay.
                let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
                let area = bounds.width * bounds.height
                if layer != 0, screenAreas.contains(where: { area >= $0 * 0.9 }) { continue }
                pids.append(pid)
            }
        }
        if let menuOwner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier,
           !pids.contains(menuOwner) {
            pids.append(menuOwner)
        }
        return pids
    }

    /// AX hit-test one app, accepting the result only when the element
    /// reports a frame containing the point — apps routinely answer misses
    /// with a bogus element (their AXMenuBar, their app element), and a
    /// frame check is the one generic way to reject those.
    private static func validatedHit(
        pid: pid_t, at cgPoint: CGPoint
    ) -> (AXUIElement, CGRect)? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            appElement, Float(cgPoint.x), Float(cgPoint.y), &hit
        ) == .success, let element = hit else { return nil }
        // Timeouts are per element ref, not inherited from the app element.
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let frame = axFrame(element),
              frame.insetBy(dx: -2, dy: -2).contains(cgPoint) else { return nil }
        return (element, frame)
    }

    // MARK: - Highlight drawing

    /// Draws on the cursor's screen only (cross-display elements clip
    /// there — accepted v1).
    private func updateHighlight(_ highlight: (rect: CGRect, label: String)?) {
        let cursorOverlay = overlayForCursor()
        for overlay in overlays {
            guard let view = overlay.contentView as? HighlightView else { continue }
            if overlay === cursorOverlay, let highlight, let screen = overlay.hostScreen {
                let cocoaRect = Self.cocoaRect(fromCG: highlight.rect)
                view.highlight = (
                    cocoaRect.offsetBy(dx: -screen.frame.origin.x, dy: -screen.frame.origin.y),
                    highlight.label
                )
            } else {
                view.highlight = nil
            }
        }
    }

    private func overlayForCursor() -> OverlayWindow? {
        let point = NSEvent.mouseLocation
        return overlays.first { $0.hostScreen?.frame.contains(point) == true }
            ?? overlays.first
    }

    // MARK: - Coordinates

    /// AppKit global (bottom-left origin, y-up) → CG/AX global (top-left
    /// of the PRIMARY screen, y-down). `screens[0]` is the primary (its
    /// AppKit origin is (0,0)) — NOT `NSScreen.main`, which is the key
    /// window's screen. This one flip is correct across all displays.
    private static func cgPoint(fromCocoa point: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private static func cocoaRect(fromCG rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Lock + popover

    private func lockAndPresent() {
        // Late hover state can be missing (e.g. instant click) — hit-test
        // synchronously at the click point.
        if currentElement == nil {
            hitTest(at: NSEvent.mouseLocation)
        }
        guard let element = currentElement else {
            end()
            return
        }
        locked = true
        // From here the transient popover owns Escape and outside-click —
        // keeping the monitor too would double-handle both.
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }

        let captured = capture(element: element)

        guard let overlay = overlayForCursor(),
              let contentView = overlay.contentView,
              let screen = overlay.hostScreen else {
            end()
            return
        }
        let viewRect = Self.cocoaRect(fromCG: captured.frame)
            .offsetBy(dx: -screen.frame.origin.x, dy: -screen.frame.origin.y)
        (contentView as? HighlightView)?.highlight = (viewRect, captured.summary)

        // Invisible anchor — NSPopover only needs its geometry.
        let anchor = NSView(frame: viewRect)
        contentView.addSubview(anchor)
        anchorView = anchor

        // BEFORE showing: outside clicks must fall through to real apps so
        // the transient popover can dismiss on them.
        overlays.forEach { $0.ignoresMouseEvents = true }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: AXInspectPopover(
            element: captured,
            projects: ProjectList.allProjects(settings: HoustonSettings.read()),
            onSend: { [weak self] instruction, projectPath in
                PromptDelivery.send(
                    AXPromptComposer.compose(element: captured, instruction: instruction),
                    toProject: projectPath
                )
                self?.end()
            },
            onSave: { [weak self] instruction, projectPath in
                AnnotationStores.store(for: projectPath)
                    .add(comment: instruction, axElement: captured)
                self?.end()
            }
        ))
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        // A popover hosted off a borderless screen-level window doesn't
        // always come up key — the text field's autofocus needs it to be.
        popover.contentViewController?.view.window?.makeKey()
        self.popover = popover
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popover = nil
            end()
        }
    }

    // MARK: - Capture

    private func capture(element: AXUIElement) -> InspectedAXElement {
        let role = Self.axString(element, kAXRoleAttribute) ?? "AXUnknown"
        let subrole = Self.axString(element, kAXSubroleAttribute)

        // Never read secure fields' values.
        var value: String?
        if subrole != (kAXSecureTextFieldSubrole as String) {
            value = Self.axString(element, kAXValueAttribute).map { raw in
                raw.count > 200 ? String(raw.prefix(200)) + "…" : raw
            }
        }

        var ancestors: [InspectedAXElement.Ancestor] = []
        var windowTitle: String?
        var cursor: AXUIElement? = Self.axElement(element, kAXParentAttribute)
        for _ in 0..<8 {
            guard let node = cursor else { break }
            let nodeRole = Self.axString(node, kAXRoleAttribute) ?? "AXUnknown"
            if nodeRole == (kAXWindowRole as String) {
                windowTitle = Self.axString(node, kAXTitleAttribute)
                break
            }
            if nodeRole == (kAXApplicationRole as String) { break }
            ancestors.append(InspectedAXElement.Ancestor(
                role: nodeRole,
                title: Self.axString(node, kAXTitleAttribute),
                identifier: Self.axString(node, kAXIdentifierAttribute)
            ))
            cursor = Self.axElement(node, kAXParentAttribute)
        }
        if windowTitle == nil,
           let window = Self.axElement(element, kAXWindowAttribute) {
            windowTitle = Self.axString(window, kAXTitleAttribute)
        }

        let app = currentApp
        return InspectedAXElement(
            role: role,
            subrole: subrole,
            roleDescription: Self.axString(element, kAXRoleDescriptionAttribute),
            title: Self.axString(element, kAXTitleAttribute),
            value: value,
            placeholder: Self.axString(element, kAXPlaceholderValueAttribute),
            help: Self.axString(element, kAXHelpAttribute),
            identifier: Self.axString(element, kAXIdentifierAttribute),
            enabled: Self.axBool(element, kAXEnabledAttribute) ?? true,
            frame: Self.axFrame(element)
                ?? CGRect(origin: Self.cgPoint(fromCocoa: NSEvent.mouseLocation), size: CGSize(width: 24, height: 24)),
            windowTitle: windowTitle,
            ancestors: ancestors,
            app: InspectedAXElement.AppInfo(
                name: app?.localizedName ?? "pid \(app?.processIdentifier ?? -1)",
                bundleID: app?.bundleIdentifier,
                bundlePath: app?.bundleURL?.path,
                pid: app?.processIdentifier ?? -1
            )
        )
    }

    // MARK: - AX helpers (main-actor only; AXUIElement is not Sendable)

    private static func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success
        else { return nil }
        // Swift owns the Copy's +1 — never CFRelease manually.
        return out
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        switch axCopy(element, attribute) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil // don't stringify arrays/elements
        }
    }

    private static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (axCopy(element, attribute) as? NSNumber)?.boolValue
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let ref = axCopy(element, attribute),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// Element frame in global CG (top-left) coordinates.
    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let posRef = axCopy(element, kAXPositionAttribute),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef = axCopy(element, kAXSizeAttribute),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}

// MARK: - Overlay window

/// Borderless windows refuse key status by default, and without a key
/// window neither keyDown (Escape) nor mouseMoved reach the local monitor.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    /// The screen this overlay was built for. `NSWindow.screen` answers
    /// "which screen shows most of me", which is the same thing here, but
    /// pin it explicitly against edge cases during teardown.
    var hostScreen: NSScreen? {
        NSScreen.screens.first { $0.frame == frame }
    }
}

/// The hover highlight: translucent fill, border, and a label chip —
/// the native twin of inspect.js's overlay div.
final class HighlightView: NSView {
    var highlight: (rect: CGRect, label: String)? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Tracking area so every overlay gets mouseMoved, not just the key
        // window's.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        guard let highlight else { return }
        let accent = NSColor.controlAccentColor

        accent.withAlphaComponent(0.15).setFill()
        let rectPath = NSBezierPath(rect: highlight.rect)
        rectPath.fill()
        accent.withAlphaComponent(0.9).setStroke()
        rectPath.lineWidth = 1.5
        rectPath.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: highlight.label, attributes: attributes)
        let textSize = text.size()
        let padding = NSSize(width: 6, height: 2)
        var chip = NSRect(
            x: highlight.rect.minX,
            y: highlight.rect.maxY + 4,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2
        )
        // Clamp on-screen; flip below the element when there's no room above.
        if chip.maxY > bounds.maxY { chip.origin.y = highlight.rect.minY - chip.height - 4 }
        chip.origin.x = max(4, min(chip.origin.x, bounds.maxX - chip.width - 4))
        chip.origin.y = max(4, chip.origin.y)

        NSColor(calibratedWhite: 0.12, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: chip.minX + padding.width, y: chip.minY + padding.height))
    }
}
