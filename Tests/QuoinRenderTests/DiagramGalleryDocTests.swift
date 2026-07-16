#if canImport(AppKit)
import XCTest
import AppKit
@testable import QuoinRender
import QuoinCore

/// Generates `docs/diagram-gallery.md` and its images — every native Mermaid
/// type shown in a simple and a complex form, each rendered by Quoin's own
/// engine (light + dark). Single source of truth: the `entries` list below,
/// so the doc and images can never drift. Gated on `QUOIN_DIAGRAM_GALLERY=<repo
/// root>` so it's skipped in normal `swift test` runs:
///
///   QUOIN_DIAGRAM_GALLERY=$PWD swift test --filter DiagramGalleryDocTests
final class DiagramGalleryDocTests: XCTestCase {

    struct Entry {
        let slug: String
        let title: String
        let note: String
        let simple: String
        let complex: String
    }

    static let entries: [Entry] = [
        Entry(slug: "flowchart", title: "Flowchart", note: "Layered placement, fan-out attachment, back-edges routed around the band.",
              simple: """
              flowchart LR
                  A[Start] --> B{OK?}
                  B -->|yes| C[Done]
                  B -->|no| A
              """,
              complex: """
              flowchart TD
                  Start([Start]) --> Parse[Parse markdown]
                  Parse --> Ready{Ready?}
                  Ready -->|yes| Render[Process input]
                  Ready -->|no| Wait[Wait]
                  Wait --> Ready
                  Render --> Store[(Store)]
                  Store --> Done([Done])
              """),
        Entry(slug: "sequence", title: "Sequence", note: "Lifelines and self-message loops.",
              simple: """
              sequenceDiagram
                  Alice->>Bob: Hello
                  Bob-->>Alice: Hi
              """,
              complex: """
              sequenceDiagram
                  participant U as User
                  participant E as Editor
                  participant S as Session
                  U->>E: type keystroke
                  E->>S: SourceEdit(range, text)
                  S->>S: reparse block
                  S-->>E: RenderedDocument
                  E-->>U: reprojected view
              """),
        Entry(slug: "class", title: "Class", note: "Compartments, orthogonal routing, ▷ ◆ ◇ markers.",
              simple: """
              classDiagram
                  Animal <|-- Dog
                  class Animal {
                    +String name
                    +eat()
                  }
              """,
              complex: """
              classDiagram
                  class Document {
                    +String source
                    +[Block] blocks
                    +render() RenderedDocument
                  }
                  class Block {
                    +BlockID id
                    +ByteRange range
                  }
                  class Renderer
                  Document "1" *-- "many" Block
                  Renderer ..> Document : projects
              """),
        Entry(slug: "state", title: "State", note: "Composite states, choice diamonds, fork/join bars.",
              simple: """
              stateDiagram-v2
                  [*] --> Idle
                  Idle --> Running: start
                  Running --> [*]: stop
              """,
              complex: """
              stateDiagram-v2
                  [*] --> Editing
                  state Editing {
                    [*] --> Clean
                    Clean --> Dirty: keystroke
                    Dirty --> Clean: autosave
                  }
                  Editing --> Conflict: external change
                  Conflict --> Editing: resolve
                  Editing --> [*]: close
              """),
        Entry(slug: "er", title: "Entity-Relationship", note: "Crow's-foot cardinalities, identifying relationships.",
              simple: """
              erDiagram
                  FOLDER ||--o{ DOCUMENT : contains
              """,
              complex: """
              erDiagram
                  LIBRARY ||--o{ FOLDER : has
                  FOLDER ||--o{ DOCUMENT : contains
                  DOCUMENT ||--o{ BLOCK : "parses into"
                  DOCUMENT {
                    string path
                    string title
                    int wordCount
                  }
                  BLOCK {
                    string kind
                    int byteOffset
                  }
              """),
        Entry(slug: "pie", title: "Pie", note: "Slices with a legend.",
              simple: """
              pie title Coverage
                  "Native" : 23
                  "Fallback" : 0
              """,
              complex: """
              pie showData title Time in the render pipeline
                  "Parse" : 18
                  "Layout" : 27
                  "Typeset math" : 15
                  "Draw diagrams" : 22
                  "Splice" : 18
              """),
        Entry(slug: "gantt", title: "Gantt", note: "Sections, dependencies, statuses, milestones.",
              simple: """
              gantt
                  title Release
                  section Build
                  Parser :done, a1, 2026-01-01, 5d
                  Renderer :active, a2, after a1, 8d
              """,
              complex: """
              gantt
                  title Renderer roadmap
                  dateFormat YYYY-MM-DD
                  section Engine
                  Incremental render :done, r1, 2026-01-01, 6d
                  Diagram routing :done, r2, after r1, 8d
                  section Diagrams
                  Chart types :active, d1, after r2, 10d
                  Graph types :crit, d2, after d1, 6d
                  section Ship
                  Gallery :milestone, m1, after d2, 0d
              """),
        Entry(slug: "timeline", title: "Timeline", note: "Vertical spine, section-tinted event cards.",
              simple: """
              timeline
                  2004 : Markdown
                  2014 : CommonMark
                  2026 : Quoin
              """,
              complex: """
              timeline
                  title Markdown milestones
                  2004 : Markdown introduced
                       : Plain-text authoring
                  2014 : CommonMark begins
                  section Modern era
                      2017 : GFM published
                           : Tables and task lists
                      2026 : Native diagrams
              """),
        Entry(slug: "mindmap", title: "Mindmap", note: "Tidy horizontal tree, per-branch tints, indentation hierarchy.",
              simple: """
              mindmap
                root((Quoin))
                  Render
                  Edit
                  Store
              """,
              complex: """
              mindmap
                root((Quoin))
                  Rendering
                    TextKit 2
                    Diagrams
                      Mermaid
                      Math
                  Editing
                    Syntax reveal
                    Byte-lossless
                  Storage
                    Plain .md files
                    Local-only
              """),
        Entry(slug: "journey", title: "User Journey", note: "Sectioned task rows, 1–5 satisfaction badges.",
              simple: """
              journey
                  title Write a note
                  section Draft
                    Type: 5: Me
                    Fix table: 2: Me
              """,
              complex: """
              journey
                  title Writing a note in Quoin
                  section Capture
                    Quick Open: 4: Writer
                    Create doc: 5: Writer
                  section Draft
                    Type markdown: 5: Writer
                    Insert diagram: 3: Writer, Reviewer
                    Fix a table: 2: Writer
                  section Publish
                    Export HTML: 4: Writer
                    Share: 5: Writer, Reviewer
              """),
        Entry(slug: "quadrant", title: "Quadrant", note: "2×2 tinted matrix with plotted points.",
              simple: """
              quadrantChart
                  x-axis Low --> High
                  y-axis Low --> High
                  "Tables": [0.3, 0.7]
                  "Mermaid": [0.7, 0.8]
              """,
              complex: """
              quadrantChart
                  title Feature risk matrix
                  x-axis Low complexity --> High complexity
                  y-axis Low impact --> High impact
                  quadrant-1 High leverage
                  quadrant-2 Strategic bets
                  quadrant-3 Easy cleanup
                  quadrant-4 Yak shave
                  "Tables": [0.30, 0.68]
                  "Mermaid": [0.74, 0.80]
                  "Footnotes": [0.44, 0.32]
                  "Sanitizer": [0.70, 0.90]
              """),
        Entry(slug: "packet", title: "Packet", note: "32-bit grid, fields wrap across rows, rotated narrow labels.",
              simple: """
              packet-beta
                  0-3: "Version"
                  4-15: "Length"
                  16-31: "Checksum"
              """,
              complex: """
              packet-beta
                  title TCP Header
                  0-15: "Source Port"
                  16-31: "Destination Port"
                  32-63: "Sequence Number"
                  64-95: "Acknowledgment Number"
                  96-99: "Data Offset"
                  100-102: "Reserved"
                  103: "NS"
                  104: "CWR"
                  105: "ECE"
                  106: "URG"
                  107: "ACK"
                  108: "PSH"
                  109: "RST"
                  110: "SYN"
                  111: "FIN"
                  112-127: "Window"
                  128-143: "Checksum"
                  144-159: "Urgent Pointer"
              """),
        Entry(slug: "xychart", title: "XY Chart", note: "Grouped bars + line series over a value axis.",
              simple: """
              xychart-beta
                  x-axis [Mon, Tue, Wed]
                  bar [3, 5, 2]
              """,
              complex: """
              xychart-beta
                  title "Render time by fixture size"
                  x-axis ["1 KB", "10 KB", "50 KB", "100 KB", "250 KB", "1 MB"]
                  y-axis "Milliseconds" 0 --> 1200
                  bar [4, 18, 82, 140, 420, 1100]
                  line [3, 12, 44, 90, 210, 760]
              """),
        Entry(slug: "kanban", title: "Kanban", note: "Tinted columns, word-wrapped cards, ticket chips.",
              simple: """
              kanban
                  todo[To Do]
                    t1[Write docs]
                  done[Done]
                    t2[Ship gallery]
              """,
              complex: """
              kanban
                  backlog[Backlog]
                    t1[Add all Mermaid diagram families]@{ ticket: MD-101, priority: 'High' }
                    t2[Add MathJax matrices]@{ ticket: MD-102 }
                  doing[In Progress]
                    t3[Run the visual regression diff]@{ ticket: MD-103 }
                  blocked[Blocked]
                    t4[Renderer lacks beta support]@{ ticket: MD-104 }
                  done[Done]
                    t5[CommonMark baseline]@{ ticket: MD-001 }
              """),
        Entry(slug: "radar", title: "Radar", note: "Spoked graticule, overlaid curve polygons, legend.",
              simple: """
              radar-beta
                  axis A, B, C, D
                  curve x["X"]{A: 80, B: 40, C: 90, D: 60}
                  max 100
              """,
              complex: """
              radar-beta
                  title Renderer capability
                  axis CM["CommonMark"], GFM["GFM"], DIA["Diagrams"], MATH["Math"], A11Y["A11y"], PERF["Perf"]
                  curve baseline["Baseline"]{CM: 90, GFM: 65, DIA: 10, MATH: 5, A11Y: 55, PERF: 88}
                  curve extended["Extended"]{CM: 92, GFM: 82, DIA: 74, MATH: 79, A11Y: 70, PERF: 76}
                  curve aspirational["Aspirational"]{CM: 98, GFM: 95, DIA: 92, MATH: 94, A11Y: 90, PERF: 90}
                  max 100
                  ticks 5
              """),
        Entry(slug: "treemap", title: "Treemap", note: "Squarified nested rectangles, area ∝ value.",
              simple: """
              treemap-beta
                  "Docs"
                      "Native": 23
                      "Fallback": 0
              """,
              complex: """
              treemap-beta
                  "Markdown Fixture"
                      "CommonMark": 32
                      "GFM"
                          "Tables": 7
                          "Task Lists": 4
                          "Autolinks": 3
                      "Mermaid"
                          "Stable": 18
                          "Beta": 14
                      "MathJax"
                          "Inline": 5
                          "Display": 8
                      "Edge Cases": 12
              """),
        Entry(slug: "gitgraph", title: "GitGraph", note: "Commit lanes, branch/merge curves, tags.",
              simple: """
              gitGraph
                  commit
                  branch dev
                  commit
                  checkout main
                  merge dev
              """,
              complex: """
              gitGraph
                  commit id: "init"
                  commit id: "commonmark"
                  branch gfm
                  checkout gfm
                  commit id: "tables"
                  commit id: "tasks"
                  checkout main
                  merge gfm tag: "v0.2"
                  branch extensions
                  checkout extensions
                  commit id: "mermaid"
                  commit id: "mathjax"
                  checkout main
                  merge extensions tag: "v0.3"
              """),
        Entry(slug: "requirement", title: "Requirement", note: "UML requirement/element boxes, verb-labelled relations.",
              simple: """
              requirementDiagram
                  requirement core {
                    id: 1
                    text: render markdown
                    risk: high
                    verifymethod: test
                  }
                  element app { type: simulation }
                  app - satisfies -> core
              """,
              complex: """
              requirementDiagram
                  requirement commonmark_core {
                    id: R-CORE-001
                    text: Preserve CommonMark semantics.
                    risk: high
                    verifymethod: test
                  }
                  functionalRequirement gfm_tables {
                    id: R-GFM-002
                    text: Support GFM tables and task lists.
                    risk: medium
                    verifymethod: inspection
                  }
                  element renderer { type: simulation }
                  renderer - satisfies -> commonmark_core
                  gfm_tables - derives -> commonmark_core
              """),
        Entry(slug: "sankey", title: "Sankey", note: "Depth-columned flow, bands proportional to value.",
              simple: """
              sankey-beta
              Source,Parse,10
              Parse,Render,7
              Parse,Sanitize,3
              """,
              complex: """
              sankey-beta
              Source Markdown,Parse Blocks,35
              Source Markdown,Parse Inline,25
              Parse Blocks,GFM Extensions,12
              Parse Blocks,Mermaid Render,18
              Parse Inline,MathJax Typeset,16
              GFM Extensions,Sanitize,10
              Mermaid Render,Sanitize,15
              MathJax Typeset,Sanitize,13
              Sanitize,DOM Commit,30
              """),
        Entry(slug: "c4", title: "C4 Context", note: "Person / system / external boxes, tagged relations.",
              simple: """
              C4Context
                  Person(user, "User")
                  System(app, "Quoin")
                  Rel(user, app, "Edits with")
              """,
              complex: """
              C4Context
                  title System Context — Internet Banking
                  Person(customer, "Banking Customer", "A customer of the bank")
                  System(banking, "Internet Banking", "Lets customers view accounts")
                  System_Ext(email, "E-mail System", "Sendmail")
                  Rel(customer, banking, "Uses")
                  Rel(banking, email, "Sends mail", "SMTP")
              """),
        Entry(slug: "architecture", title: "Architecture", note: "Grouped service boxes, side-anchored edges.",
              simple: """
              architecture-beta
                  group app(cloud)[App]
                  service ui(server)[UI] in app
                  service db(database)[DB] in app
                  ui:R --> L:db
              """,
              complex: """
              architecture-beta
                  group app(cloud)[Renderer Application]
                  group data(database)[Local Data]
                  service ui(server)[Preview UI] in app
                  service worker(server)[Parser Worker] in app
                  service cache(database)[Preview Cache] in data
                  service files(disk)[Markdown Files] in data
                  ui:R --> L:worker
                  worker:B --> T:cache
                  files:T --> B:worker
              """),
        Entry(slug: "block", title: "Block", note: "Column grid, block shapes, connectors.",
              simple: """
              block-beta
                  columns 3
                  a["A"] b["B"] c["C"]
                  a --> b
                  b --> c
              """,
              complex: """
              block-beta
                  columns 4
                  source["Markdown source"] parser["Parser"] ast(("AST")) planner["Render planner"]
                  mermaid["Mermaid"] mathjax["MathJax"] html["HTML"] css["CSS"]
                  source --> parser
                  parser --> ast
                  ast --> planner
                  planner --> mermaid
                  planner --> mathjax
              """),
        Entry(slug: "zenuml", title: "ZenUML", note: "UML sequence from the alternate zenuml syntax.",
              simple: """
              zenuml
                  Client->Server.get()
                  Server->Client: 200 OK
              """,
              complex: """
              zenuml
                  title Order Service
                  @Actor Client
                  Client->OrderService.create()
                  OrderService->DB.save()
                  DB->OrderService: ok
                  OrderService->Client: created
              """),
    ]

