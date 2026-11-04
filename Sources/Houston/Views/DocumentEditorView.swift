import AppKit
import SwiftUI

// The documents editor (2026-10-20): a native NSTextView editing
// markdown as rich text. The text storage carries two custom attributes
// — `.docBlock` (the paragraph's `DocBlockKind.token`) and `.docInline`
// (a `DocInline` bitmask) — plus the standard `.link`; everything
// visual (fonts, indents, colors) is DERIVED from those by `DocStyle`
// on every edit, and list markers / quote bars / code backgrounds are
// drawn by `DocLayoutManager`, never stored as characters. Saving is
// `DocText.blocks(of:)` → `MarkdownDocument.serialize`. Markdown is the
// only persisted form; there is no sidecar.

extension NSAttributedString.Key {
    static let docBlock = NSAttributedString.Key("houston.docBlock")
    static let docInline = NSAttributedString.Key("houston.docInline")
}

// MARK: - Palette (dynamic NSColors; Theme.swift's tokens are SwiftUI Colors)

private enum DocPalette {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { NSColor(hex: $0.isDark ? dark : light) }
    }
    static let text = dynamic(0x09090B, 0xFAFAFA)
    static let secondary = dynamic(0x71717A, 0xA1A1AA)
    static let link = dynamic(0x5B3FE0, 0xA99BFF)
    static let codeFill = dynamic(0xF4F4F5, 0x1C1C20)
    static let inlineCodeFill = dynamic(0xF4F4F5, 0x27272A)
    static let quoteBar = dynamic(0xD4D4D8, 0x3F3F46)
    static let rule = dynamic(0xE4E4E7, 0x27272A)
    static let selection = NSColor(name: nil) {
        $0.isDark
            ? NSColor(hex: 0xA99BFF).withAlphaComponent(0.28)
            : NSColor(hex: 0x5B3FE0).withAlphaComponent(0.18)
    }
}

// MARK: - Styling

enum DocStyle {
    static let bodySize: CGFloat = 14.5
    static let maxTextWidth: CGFloat = 720
    static let listIndentStep: CGFloat = 22
    static let listIndentBase: CGFloat = 26

    static func kind(of attrs: [NSAttributedString.Key: Any]) -> DocBlockKind {
        (attrs[.docBlock] as? String).flatMap(DocBlockKind.init(token:)) ?? .paragraph
    }

    static func inline(of attrs: [NSAttributedString.Key: Any]) -> DocInline {
        DocInline(rawValue: (attrs[.docInline] as? NSNumber)?.uint8Value ?? 0)
    }

    static func font(kind: DocBlockKind, inline: DocInline) -> NSFont {
        var font: NSFont
        switch kind {
        case let .heading(n):
            let size: CGFloat = n == 1 ? 26 : n == 2 ? 20 : n == 3 ? 16.5 : 15
            font = .systemFont(ofSize: size, weight: .semibold)
        case .code, .raw:
            return .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        default:
            font = .systemFont(ofSize: bodySize)
        }
        if inline.contains(.code) {
            font = .monospacedSystemFont(ofSize: font.pointSize - 1.5, weight: .regular)
        }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if inline.contains(.bold) { traits.insert(.bold) }
        if inline.contains(.italic) { traits.insert(.italic) }
        if !traits.isEmpty {
            let desc = font.fontDescriptor.withSymbolicTraits(
                font.fontDescriptor.symbolicTraits.union(traits)
            )
            font = NSFont(descriptor: desc, size: font.pointSize) ?? font
        }
        return font
    }

    static func paragraphStyle(kind: DocBlockKind) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.2
        p.paragraphSpacing = 10
        switch kind {
        case .paragraph:
            break
        case let .heading(n):
            p.paragraphSpacingBefore = n == 1 ? 14 : n == 2 ? 12 : 8
            p.paragraphSpacing = 6
            p.lineHeightMultiple = 1.1
        case let .bullet(depth), let .numbered(depth):
            let indent = listIndentBase + CGFloat(depth) * listIndentStep
            p.firstLineHeadIndent = indent
            p.headIndent = indent
            p.paragraphSpacing = 3
        case .quote:
            p.firstLineHeadIndent = 18
            p.headIndent = 18
        case .code, .raw:
            p.firstLineHeadIndent = 14
            p.headIndent = 14
            p.tailIndent = -14
            p.paragraphSpacing = 0
            p.lineHeightMultiple = 1.15
        case .rule:
            p.paragraphSpacing = 10
        }
        return p
    }

    /// Re-derives every visual attribute in the paragraphs covering
    /// `range`, and normalises each paragraph to ONE block kind (the one
    /// on its newline — the character that survives typing at its
    /// start — else its first character).
    static func restyle(_ storage: NSMutableAttributedString, range: NSRange) {
        let text = storage.string as NSString
        guard text.length > 0 else { return }
        let safe = NSRange(
            location: min(range.location, text.length),
            length: min(range.length, text.length - min(range.location, text.length))
        )
        let full = text.paragraphRange(for: safe)
        var loc = full.location
        while loc < NSMaxRange(full) || (loc == NSMaxRange(full) && loc == text.length && full.length == 0) {
            let para = text.paragraphRange(for: NSRange(location: loc, length: 0))
            restyleParagraph(storage, para)
            if para.length == 0 { break }
            loc = NSMaxRange(para)
            if loc >= text.length { break }
        }
    }

    static func blockKind(_ storage: NSAttributedString, paragraph: NSRange) -> DocBlockKind {
        guard paragraph.length > 0 else {
            // The empty final paragraph: inherit the newline before it.
            if paragraph.location > 0 {
                return kind(of: storage.attributes(at: paragraph.location - 1, effectiveRange: nil))
            }
            return .paragraph
        }
        let text = storage.string as NSString
        let last = NSMaxRange(paragraph) - 1
        let anchor = text.character(at: last) == 0x0A ? last : paragraph.location
        return kind(of: storage.attributes(at: anchor, effectiveRange: nil))
    }

    private static func restyleParagraph(_ storage: NSMutableAttributedString, _ para: NSRange) {
        guard para.length > 0 else { return }
        let kind = blockKind(storage, paragraph: para)
        let pstyle = paragraphStyle(kind: kind)
        storage.addAttributes([.docBlock: kind.token, .paragraphStyle: pstyle], range: para)
        storage.enumerateAttributes(in: para, options: []) { attrs, sub, _ in
            var inline = inline(of: attrs)
            if case .code = kind { inline = [] }
            if kind == .raw { inline = [] }
            var new: [NSAttributedString.Key: Any] = [
                .font: font(kind: kind, inline: inline),
                .foregroundColor: attrs[.link] != nil ? DocPalette.link : DocPalette.text,
                .strikethroughStyle: inline.contains(.strike)
                    ? NSUnderlineStyle.single.rawValue : 0,
                .underlineStyle: attrs[.link] != nil ? NSUnderlineStyle.single.rawValue : 0,
            ]
            if inline.contains(.code) {
                new[.backgroundColor] = DocPalette.inlineCodeFill
            } else if attrs[.backgroundColor] != nil {
                storage.removeAttribute(.backgroundColor, range: sub)
            }
            if case .heading = kind {
                new[.foregroundColor] = DocPalette.text
            } else if kind == .quote, attrs[.link] == nil {
                new[.foregroundColor] = DocPalette.secondary
            }
            storage.addAttributes(new, range: sub)
        }
    }
}

