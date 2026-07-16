// The math engine was extracted into the Vinculum package
// (Vinculum/Sources/VinculumLayout). Re-export it so QuoinCore's public
// surface is unchanged for existing consumers — `MathParser`, `MathNode`,
// `MathScanner`, `MathMacros`, `MathAlphabet`, and the model enums remain
// reachable through `import QuoinCore`, and module-internal files
// (`MarkdownConverter`, `InlinePostPasses`) see them without a per-file
// import, exactly as with MermaidLayout.
@_exported import VinculumLayout
