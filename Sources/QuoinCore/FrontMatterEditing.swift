import Foundation

// MARK: - Front-matter field editing (Properties inspector, #70)

/// Line-surgery readers and writers over the leading YAML front-matter
/// block — the Properties panel's engine. The panel is the EDITOR; the
/// in-document field grid stays the projection.
///
/// Reads are CRLF-tolerant (the walk is byte-level: Swift's `\r\n` is ONE
/// grapheme, so Character splits never split CRLF lines). Writes replace
/// only the target key's line(s) — every other line is byte-lossless.
/// Values are ONE-LINE scalars, escaped by the same quoted-scalar rules as
/// review endmatter; nested/complex values (block maps, lists, flow
/// collections, block scalars) are read-only (`isComplex`) because
/// rewriting them as scalars would silently change their YAML type.
///
/// Every writer self-calibrates: the candidate result must still parse as
/// front matter, read back the expected fields, and leave the document
/// BODY byte-identical — anything else refuses. Conservative rejections
/// are always safe.
public enum FrontMatterEditing {

    /// One top-level front-matter field, as the Properties panel sees it.
    public struct Field: Hashable, Sendable {
        public let key: String
        /// The parsed one-line scalar (quotes stripped, escapes resolved).
        /// Empty for complex fields — `rawPreview` carries their source.
        public let value: String
        /// The field's line(s) in the DOCUMENT — nested continuation lines
        /// and the trailing newline included; removal replaces exactly this.
        public let byteRange: ByteRange
        /// Nested / flow-collection / block-scalar value: shown read-only,
        /// and `setFieldEdit` refuses it.
        public let isComplex: Bool
        /// The raw source text after `key:` (continuation lines joined with
        /// newlines) — the panel's read-only preview for complex fields.
        public let rawPreview: String
    }

    // MARK: - Reading

    /// Every top-level field in the document's front matter, in file order.
    /// Empty when the document has no front-matter block.
    public static func fields(in source: String) -> [Field] {
        guard let block = block(in: source) else { return [] }
        let bytes = Array(source.utf8)
        let region = sourceLines(in: bytes).filter {
            $0.start >= block.fieldRegionStart && $0.start < block.closingLineStart
        }

        var result: [Field] = []
        var pending: PendingField?
        func flush() {
            if let field = pending { result.append(field.finished()) }
            pending = nil
        }
        for line in region {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let indented = line.text.first == " " || line.text.first == "\t"
            if trimmed.isEmpty {
                // A blank line separates fields; it belongs to none, so a
                // removal never swallows the air around its neighbors.
                flush()
                continue
            }
            if !indented, trimmed.hasPrefix("#") {
                // Top-level comments survive any adjacent field's removal.
                flush()
                continue
            }
            if !indented, let head = keyLine(trimmed) {
                flush()
                pending = PendingField(
                    key: head.key, rawValue: head.rawValue,
                    start: line.start, end: line.end)
                continue
            }
            // Continuation: an indented line, a top-level list item, or any
            // other unrecognized line rides with the field above it.
            if pending != nil {
                pending!.end = line.end
                pending!.continuations.append(trimmed)
            }
        }
        flush()
        return result
    }

    // MARK: - Writing

    /// Replaces an existing key's line, appends a new key before the
    /// closing `---`, or CREATES the whole front-matter block at byte 0
    /// when the document has none. Nil refuses: complex value under that
    /// key, an unsafe key, a duplicated key, or a candidate that fails
    /// self-calibration. The value is normalized to one physical line
    /// (newlines flatten to spaces, outer whitespace trimmed) — YAML
    /// scalars here are one-line by contract.
    public static func setFieldEdit(key: String, value: String, in source: String) -> SourceEdit? {
        guard isEditableKey(key) else { return nil }
        let normalized = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let line = "\(key): \(stringScalar(normalized))"
        guard let placed = placement(
            for: key, line: line, in: source, canReplace: { !$0.isComplex })
        else { return nil }
        return validated(placed.edit, in: source) { candidate in
            let after = fields(in: candidate)
            guard let written = after.first(where: { $0.key == key }),
                  written.value == normalized, !written.isComplex else { return false }
            return signatures(of: after.filter { $0.key != key }) == signatures(of: placed.others)
        }
    }

