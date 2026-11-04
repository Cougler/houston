import Foundation

// The documents feature's file format layer (2026-10-20): a markdown
// subset ↔ a small block model, pure Foundation, no AppKit. The editor
// (`DocumentEditorView`) edits an NSAttributedString carrying these
// kinds as attributes; this file is the only code that knows markdown
// syntax, so round-trip bugs live in one place.
//
// What's understood: ATX + setext headings, paragraphs (soft-wrapped
// lines join; a trailing `\` or two spaces is a hard break), `-`/`*`/`+`
// bullets and `1.` numbered lists (nesting by indent, lazy continuation
// lines), `>` quotes, fenced code, thematic breaks, and inline
// `**bold**`, `*italic*`, `~~strike~~`, `` `code` ``, `[text](url)`.
// Anything else is kept as plain text, never dropped — a line the
// parser doesn't recognise survives verbatim as paragraph text.

struct DocInline: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let bold = DocInline(rawValue: 1)
    static let italic = DocInline(rawValue: 2)
    static let strike = DocInline(rawValue: 4)
    static let code = DocInline(rawValue: 8)
}

struct DocRun: Equatable, Sendable {
    var text: String
    var style: DocInline = []
    var link: String? = nil
}

enum DocBlockKind: Equatable, Sendable {
    case paragraph
    case heading(Int)
    case bullet(depth: Int)
    case numbered(depth: Int)
    case quote
    case code(lang: String)
    case rule
    /// Lines the parser doesn't model (tables, HTML blocks): kept
    /// verbatim, shown monospaced, written back untouched.
    case raw

    var isList: Bool {
        switch self {
        case .bullet, .numbered: true
        default: false
        }
    }

    var listDepth: Int? {
        switch self {
        case let .bullet(depth), let .numbered(depth): depth
        default: nil
        }
    }

    /// The same kind one level shallower / deeper (lists only).
    func withListDepth(_ depth: Int) -> DocBlockKind {
        switch self {
        case .bullet: .bullet(depth: max(0, depth))
        case .numbered: .numbered(depth: max(0, depth))
        default: self
        }
    }

    /// A compact string form — what rides on the attributed string as
    /// the paragraph's block attribute (plain strings survive every
    /// NSAttributedString code path: pasteboard, archiving, fixAttributes).
    var token: String {
        switch self {
        case .paragraph: "p"
        case let .heading(n): "h\(n)"
        case let .bullet(depth): "ul:\(depth)"
        case let .numbered(depth): "ol:\(depth)"
        case .quote: "q"
        case let .code(lang): "code:" + lang
        case .rule: "hr"
        case .raw: "raw"
        }
    }

    init?(token: String) {
        switch token {
        case "p": self = .paragraph
        case "q": self = .quote
        case "hr": self = .rule
        case "raw": self = .raw
        default:
            if token.hasPrefix("h"), let n = Int(token.dropFirst()), (1...6).contains(n) {
                self = .heading(n)
            } else if token.hasPrefix("ul:"), let d = Int(token.dropFirst(3)) {
                self = .bullet(depth: d)
            } else if token.hasPrefix("ol:"), let d = Int(token.dropFirst(3)) {
                self = .numbered(depth: d)
            } else if token.hasPrefix("code:") {
                self = .code(lang: String(token.dropFirst(5)))
            } else {
                return nil
            }
        }
    }
}

/// One block. Code blocks keep their whole body (newlines included) in
/// a single plain run; everything else holds styled runs, with
/// U+2028 (line separator) marking a hard line break inside the block.
struct DocBlock: Equatable, Sendable {
    var kind: DocBlockKind
    var runs: [DocRun]

    var plainText: String { runs.map(\.text).joined() }
}

enum MarkdownDocument {
    static let hardBreak: Character = "\u{2028}"

    // MARK: - Parse

