import Foundation

// MARK: - RDFM review endmatter (suggestions design §2, S2)

/// Metadata for one comment or suggestion, keyed by its `{#id}` reference.
public struct ReviewEntry: Hashable, Sendable {
    /// Author label; the literal `AI` marks agent authorship (RDFM).
    public var by: String?
    /// ISO-8601 timestamp, kept as its source string (rendering decides
    /// how much precision to show).
    public var at: String?
    /// Parent id — a threaded reply (reply bodies live entirely in
    /// endmatter; root bodies stay inline for anchor portability).
    public var re: String?
    /// `resolved` when the thread is closed.
    public var status: String?
    /// Resolution summary, when present.
    public var resolved: String?
    /// Endmatter-only body (replies and document-level comments).
    public var body: String?
}

public struct ReviewMetadata: Hashable, Sendable {
    public var comments: [String: ReviewEntry]
    public var suggestions: [String: ReviewEntry]

    public var isEmpty: Bool { comments.isEmpty && suggestions.isEmpty }

    public func entry(for id: String) -> ReviewEntry? {
        comments[id] ?? suggestions[id]
    }
}

/// Detects and parses the RDFM YAML endmatter: the LAST `\n---\n` in the
/// document whose tail parses as a `comments:`/`suggestions:` map — and only
/// when the body actually references it (`{#` somewhere before it) or it
/// carries a document-level comment. That ambiguity heuristic (from the RDFM
/// reference implementation) protects ordinary documents that merely end
/// with a thematic break. The YAML subset is deliberately tiny — two-level
/// maps with scalar string values, double-quoted or bare — parsed by hand
/// (the one-dependency policy; front matter set the precedent of carrying
/// raw YAML).
public enum ReviewEndmatter {

    public struct Detected: Sendable {
        /// Byte range of the endmatter INCLUDING its leading `\n---\n`
        /// delimiter — the body ends where this starts.
        public let range: ByteRange
        public let yaml: String
        public let metadata: ReviewMetadata
        /// The line ending this endmatter block uses in the source
        /// (`\r\n` for CRLF documents, else `\n`). The writers do line
        /// surgery in normalized LF then re-apply THIS on emit, so a
        /// resolution never downgrades an untouched CRLF sibling entry or
        /// the delimiter to LF (byte-lossless-for-untouched, panel review
        /// BLOCKER).
        public let lineEnding: String

        public init(range: ByteRange, yaml: String, metadata: ReviewMetadata,
                    lineEnding: String = "\n") {
            self.range = range
            self.yaml = yaml
            self.metadata = metadata
            self.lineEnding = lineEnding
        }
    }

    public static func detect(in source: String) -> Detected? {
        // Cheap byte-level guard: the grapheme-aware backwards String
        // searches below cost tens of ms on a large document even when no
        // delimiter exists. The `---` fences have exactly one UTF-8 encoding,
        // so a byte scan decides "no endmatter possible" identically and far
        // faster; only a document that actually contains a fence pays for the
        // precise search (see ByteScan / performance.md).
        guard source.utf8Contains([0x0A, 0x2D, 0x2D, 0x2D, 0x0A])
           || source.utf8Contains([0x0D, 0x0A, 0x2D, 0x2D, 0x2D, 0x0D, 0x0A])
        else { return nil }
        // CRLF documents delimit with \r\n---\r\n — a pure-LF search never
        // matched, so their endmatter rendered as prose and every
        // resolution stacked a fresh LF endmatter on top (panel review,
        // MEDIUM). Prefer whichever delimiter occurs LAST in mixed files.
        let lf = source.range(of: "\n---\n", options: .backwards)
        let crlf = source.range(of: "\r\n---\r\n", options: .backwards)
        let delimiterRange: Range<String.Index>
        switch (lf, crlf) {
        case (nil, nil): return nil
        case (let l?, nil): delimiterRange = l
        case (nil, let c?): delimiterRange = c
        case (let l?, let c?):
            delimiterRange = l.lowerBound > c.lowerBound ? l : c
        }
        let tail = String(source[delimiterRange.upperBound...])
        guard let metadata = parse(yaml: tail), !metadata.isEmpty else { return nil }
        let body = String(source[..<delimiterRange.lowerBound])
        // Referenced from the body, carrying a document-level comment
        // (an entry with a body and no parent), or holding RESOLUTION
        // RECORDS (status: resolved) — Quoin's history extension: once the
        // last inline {#id} resolves, the records must keep the endmatter
        // recognized or they'd leak into prose.
        let documentLevel = metadata.comments.values.contains { $0.body != nil && $0.re == nil }
        let hasRecords = metadata.comments.values.contains { $0.status == "resolved" }
            || metadata.suggestions.values.contains { $0.status == "resolved" }
        guard body.contains("{#") || documentLevel || hasRecords else { return nil }
        // The delimiter lower bound is a `\n`, always on a UTF-8 boundary,
        // but detection is nil-tolerant — guard rather than force-unwrap.
        guard let utf8Lower = delimiterRange.lowerBound.samePosition(in: source.utf8) else { return nil }
        let offset = source.utf8.distance(from: source.utf8.startIndex, to: utf8Lower)
        let lineEnding = (crlf.map { delimiterRange == $0 } ?? false) ? "\r\n" : "\n"
        return Detected(
            range: ByteRange(offset: offset, length: source.utf8.count - offset),
            yaml: tail,
            metadata: metadata,
            lineEnding: lineEnding)
    }

