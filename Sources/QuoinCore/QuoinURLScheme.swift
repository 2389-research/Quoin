import Foundation

/// The `quoin://` deep-link scheme: pure parsing + sandbox-safe path
/// resolution, with NO filesystem or platform I/O so it builds and tests on
/// Linux and can be exercised exhaustively.
///
/// A deep link names an *action* (the URL host) and a document *path* (the
/// `path` query item). The app resolves that path against a library root it
/// already holds security-scoped access to; a link that resolves outside the
/// root is refused. The two security-critical guarantees — traversal cannot
/// escape the root, and the resolution is lexical/deterministic — live here so
/// they are testable without a running app or a real sandbox.
///
/// Grammar (host = action, `path` percent-encoded):
///
///     quoin://open?path=Notes/Today.md          (relative to the library root)
///     quoin://open?path=/abs/inside/library.md  (absolute, must be inside root)
///
/// Absolute paths are honored only when they already fall inside the library
/// root — the app has no sandbox access to anything else, so an out-of-library
/// link would fail regardless; refusing it up front makes the intent explicit.
public enum QuoinURLScheme {

    /// The registered URL scheme (also declared in the app's Info.plist
    /// `CFBundleURLTypes`).
    public static let scheme = "quoin"

    /// The `NSUserActivity` type for "editing the open document" (#36; declared
    /// in the app's Info.plist `NSUserActivityTypes`). Publishing the open
    /// document under this type feeds Handoff, Siri suggestions, and window
    /// restoration. The activity's `userInfo` carries a `quoin://` deep link —
    /// NEVER an absolute file path or a security-scoped bookmark — so the
    /// resuming side re-resolves it through ``resolvedPath(forRawPath:relativeTo:)``
    /// and stays inside the sandbox boundary.
    public static let editingActivityType = "ai.2389.Quoin.editing"

    /// The `userInfo` key under which the activity carries its `quoin://` deep
    /// link (as an absolute-string `quoin://open?path=…`). One name, used by
    /// both the publish and the continue sides, so they can't drift apart.
    public static let activityDeepLinkKey = "deepLink"

    /// A parsed, not-yet-resolved deep link. `rawPath` is percent-decoded but
    /// otherwise untrusted — it must be run through ``resolvedPath(forRawPath:relativeTo:)``
    /// against a concrete library root before any file is touched.
    public struct DeepLink: Equatable, Sendable {
        public enum Action: String, Sendable {
            /// Open a document by path.
            case open
        }

        public let action: Action
        public let rawPath: String
        /// When `true`, only a window whose library root CONTAINS the resolved
        /// document may honor this link — a window that can't resolve it leaves
        /// the pending slot alone rather than beeping (so another window can
        /// claim it). Set for Core Spotlight taps (#6): the tapped item names a
        /// document by its absolute, root-scoped path, and it must route to the
        /// library that owns it, never to a same-named file in a different
        /// library that merely happens to be the key window. External `quoin://`
        /// links (which carry a portable *relative* path) leave this `false`.
        public let confinedToContainingRoot: Bool

        public init(action: Action, rawPath: String, confinedToContainingRoot: Bool = false) {
            self.action = action
            self.rawPath = rawPath
            self.confinedToContainingRoot = confinedToContainingRoot
        }
    }

