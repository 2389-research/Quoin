import Foundation

/// A small state-machine syntax highlighter — deliberately not a grammar
/// engine. Six token kinds (matching the design spec's six colors), a
/// keyword set per language, and string/comment/number scanning cover the
/// "good enough at zero dependency cost" bar. Unknown languages fall back
/// to string/number/comment scanning only.
public enum SyntaxTokenKind: Hashable, Sendable {
    case keyword, string, comment, number, function, type
}

public struct SyntaxToken: Hashable, Sendable {
    /// Character (not byte) range into the code string.
    public let range: Range<Int>
    public let kind: SyntaxTokenKind
}

public enum SyntaxHighlighter {

    public static func highlight(code: String, language: String?) -> [SyntaxToken] {
        let profile = LanguageProfile.profile(for: language)
        let chars = Array(code)
        var tokens: [SyntaxToken] = []
        var i = 0

        func peek(_ offset: Int = 0) -> Character? {
            let idx = i + offset
            return idx < chars.count ? chars[idx] : nil
        }

        func matches(_ s: String, at index: Int) -> Bool {
            let sChars = Array(s)
            guard index + sChars.count <= chars.count else { return false }
            for (j, c) in sChars.enumerated() where chars[index + j] != c { return false }
            return true
        }

        while i < chars.count {
            let c = chars[i]

            // Line comments.
            if let marker = profile.lineComment, matches(marker, at: i) {
                let start = i
                while i < chars.count, chars[i] != "\n" { i += 1 }
                tokens.append(SyntaxToken(range: start..<i, kind: .comment))
                continue
            }

            // Block comments.
            if let (open, close) = profile.blockComment, matches(open, at: i) {
                let start = i
                i += open.count
                while i < chars.count, !matches(close, at: i) { i += 1 }
                i = min(i + close.count, chars.count)
                tokens.append(SyntaxToken(range: start..<i, kind: .comment))
                continue
            }

            // Strings.
            if profile.stringDelimiters.contains(c) {
                let start = i
                let quote = c
                i += 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == quote { i += 1; break }
                    if chars[i] == "\n" && quote != "`" { break } // unterminated line string
                    i += 1
                }
                tokens.append(SyntaxToken(range: start..<min(i, chars.count), kind: .string))
                continue
            }

            // Numbers.
            if c.isNumber {
                let start = i
                while i < chars.count, chars[i].isHexDigit || "xXbBoO._eE+-".contains(chars[i]) {
                    // Stop +- unless directly after an exponent marker.
                    if "+-".contains(chars[i]), i > start, !"eE".contains(chars[i - 1]) { break }
                    i += 1
                }
                tokens.append(SyntaxToken(range: start..<i, kind: .number))
                continue
            }

            // Identifiers / keywords / types / functions.
            if c.isLetter || c == "_" || c == "@" || c == "#" {
                let start = i
                i += 1
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
                let word = String(chars[start..<i])
                if profile.keywords.contains(word) {
                    tokens.append(SyntaxToken(range: start..<i, kind: .keyword))
                } else if peek() == "(" {
                    tokens.append(SyntaxToken(range: start..<i, kind: .function))
                } else if word.first?.isUppercase == true, word.count > 1 {
                    tokens.append(SyntaxToken(range: start..<i, kind: .type))
                }
                continue
            }

            i += 1
        }
        return tokens
    }
}

// MARK: - Language profiles

struct LanguageProfile {
    let lineComment: String?
    let blockComment: (open: String, close: String)?
    let stringDelimiters: Set<Character>
    let keywords: Set<String>