    /// Re-applies an endmatter's original line ending to an LF-built
    /// replacement (no-op for LF documents). The writers build in
    /// normalized LF; this is the last step before emitting the SourceEdit.
    static func applyLineEnding(_ replacement: String, _ ending: String) -> String {
        ending == "\n" ? replacement : replacement.replacingOccurrences(of: "\n", with: ending)
    }

    /// Parses the RDFM endmatter YAML subset:
    ///
    /// ```yaml
    /// comments:
    ///   c1: { by: user, at: "2026-04-28T12:00:00Z" }
    ///   c2:
    ///     body: "I can add one."
    ///     by: AI
    ///     re: c1
    /// suggestions:
    ///   s1: { by: AI }
    /// ```
    ///
    /// Returns nil unless at least one `comments:`/`suggestions:` section
    /// exists — the caller's ordinary-`---` disambiguator.
    public static func parse(yaml: String) -> ReviewMetadata? {
        var comments: [String: ReviewEntry] = [:]
        var suggestions: [String: ReviewEntry] = [:]
        var section: String?      // "comments" | "suggestions"
        var currentID: String?
        var sawSection = false

        func assign(_ entry: ReviewEntry, id: String) {
            if section == "comments" { comments[id] = entry }
            else if section == "suggestions" { suggestions[id] = entry }
        }
        func current() -> ReviewEntry? {
            guard let id = currentID else { return nil }
            return section == "comments" ? comments[id] : suggestions[id]
        }

        // CRLF tolerance: Swift's "\r\n" is ONE grapheme cluster, so a
        // Character-based split on "\n" never splits CRLF lines at all —
        // the whole yaml read as one line and the strict rule nil'd it.
        let normalized = yaml.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() } // stray lone \r
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count

            if indent == 0 {
                currentID = nil
                if trimmed == "comments:" { section = "comments"; sawSection = true }
                else if trimmed == "suggestions:" { section = "suggestions"; sawSection = true }
                else {
                    // STRICT: review endmatter contains ONLY the review
                    // sections. Any other top-level line (prose, a closing
                    // code fence, front-matter keys) means this `---` is not
                    // endmatter — being lenient here made a fenced spec
                    // EXAMPLE parse as real endmatter and truncate the fence
                    // (caught by RDFMConformanceTests' spec golden).
                    return nil
                }
                continue
            }
            guard section != nil else { continue }

            if indent == 2, let colon = trimmed.firstIndex(of: ":") {
                let id = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                guard !id.isEmpty, !id.contains(" ") else { return nil }
                var entry = ReviewEntry()
                let rest = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix("{"), rest.hasSuffix("}") {
                    // Flow form: { by: user, at: "…" }
                    let inner = String(rest.dropFirst().dropLast())
                    for pair in splitFlowPairs(inner) {
                        guard let (key, value) = keyValue(pair) else { return nil }
                        set(&entry, key: key, value: value)
                    }
                } else if !rest.isEmpty {
                    return nil // an id line carries either a flow map or nothing
                }
                currentID = id
                assign(entry, id: id)
                continue
            }