    /// Is this a `quoin://` URL at all? Cheap scheme check so the app can tell
    /// a deep link apart from a plain `file://` open without a full parse.
    public static func isDeepLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme
    }

    /// Parse a `quoin://` URL into a ``DeepLink``. Returns `nil` for the wrong
    /// scheme, an unknown action, or a missing/empty `path`. Pure: no I/O.
    public static func parse(_ url: URL) -> DeepLink? {
        guard isDeepLink(url) else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // The action is the URL host (`quoin://open?…`). Case-insensitive.
        guard let host = components.host?.lowercased(),
              let action = DeepLink.Action(rawValue: host) else {
            return nil
        }
        // `URLComponents.queryItems` percent-decodes the value for us.
        guard let path = components.queryItems?
            .first(where: { $0.name == "path" })?.value,
            !path.isEmpty else {
            return nil
        }
        // A NUL byte can never appear in a legitimate path and truncates C
        // strings downstream — refuse it here.
        guard !path.contains("\0") else { return nil }
        return DeepLink(action: action, rawPath: path)
    }

    /// Resolve `rawPath` (relative to, or absolute inside, `rootPath`) to a
    /// concrete absolute path that is *provably contained* within `rootPath`.
    ///
    /// Containment is lexical: `.` and `..` are collapsed by string math (never
    /// by consulting the filesystem), so a path that climbs above the root —
    /// `../../etc/passwd`, or an absolute path elsewhere — resolves to
    /// something that is not under `root + "/"` and is refused (`nil`). The root
    /// itself is refused too: a deep link opens a *document*, not the folder.
    ///
    /// This is the lexical half of the defense. The app pairs it with the
    /// sandbox's own boundary (it only holds security scope on the library
    /// root) and an on-disk existence check, so a symlink inside the root that
    /// points elsewhere still cannot be *read* even though it passes lexically.
    /// Pure: no I/O.
    public static func resolvedPath(forRawPath rawPath: String, relativeTo rootPath: String) -> String? {
        let root = normalize(rootPath)
        guard root.hasPrefix("/"), root != "/" else { return nil }
        guard !rawPath.isEmpty, !rawPath.contains("\0") else { return nil }

        let candidate: String
        if rawPath.hasPrefix("/") {
            candidate = rawPath
        } else {
            candidate = root + "/" + rawPath
        }
        let resolved = normalize(candidate)

        // The root folder itself is not a document.
        guard resolved != root else { return nil }
        // Must live strictly under the root. The trailing slash prevents a
        // sibling whose name merely *starts* with the root (e.g. root
        // "/Library" vs "/LibraryOther") from slipping through.
        guard resolved.hasPrefix(root + "/") else { return nil }
        return resolved
    }

    /// Build a `quoin://open?path=…` deep link for `documentPath` (an absolute
    /// POSIX path) expressed *relative to* `rootPath`. Returns `nil` when the
    /// document is not strictly contained within the root — the sandbox holds no
    /// access outside a granted library, so no portable link can name a document
    /// there, and #36 must publish NO activity for such a document.
    ///
    /// This is the exact inverse of ``resolvedPath(forRawPath:relativeTo:)``: the
    /// link it produces re-resolves back to `documentPath` under the same root.
    /// The emitted `path` is *relative* (not absolute) so the link stays portable
    /// across machines whose library lives at a different absolute location — the
    /// resuming side re-anchors it to ITS root. Pure: no I/O.
    public static func deepLink(forDocumentPath documentPath: String, relativeTo rootPath: String) -> URL? {
        guard let relative = relativePath(forDocumentPath: documentPath, relativeTo: rootPath) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = DeepLink.Action.open.rawValue
        components.queryItems = [URLQueryItem(name: "path", value: relative)]
        return components.url
    }

    /// The library-root-relative path for `documentPath` (an absolute POSIX
    /// path), or `nil` when the document is not strictly contained within
    /// `rootPath`. This is the boundary-safe handle window-session restoration
    /// persists instead of an absolute path or a raw security-scoped bookmark:
    /// it round-trips back to the absolute path through
    /// ``resolvedPath(forRawPath:relativeTo:)`` under the same root, and stays
    /// portable across machines whose library lives at a different absolute
    /// location. Pure: no I/O.
    public static func relativePath(forDocumentPath documentPath: String, relativeTo rootPath: String) -> String? {
        guard !documentPath.contains("\0") else { return nil }
        let root = normalize(rootPath)
        guard root.hasPrefix("/"), root != "/" else { return nil }
        let doc = normalize(documentPath)
        // Must live strictly under the root — the trailing slash stops a sibling
        // whose name merely starts with the root from slipping through, and the
        // root folder itself is not a document.
        guard doc != root, doc.hasPrefix(root + "/") else { return nil }
        let relative = String(doc.dropFirst(root.count + 1))
        guard !relative.isEmpty else { return nil }
        return relative
    }

    /// Build a `quoin://open?path=<relativePath>` deep link straight from a
    /// stable relative-path identifier (the Core Spotlight domain id, #6),
    /// WITHOUT needing the absolute path or the root. Validates the path the
    /// same way ``parse(_:)`` does — an empty path or a NUL byte is refused
    /// (`nil`) — so a hostile Spotlight identifier can't smuggle a malformed
    /// link. The link still re-resolves through
    /// ``resolvedPath(forRawPath:relativeTo:)`` on the receiving side, so the
    /// library-root confinement holds. Pure: no I/O.
    public static func openLink(relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.contains("\0") else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = DeepLink.Action.open.rawValue
        components.queryItems = [URLQueryItem(name: "path", value: relativePath)]
        return components.url
    }

    /// Build the ``DeepLink`` for a tapped Core Spotlight result (#6). The
    /// tapped item's `uniqueIdentifier` is the document's *root-scoped* path
    /// (see ``/QuoinCore/SpotlightIndexing/identifier(forDocumentPath:relativeTo:)``);
    /// this validates it exactly as ``parse(_:)`` does (an empty path or a NUL
    /// byte is refused — a hostile identifier can't smuggle a malformed link)
    /// and stamps ``DeepLink/confinedToContainingRoot`` so the resume side
    /// routes it ONLY to the library that owns the document, never to a
    /// same-named file in whichever library is key. The link still re-resolves
    /// through ``resolvedPath(forRawPath:relativeTo:)`` on the receiving side,
    /// so the library-root confinement holds. Pure: no I/O.
    public static func spotlightDeepLink(identifier: String) -> DeepLink? {
        guard let url = openLink(relativePath: identifier),
              let link = parse(url) else { return nil }
        return DeepLink(
            action: link.action,
            rawPath: link.rawPath,
            confinedToContainingRoot: true)
    }

    /// Lexically normalize an absolute or relative POSIX path: collapse empty
    /// components and `.`, and pop a component for each `..` (an absolute path
    /// cannot climb above `/`; a relative one keeps leading `..`). No symlink
    /// resolution, no filesystem access — deterministic on every platform.
    static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var stack: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
                // Absolute: a `..` at/above root is simply dropped.
            default:
                stack.append(component)
            }
        }
        return (isAbsolute ? "/" : "") + stack.joined(separator: "/")
    }
}