    static func profile(for language: String?) -> LanguageProfile {
        switch language?.lowercased() {
        case "swift":
            return LanguageProfile(
                lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\""],
                keywords: ["func", "let", "var", "if", "else", "guard", "return", "for", "while", "repeat",
                           "switch", "case", "default", "break", "continue", "struct", "class", "enum",
                           "protocol", "extension", "import", "public", "private", "internal", "fileprivate",
                           "open", "static", "final", "init", "deinit", "self", "Self", "super", "nil",
                           "true", "false", "throw", "throws", "rethrows", "try", "catch", "do", "defer",
                           "in", "where", "as", "is", "any", "some", "async", "await", "actor", "mutating",
                           "override", "typealias", "associatedtype", "inout", "indirect", "lazy", "weak"])
        case "python", "py":
            return LanguageProfile(
                lineComment: "#", blockComment: nil, stringDelimiters: ["\"", "'"],
                keywords: ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from",
                           "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue",
                           "lambda", "yield", "global", "nonlocal", "assert", "del", "in", "is", "not",
                           "and", "or", "None", "True", "False", "async", "await", "match", "case", "self"])
        case "javascript", "js", "typescript", "ts", "jsx", "tsx":
            return LanguageProfile(
                lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'", "`"],
                keywords: ["function", "const", "let", "var", "if", "else", "for", "while", "do", "return",
                           "switch", "case", "default", "break", "continue", "class", "extends", "new",
                           "this", "super", "import", "export", "from", "as", "try", "catch", "finally",
                           "throw", "typeof", "instanceof", "in", "of", "null", "undefined", "true",
                           "false", "async", "await", "yield", "static", "get", "set", "interface",
                           "type", "enum", "implements", "public", "private", "protected", "readonly"])
        case "go":
            return LanguageProfile(
                lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\"", "`"],
                keywords: ["func", "var", "const", "type", "struct", "interface", "map", "chan", "if",
                           "else", "for", "range", "switch", "case", "default", "break", "continue",
                           "return", "go", "defer", "select", "package", "import", "nil", "true", "false",
                           "make", "new", "len", "cap", "append", "fallthrough", "goto"])
        case "rust", "rs":
            return LanguageProfile(
                lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\""],
                keywords: ["fn", "let", "mut", "const", "static", "if", "else", "match", "for", "while",
                           "loop", "break", "continue", "return", "struct", "enum", "trait", "impl", "use",
                           "mod", "pub", "crate", "self", "Self", "super", "where", "async", "await",
                           "move", "ref", "in", "as", "dyn", "unsafe", "true", "false", "Some", "None",
                           "Ok", "Err"])
        case "ruby", "rb":
            return LanguageProfile(
                lineComment: "#", blockComment: nil, stringDelimiters: ["\"", "'"],
                keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "case",
                           "when", "while", "until", "for", "do", "return", "yield", "begin", "rescue",
                           "ensure", "raise", "require", "require_relative", "attr_accessor", "attr_reader",
                           "self", "nil", "true", "false", "and", "or", "not", "then", "lambda", "proc"])
        case "c", "cpp", "c++", "objc", "objective-c", "h":
            return LanguageProfile(
                lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'"],
                keywords: ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed",
                           "const", "static", "struct", "union", "enum", "typedef", "if", "else", "for",
                           "while", "do", "switch", "case", "default", "break", "continue", "return",
                           "goto", "sizeof", "class", "public", "private", "protected", "virtual",
                           "override", "new", "delete", "namespace", "using", "template", "typename",
                           "nullptr", "true", "false", "auto", "@interface", "@implementation", "@end",
                           "@property", "@synthesize", "self", "nil", "YES", "NO", "id"])
        case "java", "kotlin", "kt":
            return LanguageProfile(
                lineComment: "//", blockComment: ("/*", "*/"), stringDelimiters: ["\""],
                keywords: ["fun", "val", "var", "class", "interface", "object", "public", "private",
                           "protected", "internal", "static", "final", "abstract", "if", "else", "for",
                           "while", "do", "when", "switch", "case", "default", "break", "continue",
                           "return", "try", "catch", "finally", "throw", "throws", "new", "this", "super",
                           "import", "package", "extends", "implements", "null", "true", "false",
                           "override", "data", "sealed", "suspend", "companion", "lateinit", "void", "int",
                           "boolean", "long", "double", "float", "char", "byte", "String"])
        case "sh", "bash", "shell", "zsh":
            return LanguageProfile(
                lineComment: "#", blockComment: nil, stringDelimiters: ["\"", "'"],
                keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
                           "case", "esac", "function", "return", "exit", "export", "local", "readonly",
                           "echo", "cd", "source", "alias", "set", "unset", "trap", "shift", "true", "false"])
        case "sql":
            return LanguageProfile(
                lineComment: "--", blockComment: ("/*", "*/"), stringDelimiters: ["'"],
                keywords: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                           "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "JOIN", "LEFT", "RIGHT",
                           "INNER", "OUTER", "ON", "AS", "AND", "OR", "NOT", "NULL", "ORDER", "BY",
                           "GROUP", "HAVING", "LIMIT", "OFFSET", "DISTINCT", "UNION", "PRIMARY", "KEY",
                           "FOREIGN", "REFERENCES", "select", "from", "where", "insert", "into", "values",
                           "update", "set", "delete", "join", "on", "as", "and", "or", "not", "null",
                           "order", "by", "group", "limit"])
        case "yaml", "yml", "toml", "ini":
            return LanguageProfile(
                lineComment: "#", blockComment: nil, stringDelimiters: ["\"", "'"],
                keywords: ["true", "false", "null", "yes", "no"])
        case "json":
            return LanguageProfile(
                lineComment: nil, blockComment: nil, stringDelimiters: ["\""],
                keywords: ["true", "false", "null"])
        case "html", "xml", "css":
            return LanguageProfile(
                lineComment: nil, blockComment: ("<!--", "-->"), stringDelimiters: ["\"", "'"],
                keywords: [])
        default:
            return LanguageProfile(
                lineComment: "#", blockComment: nil, stringDelimiters: ["\"", "'"],
                keywords: [])
        }
    }
}