            if indent >= 4, currentID != nil {
                guard let (key, value) = keyValue(trimmed), var entry = current() else { return nil }
                set(&entry, key: key, value: value)
                assign(entry, id: currentID!)
                continue
            }
            return nil // anything else isn't our subset
        }
        guard sawSection else { return nil }
        return ReviewMetadata(comments: comments, suggestions: suggestions)
    }

    private static func set(_ entry: inout ReviewEntry, key: String, value: String) {
        switch key {
        case "by": entry.by = value
        case "at": entry.at = value
        case "re": entry.re = value
        case "status": entry.status = value
        case "resolved": entry.resolved = value
        case "body": entry.body = value
        default: break // unknown keys are preserved in the raw yaml, ignored here
        }
    }

    private static func keyValue(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        var value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            // Single left-to-right unescape: the two-pass replacing version
            // mangled `\\\"` sequences (unescape a backslash, then treat the
            // freed quote as escaped).
            var unescaped = ""
            var iterator = value.dropFirst().dropLast().makeIterator()
            while let ch = iterator.next() {
                if ch == "\\", let next = iterator.next() {
                    unescaped.append(next)
                } else {
                    unescaped.append(ch)
                }
            }
            value = unescaped
        }
        return (key, value)
    }

    /// Splits `by: user, at: "a, b"` on commas OUTSIDE quotes. Escapes are
    /// consumed as two-character units in one scan — the previous-character
    /// check treated the closing quote after `"C:\\"` as escaped and
    /// swallowed the next field (panel review).
    private static func splitFlowPairs(_ text: String) -> [String] {
        var pairs: [String] = []
        var current = ""
        var inQuotes = false
        var chars = text.makeIterator()
        while let ch = chars.next() {
            if inQuotes, ch == "\\", let escaped = chars.next() {
                current.append(ch)
                current.append(escaped)
                continue
            }
            if ch == "\"" { inQuotes.toggle() }
            if ch == ",", !inQuotes {
                pairs.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { pairs.append(current) }
        return pairs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Maintenance on resolution (suggestions S2, redlined 2026-07-14)

extension ReviewEndmatter {

    /// The endmatter's counterpart edit when the mark with `id` resolves:
    /// removes that entry AND its reply thread (entries whose `re` points
    /// into the removed set, transitively); when nothing remains, removes
    /// the ENTIRE endmatter block — otherwise the detection heuristic
    /// rightly stops firing once the last `{#id}` leaves the body, and the
    /// orphaned YAML leaks into the prose as a paragraph (the live bug:
    /// dismissing the only comment turned the endmatter into visible YAML
    /// soup). Remaining entries keep their original lines byte-exactly.
    public static func maintenanceEdit(afterResolving id: String, in source: String) -> SourceEdit? {
        guard let detected = detect(in: source) else { return nil }
        guard detected.metadata.entry(for: id) != nil else { return nil }

        // Transitive removal set over `re` links.
        var removed: Set<String> = [id]
        var grew = true
        while grew {
            grew = false
            for (entryID, entry) in detected.metadata.comments where !removed.contains(entryID) {
                if let re = entry.re, removed.contains(re) { removed.insert(entryID); grew = true }
            }
            for (entryID, entry) in detected.metadata.suggestions where !removed.contains(entryID) {
                if let re = entry.re, removed.contains(re) { removed.insert(entryID); grew = true }
            }
        }

        let remainingCount = (detected.metadata.comments.count + detected.metadata.suggestions.count)
            - removed.count
        if remainingCount <= 0 {
            return SourceEdit(range: detected.range, replacement: "")
        }

        // Line surgery: keep every line except removed entries' blocks and
        // section headers whose entries are all gone.
        var keptLines: [String] = []
        var pendingHeader: String?
        var skippingEntry = false
        let normalizedYAML = detected.yaml.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalizedYAML.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() } // CRLF tolerance
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                skippingEntry = false
                if trimmed == "comments:" || trimmed == "suggestions:" {
                    pendingHeader = line // emit only if it gains an entry
                } else {
                    if trimmed.isEmpty { keptLines.append(line) }
                }
                continue
            }
            if indent == 2, let colon = trimmed.firstIndex(of: ":") {
                let entryID = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                skippingEntry = removed.contains(entryID)
                if !skippingEntry {
                    if let header = pendingHeader { keptLines.append(header); pendingHeader = nil }
                    keptLines.append(line)
                }
                continue
            }
            if !skippingEntry {
                keptLines.append(line)
            }
        }
        var replacement = "\n---\n" + keptLines.joined(separator: "\n")
        if !replacement.hasSuffix("\n") { replacement += "\n" }
        return SourceEdit(
            range: detected.range,
            replacement: applyLineEnding(replacement, detected.lineEnding))
    }
}

// MARK: - Resolution records (history — suggestions S2, 2026-07-14 ask)

/// A resolved review item, read back from endmatter entries carrying
/// `status: resolved` — the RDFM-native history: resolutions live in the
/// file, portable and agent-readable, instead of vanishing.
public struct ResolvedRecord: Hashable, Sendable {
    public let id: String
    public let by: String?
    public let at: String?
    /// The `resolved:` summary Quoin writes: "accepted · <text>",
    /// "rejected · <old> → <new>", "dismissed · <comment>".
    public let summary: String
}