    /// Where a `key: value` line lands: replacing the key's existing
    /// line(s), appending before the closing `---`, or creating the whole
    /// block at byte 0. Nil refuses: a duplicated key is ambiguous (one
    /// contiguous edit can't fix both lines — refuse, don't shadow), and
    /// `canReplace` vetoes overwriting values the caller can't represent.
    private static func placement(
        for key: String, line: String, in source: String,
        canReplace: (Field) -> Bool
    ) -> (edit: SourceEdit, others: [Field])? {
        if let block = block(in: source) {
            let existing = fields(in: source)
            let matches = existing.filter { $0.key == key }
            let others = existing.filter { $0.key != key }
            if let field = matches.first {
                guard matches.count == 1, canReplace(field) else { return nil }
                return (SourceEdit(range: field.byteRange, replacement: line + block.newline),
                        others)
            }
            return (SourceEdit(
                range: ByteRange(offset: block.closingLineStart, length: 0),
                replacement: line + block.newline), others)
        }
        // No front matter: create the whole block at byte 0, in the
        // document's own newline flavor.
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        return (SourceEdit(
            range: ByteRange(offset: 0, length: 0),
            replacement: "---\(newline)\(line)\(newline)---\(newline)"), [])
    }

    /// Removes the key's line(s) — nested continuation lines included.
    /// Removing the LAST field removes the entire block (an empty
    /// `---\n---\n` chip is noise, and the grid renders nothing anyway).
    /// Nil refuses: key absent, key duplicated, or self-calibration failed.
    public static func removeFieldEdit(key: String, in source: String) -> SourceEdit? {
        guard let block = block(in: source) else { return nil }
        let existing = fields(in: source)
        let matches = existing.filter { $0.key == key }
        guard matches.count == 1, let field = matches.first else { return nil }
        let others = existing.filter { $0.key != key }

        if others.isEmpty, fieldRegionIsBlankOutside(field.byteRange, block: block, in: source) {
            // Last field, nothing else in the block: remove the block.
            let edit = SourceEdit(range: ByteRange(offset: 0, length: block.length), replacement: "")
            guard let (candidate, _) = try? edit.apply(to: source),
                  // The body must not get REINTERPRETED as front matter (a
                  // body that itself starts with `---\n…---` would silently
                  // promote its first section into metadata).
                  self.block(in: candidate) == nil,
                  candidate == bodySuffix(of: source, afterBlockLength: block.length)
            else { return nil }
            return edit
        }

        let edit = SourceEdit(range: field.byteRange, replacement: "")
        return validated(edit, in: source) { candidate in
            let after = fields(in: candidate)
            return !after.contains { $0.key == key }
                && signatures(of: after) == signatures(of: others)
        }
    }

    /// Keys the writers accept: the same shape the field grid renders as a
    /// key row (letters, digits, `_`, `-`) — anything else could smuggle
    /// structure (colons, quotes, leading `-`) into the key position.
    public static func isEditableKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    // MARK: - Block geometry (shared with MarkdownConverter via InlinePostPasses)

    /// The front-matter block's byte geometry. `yaml` is the CRLF-normalized
    /// text between the delimiters — the exact value `MarkdownConverter`
    /// stores in `.frontMatter(yaml:)`.
    struct DetectedBlock {
        let yaml: String
        /// Bytes `0..<length` are the whole block, closing line included.
        let length: Int
        /// Just past the opening `---` line: the field region's start.
        let fieldRegionStart: Int
        /// The closing delimiter line's first byte: the field region's end,
        /// and where a new field appends.
        let closingLineStart: Int
        /// The block's own line terminator, for lines the writers create.
        let newline: String
    }