// MARK: - Bridge: blocks ↔ attributed string

enum DocText {
    static func attributed(_ blocks: [DocBlock]) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var first = true
        // The separator newline belongs to the paragraph BEFORE it, so it
        // wears that paragraph's kind — tracked here because an empty
        // paragraph (a rule) leaves no character to read it back from.
        var lastToken = DocBlockKind.paragraph.token
        for block in blocks {
            // Code/raw bodies span paragraphs; each line is its own
            // paragraph wearing the same kind.
            let paragraphs: [NSAttributedString]
            switch block.kind {
            case .code, .raw:
                paragraphs = block.plainText
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { NSAttributedString(string: String($0), attributes: [.docBlock: block.kind.token]) }
            case .rule:
                paragraphs = [NSAttributedString(string: "", attributes: [.docBlock: block.kind.token])]
            default:
                let p = NSMutableAttributedString()
                for run in block.runs {
                    var attrs: [NSAttributedString.Key: Any] = [
                        .docBlock: block.kind.token,
                        .docInline: NSNumber(value: run.style.rawValue),
                    ]
                    if let link = run.link { attrs[.link] = link }
                    p.append(NSAttributedString(string: run.text, attributes: attrs))
                }
                paragraphs = [p]
            }
            for p in paragraphs {
                if !first {
                    out.append(NSAttributedString(string: "\n", attributes: [.docBlock: lastToken]))
                }
                out.append(p)
                lastToken = block.kind.token
                first = false
            }
        }
        // A trailing empty paragraph is where the cursor lands after the
        // last block; without it a file ending in a rule or code has no
        // place to type.
        if let last = blocks.last, last.kind == .rule || {
            if case .code = last.kind { return true }
            return last.kind == .raw
        }() {
            out.append(NSAttributedString(string: "\n", attributes: [.docBlock: last.kind.token]))
            out.append(NSAttributedString(string: "", attributes: [.docBlock: DocBlockKind.paragraph.token]))
        }
        DocStyle.restyle(out, range: NSRange(location: 0, length: out.length))
        return out
    }

    static func blocks(of storage: NSAttributedString) -> [DocBlock] {
        let text = storage.string as NSString
        var blocks: [DocBlock] = []
        var loc = 0
        while loc <= text.length {
            let para = text.paragraphRange(for: NSRange(location: loc, length: 0))
            let kind = DocStyle.blockKind(storage, paragraph: para)
            var content = para
            if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 0x0A {
                content.length -= 1
            }
            let plain = text.substring(with: content)
            switch kind {
            case .code, .raw:
                // Consecutive lines of one kind fold into a single block.
                if var last = blocks.last, last.kind == kind {
                    last.runs = [DocRun(text: last.plainText + "\n" + plain)]
                    blocks[blocks.count - 1] = last
                } else {
                    blocks.append(DocBlock(kind: kind, runs: [DocRun(text: plain)]))
                }
            case .rule:
                blocks.append(DocBlock(kind: .rule, runs: []))
            default:
                var runs: [DocRun] = []
                if content.length > 0 {
                    storage.enumerateAttributes(in: content, options: []) { attrs, sub, _ in
                        runs.append(DocRun(
                            text: text.substring(with: sub),
                            style: DocStyle.inline(of: attrs),
                            link: linkString(attrs[.link])
                        ))
                    }
                }
                let merged = MarkdownDocument.mergeRuns(runs)
                // Empty paragraphs are editor breathing room, not content.
                if !merged.isEmpty || kind != .paragraph {
                    blocks.append(DocBlock(kind: kind, runs: merged))
                }
            }
            if para.length == 0 { break }
            loc = NSMaxRange(para)
            if loc >= text.length {
                // A trailing newline leaves an empty final paragraph
                // (already covered: it serialises to nothing).
                break
            }
        }
        // Drop empty paragraphs that only existed to give the cursor a
        // home, and empty trailing list items / quotes.
        while let last = blocks.last, last.runs.isEmpty, last.kind != .rule,
              !isCodeLike(last.kind) {
            blocks.removeLast()
        }
        return blocks
    }

    private static func isCodeLike(_ k: DocBlockKind) -> Bool {
        if case .code = k { return true }
        return k == .raw
    }

    private static func linkString(_ value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        if let s = value as? String { return s }
        return nil
    }
}

// MARK: - Layout manager: markers, bars, code backgrounds, rules

