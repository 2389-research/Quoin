// The Mermaid engine was extracted into the MermaidKit package
// (MermaidKit/Sources/MermaidLayout). Re-export it so QuoinCore's public
// surface is unchanged for existing consumers — `MermaidParser`,
// `DiagramLayoutEngine`, `DiagramScene`, `DiagramLayoutLinter`, and the
// per-type models remain reachable through `import QuoinCore`.
@_exported import MermaidLayout