    /// Byte-level front-matter detection: the source must OPEN with a bare
    /// `---` line and a later line must close with `---` or `…` (`...`).
    /// Unterminated front matter is ordinary content, exactly like the
    /// converter's rule.
    static func block(in source: String) -> DetectedBlock? {
        let bytes = Array(source.utf8)
        // Front matter must open with a bare `---` line at byte 0. The
        // overwhelmingly common no-front-matter document fails this in four
        // byte comparisons, so check it before building a whole-document line
        // table (see performance.md → Benchmarks). `----…` or `--- …` are not
        // an opening fence, matching the `opening.text == "---"` check below.
        guard bytes.count > 3, bytes[0] == 0x2D, bytes[1] == 0x2D, bytes[2] == 0x2D,
              bytes[3] == 0x0A || bytes[3] == 0x0D
        else { return nil }
        let lines = sourceLines(in: bytes)
        guard let opening = lines.first, opening.text == "---",
              // A bare `---` at EOF (no terminator) is a thematic break.
              opening.end > opening.start + 3
        else { return nil }
        let usesCRLF = bytes[opening.end - 2] == 0x0D
        for (index, line) in lines.enumerated().dropFirst() {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard trimmed == "---" || trimmed == "..." else { continue }
            let yaml = lines[1..<index].map(\.text).joined(separator: "\n")
            return DetectedBlock(
                yaml: yaml,
                length: line.end,
                fieldRegionStart: opening.end,
                closingLineStart: line.start,
                newline: usesCRLF ? "\r\n" : "\n")
        }
        return nil
    }

    // MARK: - Internals

    private struct PendingField {
        let key: String
        let rawValue: String
        let start: Int
        var end: Int
        var continuations: [String] = []

        func finished() -> Field {
            let hasContinuations = !continuations.isEmpty
            // Flow collections, block scalars, and YAML anchors/aliases are
            // not one-line scalars even on one line.
            let complexLead = rawValue.first.map { "[{|>&*".contains($0) } ?? false
            let isComplex = hasContinuations || complexLead
            let preview = ([rawValue] + continuations)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return Field(
                key: key,
                value: isComplex ? "" : unquoted(rawValue),
                byteRange: ByteRange(offset: start, length: end - start),
                isComplex: isComplex,
                rawPreview: preview)
        }
    }