final class DocLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let text = storage.string as NSString
        let charRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let width = container.size.width - container.lineFragmentPadding * 2
        let pad = container.lineFragmentPadding

        var loc = charRange.location
        while loc <= text.length {
            let para = text.paragraphRange(for: NSRange(location: loc, length: 0))
            if para.location > NSMaxRange(charRange) { break }
            let kind = DocStyle.blockKind(storage, paragraph: para)
            let rect = paragraphRect(para, in: container)
            if rect.height > 0 {
                let frame = rect.offsetBy(dx: origin.x, dy: origin.y)
                switch kind {
                case let .bullet(depth):
                    drawMarker(depth == 0 ? "•" : depth == 1 ? "◦" : "▪", para: para, kind: kind, origin: origin)
                case let .numbered(depth):
                    drawMarker("\(ordinal(of: para, depth: depth, storage: storage)).", para: para, kind: kind, origin: origin)
                case .quote:
                    let bar = NSRect(x: frame.minX + pad + 4, y: frame.minY + 2, width: 3, height: frame.height - 4)
                    DocPalette.quoteBar.setFill()
                    NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
                case .code, .raw:
                    let prevSame = previousKind(para, storage: storage) == kind
                    let nextSame = nextKind(para, storage: storage, text: text) == kind
                    var box = NSRect(x: frame.minX + pad, y: frame.minY, width: width, height: frame.height)
                    // Round only the group's outer corners: extend the
                    // path past the joined edges and clip to the line.
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(rect: box).addClip()
                    if prevSame { box.origin.y -= 10; box.size.height += 10 }
                    if nextSame { box.size.height += 10 }
                    if !prevSame { box.origin.y -= 6; box.size.height += 6 }
                    if !nextSame { box.size.height += 6 }
                    DocPalette.codeFill.setFill()
                    NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
                    NSGraphicsContext.restoreGraphicsState()
                case .rule:
                    let y = (frame.midY).rounded() + 0.5
                    DocPalette.rule.setFill()
                    NSRect(x: frame.minX + pad, y: y, width: width, height: 1).fill()
                default:
                    break
                }
            }
            if para.length == 0 { break }
            loc = NSMaxRange(para)
            if loc >= text.length { break }
        }
    }

    /// Union of the paragraph's full-width line fragments.
    private func paragraphRect(_ para: NSRange, in container: NSTextContainer) -> NSRect {
        if para.length == 0 { return extraLineFragmentRect }
        let glyphs = glyphRange(forCharacterRange: para, actualCharacterRange: nil)
        var union = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
            union = union.union(rect)
        }
        return union.isNull ? .zero : union
    }

    private func drawMarker(_ marker: String, para: NSRange, kind: DocBlockKind, origin: NSPoint) {
        let font = DocStyle.font(kind: kind, inline: [])
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: DocPalette.secondary,
        ]
        let size = (marker as NSString).size(withAttributes: attrs)
        let glyph = glyphIndexForCharacter(at: para.location)
        let line = para.length == 0
            ? extraLineFragmentRect
            : lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline: CGFloat = para.length == 0
            ? line.minY + font.ascender
            : line.minY + location(forGlyphAt: glyph).y
        let indent = (kind.listDepth.map { DocStyle.listIndentBase + CGFloat($0) * DocStyle.listIndentStep } ?? 0)
        let x = origin.x + (textContainers.first?.lineFragmentPadding ?? 0) + indent - size.width - 8
        (marker as NSString).draw(
            at: NSPoint(x: x, y: origin.y + baseline - font.ascender), withAttributes: attrs
        )
    }

    private func previousKind(_ para: NSRange, storage: NSAttributedString) -> DocBlockKind? {
        guard para.location > 0 else { return nil }
        let text = storage.string as NSString
        let prev = text.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
        return DocStyle.blockKind(storage, paragraph: prev)
    }

    private func nextKind(_ para: NSRange, storage: NSAttributedString, text: NSString) -> DocBlockKind? {
        let end = NSMaxRange(para)
        guard para.length > 0, end < text.length || (end == text.length && text.character(at: end - 1) == 0x0A) else { return nil }
        let next = text.paragraphRange(for: NSRange(location: end, length: 0))
        return DocStyle.blockKind(storage, paragraph: next)
    }

    /// 1-based position among the consecutive numbered items at this depth.
    private func ordinal(of para: NSRange, depth: Int, storage: NSAttributedString) -> Int {
        let text = storage.string as NSString
        var n = 1
        var cursor = para
        while cursor.location > 0 {
            let prev = text.paragraphRange(for: NSRange(location: cursor.location - 1, length: 0))
            let kind = DocStyle.blockKind(storage, paragraph: prev)
            guard let d = kind.listDepth, d >= depth else { break }
            if case .numbered = kind, d == depth { n += 1 }
            if case .bullet = kind, d == depth { break }
            cursor = prev
        }
        return n
    }
}

// MARK: - The text view

@MainActor
protocol DocTextViewDelegate: AnyObject {
    func docTextDidChange(_ view: DocTextView)
    func docSelectionDidChange(_ view: DocTextView)
    func docRequestsSave(_ view: DocTextView)
}

final class DocTextView: NSTextView, NSTextStorageDelegate {
    weak var docDelegate: DocTextViewDelegate?
    private var restyling = false
    var placeholder = "Start writing…"

    static func make() -> DocTextView {
        let storage = NSTextStorage()
        let layout = DocLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 6
        layout.addTextContainer(container)
        let view = DocTextView(frame: .zero, textContainer: container)
        view.configure()
        storage.delegate = view
        return view
    }