    func testBuildDiagramGallery() throws {
        guard let root = ProcessInfo.processInfo.environment["QUOIN_DIAGRAM_GALLERY"] else {
            throw XCTSkip("set QUOIN_DIAGRAM_GALLERY=<repo root> to regenerate the gallery")
        }
        let imagesDir = "\(root)/docs/images/diagrams"
        try FileManager.default.createDirectory(atPath: imagesDir, withIntermediateDirectories: true)

        func render(_ source: String, _ path: String, dark: Bool) -> Bool {
            guard let png = DiagramGalleryTests.renderPNG(
                source: source, theme: Theme(prefersDark: dark), scale: 2) else { return false }
            try? png.write(to: URL(fileURLWithPath: path))
            return true
        }

        var md = """
        # Diagram gallery

        Every diagram below is drawn by **Quoin's own native Mermaid engine** —
        no Mermaid.js, no JavaScript, no network. Each type is shown in a simple
        and a complex form; the images adapt to your light/dark theme. Regenerate
        with `QUOIN_DIAGRAM_GALLERY=$PWD swift test --filter DiagramGalleryDocTests`.

        All \(Self.entries.count) Mermaid diagram types Quoin recognises render natively.

        """

        for entry in Self.entries {
            for (variant, source) in [("simple", entry.simple), ("complex", entry.complex)] {
                _ = render(source, "\(imagesDir)/\(entry.slug)-\(variant).png", dark: false)
                _ = render(source, "\(imagesDir)/\(entry.slug)-\(variant)-dark.png", dark: true)
            }
            md += """

            ## \(entry.title)

            \(entry.note)

            """
            for variant in ["simple", "complex"] {
                let src = variant == "simple" ? entry.simple : entry.complex
                md += """

                **\(variant.capitalized)**

                <picture>
                  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/\(entry.slug)-\(variant)-dark.png">
                  <img alt="\(entry.title) — \(variant)" src="images/diagrams/\(entry.slug)-\(variant).png" height="200">
                </picture>

                <details><summary>Source</summary>

                ```mermaid
                \(src)
                ```

                </details>

                """
            }
        }

        try md.write(toFile: "\(root)/docs/diagram-gallery.md", atomically: true, encoding: .utf8)
        print("wrote docs/diagram-gallery.md and \(Self.entries.count * 4) images")
    }
}
#endif