    /// Splits a top-level `key: value` line, or nil when the line isn't a
    /// field (the same key shape the grid renderer recognizes).
    private static func keyLine(_ trimmed: String) -> (key: String, rawValue: String)? {
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[..<colon])
        guard isEditableKey(key) else { return nil }
        let rawValue = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return (key, rawValue)
    }

    /// One-line scalar readback: strips a matching pair of double quotes
    /// (resolving `\"`/`\\` in one left-to-right scan, the ReviewEndmatter
    /// rule) or single quotes (resolving `''`).
    private static func unquoted(_ raw: String) -> String {
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            var unescaped = ""
            var iterator = raw.dropFirst().dropLast().makeIterator()
            while let ch = iterator.next() {
                if ch == "\\", let next = iterator.next() {
                    unescaped.append(next)
                } else {
                    unescaped.append(ch)
                }
            }
            return unescaped
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    /// True when nothing but blank lines remains in the field region once
    /// `range` is taken out — the whole-block-removal precondition.
    private static func fieldRegionIsBlankOutside(
        _ range: ByteRange, block: DetectedBlock, in source: String
    ) -> Bool {
        let bytes = Array(source.utf8)
        return sourceLines(in: bytes)
            .filter { $0.start >= block.fieldRegionStart && $0.start < block.closingLineStart }
            .filter { $0.start < range.offset || $0.start >= range.upperBound }
            .allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The self-calibration gate shared by both writers: the candidate must
    /// still open with a parsable front-matter block, its BODY must be
    /// byte-identical to the original body, and the caller's field-level
    /// expectation must hold.
    private static func validated(
        _ edit: SourceEdit, in source: String, expecting check: (String) -> Bool
    ) -> SourceEdit? {
        guard let (candidate, _) = try? edit.apply(to: source) else { return nil }
        guard let newBlock = block(in: candidate) else { return nil }
        let oldBody = bodySuffix(of: source, afterBlockLength: block(in: source)?.length ?? 0)
        guard bodySuffix(of: candidate, afterBlockLength: newBlock.length) == oldBody else { return nil }
        guard check(candidate) else { return nil }
        return edit
    }

    private static func bodySuffix(of source: String, afterBlockLength length: Int) -> String {
        let bytes = Array(source.utf8)
        guard length <= bytes.count else { return "" }
        return String(decoding: bytes[length...], as: UTF8.self)
    }

    /// Comparable field identity for the untouched-fields check: byte
    /// ranges shift with any edit above them, so compare content only.
    private static func signatures(of fields: [Field]) -> [[String]] {
        fields.map { [$0.key, $0.value, $0.isComplex ? "complex" : "scalar", $0.rawPreview] }
    }

    // MARK: - Byte-level line walking

    private struct SourceLine {
        /// Content without its terminator; a trailing `\r` is stripped so
        /// CRLF and LF lines read identically.
        let text: String
        /// Byte offset of the line's first byte.
        let start: Int
        /// Byte offset just past the terminator (the next line's start, or EOF).
        let end: Int
    }

    private static func sourceLines(in bytes: [UInt8]) -> [SourceLine] {
        var lines: [SourceLine] = []
        var start = 0
        var i = 0
        while i <= bytes.count {
            if i == bytes.count || bytes[i] == 0x0A {
                guard start < bytes.count else { break }
                var contentEnd = i
                if contentEnd > start, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
                let end = i == bytes.count ? i : i + 1
                lines.append(SourceLine(
                    text: String(decoding: bytes[start..<contentEnd], as: UTF8.self),
                    start: start,
                    end: end))
                start = end
            }
            i += 1
        }
        return lines
    }
}

// MARK: - Typed values (Properties inspector, #79)

extension FrontMatterEditing {

    /// The type a value EDITS as. Inference is byte-conservative: a value
    /// that does not parse CLEANLY as a candidate type stays `.string`,
    /// and a quoted scalar is a deliberate YAML string — it never infers
    /// (a typed write-back would drop its quotes and change its type).
    public enum FieldType: Hashable, Sendable {
        case string
        case bool
        case number
        case date(DatePrecision)
        case list
    }

    /// The exact serialization shape of a date value — write-back must
    /// reproduce it: a date-only value never gains a time component, and
    /// a `Z`/offset suffix rides through verbatim.
    public struct DatePrecision: Hashable, Sendable {
        public let hasTime: Bool
        public let hasSeconds: Bool
        /// Trailing zone designator, verbatim: `""`, `"Z"`, `"+05:30"`.
        public let zoneSuffix: String

        public init(hasTime: Bool, hasSeconds: Bool, zoneSuffix: String) {
            self.hasTime = hasTime
            self.hasSeconds = hasSeconds
            self.zoneSuffix = zoneSuffix
        }
    }

    /// An ISO front-matter date, parsed to WALL-CLOCK components. The
    /// digits are edited as-is and the zone suffix is pass-through (never
    /// applied as an offset), so write-back touches only the digits the
    /// picker changed.
    public struct ParsedDate: Hashable, Sendable {
        public var year, month, day, hour, minute, second: Int
        public let precision: DatePrecision

        /// UTC calendar: the identity mapping between wall-clock
        /// components and `Date`, on every platform and locale.
        static var utcCalendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar
        }

        /// The components as a `Date` for a UTC-pinned picker; nil only
        /// for components no calendar day matches.
        public var dateValue: Date? {
            let components = DateComponents(
                year: year, month: month, day: day,
                hour: hour, minute: minute, second: second)
            return Self.utcCalendar.date(from: components)
        }

        /// The same precision and suffix around `date`'s UTC wall clock —
        /// how a picker change becomes a write-back value.
        public func replacingWallClock(_ date: Date) -> ParsedDate {
            let read = Self.utcCalendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date)
            var copy = self
            copy.year = read.year ?? year
            copy.month = read.month ?? month
            copy.day = read.day ?? day
            copy.hour = read.hour ?? hour
            copy.minute = read.minute ?? minute
            copy.second = read.second ?? second
            return copy
        }

        /// The value in its ORIGINAL precision: date-only stays date-only,
        /// seconds appear only if they were there, the suffix is verbatim.
        public var serialized: String {
            var out = String(format: "%04d-%02d-%02d", year, month, day)
            if precision.hasTime {
                out += String(format: "T%02d:%02d", hour, minute)
                if precision.hasSeconds { out += String(format: ":%02d", second) }
                out += precision.zoneSuffix
            }
            return out
        }
    }

    /// Strict ISO reader: `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM[:SS][Z|±HH:MM]`,
    /// calendar-validated (2026-02-30 refuses). Nil means not a date.
    public static func parseDate(_ raw: String) -> ParsedDate? {
        let chars = Array(raw)
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for i in range {
                guard chars[i].isASCII, let digit = chars[i].wholeNumberValue else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard chars.count >= 10,
              let year = number(0..<4), chars[4] == "-",
              let month = number(5..<7), chars[7] == "-",
              let day = number(8..<10) else { return nil }
        var hour = 0, minute = 0, second = 0
        var precision = DatePrecision(hasTime: false, hasSeconds: false, zoneSuffix: "")
        if chars.count > 10 {
            guard chars[10] == "T", chars.count >= 16,
                  let h = number(11..<13), chars[13] == ":",
                  let m = number(14..<16) else { return nil }
            hour = h
            minute = m
            var suffixStart = 16
            var hasSeconds = false
            if chars.count >= 19, chars[16] == ":" {
                guard let s = number(17..<19) else { return nil }
                second = s
                hasSeconds = true
                suffixStart = 19
            }
            let suffix = String(chars[suffixStart...])
            guard isZoneSuffix(suffix) else { return nil }
            precision = DatePrecision(hasTime: true, hasSeconds: hasSeconds, zoneSuffix: suffix)
        }
        let candidate = ParsedDate(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second, precision: precision)
        // Clean parse = the calendar round-trips the components untouched
        // (Feb 30 would normalize to Mar 2; hour 25 to the next day).
        guard let date = candidate.dateValue,
              candidate.replacingWallClock(date) == candidate else { return nil }
        return candidate
    }

    private static func isZoneSuffix(_ suffix: String) -> Bool {
        if suffix.isEmpty || suffix == "Z" { return true }
        let chars = Array(suffix)
        func isDigit(_ ch: Character) -> Bool { ch.isASCII && ch.isWholeNumber }
        return chars.count == 6 && (chars[0] == "+" || chars[0] == "-") && chars[3] == ":"
            && isDigit(chars[1]) && isDigit(chars[2]) && isDigit(chars[4]) && isDigit(chars[5])
    }

    /// Integer or decimal literal — the only shapes the number editor
    /// writes back verbatim. No exponents, no `+`, no bare `.`.
    private static func isNumberLiteral(_ raw: String) -> Bool {
        var digits = Substring(raw)
        if digits.first == "-" { digits = digits.dropFirst() }
        guard !digits.isEmpty else { return false }
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, !parts.contains(where: \.isEmpty) else { return false }
        return parts.allSatisfy { $0.allSatisfy { $0.isASCII && $0.isWholeNumber } }
    }

    /// The bytes to write for a value the user typed in a STRING field.
    /// A value whose bare form would infer as a non-string type
    /// (`true`, `123`, `2026-07-15`, `[a, b]`) is FORCE-QUOTED so it stays
    /// a string — the string editor must never silently change a field's
    /// YAML type (review MEDIUM: `setFieldEdit(key, "true")` wrote bare
    /// `true`, which read back as a bool and flipped the panel to a
    /// toggle). Ordinary strings pass through `fieldValue`'s bare/quoted
    /// rules unchanged.
    static func stringScalar(_ value: String) -> String {
        if !value.isEmpty, typedForm(of: value) != nil {
            return "\"\(ReviewEndmatter.escapedScalar(value))\""
        }
        return ReviewEndmatter.fieldValue(value)
    }

    /// The type `raw` parses CLEANLY as, or nil (= plain string). Bool is
    /// lowercase `true`/`false` ONLY — `True`/`yes` are strings.
    static func typedForm(of raw: String) -> FieldType? {
        if raw == "true" || raw == "false" { return .bool }
        if isNumberLiteral(raw) { return .number }
        if let date = parseDate(raw) { return .date(date.precision) }
        if raw.hasPrefix("["), flowListItems(raw) != nil { return .list }
        return nil
    }

    /// True when `raw` is a machine-writable typed form — the only values
    /// `setTypedFieldEdit` writes verbatim.
    public static func isTypedRawValue(_ raw: String) -> Bool {
        typedForm(of: raw) != nil
    }

    /// Keys whose NAME hints a type. A hint refines ambiguity only when
    /// the value also parses cleanly for that type — it never coerces
    /// (`draft: yes` and `date: tomorrow` stay plain strings). Clean
    /// dates/bools/lists are already claimed by generic inference, so the
    /// hints' residual effect is the EMPTY value under a list key: it
    /// edits as an empty CSV list, where an empty date or bool editor
    /// would have to fabricate a value the file doesn't contain.
    private static let dateHintKeys: Set<String> = ["date", "created", "updated", "modified"]
    private static let boolHintKeys: Set<String> = ["draft", "published", "archived"]
    private static let listHintKeys: Set<String> = ["tags", "aliases", "categories"]

    /// The editor a field gets. `rawValue` is the RAW source text after
    /// `key:` (`Field.rawPreview`) — inference must see quoting and flow
    /// punctuation, not the resolved scalar.
    public static func inferredType(key: String, rawValue: String) -> FieldType {
        let raw = rawValue.trimmingCharacters(in: .whitespaces)
        if let typed = typedForm(of: raw) { return typed }
        let lowered = key.lowercased()
        if raw.isEmpty, listHintKeys.contains(lowered) { return .list }
        if dateHintKeys.contains(lowered), let date = parseDate(raw) { return .date(date.precision) }
        if boolHintKeys.contains(lowered), raw == "true" || raw == "false" { return .bool }
        return .string
    }

    // MARK: Flow lists ⇄ CSV

    /// Splits a one-line flow sequence into its items, quotes resolved.
    /// Nil REFUSES the list editor: nested collections, unterminated or
    /// partial quotes, empty items, YAML-meaningful bare punctuation, or
    /// a quoted item containing a comma (CSV could never round-trip it)
    /// all fall back to `.string`.
    public static func flowListItems(_ raw: String) -> [String]? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains("\n"), trimmed.hasPrefix("["), trimmed.hasSuffix("]"),
              trimmed.count >= 2 else { return nil }
        let body = Array(trimmed.dropFirst().dropLast())
        if body.allSatisfy({ $0 == " " }) { return [] }

        var parts: [[Character]] = []
        var current: [Character] = []
        var quote: Character?
        var index = 0
        while index < body.count {
            let ch = body[index]
            if let q = quote {
                current.append(ch)
                if q == "\"", ch == "\\", index + 1 < body.count {
                    current.append(body[index + 1])
                    index += 2
                    continue
                }
                if ch == q {
                    if q == "'", index + 1 < body.count, body[index + 1] == "'" {
                        current.append("'")
                        index += 2
                        continue
                    }
                    quote = nil
                }
                index += 1
                continue
            }
            switch ch {
            case "\"", "'":
                quote = ch
                current.append(ch)
            case "[", "]", "{", "}":
                return nil
            case ",":
                parts.append(current)
                current = []
            default:
                current.append(ch)
            }
            index += 1
        }
        guard quote == nil else { return nil }
        parts.append(current)

        var items: [String] = []
        for part in parts {
            let item = String(part).trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return nil }
            if item.hasPrefix("\"") || item.hasPrefix("'") {
                // A quoted EMPTY item (`""`) reads as valid but the CSV
                // round-trip drops it (csvItems splits on ", " and discards
                // empty components) — so `["", "a"]` would silently become
                // `[a]` after any panel edit. Refuse the list editor, same
                // as a bare empty item (review LOW).
                guard let content = quotedItemContent(item),
                      !content.contains(","), !content.isEmpty
                else { return nil }
                items.append(content)
            } else {
                guard isBareFlowItem(item) else { return nil }
                items.append(item)
            }
        }
        return items
    }

    /// The CSV projection the panel's list editor shows.
    public static func csv(fromItems items: [String]) -> String {
        items.joined(separator: ", ")
    }

    /// The CSV draft back into items: split on commas, trim, drop empties
    /// (a trailing comma is not an empty tag).
    public static func csvItems(_ csv: String) -> [String] {
        csv.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Flow-form write-back: bare-safe items stay bare, anything else is
    /// double-quoted + escaped so the result still parses as a flow list.
    public static func flowList(fromItems items: [String]) -> String {
        let rendered = items.map { item in
            isBareFlowItem(item) && item == item.trimmingCharacters(in: .whitespaces)
                ? item
                : "\"\(ReviewEndmatter.escapedScalar(item))\""
        }
        return "[" + rendered.joined(separator: ", ") + "]"
    }

    /// Bare (unquoted) flow items keep to inert scalar characters — a
    /// colon, comma, comment sign, or flow/indicator punctuation would
    /// change YAML meaning. The same predicate gates read acceptance and
    /// write-back quoting, so the two stay symmetric.
    private static func isBareFlowItem(_ item: String) -> Bool {
        guard !item.isEmpty else { return false }
        let forbidden: Set<Character> = [
            ":", ",", "#", "&", "*", "!", "|", ">", "@", "`", "%", "?",
            "\"", "'", "[", "]", "{", "}",
        ]
        return !item.contains { forbidden.contains($0) }
    }

    /// The unescaped content of a FULLY quoted item — the closing quote
    /// must be the very last character (`"a"b` shapes refuse).
    private static func quotedItemContent(_ item: String) -> String? {
        let chars = Array(item)
        guard chars.count >= 2, let q = chars.first, q == "\"" || q == "'",
              chars.last == q else { return nil }
        var content = ""
        var index = 1
        while index < chars.count - 1 {
            let ch = chars[index]
            if q == "\"", ch == "\\", index + 1 < chars.count - 1 {
                content.append(chars[index + 1])
                index += 2
                continue
            }
            if ch == q {
                if q == "'", index + 1 < chars.count - 1, chars[index + 1] == "'" {
                    content.append("'")
                    index += 2
                    continue
                }
                return nil
            }
            content.append(ch)
            index += 1
        }
        return content
    }

    // MARK: Typed writer

    /// Sets one field to a TYPED raw value written VERBATIM — the typed
    /// editors' writer. Only machine-writable forms pass (`true`/`false`,
    /// number literals, strict ISO dates, clean flow lists): a datetime
    /// keeps its bare `:`s where the scalar writer would quote them, and
    /// a flow list stays a flow list where it would refuse. Replacing an
    /// existing field requires a simple scalar or a clean one-line flow
    /// list — block collections stay read-only. Same self-calibration as
    /// `setFieldEdit`; nil refuses.
    public static func setTypedFieldEdit(
        key: String, rawValue: String, in source: String
    ) -> SourceEdit? {
        guard isEditableKey(key) else { return nil }
        let raw = rawValue.trimmingCharacters(in: .whitespaces)
        guard isTypedRawValue(raw) else { return nil }
        let line = "\(key): \(raw)"
        guard let placed = placement(for: key, line: line, in: source, canReplace: {
            !$0.isComplex || flowListItems($0.rawPreview) != nil
        }) else { return nil }
        return validated(placed.edit, in: source) { candidate in
            let after = fields(in: candidate)
            guard let written = after.first(where: { $0.key == key }) else { return false }
            // Flow lists read back complex (rawPreview carries the source);
            // typed scalars are quote-free, so value == raw is identity.
            let readsBack = written.isComplex
                ? written.rawPreview == raw && flowListItems(raw) != nil
                : written.value == raw
            return readsBack
                && signatures(of: after.filter { $0.key != key }) == signatures(of: placed.others)
        }
    }
}