extension ReviewEndmatter {

    /// Every resolved entry in the document's metadata, newest last. A
    /// record whose mark is STILL IN THE BODY isn't history yet (an undo
    /// restored the mark; the mark wins) — it's excluded until the mark
    /// resolves again.
    public static func resolvedRecords(in document: QuoinDocument) -> [ResolvedRecord] {
        guard let metadata = document.reviewMetadata else { return [] }
        let liveIDs = Set(SuggestionResolver.marks(in: document).compactMap(\.id))
        // BOTH maps, independently: merging dropped the suggestion-side
        // record whenever an id collided across sections (panel review).
        let all = Array(metadata.comments) + Array(metadata.suggestions)
        return all
            .filter { $0.value.status == "resolved" && !liveIDs.contains($0.key) }
            .map { ResolvedRecord(
                id: $0.key, by: $0.value.by, at: $0.value.at,
                summary: $0.value.resolved ?? "resolved") }
            .sorted { ($0.at ?? $0.id) < ($1.at ?? $1.id) }
    }

    /// The endmatter edit that RECORDS a resolution instead of deleting the
    /// entry (the "things that have been acted on just disappear" redline):
    /// the entry keeps its author/time and gains `status: resolved` +
    /// `resolved: <summary>`. Reply threads stay — they're part of the
    /// record. Other entries keep their lines byte-exactly. Returns nil when
    /// the id has no entry (an un-referenced mark resolves unrecorded).
    public static func resolutionRecordEdit(
        resolving id: String, summary: String, in source: String
    ) -> SourceEdit? {
        guard let detected = detect(in: source),
              detected.metadata.entry(for: id) != nil else { return nil }

        var keptLines: [String] = []
        var inTargetEntry = false
        var wroteRecord = false
        func emitRecord(indentOnly: Bool = false) {
            guard inTargetEntry, !wroteRecord else { return }
            keptLines.append("    status: resolved")
            keptLines.append("    resolved: \"\(escapedScalar(summary))\"")
            wroteRecord = true
            inTargetEntry = false
        }
        // CRLF tolerance: Swift's "\r\n" is one grapheme, so an unnormalized
        // split never splits CRLF lines (same rule as parse()).
        let normalizedYAML = detected.yaml.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalizedYAML.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                emitRecord()
                keptLines.append(line)
                continue
            }
            if indent == 2, let colon = trimmed.firstIndex(of: ":") {
                emitRecord() // leaving the previous entry
                let entryID = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                if entryID == id {
                    inTargetEntry = true
                    // Normalize a flow-form entry to block form so the
                    // record fields can append beneath it.
                    let rest = String(trimmed[trimmed.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("{"), rest.hasSuffix("}") {
                        keptLines.append("  \(entryID):")
                        let inner = String(rest.dropFirst().dropLast())
                        for pair in splitFlowPairs(inner) {
                            // Same stale-field rule as the block form below,
                            // or a re-resolution writes duplicate keys.
                            if pair.hasPrefix("status:") || pair.hasPrefix("resolved:") { continue }
                            keptLines.append("    \(pair)")
                        }
                    } else {
                        keptLines.append(line)
                    }
                    continue
                }
            }
            if inTargetEntry, indent >= 4 {
                // Existing block-form fields of the target entry: keep,
                // but drop any stale status/resolved (re-resolution).
                if trimmed.hasPrefix("status:") || trimmed.hasPrefix("resolved:") { continue }
                keptLines.append(line)
                continue
            }
            keptLines.append(line)
        }
        emitRecord()
        var replacement = "\n---\n" + keptLines.joined(separator: "\n")
        if !replacement.hasSuffix("\n") { replacement += "\n" }
        return SourceEdit(
            range: detected.range,
            replacement: applyLineEnding(replacement, detected.lineEnding))
    }
}

extension ReviewEndmatter {

    /// Records a resolution for a mark that had NO `{#id}`: synthesizes the
    /// next document-local id (c1…/s1… counters, RDFM style) and appends
    /// the entry — creating the endmatter itself when the document has
    /// none. History must not depend on the author having used metadata.
    public static func appendedRecordEdit(
        summary: String, asComment: Bool, in source: String
    ) -> SourceEdit? {
        appendedRecordEdit(summary: summary, asComment: asComment, reusing: nil, in: source)
    }

