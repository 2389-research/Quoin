import QuoinCore
import MermaidRender

extension DiagramFormat {
    /// The MermaidKit renderer format this diagram block maps to. Quoin's
    /// platform-free `DiagramFormat` (QuoinCore) is decoupled from the Apple-only
    /// renderer; this seam bridges them at draw time (ADR: diagram rendering
    /// lives in MermaidKit, Quoin routes).
    var mermaidRenderFormat: MermaidRenderer.DiagramSourceFormat {
        switch self {
        case .mermaid: return .mermaid
        case .dot: return .dot
        case .dippin: return .dippin
        }
    }
}
