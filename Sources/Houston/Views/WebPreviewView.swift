import AppKit
import SwiftUI
import WebKit

/// Contents of one web-preview window: toolbar, the WKWebView, the
/// element-inspector panel (bottom, when an element is selected), and the
/// annotations list (trailing, when toggled).
struct WebPreviewView: View {
    @ObservedObject var model: WebPreviewModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle()
                .fill(Theme.borderHeader)
                .frame(height: 1)
            HStack(spacing: 0) {
                WebViewRepresentable(webView: model.webView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Anchored at the clicked element; dismissing it (click
                    // away, Escape) deselects the element and unpins the
                    // page highlight.
                    .popover(
                        isPresented: inspectorShown,
                        attachmentAnchor: .rect(.rect(anchorRect)),
                        arrowEdge: .bottom
                    ) {
                        InspectorPopover(model: model)
                    }
                if model.showAnnotations, let store = model.annotations {
                    Rectangle()
                        .fill(Theme.borderHeader)
                        .frame(width: 1)
                    AnnotationsPanel(model: model, store: store)
                        .frame(width: 300)
                }
            }
        }
        .background(Theme.background)
    }

    /// Presented while an element is selected; setting it false (any
    /// popover dismissal path) clears the selection.
    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { model.selection != nil },
            set: { shown in if !shown { model.clearSelection() } }
        )
    }

    /// The clicked element's viewport rect — CSS pixels match the web
    /// view's points, so it doubles as the popover anchor.
    private var anchorRect: CGRect {
        guard let rect = model.selection?.rect else { return .zero }
        return CGRect(
            x: rect.x, y: rect.y,
            width: max(rect.width, 4), height: max(rect.height, 4)
        )
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ToolbarIconButton(symbol: "arrow.clockwise", help: "Reload") {
                model.reload()
            }
            Text(model.currentURL.replacingOccurrences(of: "http://", with: ""))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let error = model.loadError {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.dotDegraded)
                        .frame(width: 6, height: 6)
                    Text("Not loading")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDanger)
                }
                .help(error)
            }
            Spacer(minLength: 12)
            if let store = model.annotations {
                AnnotationsToggle(model: model, store: store)
                ToolbarIconButton(
                    symbol: "mappin.circle",
                    help: model.showPins ? "Hide pins on the page" : "Show pins on the page",
                    active: model.showPins
                ) {
                    model.showPins.toggle()
                }
            }
            ToolbarIconButton(symbol: "safari", help: "Open in Browser") {
                model.openInBrowser()
            }
            inspectToggle
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Theme.panelFill)
    }

    private var inspectToggle: some View {
        Button {
            model.inspectMode.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 11, weight: .medium))
                Text("Inspect")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(model.inspectMode ? Theme.buttonActiveStroke : Theme.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(model.inspectMode ? Theme.buttonActiveFill : Theme.buttonFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        model.inspectMode ? Theme.buttonActiveStroke : Theme.buttonStroke,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click an element on the page to see where it lives, then describe a change")
    }
}

/// The annotations toolbar button in its own view: the badge count comes
/// from the store, a *nested* ObservableObject the window's root view would
/// never re-render for.
private struct AnnotationsToggle: View {
    @ObservedObject var model: WebPreviewModel
    @ObservedObject var store: AnnotationStore

    var body: some View {
        ToolbarIconButton(
            symbol: "checklist",
            help: "Tasks",
            active: model.showAnnotations,
            badge: store.open.count
        ) {
            model.showAnnotations.toggle()
        }
    }
}

// MARK: - Inspector popover

private struct InspectorPopover: View {
    @ObservedObject var model: WebPreviewModel