    static func parse(_ markdown: String) -> [DocBlock] {
        var p = Parser()
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            p.consume(line)
        }
        p.finish()
        return p.blocks
    }

    private struct Parser {
        var blocks: [DocBlock] = []
        /// The block being accumulated line by line (lists, quotes and
        /// paragraphs take lazy continuation lines).
        private var pendingKind: DocBlockKind?
        private var pendingLines: [String] = []
        private var fence: (lang: String, marker: String, lines: [String])?
        /// Indent columns of the open list levels — a deeper indent
        /// nests, a shallower one pops back.
        private var listIndents: [Int] = []

        mutating func consume(_ line: String) {
            if var f = fence {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix(f.marker),
                   line.trimmingCharacters(in: .whitespaces)
                    .allSatisfy({ $0 == f.marker.first! }) {
                    blocks.append(DocBlock(
                        kind: .code(lang: f.lang),
                        runs: [DocRun(text: f.lines.joined(separator: "\n"))]
                    ))
                    fence = nil
                } else {
                    f.lines.append(line)
                    fence = f
                }
                return
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let body = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            if trimmed.isEmpty {
                flush()
                listIndents = []
                return
            }

            // Fence open: ``` or ~~~ with an optional language word.
            if let open = fenceOpen(trimmed) {
                flush()
                listIndents = []
                fence = (open.lang, open.marker, [])
                return
            }

            // Setext underline turns the pending paragraph into a heading.
            if pendingKind == .paragraph, !pendingLines.isEmpty,
               let level = setextLevel(trimmed) {
                let text = pendingLines.joined(separator: " ")
                pendingKind = nil
                pendingLines = []
                blocks.append(DocBlock(kind: .heading(level), runs: parseInline(text)))
                return
            }

            if isRule(trimmed) {
                flush()
                listIndents = []
                blocks.append(DocBlock(kind: .rule, runs: []))
                return
            }

            if let (level, text) = atxHeading(trimmed) {
                flush()
                listIndents = []
                blocks.append(DocBlock(kind: .heading(level), runs: parseInline(text)))
                return
            }

            if let (indent, ordered, text) = listItem(line) {
                flush()
                // Resolve the nesting depth from the indent stack.
                while let top = listIndents.last, indent < top { listIndents.removeLast() }
                if listIndents.isEmpty || indent > listIndents.last! {
                    listIndents.append(indent)
                }
                let depth = max(0, listIndents.count - 1)
                pendingKind = ordered ? .numbered(depth: depth) : .bullet(depth: depth)
                pendingLines = [text]
                return
            }

            // Tables and HTML blocks: not modelled, preserved verbatim.
            if pendingKind == .raw || isRawStart(trimmed) {
                if pendingKind == .raw {
                    pendingLines.append(line)
                } else {
                    flush()
                    listIndents = []
                    pendingKind = .raw
                    pendingLines = [line]
                }
                return
            }

            if trimmed.hasPrefix(">") {
                var text = String(body.dropFirst())
                if text.hasPrefix(" ") { text.removeFirst() }
                if pendingKind == .quote {
                    pendingLines.append(text)
                } else {
                    flush()
                    listIndents = []
                    pendingKind = .quote
                    pendingLines = [text]
                }
                return
            }

            // Plain text: continues an open block (lazy continuation),
            // else starts a paragraph.
            if pendingKind != nil {
                pendingLines.append(body)
            } else {
                pendingKind = .paragraph
                pendingLines = [body]
            }
        }

        mutating func finish() {
            if let f = fence {
                // Unterminated fence: keep the body as code anyway.
                blocks.append(DocBlock(
                    kind: .code(lang: f.lang),
                    runs: [DocRun(text: f.lines.joined(separator: "\n"))]
                ))
                fence = nil
            }
            flush()
        }

        private mutating func flush() {
            guard let kind = pendingKind else { return }
            if kind == .raw {
                blocks.append(DocBlock(
                    kind: .raw, runs: [DocRun(text: pendingLines.joined(separator: "\n"))]
                ))
            } else {
                let text = joinLines(pendingLines)
                blocks.append(DocBlock(kind: kind, runs: parseInline(text)))
            }
            pendingKind = nil
            pendingLines = []
        }

        /// Soft-wrapped lines join with a space; a line ending in `\` or
        /// two spaces is a hard break.
        private func joinLines(_ lines: [String]) -> String {
            var out = ""
            for (i, raw) in lines.enumerated() {
                var line = raw
                var hard = false
                if line.hasSuffix("\\") {
                    line.removeLast()
                    hard = true
                } else if line.hasSuffix("  ") {
                    hard = true
                }
                line = line.trimmingCharacters(in: .whitespaces)
                out += line
                if i < lines.count - 1 {
                    out.append(hard ? MarkdownDocument.hardBreak : " ")
                }
            }
            return out
        }
    }

    private static func fenceOpen(_ t: String) -> (lang: String, marker: String)? {
        for ch in ["`", "~"] {
            let marker = String(repeating: ch, count: 3)
            guard t.hasPrefix(marker) else { continue }
            let rest = t.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if ch == "`", rest.contains("`") { return nil }
            let lang = rest.split(separator: " ").first.map(String.init) ?? ""
            return (lang, marker)
        }
        return nil
    }

    /// A table row or an HTML block opener.
    private static func isRawStart(_ t: String) -> Bool {
        if t.hasPrefix("|") { return true }
        guard t.hasPrefix("<"), t.count > 1 else { return false }
        let c = t[t.index(after: t.startIndex)]
        return c.isLetter || c == "!" || c == "/"
    }

    private static func setextLevel(_ t: String) -> Int? {
        guard t.count >= 1 else { return nil }
        if t.allSatisfy({ $0 == "=" }) { return 1 }
        if t.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func isRule(_ t: String) -> Bool {
        let compact = t.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first,
              "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func atxHeading(_ t: String) -> (Int, String)? {
        var level = 0
        var it = t.makeIterator()
        while let c = it.next(), c == "#" { level += 1 }
        guard (1...6).contains(level) else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes.
        while text.hasSuffix("#") { text.removeLast() }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    /// `(indent columns, ordered?, item text)` for a list-item line.
    private static func listItem(_ line: String) -> (Int, Bool, String)? {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            if line[idx] == " " { indent += 1 }
            else if line[idx] == "\t" { indent += 4 }
            else { break }
            idx = line.index(after: idx)
        }
        let rest = line[idx...]
        guard let first = rest.first else { return nil }
        if "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            return (indent, false, String(after.drop(while: { $0 == " " || $0 == "\t" })))
        }
        if first.isNumber {
            var digits = 0
            var j = rest.startIndex
            while j < rest.endIndex, rest[j].isNumber, digits < 9 {
                digits += 1
                j = rest.index(after: j)
            }
            guard j < rest.endIndex, rest[j] == "." || rest[j] == ")" else { return nil }
            let after = rest[rest.index(after: j)...]
            guard after.first == " " || after.first == "\t" else { return nil }
            return (indent, true, String(after.drop(while: { $0 == " " || $0 == "\t" })))
        }
        return nil
    }

    // MARK: - Inline

    static func parseInline(_ s: String) -> [DocRun] {
        var runs: [DocRun] = []
        let chars = Array(s)
        let n = chars.count
        var i = 0
        var buf = ""
        var style: DocInline = []

        func flush() {
            if !buf.isEmpty {
                runs.append(DocRun(text: buf, style: style))
                buf = ""
            }
        }
        func isSpace(_ k: Int) -> Bool {
            k < 0 || k >= n || chars[k].isWhitespace || chars[k] == hardBreak
        }
        func isWordChar(_ k: Int) -> Bool {
            k >= 0 && k < n && (chars[k].isLetter || chars[k].isNumber)
        }
        func find(_ delim: [Character], from: Int) -> Int? {
            var k = from
            while k + delim.count <= n {
                if Array(chars[k..<k + delim.count]) == delim { return k }
                k += 1
            }
            return nil
        }

        while i < n {
            let c = chars[i]

            if c == "\\", i + 1 < n, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                buf.append(chars[i + 1])
                i += 2
                continue
            }

            if c == "`" {
                var count = 0
                while i + count < n, chars[i + count] == "`" { count += 1 }
                let delim = Array(repeating: Character("`"), count: count)
                if let close = find(delim, from: i + count) {
                    var inner = String(chars[(i + count)..<close])
                    if inner.count >= 2, inner.hasPrefix(" "), inner.hasSuffix(" "),
                       !inner.allSatisfy({ $0 == " " }) {
                        inner = String(inner.dropFirst().dropLast())
                    }
                    flush()
                    runs.append(DocRun(text: inner, style: style.union(.code)))
                    i = close + count
                    continue
                }
                buf.append(contentsOf: String(delim))
                i += count
                continue
            }

            if c == "[", let link = parseLink(chars, at: i) {
                flush()
                for var run in parseInline(link.label) {
                    run.style.formUnion(style)
                    run.link = link.url
                    runs.append(run)
                }
                i = link.end
                continue
            }

            if c == "*" || c == "_" {
                let double = i + 1 < n && chars[i + 1] == c
                let len = double ? 2 : 1
                let flag: DocInline = double ? .bold : .italic
                let delim = Array(repeating: c, count: len)
                if style.contains(flag) {
                    // Closer: not preceded by whitespace; `_` also needs a
                    // word boundary after it (snake_case stays literal).
                    if !isSpace(i - 1), c == "*" || !isWordChar(i + len) {
                        flush()
                        style.remove(flag)
                        i += len
                        continue
                    }
                } else if !isSpace(i + len), find(delim, from: i + len) != nil,
                          c == "*" || !isWordChar(i - 1) {
                    flush()
                    style.insert(flag)
                    i += len
                    continue
                }
                buf.append(contentsOf: String(delim))
                i += len
                continue
            }

            if c == "~", i + 1 < n, chars[i + 1] == "~" {
                if style.contains(.strike) {
                    flush()
                    style.remove(.strike)
                    i += 2
                    continue
                } else if !isSpace(i + 2), find(["~", "~"], from: i + 2) != nil {
                    flush()
                    style.insert(.strike)
                    i += 2
                    continue
                }
            }

            buf.append(c)
            i += 1
        }
        flush()
        return mergeRuns(runs)
    }

    private static func parseLink(_ chars: [Character], at start: Int) -> (label: String, url: String, end: Int)? {
        var k = start + 1
        var depth = 1
        while k < chars.count {
            if chars[k] == "[" { depth += 1 }
            if chars[k] == "]" {
                depth -= 1
                if depth == 0 { break }
            }
            k += 1
        }
        guard k < chars.count, k + 1 < chars.count, chars[k + 1] == "(" else { return nil }
        let label = String(chars[(start + 1)..<k])
        var m = k + 2
        var paren = 1
        while m < chars.count {
            if chars[m] == "(" { paren += 1 }
            if chars[m] == ")" {
                paren -= 1
                if paren == 0 { break }
            }
            m += 1
        }
        guard m < chars.count else { return nil }
        var url = String(chars[(k + 2)..<m]).trimmingCharacters(in: .whitespaces)
        // Drop an optional "title" part.
        if let space = url.firstIndex(of: " ") { url = String(url[..<space]) }
        if url.hasPrefix("<"), url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
        return (label, url, m + 1)
    }

    static func mergeRuns(_ runs: [DocRun]) -> [DocRun] {
        var out: [DocRun] = []
        for run in runs where !run.text.isEmpty {
            if var last = out.last, last.style == run.style, last.link == run.link {
                last.text += run.text
                out[out.count - 1] = last
            } else {
                out.append(run)
            }
        }
        return out
    }

    // MARK: - Serialize

    static func serialize(_ blocks: [DocBlock]) -> String {
        var lines: [String] = []
        var counters: [Int] = []
        var prev: DocBlockKind?

        for block in blocks {
            // Tight lists: no blank line between items. Everything else
            // gets one.
            let tight = block.kind.isList && (prev?.isList ?? false)
            if prev != nil, !tight { lines.append("") }
            if !block.kind.isList { counters = [] }

            switch block.kind {
            case .paragraph:
                lines.append(inlineText(block.runs, continuation: ""))
            case let .heading(n):
                lines.append(String(repeating: "#", count: n) + " "
                    + inlineText(block.runs, continuation: ""))
            case let .bullet(depth):
                let indent = String(repeating: " ", count: depth * 2)
                counters = Array(counters.prefix(depth + 1))
                lines.append(indent + "- " + inlineText(block.runs, continuation: indent + "  "))
            case let .numbered(depth):
                let indent = String(repeating: " ", count: depth * 2)
                if counters.count > depth + 1 { counters = Array(counters.prefix(depth + 1)) }
                while counters.count < depth + 1 { counters.append(0) }
                if prev.map({ $0.isList && $0.listDepth == depth && !isNumbered($0) }) ?? true,
                   counters[depth] == 0 {
                    counters[depth] = 0
                }
                counters[depth] += 1
                let marker = "\(counters[depth]). "
                lines.append(indent + marker + inlineText(
                    block.runs, continuation: indent + String(repeating: " ", count: marker.count)
                ))
            case .quote:
                lines.append("> " + inlineText(block.runs, continuation: "> "))
            case let .code(lang):
                let body = block.plainText
                var fence = "```"
                while body.contains(fence) { fence += "`" }
                lines.append(fence + lang)
                lines.append(contentsOf: body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
                lines.append(fence)
            case .rule:
                lines.append("---")
            case .raw:
                lines.append(contentsOf: block.plainText
                    .split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
            }
            prev = block.kind
        }
        var out = lines.joined(separator: "\n")
        if !out.isEmpty { out += "\n" }
        return out
    }

    private static func isNumbered(_ kind: DocBlockKind) -> Bool {
        if case .numbered = kind { return true }
        return false
    }

    /// Inline runs back to markdown; hard breaks become `\` + newline +
    /// the block's continuation indent.
    static func inlineText(_ runs: [DocRun], continuation: String) -> String {
        var out = ""
        for run in mergeRuns(runs) {
            out += serializeRun(run)
        }
        if let first = out.first, startsLikeBlock(out) || first == " " {
            out = "\\" + out
        }
        return out.replacingOccurrences(of: String(hardBreak), with: "\\\n" + continuation)
    }

    private static func serializeRun(_ run: DocRun) -> String {
        var body: String
        if run.style.contains(.code) {
            var ticks = "`"
            while run.text.contains(ticks) { ticks += "`" }
            let pad = run.text.hasPrefix("`") || run.text.hasSuffix("`") ? " " : ""
            body = ticks + pad + run.text + pad + ticks
        } else {
            // Emphasis can't wrap whitespace: move edge spaces outside.
            let text = escape(run.text)
            let lead = text.prefix { $0 == " " }
            let core = text.dropFirst(lead.count)
            let trailCount = core.reversed().prefix { $0 == " " }.count
            let inner = String(core.dropLast(trailCount))
            let trail = String(core.suffix(trailCount))
            var wrapped = inner
            if !inner.isEmpty {
                if run.style.contains(.strike) { wrapped = "~~" + wrapped + "~~" }
                if run.style.contains(.bold) && run.style.contains(.italic) {
                    wrapped = "***" + wrapped + "***"
                } else if run.style.contains(.bold) {
                    wrapped = "**" + wrapped + "**"
                } else if run.style.contains(.italic) {
                    wrapped = "*" + wrapped + "*"
                }
            }
            body = String(lead) + wrapped + trail
        }
        if let link = run.link, !link.isEmpty {
            body = "[" + body + "](" + link + ")"
        }
        return body
    }

    /// Escapes the characters the inline parser would otherwise read as
    /// markup. `_` only at word boundaries — snake_case stays clean.
    private static func escape(_ s: String) -> String {
        var out = ""
        let chars = Array(s)
        for (k, c) in chars.enumerated() {
            switch c {
            case "*", "`", "[", "\\":
                out.append("\\")
                out.append(c)
            case "~" where k + 1 < chars.count && chars[k + 1] == "~":
                out.append("\\~")
            case "_":
                let prevWord = k > 0 && (chars[k - 1].isLetter || chars[k - 1].isNumber)
                let nextWord = k + 1 < chars.count && (chars[k + 1].isLetter || chars[k + 1].isNumber)
                if prevWord && nextWord { out.append(c) } else { out.append("\\_") }
            default:
                out.append(c)
            }
        }
        return out
    }

    /// Text that, at the start of a line, would parse as a block marker.
    private static func startsLikeBlock(_ s: String) -> Bool {
        let t = s
        if t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```") || t.hasPrefix("~~~") { return true }
        if isRule(t) || setextLevel(t) != nil { return true }
        return listItem(t) != nil
    }
}
