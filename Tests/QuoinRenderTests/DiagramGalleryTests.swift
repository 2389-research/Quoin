#if canImport(AppKit)
import XCTest
import AppKit
@testable import QuoinRender
import MermaidRender
import QuoinCore

/// A visual harness — not a CI assertion. Renders each Mermaid diagram type to
/// a PNG so the drawing can be *observed* and iterated toward a polished look.
/// Gated on the `QUOIN_RENDER_GALLERY` env var (an output directory), so it is
/// skipped in normal `swift test` runs:
///
///   QUOIN_RENDER_GALLERY=/tmp/gallery swift test --filter DiagramGalleryTests
///
/// Each sample renders in both light and dark themes at 2.5×, on a padded card
/// matching the theme's canvas.
final class DiagramGalleryTests: XCTestCase {

    static let samples: [(name: String, source: String)] = [
        ("flowchart", """
        flowchart TD
            A[Start] --> B{Ready?}
            B -->|Yes| C[Process input]
            B -->|No| D[Wait]
            C --> E[(Store)]
            D --> B
            E --> F([Done])
        """),
        ("sequence", """
        sequenceDiagram
            participant U as User
            participant A as API
            participant DB as Database
            U->>A: POST /order
            A->>DB: insert order
            DB-->>A: order id
            A-->>U: 201 Created
        """),
        ("pie", """
        pie title Time by phase
            "Parsing" : 35
            "Layout" : 25
            "Drawing" : 30
            "Tests" : 10
        """),
        ("class", """
        classDiagram
            class Shape {
                +String name
                +area() double
            }
            class Circle {
                +double radius
                +area() double
            }
            class Rectangle {
                +double w
                +double h
            }
            Shape <|-- Circle
            Shape <|-- Rectangle
        """),
        ("er", """
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            ORDER ||--|{ LINE_ITEM : contains
            CUSTOMER {
                string name
                string email
            }
            ORDER {
                int id
                date created
            }
        """),
        ("state", """
        stateDiagram-v2
            [*] --> Idle
            Idle --> Running : start
            Running --> Paused : pause
            Paused --> Running : resume
            Running --> Idle : stop
            Running --> [*]
        """),
        ("gantt", """
        gantt
            title Renderer Hardening Schedule
            section Parser
            CommonMark baseline    :done,    cm, 2026-07-01, 2d
            GFM tables/tasks       :active,  gfm, after cm, 3d
            Unicode and RTL sweep  :         uni, after gfm, 2d
            section Extensions
            Mermaid pass           :crit,    mer, 2026-07-06, 4d
            MathJax pass           :crit,    mj,  after mer, 3d
            section Release
            Visual regression      :milestone, vr, 2026-07-17, 0d
            Canary                 :         canary, after vr, 2d
        """),

        // Larger, denser diagrams to stress layout, routing, and degradation.
        ("flowchart-complex", """
        flowchart TD
            A([Start]) --> B[Load cart]
            B --> C{Items > 0?}
            C -->|No| Z([Empty])
            C -->|Yes| D[Validate stock]
            D --> E{In stock?}
            E -->|No| F[Notify user]
            F --> B
            E -->|Yes| G[Calculate total]
            G --> H{Coupon?}
            H -->|Yes| I[Apply discount]
            H -->|No| J[Charge card]
            I --> J
            J --> K{Payment OK?}
            K -->|No| L[Retry]
            L --> J
            K -->|Yes| M[(Save order)]
            M --> N[Send email]
            N --> O([Done])
        """),
        ("sequence-complex", """
        sequenceDiagram
            participant C as Client
            participant G as Gateway
            participant A as Auth
            participant S as Service
            C->>G: request + token
            G->>A: validate token
            A->>A: check signature
            A-->>G: claims
            G->>S: forward + claims
            S-->>G: 200 payload
            G-->>C: 200 payload
        """),
        ("class-complex", """
        classDiagram
            class Repository {
                +save(item)
                +find(id) Item
                +delete(id)
            }
            class UserRepository {
                +findByEmail(email) User
            }
            class User {
                +String id
                +String email
                +activate()
            }
            class Session {
                +String token
                +Date expires
            }
            Repository <|-- UserRepository
            UserRepository o-- User
            User *-- Session
        """),
        ("er-complex", """
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            ORDER ||--|{ LINE_ITEM : contains
            PRODUCT ||--o{ LINE_ITEM : "ordered in"
            CATEGORY ||--o{ PRODUCT : groups
            CUSTOMER {
                int id
                string name
                string email
            }
            ORDER {
                int id
                date created
                string status
            }
            PRODUCT {
                int sku
                string title
                float price
            }
        """),
        ("state-complex", """
        stateDiagram-v2
            [*] --> Idle
            Idle --> Connecting : connect
            Connecting --> Connected : ok
            Connecting --> Idle : fail
            state Connected {
                [*] --> Syncing
                Syncing --> Live : synced
                Live --> Syncing : stale
            }
            Connected --> Idle : disconnect
            Connected --> [*]
        """),
        ("gantt-complex", """
        gantt
            title Product Launch
            dateFormat YYYY-MM-DD
            section Research
            User interviews   :done, r1, 2026-01-05, 10d
            Competitive audit :done, r2, after r1, 5d
            section Design
            Wireframes        :active, d1, after r2, 8d
            Visual design     :d2, after d1, 10d
            Prototype         :crit, d3, after d2, 6d
            section Build
            Frontend          :b1, after d3, 20d
            Backend           :b2, after d3, 18d
            Integration       :crit, b3, after b1, 8d
            section Launch
            Beta              :milestone, m1, after b3, 0d
            GA                :milestone, m2, after m1, 0d
        """),
        ("pie-complex", """
        pie title Traffic sources
            "Organic" : 40
            "Direct" : 22
            "Referral" : 15
            "Social" : 12
            "Email" : 8
            "Paid" : 3
        """),
        ("timeline", """
        timeline
            title Markdown Renderer Milestones
            2004 : Markdown introduced
                 : Plain-text authoring becomes mainstream
            2014 : CommonMark project begins
                 : Formalized parsing edge cases
            section Modern era
                2017 : GFM specification published
                     : Tables and task lists expected
                2026 : Native diagram families
        """),
        ("mindmap", """
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
        ("requirement", """
        requirementDiagram
            requirement commonmark_core {
              id: R-CORE-001
              text: Preserve CommonMark block and inline semantics.
              risk: high
              verifymethod: test
            }
            functionalRequirement gfm_tables {
              id: R-GFM-002
              text: Support GFM tables and task lists.
              risk: medium
              verifymethod: inspection
            }
            element renderer {
              type: simulation
            }
            renderer - satisfies -> commonmark_core
            gfm_tables - derives -> commonmark_core
        """),
        ("sankey", """
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
        ("block", """
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
        ("architecture", """
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
        ("zenuml", """
        zenuml
            title Order Service
            @Actor Client
            Client->OrderService.create()
            OrderService->DB.save()
            DB->OrderService: ok
            OrderService->Client: created
        """),
        ("c4", """
        C4Context
            title System Context — Internet Banking
            Person(customer, "Banking Customer", "A customer of the bank")
            System(banking, "Internet Banking", "Lets customers view accounts")
            System_Ext(email, "E-mail System", "Sendmail")
            Rel(customer, banking, "Uses")
            Rel(banking, email, "Sends mail", "SMTP")
        """),
        ("gitgraph", """
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
        ("treemap", """
        treemap-beta
            "Markdown Fixture"
                "CommonMark": 32
                "GFM"
                    "Tables": 7
                    "Task Lists": 4
                    "Autolinks": 3
                    "Strikethrough": 4
                "Mermaid"
                    "Stable diagrams": 18
                    "Beta diagrams": 14
                "MathJax"
                    "Inline": 5
                    "Display": 8
                    "Macros": 3
                "Edge Cases": 12
        """),
        ("radar", """
        radar-beta
            title Renderer Capability Radar
            axis CM["CommonMark"], GFM["GFM"], DIA["Diagrams"], MATH["Math"], A11Y["Accessibility"], PERF["Performance"]
            curve baseline["Baseline"]{CM: 90, GFM: 65, DIA: 10, MATH: 5, A11Y: 55, PERF: 88}
            curve extended["Extended"]{CM: 92, GFM: 82, DIA: 74, MATH: 79, A11Y: 70, PERF: 76}
            curve aspirational["Aspirational"]{CM: 98, GFM: 95, DIA: 92, MATH: 94, A11Y: 90, PERF: 90}
            max 100
            min 0
            ticks 5
        """),
        ("kanban", """
        kanban
            backlog[Backlog]
                t1[Add all Mermaid diagram families]@{ ticket: MD-101, priority: 'High' }
                t2[Add MathJax matrices and cases]@{ ticket: MD-102 }
            doing[In Progress]
                t3[Run the visual regression diff]@{ ticket: MD-103 }
            blocked[Blocked]
                t4[Renderer lacks beta diagram support]@{ ticket: MD-104 }
            done[Done]
                t5[CommonMark baseline parser]@{ ticket: MD-001 }
                t6[GFM tables and task lists]@{ ticket: MD-002 }
        """),
        ("xychart", """
        xychart-beta
            title "Renderer timing by fixture size"
            x-axis ["1 KB", "10 KB", "50 KB", "100 KB", "250 KB", "1 MB"]
            y-axis "Milliseconds" 0 --> 1200
            bar [4, 18, 82, 140, 420, 1100]
            line [3, 12, 44, 90, 210, 760]
        """),
        ("packet", """
        packet-beta
            title IPv4 Header Layout
            0-3: "Version"
            4-7: "IHL"
            8-15: "Type of Service"
            16-31: "Total Length"
            32-47: "Identification"
            48-50: "Flags"
            51-63: "Fragment Offset"
            64-71: "TTL"
            72-79: "Protocol"
            80-95: "Header Checksum"
            96-127: "Source Address"
            128-159: "Destination Address"
        """),
        ("packet-tcp", """
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
            112-127: "Window Size"
            128-143: "Checksum"
            144-159: "Urgent Pointer"
            160-191: "Options (if any)"
            192-255: "Data (variable)"
        """),
        ("quadrant", """
        quadrantChart
            title Feature Risk Matrix
            x-axis Low complexity --> High complexity
            y-axis Low impact --> High impact
            quadrant-1 High leverage
            quadrant-2 Strategic bets
            quadrant-3 Easy cleanup
            quadrant-4 Yak shave
            "Tables": [0.30, 0.68]
            "Mermaid": [0.74, 0.80]
            "Footnotes": [0.44, 0.32]
            "Emoji width": [0.22, 0.46]
            "Sanitizer": [0.70, 0.90]
        """),
        ("journey", """
        journey
            title Writing a note in Quoin
            section Capture
              Open Quick Open: 4: Writer
              Create document: 5: Writer
            section Draft
              Type markdown: 5: Writer
              Insert diagram: 3: Writer, Reviewer
              Fix a broken table: 2: Writer
            section Publish
              Export to HTML: 4: Writer
              Share with team: 5: Writer, Reviewer
        """),
    ]

    func testRenderGallery() throws {
        guard let dir = ProcessInfo.processInfo.environment["QUOIN_RENDER_GALLERY"] else {
            throw XCTSkip("set QUOIN_RENDER_GALLERY=<dir> to render the diagram gallery")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, source) in Self.samples {
            for (suffix, dark) in [("light", false), ("dark", true)] {
                guard let png = Self.renderPNG(source: source, theme: Theme(prefersDark: dark), scale: 2.5) else {
                    print("SKIP \(name)-\(suffix): no native render"); continue
                }
                let file = out.appendingPathComponent("\(name)-\(suffix).png")
                try png.write(to: file)
                print("wrote \(file.path)")
            }
        }
    }

    /// Renders the Mermaid blocks embedded in the docs through Quoin's own
    /// engine and writes them to `docs/images/`, so the documentation is
    /// illustrated by the very renderer it documents. Gated on
    /// `QUOIN_DOC_DIAGRAMS=<repo root>`; regenerates from live doc source so
    /// the images can't drift.
    func testRenderDocDiagrams() throws {
        guard let root = ProcessInfo.processInfo.environment["QUOIN_DOC_DIAGRAMS"] else {
            throw XCTSkip("set QUOIN_DOC_DIAGRAMS=<repo root> to regenerate doc diagram images")
        }
        // Only diagrams whose PNG is actually embedded in a doc. README's
        // architecture flowchart renders inline (GitHub honors <br/> line
        // breaks); it isn't pre-rendered to a PNG because MermaidKit doesn't
        // yet break on <br/>. data-flow uses single-line labels, so it renders
        // cleanly and doubles as a fixture.
        let jobs: [(file: String, blockIndex: Int, baseName: String)] = [
            ("docs/reference/architecture.md", 0, "data-flow"),
        ]
        for job in jobs {
            let text = try String(contentsOfFile: "\(root)/\(job.file)", encoding: .utf8)
            let blocks = Self.mermaidBlocks(in: text)
            guard job.blockIndex < blocks.count else {
                print("SKIP \(job.baseName): no block \(job.blockIndex) in \(job.file)"); continue
            }
            for (suffix, dark) in [("", false), ("-dark", true)] {
                guard let png = Self.renderPNG(source: blocks[job.blockIndex],
                                               theme: Theme(prefersDark: dark), scale: 2) else {
                    print("SKIP \(job.baseName)\(suffix): not natively rendered"); continue
                }
                let out = "\(root)/docs/images/\(job.baseName)\(suffix).png"
                try png.write(to: URL(fileURLWithPath: out))
                print("wrote \(out)")
            }
        }
    }

    /// Extracts the contents of every ```mermaid fenced block, in order.
    static func mermaidBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var current: [String]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if current == nil, trimmed == "```mermaid" {
                current = []
            } else if current != nil, trimmed == "```" {
                blocks.append(current!.joined(separator: "\n"))
                current = nil
            } else if current != nil {
                current!.append(line)
            }
        }
        return blocks
    }

    /// Renders a diagram to a padded PNG card, or nil if the source isn't
    /// natively rendered. Draws the diagram image under the theme's appearance
    /// so dynamic colors resolve to match the card.
    static func renderPNG(source: String, theme: Theme, scale: CGFloat, pad: CGFloat = 24) -> Data? {
        guard let attachment = MermaidRenderer.attachmentString(source: source, theme: theme.diagramTheme),
              let image = (attachment.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image
        else { return nil }
        let size = NSSize(width: image.size.width * scale + pad * 2, height: image.size.height * scale + pad * 2)
        let card = NSImage(size: size)
        card.lockFocus()
        let background = theme.prefersDark ? NSColor(srgbRed: 0x1B / 255, green: 0x1B / 255, blue: 0x1D / 255, alpha: 1) : .white
        background.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(x: pad, y: pad, width: image.size.width * scale, height: image.size.height * scale),
                   from: .zero, operation: .sourceOver, fraction: 1)
        card.unlockFocus()
        guard let tiff = card.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
