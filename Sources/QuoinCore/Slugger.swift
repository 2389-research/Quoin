import Foundation

/// Generates GitHub-style heading anchors: lowercase, alphanumerics and
/// hyphens kept, spaces become hyphens, duplicates get -1, -2… suffixes.
struct Slugger {
    private var seen: [String: Int] = [:]

    mutating func slug(for title: String) -> String {
        var base = ""
        for scalar in title.lowercased().unicodeScalars {
            if scalar == " " {
                base.append("-")
            } else if scalar == "-" || scalar == "_"
                || CharacterSet.alphanumerics.contains(scalar) {
                base.unicodeScalars.append(scalar)
            }
            // Other punctuation is dropped.
        }
        if let count = seen[base] {
            seen[base] = count + 1
            return "\(base)-\(count)"
        } else {
            seen[base] = 1
            return base
        }
    }
}