    private func configure() {
        isRichText = true
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        importsGraphics = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        insertionPointColor = DocPalette.text
        selectedTextAttributes = [.backgroundColor: DocPalette.selection]
        linkTextAttributes = [
            .foregroundColor: DocPalette.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        resetTypingAttributes()
    }

    /// Plain-paragraph typing attributes — on load, so a document never
    /// inherits the previous one's cursor state.
    func resetTypingAttributes() {
        typingAttributes = [
            .docBlock: DocBlockKind.paragraph.token,
            .font: DocStyle.font(kind: .paragraph, inline: []),
            .foregroundColor: DocPalette.text,
            .paragraphStyle: DocStyle.paragraphStyle(kind: .paragraph),
        ]
    }

    // Center the column: side insets grow with the view, the text never
    // runs wider than `maxTextWidth`.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let side = max(28, ((newSize.width - DocStyle.maxTextWidth) / 2).rounded(.down))
        if textContainerInset.width != side {
            textContainerInset = NSSize(width: side, height: 28)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: DocStyle.font(kind: .paragraph, inline: []),
                .foregroundColor: DocPalette.secondary,
            ]
            let origin = NSPoint(
                x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                y: textContainerInset.height
            )
            (placeholder as NSString).draw(at: origin, withAttributes: attrs)
        }
    }

    // MARK: Storage delegate — the styling pass

    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        MainActor.assumeIsolated {
            // `self.textStorage` is the same object as the parameter; the
            // parameter can't cross into the actor under strict checking.
            guard !restyling, let storage = self.textStorage else { return }
            restyling = true
            DocStyle.restyle(storage, range: editedRange)
            restyling = false
        }
    }

    override func didChangeText() {
        super.didChangeText()
        docDelegate?.docTextDidChange(self)
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { docDelegate?.docSelectionDidChange(self) }
    }

    // MARK: Paragraph helpers

    private var text: NSString { string as NSString }

    var currentParagraph: NSRange {
        text.paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
    }

    var currentKind: DocBlockKind {
        guard let storage = textStorage else { return .paragraph }
        return DocStyle.blockKind(storage, paragraph: currentParagraph)
    }

    var currentInline: DocInline {
        let sel = selectedRange()
        if sel.length > 0, let storage = textStorage, sel.location < storage.length {
            return DocStyle.inline(of: storage.attributes(at: sel.location, effectiveRange: nil))
        }
        return DocStyle.inline(of: typingAttributes)
    }

    var currentLink: String? {
        let sel = selectedRange()
        guard let storage = textStorage else { return nil }
        let at = sel.length > 0 ? sel.location : max(0, sel.location - 1)
        guard at < storage.length else { return nil }
        let v = storage.attribute(.link, at: at, effectiveRange: nil)
        return (v as? URL)?.absoluteString ?? v as? String
    }

    /// Text of the paragraph before the insertion point (no newline).
    private func paragraphPrefix() -> String {
        let para = currentParagraph
        let upTo = selectedRange().location - para.location
        return text.substring(with: NSRange(location: para.location, length: max(0, upTo)))
    }

    private func paragraphContent(_ para: NSRange) -> String {
        var r = para
        if r.length > 0, text.character(at: NSMaxRange(r) - 1) == 0x0A { r.length -= 1 }
        return text.substring(with: r)
    }

    /// Sets the block kind on whole paragraphs (undoable).
    func setKind(_ kind: DocBlockKind, in range: NSRange? = nil) {
        guard let storage = textStorage else { return }
        let target = text.paragraphRange(for: range ?? selectedRange())
        let sel = selectedRange()
        if target.length == 0 {
            // Empty document / empty trailing paragraph: the kind rides
            // the typing attributes until a character lands.
            var attrs = typingAttributes
            attrs[.docBlock] = kind.token
            attrs[.font] = DocStyle.font(kind: kind, inline: DocStyle.inline(of: attrs))
            attrs[.paragraphStyle] = DocStyle.paragraphStyle(kind: kind)
            typingAttributes = attrs
            if storage.length == 0 {
                // Give the layout manager a paragraph to decorate.
                insertText(NSAttributedString(string: "", attributes: attrs), replacementRange: sel)
            }
            docDelegate?.docSelectionDidChange(self)
            return
        }
        guard shouldChangeText(in: target, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttribute(.docBlock, value: kind.token, range: target)
        storage.endEditing()
        didChangeText()
        setSelectedRange(sel)
        var attrs = typingAttributes
        attrs[.docBlock] = kind.token
        typingAttributes = attrs
        docDelegate?.docSelectionDidChange(self)
    }

    func toggleInline(_ flag: DocInline) {
        guard let storage = textStorage else { return }
        let sel = selectedRange()
        if sel.length == 0 {
            var attrs = typingAttributes
            var inline = DocStyle.inline(of: attrs)
            if inline.contains(flag) { inline.remove(flag) } else { inline.insert(flag) }
            attrs[.docInline] = NSNumber(value: inline.rawValue)
            attrs[.font] = DocStyle.font(kind: currentKind, inline: inline)
            attrs[.backgroundColor] = inline.contains(.code) ? DocPalette.inlineCodeFill : nil
            typingAttributes = attrs
            docDelegate?.docSelectionDidChange(self)
            return
        }
        var all = true
        storage.enumerateAttribute(.docInline, in: sel, options: []) { v, _, stop in
            let inline = DocInline(rawValue: (v as? NSNumber)?.uint8Value ?? 0)
            if !inline.contains(flag) { all = false; stop.pointee = true }
        }
        guard shouldChangeText(in: sel, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.docInline, in: sel, options: []) { v, sub, _ in
            var inline = DocInline(rawValue: (v as? NSNumber)?.uint8Value ?? 0)
            if all { inline.remove(flag) } else { inline.insert(flag) }
            storage.addAttribute(.docInline, value: NSNumber(value: inline.rawValue), range: sub)
        }
        storage.endEditing()
        didChangeText()
        setSelectedRange(sel)
        docDelegate?.docSelectionDidChange(self)
    }

    func setLink(_ url: String?) {
        guard let storage = textStorage else { return }
        var sel = selectedRange()
        if sel.length == 0, let url, !url.isEmpty {
            // Nothing selected: the URL becomes linked text.
            let attrs = typingAttributes.merging([.link: url]) { $1 }
            insertText(NSAttributedString(string: url, attributes: attrs), replacementRange: sel)
            sel = NSRange(location: sel.location, length: (url as NSString).length)
        }
        guard sel.length > 0, shouldChangeText(in: sel, replacementString: nil) else { return }
        storage.beginEditing()
        if let url, !url.isEmpty {
            storage.addAttribute(.link, value: url, range: sel)
        } else {
            storage.removeAttribute(.link, range: sel)
        }
        storage.endEditing()
        didChangeText()
        setSelectedRange(sel)
        docDelegate?.docSelectionDidChange(self)
    }

    func insertRule() {
        let para = currentParagraph
        let content = paragraphContent(para)
        var insertion = NSMaxRange(para)
        let rule = NSMutableAttributedString()
        if !content.isEmpty, text.character(at: max(0, insertion - 1)) != 0x0A || insertion == text.length {
            if insertion == text.length, !content.isEmpty {
                rule.append(NSAttributedString(string: "\n", attributes: [.docBlock: currentKind.token]))
            }
        }
        if content.isEmpty { insertion = para.location }
        rule.append(NSAttributedString(string: "\n", attributes: [.docBlock: DocBlockKind.rule.token]))
        if content.isEmpty, para.length > 0 {
            // Replace the empty paragraph's newline.
            insertText(rule, replacementRange: NSRange(location: para.location, length: 0))
        } else {
            insertText(rule, replacementRange: NSRange(location: insertion, length: 0))
        }
        let after = NSRange(location: insertion + rule.length, length: 0)
        if after.location >= text.length {
            insertText(NSAttributedString(string: "", attributes: typingAttributes), replacementRange: after)
        }
        setSelectedRange(after)
        setKind(.paragraph)
    }

    // MARK: Keys

    override func insertNewline(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            insertLineBreak(sender)
            return
        }
        let para = currentParagraph
        let kind = currentKind
        let content = paragraphContent(para)
        let atEnd = selectedRange().location >= NSMaxRange(para) - (para.length > 0 && text.character(at: NSMaxRange(para) - 1) == 0x0A ? 1 : 0)
        // The inserted newline becomes THIS paragraph's anchor character,
        // so it must wear this paragraph's kind — the typing attributes
        // may still hold whatever the cursor last sat on.
        var attrs = typingAttributes
        attrs[.docBlock] = kind.token
        typingAttributes = attrs

        switch kind {
        case .bullet, .numbered:
            if content.isEmpty {
                // Enter on an empty item leaves the list (outdenting first).
                if let d = kind.listDepth, d > 0 { setKind(kind.withListDepth(d - 1)) }
                else { setKind(.paragraph) }
                return
            }
            super.insertNewline(sender)
            setKind(kind)
        case .quote:
            if content.isEmpty { setKind(.paragraph); return }
            super.insertNewline(sender)
            setKind(kind)
        case .code, .raw:
            // Two empty lines then Enter: step out of the block.
            if content.isEmpty, para.location > 0 {
                let prev = text.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
                if paragraphContent(prev).isEmpty,
                   DocStyle.blockKind(textStorage!, paragraph: prev) == kind {
                    insertText("", replacementRange: NSRange(location: prev.location, length: para.location - prev.location))
                    setKind(.paragraph)
                    return
                }
            }
            super.insertNewline(sender)
            setKind(kind)
        case .heading:
            super.insertNewline(sender)
            setKind(atEnd ? .paragraph : kind)
        case .rule:
            super.insertNewline(sender)
            setKind(.paragraph)
        case .paragraph:
            if content == "---" || content == "***" {
                // The typed rule: swap the dashes for a rule paragraph.
                let r = NSRange(location: para.location, length: (content as NSString).length)
                insertText("", replacementRange: r)
                setKind(.rule, in: NSRange(location: para.location, length: 0))
                super.insertNewline(sender)
                setKind(.paragraph)
                return
            }
            super.insertNewline(sender)
            setKind(.paragraph)
        }
    }

    override func insertTab(_ sender: Any?) {
        let kind = currentKind
        if let d = kind.listDepth {
            setKind(kind.withListDepth(min(d + 1, 5)))
        } else if case .code = kind {
            insertText("    ", replacementRange: selectedRange())
        } else if kind == .raw {
            insertText("\t", replacementRange: selectedRange())
        }
    }

    override func insertBacktab(_ sender: Any?) {
        let kind = currentKind
        if let d = kind.listDepth, d > 0 { setKind(kind.withListDepth(d - 1)) }
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        let para = currentParagraph
        guard sel.length == 0, sel.location == para.location else {
            super.deleteBackward(sender)
            return
        }
        let kind = currentKind
        switch kind {
        case .bullet, .numbered:
            if let d = kind.listDepth, d > 0 { setKind(kind.withListDepth(d - 1)) }
            else { setKind(.paragraph) }
        case .quote, .heading, .rule:
            setKind(.paragraph)
        case .code, .raw:
            // First line of the block → paragraph; inner lines join.
            if para.location == 0 {
                setKind(.paragraph)
            } else {
                let prev = text.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
                if DocStyle.blockKind(textStorage!, paragraph: prev) == kind {
                    super.deleteBackward(sender)
                } else {
                    setKind(.paragraph)
                }
            }
        case .paragraph:
            guard para.location > 0, let storage = textStorage else {
                super.deleteBackward(sender)
                return
            }
            // Joining onto the previous paragraph keeps ITS kind.
            let prev = text.paragraphRange(for: NSRange(location: para.location - 1, length: 0))
            let prevKind = DocStyle.blockKind(storage, paragraph: prev)
            if prevKind == .rule {
                // Backspacing into a rule removes the rule.
                insertText("", replacementRange: NSRange(location: prev.location, length: prev.length))
                return
            }
            super.deleteBackward(sender)
            setKind(prevKind, in: NSRange(location: selectedRange().location, length: 0))
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard let typed = string as? String ?? (string as? NSAttributedString)?.string,
              typed == " " || typed == "`" else { return }
        applyInputRule()
    }

    /// Markdown shortcuts at the start of a paragraph: `# `, `- `,
    /// `1. `, `> `, "```" (TipTap's input rules, the ones people type
    /// without thinking).
    private func applyInputRule() {
        let kind = currentKind
        let para = currentParagraph
        let prefix = paragraphPrefix()
        var target: DocBlockKind?
        if case .code = kind { return }
        if kind == .raw { return }
        if prefix == "```" {
            target = .code(lang: "")
        } else if prefix.hasSuffix(" ") {
            let head = String(prefix.dropLast())
            if head.allSatisfy({ $0 == "#" }), (1...6).contains(head.count) {
                target = .heading(head.count)
            } else if head == "-" || head == "*" || head == "+" {
                target = .bullet(depth: kind.listDepth ?? 0)
            } else if head == ">" {
                target = .quote
            } else if head.count <= 3, head.allSatisfy(\.isNumber), head.hasSuffix("") {
                target = nil
            } else if head.hasSuffix("."), head.dropLast().allSatisfy(\.isNumber), !head.dropLast().isEmpty {
                target = .numbered(depth: kind.listDepth ?? 0)
            }
        }
        guard let target, kind == .paragraph || (kind.isList && target.isList) else { return }
        insertText("", replacementRange: NSRange(location: para.location, length: (prefix as NSString).length))
        setKind(target, in: NSRange(location: para.location, length: 0))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == [.command] {
            switch key {
            case "b": toggleInline(.bold); return true
            case "i": toggleInline(.italic); return true
            case "e": toggleInline(.code); return true
            case "k": promptForLink(); return true
            case "s": docDelegate?.docRequestsSave(self); return true
            default: break
            }
        }
        if flags == [.command, .shift] {
            switch key {
            case "x": toggleInline(.strike); return true
            case "7", "&": setKind(currentKind.isNumberedList ? .paragraph : .numbered(depth: 0)); return true
            case "8", "*": setKind(currentKind.isBulletList ? .paragraph : .bullet(depth: 0)); return true
            case ".", ">": setKind(currentKind == .quote ? .paragraph : .quote); return true
            default: break
            }
        }
        if flags == [.command, .option] {
            switch key {
            case "0": setKind(.paragraph); return true
            case "1": setKind(.heading(1)); return true
            case "2": setKind(.heading(2)); return true
            case "3": setKind(.heading(3)); return true
            case "c": setKind({ if case .code = currentKind { return .paragraph }; return .code(lang: "") }()); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Menu actions (Format menu; validated via the responder chain)

    @objc func toggleDocBold(_ sender: Any?) { toggleInline(.bold) }
    @objc func toggleDocItalic(_ sender: Any?) { toggleInline(.italic) }
    @objc func toggleDocStrike(_ sender: Any?) { toggleInline(.strike) }
    @objc func toggleDocCode(_ sender: Any?) { toggleInline(.code) }
    @objc func setDocLink(_ sender: Any?) { promptForLink() }
    @objc func setDocParagraph(_ sender: Any?) { setKind(.paragraph) }
    @objc func setDocHeading1(_ sender: Any?) { setKind(.heading(1)) }
    @objc func setDocHeading2(_ sender: Any?) { setKind(.heading(2)) }
    @objc func setDocHeading3(_ sender: Any?) { setKind(.heading(3)) }
    @objc func setDocBullet(_ sender: Any?) { setKind(currentKind.isBulletList ? .paragraph : .bullet(depth: 0)) }
    @objc func setDocNumbered(_ sender: Any?) { setKind(currentKind.isNumberedList ? .paragraph : .numbered(depth: 0)) }
    @objc func setDocQuote(_ sender: Any?) { setKind(currentKind == .quote ? .paragraph : .quote) }
    @objc func setDocCodeBlock(_ sender: Any?) {
        if case .code = currentKind { setKind(.paragraph) } else { setKind(.code(lang: "")) }
    }
    @objc func insertDocRule(_ sender: Any?) { insertRule() }

    func promptForLink() {
        let alert = NSAlert()
        alert.messageText = "Link"
        alert.informativeText = selectedRange().length > 0
            ? "The selected text links to this URL." : "Inserted as linked text."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://"
        field.stringValue = currentLink ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Set Link")
        alert.addButton(withTitle: "Cancel")
        if currentLink != nil { alert.addButton(withTitle: "Remove Link") }
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                var url = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty, !url.contains("://"), !url.hasPrefix("mailto:"), !url.hasPrefix("/") {
                    url = "https://" + url
                }
                self.setLink(url.isEmpty ? nil : url)
            case .alertThirdButtonReturn:
                self.setLink(nil)
            default:
                break
            }
            self.window?.makeFirstResponder(self)
        }
    }

    // MARK: Clipboard — markdown out, markdown in

    override func copy(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length > 0, let storage = textStorage else { return }
        let sub = storage.attributedSubstring(from: sel)
        let md = MarkdownDocument.serialize(DocText.blocks(of: sub))
            .trimmingCharacters(in: .newlines)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(md, forType: .string)
    }

    override func cut(_ sender: Any?) {
        copy(sender)
        delete(sender)
    }

    override func paste(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let sel = selectedRange()
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let blocky = lines.count > 1 && lines.contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("#") || t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("> ")
                || t.hasPrefix("```") || t.range(of: #"^\d+\. "#, options: .regularExpression) != nil
        }
        if blocky {
            // Multi-line markdown pastes as structure: lists stay lists.
            let parsed = DocText.attributed(MarkdownDocument.parse(raw))
            let para = currentParagraph
            var body = NSMutableAttributedString()
            if paragraphContent(para).isEmpty || sel.location != para.location {
                body = parsed
            } else {
                body = parsed
            }
            if sel.location != para.location, !paragraphContent(para).isEmpty {
                body.insert(NSAttributedString(string: "\n", attributes: typingAttributes), at: 0)
            }
            insertText(body, replacementRange: sel)
        } else {
            let attrs = typingAttributes
            if case .code = currentKind {
                insertText(NSAttributedString(string: raw, attributes: attrs), replacementRange: sel)
            } else {
                // Single paragraph: inline markup is honored, line breaks
                // become paragraphs of the current kind.
                let out = NSMutableAttributedString()
                for (i, line) in lines.enumerated() {
                    if i > 0 { out.append(NSAttributedString(string: "\n", attributes: attrs)) }
                    for run in MarkdownDocument.parseInline(String(line)) {
                        var a = attrs
                        a[.docInline] = NSNumber(value: run.style.union(DocStyle.inline(of: attrs)).rawValue)
                        if let link = run.link { a[.link] = link }
                        out.append(NSAttributedString(string: run.text, attributes: a))
                    }
                }
                insertText(out, replacementRange: sel)
            }
        }
    }
}

extension DocBlockKind {
    var isBulletList: Bool { if case .bullet = self { return true }; return false }
    var isNumberedList: Bool { if case .numbered = self { return true }; return false }
}

// MARK: - Model: file ↔ text view, autosave

@MainActor
final class DocumentEditorModel: ObservableObject, DocTextViewDelegate {
    let path: String
    @Published var kind: DocBlockKind = .paragraph
    @Published var inline: DocInline = []
    @Published var hasLink = false
    @Published var dirty = false
    @Published var loadError: String?

    weak var textView: DocTextView? {
        didSet { textView?.docDelegate = self }
    }
    private var lastWritten = ""
    private var knownMTime: Date?
    private var saveWork: DispatchWorkItem?
    private var watch: Timer?

    init(path: String) {
        self.path = path
    }

    var title: String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    func attach(_ view: DocTextView) {
        textView = view
        load()
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkExternalChange() }
        }
    }

    func detach() {
        saveWork?.cancel()
        saveNow()
        watch?.invalidate()
        watch = nil
    }

    private func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func load() {
        guard let view = textView, let storage = view.textStorage else { return }
        let markdown = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        lastWritten = markdown
        knownMTime = mtime()
        let attributed = DocText.attributed(MarkdownDocument.parse(markdown))
        storage.setAttributedString(attributed)
        view.resetTypingAttributes()
        view.undoManager?.removeAllActions()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        dirty = false
        docSelectionDidChange(view)
    }

    /// An agent (or anything else) rewrote the file: reload unless the
    /// editor holds unsaved edits — then ours win on the next save.
    private func checkExternalChange() {
        guard !dirty, let current = mtime(), let known = knownMTime, current > known else { return }
        let onDisk = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard onDisk != lastWritten else { knownMTime = current; return }
        let sel = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        load()
        if let view = textView, sel.location <= view.string.utf16.count {
            view.setSelectedRange(NSRange(location: sel.location, length: 0))
        }
    }

    func docTextDidChange(_ view: DocTextView) {
        dirty = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func docSelectionDidChange(_ view: DocTextView) {
        kind = view.currentKind
        inline = view.currentInline
        hasLink = view.currentLink != nil
    }

    func docRequestsSave(_ view: DocTextView) {
        saveWork?.cancel()
        saveNow()
    }

    func saveNow() {
        guard let storage = textView?.textStorage else { return }
        let markdown = MarkdownDocument.serialize(DocText.blocks(of: storage))
        dirty = false
        guard markdown != lastWritten else { return }
        do {
            try markdown.write(toFile: path, atomically: true, encoding: .utf8)
            lastWritten = markdown
            knownMTime = mtime()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - SwiftUI

private struct DocTextRepresentable: NSViewRepresentable {
    @ObservedObject var model: DocumentEditorModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller = ThinScroller()
        let view = DocTextView.make()
        scroll.documentView = view
        model.attach(view)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: ()) {
        (nsView.documentView as? DocTextView)?.docDelegate.map { delegate in
            (delegate as? DocumentEditorModel)?.detach()
        }
    }
}

/// The document surface: title row (rename in place), a formatting
/// strip, and the editor column.
struct DocumentEditorView: View {
    let path: String
    /// Project-relative label under the title ("docs/Spec.md"), or
    /// "Global" for the shared folder.
    let subtitle: String
    let onRename: (String) -> Void
    let onClose: () -> Void

    @StateObject private var model: DocumentEditorModel
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    init(path: String, subtitle: String, onRename: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.path = path
        self.subtitle = subtitle
        self.onRename = onRename
        self.onClose = onClose
        _model = StateObject(wrappedValue: DocumentEditorModel(path: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            DocTextRepresentable(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .onAppear { titleDraft = model.title }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Untitled", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { commitTitle() }
                    }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text(model.loadError ?? (model.dirty ? "Editing…" : "Saved"))
                .font(.system(size: 11))
                .foregroundStyle(model.loadError == nil ? Theme.textSecondary : Theme.textDanger)
            PanelControlButton(icon: "x", help: "Back to chat", action: onClose)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func commitTitle() {
        let clean = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != model.title else {
            titleDraft = model.title
            return
        }
        onRename(clean)
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Menu {
                blockItem("Paragraph", .paragraph)
                blockItem("Heading 1", .heading(1))
                blockItem("Heading 2", .heading(2))
                blockItem("Heading 3", .heading(3))
                Divider()
                blockItem("Bulleted list", .bullet(depth: 0))
                blockItem("Numbered list", .numbered(depth: 0))
                blockItem("Quote", .quote)
                blockItem("Code block", .code(lang: ""))
                Divider()
                Button("Divider") { model.textView?.insertRule() }
            } label: {
                HStack(spacing: 5) {
                    LucideIcon(blockIcon, size: 13)
                    Text(blockLabel)
                        .font(.system(size: 12))
                    LucideIcon("chevron-down", size: 11)
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.controlChip))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            Rectangle().fill(Theme.borderSidebar).frame(width: 1, height: 16).padding(.horizontal, 6)
            DocToolButton(icon: "bold", help: "Bold (⌘B)", active: model.inline.contains(.bold)) {
                model.textView?.toggleInline(.bold)
            }
            DocToolButton(icon: "italic", help: "Italic (⌘I)", active: model.inline.contains(.italic)) {
                model.textView?.toggleInline(.italic)
            }
            DocToolButton(icon: "strikethrough", help: "Strikethrough (⇧⌘X)", active: model.inline.contains(.strike)) {
                model.textView?.toggleInline(.strike)
            }
            DocToolButton(icon: "code", help: "Inline code (⌘E)", active: model.inline.contains(.code)) {
                model.textView?.toggleInline(.code)
            }
            DocToolButton(icon: "link", help: "Link (⌘K)", active: model.hasLink) {
                model.textView?.promptForLink()
            }
            Rectangle().fill(Theme.borderSidebar).frame(width: 1, height: 16).padding(.horizontal, 6)
            DocToolButton(icon: "list", help: "Bulleted list (⇧⌘8)", active: model.kind.isBulletList) {
                model.textView?.setDocBullet(nil)
            }
            DocToolButton(icon: "list-ordered", help: "Numbered list (⇧⌘7)", active: model.kind.isNumberedList) {
                model.textView?.setDocNumbered(nil)
            }
            DocToolButton(icon: "text-quote", help: "Quote (⇧⌘.)", active: model.kind == .quote) {
                model.textView?.setDocQuote(nil)
            }
            DocToolButton(icon: "square-code", help: "Code block (⌥⌘C)", active: {
                if case .code = model.kind { return true }; return false
            }()) {
                model.textView?.setDocCodeBlock(nil)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
    }

    private func blockItem(_ label: String, _ kind: DocBlockKind) -> some View {
        Toggle(label, isOn: Binding(
            get: { model.kind == kind },
            set: { _ in model.textView?.setKind(kind) }
        ))
    }

    private var blockLabel: String {
        switch model.kind {
        case .paragraph: "Paragraph"
        case let .heading(n): "Heading \(n)"
        case .bullet: "Bulleted list"
        case .numbered: "Numbered list"
        case .quote: "Quote"
        case .code: "Code block"
        case .rule: "Divider"
        case .raw: "Raw markdown"
        }
    }

    private var blockIcon: String {
        switch model.kind {
        case .paragraph: "pilcrow"
        case let .heading(n): n == 1 ? "heading-1" : n == 2 ? "heading-2" : "heading-3"
        case .bullet: "list"
        case .numbered: "list-ordered"
        case .quote: "text-quote"
        case .code, .raw: "square-code"
        case .rule: "minus"
        }
    }
}

private struct DocToolButton: View {
    let icon: String
    let help: String
    let active: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Theme.controlChip : Color.clear)
                if hovered {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.rowHovered)
                }
                LucideIcon(icon, size: 14)
                    .foregroundStyle(active ? Theme.text : Theme.textSecondary)
            }
            .frame(width: 26, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

// MARK: - Headless self-test (HOUSTON_DOC_SELFTEST=1)

/// Exercises the bridge and the editor's key handling without a window:
/// `HOUSTON_DOC_SELFTEST=1 .build/debug/Houston` prints results and
/// exits. Not a unit-test target (the package has none); it's the
/// cheapest way to keep "Enter on an empty bullet leaves the list"
/// true after a refactor.
enum DocumentSelfTest {
    @MainActor
    static func run() -> Int32 {
        var failures = 0
        func expect(_ name: String, _ got: String, _ want: String) {
            if got == want {
                print("ok   \(name)")
            } else {
                failures += 1
                print("FAIL \(name)\n--- want\n\(want)\n--- got\n\(got)")
            }
        }

        // Bridge round trip.
        for md in [
            "# Title\n\nSome **bold** and *italic*.\n",
            "- one\n- two\n  - nested\n- three\n",
            "1. a\n2. b\n",
            "> quote\n",
            "```swift\nlet x = 1\n\nprint(x)\n```\n",
            "a\n\n---\n\nb\n",
            "| a | b |\n|---|---|\n",
            "[link](https://x.y) and `code`\n",
            "line\\\nbreak\n",
        ] {
            let blocks = MarkdownDocument.parse(md)
            let back = DocText.blocks(of: DocText.attributed(blocks))
            expect("bridge " + md.prefix(12).replacingOccurrences(of: "\n", with: "⏎"),
                   MarkdownDocument.serialize(back), MarkdownDocument.serialize(blocks))
        }

        // Editor behaviour.
        let view = DocTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        func load(_ md: String) {
            view.textStorage?.setAttributedString(DocText.attributed(MarkdownDocument.parse(md)))
            view.resetTypingAttributes()
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        }
        func out() -> String {
            MarkdownDocument.serialize(DocText.blocks(of: view.textStorage!))
        }

        load("- one")
        view.insertNewline(nil)
        view.insertText("two", replacementRange: view.selectedRange())
        expect("enter continues list", out(), "- one\n- two\n")
        view.insertNewline(nil)
        view.insertNewline(nil)
        view.insertText("para", replacementRange: view.selectedRange())
        expect("enter on empty item exits", out(), "- one\n- two\n\npara\n")

        load("")
        view.insertText("-", replacementRange: view.selectedRange())
        view.insertText(" ", replacementRange: view.selectedRange())
        view.insertText("item", replacementRange: view.selectedRange())
        expect("input rule dash", out(), "- item\n")
        view.insertTab(nil)
        expect("tab indents", out(), "  - item\n")
        view.insertBacktab(nil)
        expect("backtab outdents", out(), "- item\n")

        load("")
        for c in ["#", "#", " ", "H"] { view.insertText(c, replacementRange: view.selectedRange()) }
        expect("input rule heading", out(), "## H\n")
        view.insertNewline(nil)
        view.insertText("body", replacementRange: view.selectedRange())
        expect("enter after heading is paragraph", out(), "## H\n\nbody\n")

        load("")
        for c in ["1", ".", " ", "x"] { view.insertText(c, replacementRange: view.selectedRange()) }
        view.insertNewline(nil)
        view.insertText("y", replacementRange: view.selectedRange())
        expect("numbered", out(), "1. x\n2. y\n")

        load("")
        for c in ["`", "`", "`"] { view.insertText(c, replacementRange: view.selectedRange()) }
        view.insertText("let a = 1", replacementRange: view.selectedRange())
        view.insertNewline(nil)
        view.insertText("let b = 2", replacementRange: view.selectedRange())
        expect("code fence rule", out(), "```\nlet a = 1\nlet b = 2\n```\n")
        view.insertNewline(nil)
        view.insertNewline(nil)
        view.insertNewline(nil)
        view.insertText("after", replacementRange: view.selectedRange())
        expect("triple enter exits code", out(), "```\nlet a = 1\nlet b = 2\n```\n\nafter\n")

        load("hello world")
        view.setSelectedRange(NSRange(location: 6, length: 5))
        view.toggleInline(.bold)
        expect("bold selection", out(), "hello **world**\n")
        view.toggleInline(.italic)
        expect("bold+italic", out(), "hello ***world***\n")
        view.toggleInline(.bold)
        expect("unbold", out(), "hello *world*\n")
        view.setLink("https://x.y")
        expect("link", out(), "hello [*world*](https://x.y)\n")

        load("- a\n- b")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.deleteBackward(nil)
        expect("backspace at item start → paragraph", out(), "- a\n\nb\n")
        view.deleteBackward(nil)
        expect("backspace joins onto previous kind", out(), "- ab\n")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.deleteBackward(nil)
        expect("backspace at doc start leaves list", out(), "ab\n")

        load("# H\npara")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.deleteBackward(nil)
        expect("join keeps first kind", out(), "# Hpara\n")

        load("x")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertRule()
        view.insertText("y", replacementRange: view.selectedRange())
        expect("insert rule", out(), "x\n\n---\n\ny\n")

        load("x")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.insertNewline(nil)
        for c in ["-", "-", "-"] { view.insertText(c, replacementRange: view.selectedRange()) }
        view.insertNewline(nil)
        view.insertText("z", replacementRange: view.selectedRange())
        expect("typed --- rule", out(), "x\n\n---\n\nz\n")

        load("")
        view.setKind(.heading(1))
        view.insertText("T", replacementRange: view.selectedRange())
        expect("kind on empty doc", out(), "# T\n")

        load("para")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.setKind(.quote)
        expect("set quote", out(), "> para\n")
        view.setKind(.quote)
        expect("toggle via menu action", out(), "> para\n")
        view.setDocQuote(nil)
        expect("toggle off quote", out(), "para\n")

        // Copy writes markdown.
        load("a **b** c")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.copy(nil)
        expect("copy markdown", NSPasteboard.general.string(forType: .string) ?? "", "a **b**")

        // Paste: multi-line markdown becomes structure.
        load("")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("- p\n- q", forType: .string)
        view.paste(nil)
        expect("paste list", out(), "- p\n- q\n")

        // CLAUDE.md through the whole pipeline.
        let claudePath = NSHomeDirectory() + "/Apps/houston/CLAUDE.md"
        if let md = try? String(contentsOfFile: claudePath, encoding: .utf8) {
            let viaParser = MarkdownDocument.serialize(MarkdownDocument.parse(md))
            load(md)
            expect("CLAUDE.md editor round trip", out(), viaParser)
        }

        print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
