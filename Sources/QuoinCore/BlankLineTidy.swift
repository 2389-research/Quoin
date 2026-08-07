/// Explicit, undoable blank-line cleanup (Format ▸ Tidy Blank Lines). NEVER
/// automatic: Quoin is byte-lossless, so a save must not move the user's text.
/// Runs of 2+ blank lines collapse to one, OUTSIDE fenced code — blank lines
/// inside a fence are content, not spacing.
public enum BlankLineTidy {

    public static func tidied(_ source: String) -> String {
        var out = ""
        var inFence = false
        var pendingBlanks: [String] = []
        for line in physicalLines(of: source) {
            // Strip the terminator at the scalar level. `\r\n` is ONE grapheme
            // cluster (CLAUDE.md pitfall), so `dropLast` on Characters would
            // eat real content — walk unicodeScalars instead.
            var body = line
            if body.unicodeScalars.last == "\n" { body.unicodeScalars.removeLast() }
            if body.unicodeScalars.last == "\r" { body.unicodeScalars.removeLast() }
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, trimmed.isEmpty {
                pendingBlanks.append(line)      // hold; emit at most one
                continue
            }
            if let first = pendingBlanks.first { out += first }
            pendingBlanks.removeAll()
            out += line
        }
        if let first = pendingBlanks.first { out += first }
        return out
    }

    /// Lines WITH their terminators, split on \n but keeping \r\n intact.
    private static func physicalLines(of source: String) -> [String] {
        var lines: [String] = []
        var current = ""
        for scalar in source.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if scalar == "\n" { lines.append(current); current = "" }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