    @State private var instruction = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let element = model.selection {
                sourceRow(
                    label: "STRUCTURE",
                    resolved: model.resolvedStructure,
                    raw: element.structure?.file
                )
                sourceRow(
                    label: "STYLES",
                    resolved: model.resolvedStyles.first,
                    extra: max(0, model.resolvedStyles.count - 1),
                    raw: element.styles.first(where: { !$0.inline })?.source
                )
                sourceRow(
                    label: "SCRIPT",
                    resolved: model.resolvedScript,
                    raw: scriptFallback(element)
                )
            }
            promptField
        }
        .padding(14)
        .frame(width: 460, alignment: .leading)
        .onAppear {
            // One async hop — focusing during popover presentation is
            // silently dropped.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let element = model.selection {
                Text("<\(element.summary)>")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let text = element.text, !text.isEmpty {
                    Text("“\(text.prefix(60))\(text.count > 60 ? "…" : "")”")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func sourceRow(
        label: String,
        resolved: ResolvedSource?,
        extra: Int = 0,
        raw: String?
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.heading)
                .frame(width: 72, alignment: .leading)
            if let resolved {
                Text(resolved.display)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if extra > 0 {
                    Text("+\(extra) more")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                CopyIconButton(text: resolved.absolutePath, help: "Copy path")
            } else if let raw, !raw.isEmpty {
                Text(raw)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("not detected")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Something honest when no script file resolved: the first attributed
    /// handler ("onClick · React"), or nothing.
    private func scriptFallback(_ element: InspectedElement) -> String? {
        guard let handler = element.scripts.first else { return nil }
        if let source = handler.source { return source }
        switch handler.origin {
        case "reactProp": return "\(handler.type) · React"
        case "inline": return "\(handler.type) attribute"
        default: return handler.type
        }
    }

    private var canPrompt: Bool {
        model.server.cwd != nil
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var promptField: some View {
        HStack(spacing: 8) {
            TextField("Describe a change to this element…", text: $instruction)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($fieldFocused)
                .onSubmit { sendNow() }
            Button("Send to Claude") { sendNow() }
                .font(.system(size: 12))
                .controlSize(.small)
                .disabled(!canPrompt)
            Button("Add to Tasks") { saveToList() }
                .font(.system(size: 12))
                .controlSize(.small)
                .disabled(!canPrompt || model.annotations == nil)
        }
    }

    private func sendNow() {
        guard canPrompt else { return }
        model.send(instruction: instruction)
        instruction = ""
        // Done with this element — dismiss the popover and unpin.
        model.clearSelection()
    }

    private func saveToList() {
        guard canPrompt else { return }
        model.saveComment(instruction)
        instruction = ""
        // The annotations badge (and pins, when shown) confirm the save.
        model.clearSelection()
    }
}

// MARK: - Annotations panel

private struct AnnotationsPanel: View {
    @ObservedObject var model: WebPreviewModel
    @ObservedObject var store: AnnotationStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TASKS")
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Theme.heading)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if store.items.isEmpty {
                        Text("Click an element in inspect mode and “Add to Tasks” to queue up changes.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }
                    ForEach(Array(store.open.enumerated()), id: \.element.id) { index, item in
                        row(item, pin: index + 1)
                    }
                    if !store.doneItems.isEmpty {
                        Text("DONE")
                            .font(.system(size: 9, weight: .semibold))
                            .kerning(0.5)
                            .foregroundStyle(Theme.heading)
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                        ForEach(store.doneItems) { item in
                            row(item, pin: nil).opacity(0.55)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
            if !unsentOpen.isEmpty {
                Rectangle()
                    .fill(Theme.borderFooter)
                    .frame(height: 1)
                Button("Send all open (\(unsentOpen.count))") {
                    model.sendAllOpen()
                }
                .font(.system(size: 12))
                .controlSize(.small)
                .disabled(model.server.cwd == nil)
                .padding(.vertical, 10)
            }
        }
        .background(Theme.panelFill)
    }

    private var unsentOpen: [Annotation] {
        store.open.filter { !$0.sent }
    }

    private func row(_ item: Annotation, pin: Int?) -> some View {
        AnnotationRowView(
            item: item,
            pin: pin,
            projectPath: model.server.cwd,
            onSend: { model.sendAnnotation(item.id) },
            onToggleDone: {
                item.done ? store.markUndone(item.id) : store.markDone(item.id)
            },
            onDelete: { store.remove(item.id) },
            onEdit: { store.updateComment(item.id, comment: $0) }
        )
    }
}

// MARK: - Small pieces

private struct ToolbarIconButton: View {
    let symbol: String
    let help: String
    var active = false
    var badge = 0
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    active ? Theme.buttonActiveStroke : hovered ? Theme.text : Theme.textSecondary
                )
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? Theme.rowHovered : .clear)
                )
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(String(badge))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Capsule().fill(Theme.buttonActiveStroke))
                            .offset(x: 4, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// The model owns the WKWebView; SwiftUI only adopts it — same ownership
/// philosophy as `TerminalHostView`, so representable re-creation never
/// tears down page state.
private struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