    /// Same, but `reusing` keeps the mark's OWN `{#id}` as the record key —
    /// a mark can carry an id its endmatter never declared (agent wrote the
    /// ref but not the entry, or the entry was hand-deleted); resolving it
    /// silently skipped history (panel review, MEDIUM: contradicts the
    /// "EVERY resolution is recorded" rule).
    public static func appendedRecordEdit(
        summary: String, asComment: Bool, reusing existingID: String?, in source: String
    ) -> SourceEdit? {
        appendedEntryEdit(
            fieldLines: ["status: resolved", "resolved: \"\(escapedScalar(summary))\""],
            asComment: asComment, reusing: existingID, in: source)?.edit
    }

    /// The next free `c…`/`s…` id: collision-checked against BOTH maps and
    /// every inline `{#…}` reference.
    static func allocateID(asComment: Bool, in source: String) -> String {
        let prefix = asComment ? "c" : "s"
        let taken: Set<String>
        if let detected = detect(in: source) {
            taken = Set(detected.metadata.comments.keys)
                .union(detected.metadata.suggestions.keys)
        } else {
            taken = []
        }
        var n = 1
        while taken.contains("\(prefix)\(n)") || source.contains("{#\(prefix)\(n)}") { n += 1 }
        return "\(prefix)\(n)"
    }

    /// The shared entry appender: writes a block-form entry with the given
    /// indent-4 field lines (already escaped) under the section, creating
    /// the endmatter at EOF when the document has none. Resolution records
    /// and CREATED annotations (S3a: `by:`/`at:`, no `status:`) both ride
    /// this one writer.
    static func appendedEntryEdit(
        fieldLines: [String], asComment: Bool, reusing existingID: String?, in source: String
    ) -> (edit: SourceEdit, id: String)? {
        let section = asComment ? "comments" : "suggestions"
        let id = existingID ?? allocateID(asComment: asComment, in: source)
        let entry = "  \(id):\n" + fieldLines.map { "    \($0)\n" }.joined()

        if let detected = detect(in: source) {
            // Normalized for the same CRLF-grapheme reason as parse().
            var yaml = detected.yaml.replacingOccurrences(of: "\r\n", with: "\n")
            // LINE-anchored section header: a bare substring search could
            // match an indent-4 `suggestions:` field inside some entry and
            // reparent that entry's fields onto the new record.
            let headerLine = "\(section):\n"
            let sectionRange: Range<String.Index>?
            if yaml.hasPrefix(headerLine) {
                sectionRange = yaml.startIndex..<yaml.index(yaml.startIndex, offsetBy: headerLine.count)
            } else {
                sectionRange = yaml.range(of: "\n" + headerLine)
                    .map { yaml.index(after: $0.lowerBound)..<$0.upperBound }
            }
            if let sectionRange {
                yaml.insert(contentsOf: entry, at: sectionRange.upperBound)
            } else {
                if !yaml.hasSuffix("\n") { yaml += "\n" }
                yaml += "\(section):\n" + entry
            }
            return (SourceEdit(
                range: detected.range,
                replacement: applyLineEnding("\n---\n" + yaml, detected.lineEnding)), id)
        }

        // No endmatter yet: create one at EOF. Match the document's line
        // ending so a CRLF file doesn't gain an LF endmatter block. The
        // leading `\n---\n` is REQUIRED — detect() finds the endmatter by
        // its `\n---\n` delimiter, so even an empty document keeps it (the
        // blank line is structural, not spurious).
        let ending = source.contains("\r\n") ? "\r\n" : "\n"
        let needsNewline = source.hasSuffix("\n") ? "" : "\n"
        let block = applyLineEnding(
            "\(needsNewline)\n---\n\(section):\n" + entry, ending)
        return (SourceEdit(
            range: ByteRange(offset: source.utf8.count, length: 0),
            replacement: block), id)
    }

    /// A bare YAML scalar is safe for simple values; anything else gets
    /// quoted + escaped.
    static func fieldValue(_ value: String) -> String {
        let bareSafe = value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" || $0 == "."
        }
        return bareSafe && !value.isEmpty && !value.contains("  ")
            ? value : "\"\(escapedScalar(value))\""
    }
}


extension ReviewEndmatter {
    /// One double-quoted YAML scalar on ONE physical line: backslash and
    /// quote escaped, any line break flattened to a space. A raw newline
    /// here split the scalar across lines and the strict parser rejected
    /// the whole endmatter (panel review, HIGH) — summaries are pre-
    /// flattened at construction, this is the writers' backstop.
    static func escapedScalar(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
    }
}
