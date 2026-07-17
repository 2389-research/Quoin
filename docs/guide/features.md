# What you can do with Quoin

A tour of Quoin organized by what you *do* — write, review, organize, read,
reference — not by how it's built. Every feature names its keyboard shortcut
and describes the real behavior you'll see. New to Quoin? Start with
[Getting started](getting-started.md) for a five-minute walkthrough instead.

Quoin is a native macOS WYSIWYG editor for plain `.md` files. The file on disk
is the source of truth; what you see is a live projection of it. There is no
web view, no JavaScript at runtime, and nothing leaves your machine. When you
edit, you're editing the markdown — the rendered view just re-projects it.
See [architecture](../reference/architecture.md) for the machinery behind
this, and [PRODUCT.md](../PRODUCT.md) for the full capability spec this tour
summarizes.

```mermaid
flowchart LR
    file[("your .md file<br/>on disk")] -->|parse| ast["Markdown + AST<br/>(source of truth)"]
    ast -->|project| view["Rendered document<br/>(what you see)"]
    view -->|you type / click| edit["Edit"]
    edit -->|mutate source| ast
    ast -->|save, byte-lossless| file
```

Because the file *is* the document, any tool that writes markdown — a
collaborator, a script, or an AI agent — writes Quoin documents. That is the
foundation of the review loop, the feature nothing else quite does.

The four clusters below map onto one flow: you write in a live projection,
optionally route changes through review, organize documents around it, and
read it back comfortably.

```mermaid
flowchart TD
    write["Write<br/>WYSIWYG on plain markdown"] --> review["Review<br/>suggestions & comments in-file"]
    write --> organize["Organize<br/>library, outline, properties, find"]
    write --> read["Read<br/>focus, typewriter scroll, code themes"]
    review -.->|accepted marks change prose| write
    organize -.->|navigate to a document| write
    read -.->|math & diagrams rendered natively| ref["Reference: math & diagrams"]
```

---

## Write

Quoin is WYSIWYG on plain markdown. The rendered document *is* the editor, and
the file on disk stays clean markdown you own.

- **Rich rendering as you read** — headings, emphasis, lists, tables, task
  lists, callouts, highlights, footnotes, code with syntax highlighting, math,
  and Mermaid diagrams, all drawn natively (no web view, no JavaScript).
- **Edit in place** — click into any block and it reveals its literal markdown
  source, character-for-character with the file. Edit it, click away, it
  re-renders. The line you're on never jumps on screen. This projection model
  — rendered by default, literal source while active — is documented in
  [editor modes](../design/editor-modes.md).
- **Formatting that writes real markdown** — every command below edits the
  source, so the file stays clean and portable:

  | Action | Shortcut | What it writes |
  | :--- | :--- | :--- |
  | Bold | ⌘B | `**text**` |
  | Italic | ⌘I | `*text*` |
  | Highlight | ⇧⌘H | `==text==` (cycles a color palette) |
  | Add Link | ⌘K | `[text](url)` |
  | Edit Source / Done Editing | ⌘↩ | toggles the caret block into raw markdown |
  | Move Block Up / Down | ⌥⌘↑ / ⌥⌘↓ | reorders whole blocks byte-exactly |

- **Structure commands** (Format ▸ Structure, while editing a block) — reshape
  the caret's block without hand-editing prefixes:

  | Action | Shortcut | What it does |
  | :--- | :--- | :--- |
  | Heading 1–6 | ⌥⌘1 … ⌥⌘6 | set the heading level (`#` … `######`) |
  | No Heading / Cycle Heading Level | menu | strip to a paragraph, or cycle none → 1 → … → 6 → none |
  | Toggle Bullet / Numbered List | menu | wrap the block's lines as `- ` / `1. ` items (or unwrap) |
  | Toggle Block Quote | menu | add or remove a `>` prefix on every line |
  | Toggle Checkbox | ⌃⌘↩ | flip `- [ ]` ⇄ `- [x]` on the caret's line (adds one to a plain line) |

- **List editing** — `Tab` / `⇧Tab` indent and outdent the current item;
  **Return** continues the list — bullets, incrementing numbers, `- [ ]`
  checkboxes (reset to unchecked), and `>` quotes — and Return on an empty
  item ends the list. All as byte-exact source edits.
- **Task lists** — click a checkbox; it toggles and writes `- [x]` back to the
  file.
- **Spell-check** — misspellings are underlined as you write (Edit ▸ Spelling
  and Grammar to toggle or correct). It only annotates — autocorrect and smart
  quote/dash substitutions stay off so your exact bytes reach disk.
- **Images** — drag an image file in, or **paste** a screenshot / copied image
  (⌘V). Quoin copies it into an `assets/` folder beside your document and
  inserts `![](assets/…)` at the caret — the file stays a plain `.md` you can
  move as a folder.
- **Word-granular undo** — typing coalesces into word-sized undo steps, so `⌘Z`
  removes a word (or a backspaced run), not one letter at a time. The Edit menu
  names the step it will reverse — **Undo Typing**, **Undo Move Block**, **Undo
  Edit Properties** — and disables when there's nothing left to undo.
- **Block operations** — right-click any block for **Duplicate Block**,
  **Delete Block**, **Move Block Up/Down**, and (on a table) **Add Table Row**
  and **Add Table Column**. Each is a byte-exact source splice.
- **Byte-lossless** — anything you don't touch is saved exactly as it was, down
  to whitespace and delimiter style. See
  [invariants](../reference/invariants.md).

### Why the file is the source of truth

Most editors keep an internal model — an attributed string, an HTML DOM — and
treat markdown as an import/export format. That makes round-trips lossy: open a
file, save it, and the byte layout shifts. Quoin never holds a second
representation. The markdown string and its parsed AST *are* the document; the
view is a pure projection. This is why an untouched paragraph survives edit →
save unchanged, and why an agent's edits and yours compose cleanly — you're
both writing to the same file.

---

## Review — the thing nothing else does

Suggestions and comments live *inside the markdown file* using RDFM /
CriticMarkup syntax. A collaborator or an AI agent can propose edits anywhere in
the document, and you triage them in a real UI — where every accept and reject
is one atomic, byte-safe edit to the file. Design notes:
[suggestions](../design/suggestions.md).

```mermaid
sequenceDiagram
    participant A as Agent / collaborator
    participant F as Your .md file
    participant Q as Quoin
    participant You

    A->>F: writes marks, e.g. {~~old~>new~~}, {>>comment<<}
    F->>Q: Quoin re-parses the file
    Q->>You: renders each mark as a card in the Review inspector
    You->>Q: Accept / Reject / Dismiss
    Q->>F: one atomic, byte-safe splice (one undo)
    Note over F: The prose only changes when you accept.
```

### The marks

Five kinds of mark render as tracked changes. The raw delimiters never appear in
the read view — you see the *change*, not the syntax.

| You (or an agent) write | Renders as |
| :--- | :--- |
| `{++inserted++}` | proposed insertion |
| `{--deleted--}` | proposed deletion |
| `{~~old~>new~~}` | proposed replacement |
| `{>>comment<<}` | a comment |
| `{==highlight==}` | a highlight |

### The Review inspector

The right-hand inspector has three modes — **Outline**, **Review**, and
**Properties** — toggled with ⌥⌘0. In **Review** mode, every mark in the
document is a card showing its author and relative time.

![Review inspector showing suggestion and comment cards, each with an author and relative time](../images/review-panel.png)

```mermaid
flowchart TB
    subgraph win["Quoin window"]
        direction LR
        sidebar["Library sidebar<br/>(⌘0)"]
        doc["Document<br/>marks render inline<br/>as tracked changes"]
        subgraph insp["Inspector (⌥⌘0)"]
            direction TB
            o["Outline"]
            r["Review — cards"]
            p["Properties"]
        end
    end
    doc <-->|click card ⇄ caret in mark| r
```

- **Per-card actions** — **✓ Accept**, **✕ Reject**, or **✕ Dismiss**. Bulk
  actions **✓ Accept All** and **✕ Reject All** sit at the top. Each resolution
  is one atomic edit, so one ⌘Z undoes it.
- **Card ↔ document linkage** — click a card to scroll its mark to center and
  flash an accent ring around it; put the caret inside a mark and its card
  highlights. When you resolve something offscreen, the view scrolls to where
  the change landed and pulses it.
- **History that's never lost** — resolved items are recorded in the file
  itself as RDFM endmatter (`status: resolved`), so the record is portable and
  agent-readable, and the Review tab stays available once any history exists.

### Suggest without touching the prose

Select text and use the **Format ▸ Review** menu (or right-click) to annotate
without changing what the document says. The prose only changes when someone
accepts the mark.

| Gesture | Shortcut | Effect |
| :--- | :--- | :--- |
| Add Comment… | ⇧⌘M | wraps the selection in `{>>…<<}` |
| Suggest Replacement… | ⇧⌘R | proposes `{~~old~>new~~}` |
| Suggest Deletion | — | proposes `{--…--}` |
| Highlight for Review | — | wraps the selection in `{==…==}` |
| Suggest Edits (mode) | ⌃⌘R | see below |

**Comment on opaque blocks** — code, tables, diagrams, and math can't hold
inline marks (marks must never be injected into runnable content). Right-click
one and choose **Comment on Block…**; Quoin drops a `{>>comment<<}` paragraph
next to the block instead.

### Suggest Edits mode

Toggle **Suggest Edits** (⌃⌘R) and your ordinary typing *becomes* suggestions
instead of edits. Insertions land as `{++…++}`, deletions as `{--…--}`, and
overwrites as `{~~old~>new~~}`. A single keystroke grows the current mark rather
than minting a fresh one each time. An accent **SUGGESTING** chip shows while
the mode is on, so you always know your edits are being tracked.

![The accent SUGGESTING status chip active in the toolbar during Suggest Edits mode](../images/review-mode.png)

```mermaid
stateDiagram-v2
    [*] --> Pending: mark created (you or an agent)
    Pending --> Accepted: ✓ Accept
    Pending --> Rejected: ✕ Reject
    Pending --> Dismissed: ✕ Dismiss
    Accepted --> History: recorded in file
    Rejected --> History: recorded in file
    Dismissed --> History: recorded in file
    History --> [*]
```

### Why marks in the file matter

Because suggestions are just text in your markdown, there's no proprietary
review database and no service to sync with. The review loop *is* the agent
interface: point an agent (like Claude Code) at your document, it writes marks,
and the cards appear in your panel. Every resolution is computed inside the
document session at apply time against the current file — if the underlying text
has drifted, Quoin refuses rather than splicing stale offsets. Candidate edits
are re-parsed and rejected unless exactly the expected mark comes back, so a
resolution can never quietly corrupt the document.

---

## Organize

- **Library** — pick a folder and its tree becomes your sidebar (⌘0). Folders
  are directories; documents are plain files. **Open Folder in New Window** (in
  the File menu) gives each window its own folder, restored on relaunch.
- **Drag out to Finder** — drag any document (or folder) from the sidebar
  straight into the Finder or another app. Because documents are plain files,
  the drop is a real copy of the file — your original stays put in the library.
- **`quoin://` links** — a `quoin://open?path=…` link opens a document in the
  library. `path` may be relative to the library root
  (`quoin://open?path=Notes/Today.md`) or an absolute path *inside* it. Links
  that point outside the library, use `..` to climb out, or name a file that
  isn't there are refused — Quoin only reaches files inside the folder you
  granted it. Handy for scripts, notes apps, and `Reveal in Finder`'s companion:
  a stable way to jump back to a document.
- **Outline** — a live heading tree (⌥⌘0, Outline mode). Manual collapse sticks,
  and the current-section highlight follows your reading position; when you
  collapse an ancestor, Quoin highlights that ancestor instead of re-expanding.
- **Properties** — the third inspector mode edits YAML front matter as a
  key/value panel with type-appropriate editors — date picker, toggle, number
  field, comma-separated list — plus an **Edit as Text** escape hatch. It's
  byte-conservative: a value that doesn't parse cleanly as its type stays a
  string, and typed writes preserve the original precision. In the document,
  front matter renders as a tidy field grid.

  ![Properties inspector editing YAML front-matter fields with type-appropriate controls](../images/properties-panel.png)

- **Find & search**:

  | Action | Shortcut |
  | :--- | :--- |
  | Find in Document… | ⌘F |
  | Find & Replace… | ⌥⌘F |
  | Find Next / Previous | ⌘G / ⇧⌘G |
  | Search Library… | ⇧⌘F |
  | Quick Open… | ⇧⌘O |
  | Daily Note | ⌘D |

  Find-in-document (⌘F) shows a live match count as you type:

  ![Find bar showing a search term and match count within the current document](../images/find-bar.png)

  The find bar carries four option toggles that apply to both the live
  highlight/count and to Replace:

  | Toggle | What it does |
  | :--- | :--- |
  | **Aa** — Match Case | Case-sensitive matching (off = case-insensitive). Accents are always significant — `cafe` never matches `café`. |
  | **W** — Whole Word | Match only complete words (bounded by non-word characters). |
  | **.\*** — Regular Expression | Interpret the query as a regular expression; an invalid pattern turns the field red and matches nothing. |
  | **In Selection** | Limit find & replace to the current text selection. |

  Match Case, Whole Word, and Regex are sticky across sessions; In Selection
  is per-use. The same option set drives the highlight, the “_N of M_” count,
  and Replace / Replace All, so the count you see is exactly what Replace All
  acts on. Replace reports how many occurrences it changed (“Replaced _N_”).
  Regex replacement text is inserted literally — `$1`-style capture-group
  substitution is not performed.

  Search Library (⇧⌘F) runs full-text search across every document in the folder:

  ![Search Library panel showing full-text results across the library](../images/library-search.png)

- **Tabs & navigation** — document tabs (⌘1–9 select by position; **Show Next
  Tab** ⌃⇥ and **Show Previous Tab** ⌃⇧⇥ cycle through them from the Window
  menu), jump history **Back** ⌘[ and **Forward** ⌘], a breadcrumb path, and
  footnote click-to-jump with a hover preview and an ↩ backlink to return.

  ![Footnote reference marker with a hover preview popover](../images/footnotes.png)

---

## Read comfortably

| Feature | Shortcut | What it does |
| :--- | :--- | :--- |
| Focus Mode | View menu / toolbar | dims everything but the current block (per-window) |
| Sentence Focus | View menu | narrows the focus to the current sentence (needs Focus Mode) |
| Typewriter Scrolling | ⌥⌘T | keeps the active line vertically centered (per-window) |
| Zoom In / Out | ⌘= / ⌘− | scales the reading text up or down |
| Actual Size | ⌃⌘0 | resets the reading text to 100% |
| Wrap Lines | View menu | wrap long lines to the column, or let them run and scroll horizontally |
| Status Bar | — | word count, reading progress, and goals |

Focus Mode, Sentence Focus, and Typewriter Scrolling are per-window — turning
one on in one document doesn't flip it in your other open windows.

Text zoom changes only how large the document reads on screen — it's a viewing
preference, not an edit. Exports (PDF, RTF) and print always render at 100%, so a
comfortable reading zoom never leaks into the files you share.

Twelve selectable code themes are available for fenced code blocks; the default
follows the app's light/dark appearance. A reading-progress hairline and
word-count goals live in the status bar.

![A fenced code block rendered in one of the twelve selectable syntax themes](../images/code-theme.png)

Every rendered element — front matter, callouts, tables, code, math, diagrams —
carries its own light and dark styling; there's no separate "dark mode" theme
to fight with your content.

![A document rendered in dark appearance, headings and front-matter grid intact](../images/dark-document.png)

---

## Accessibility

Quoin honors the system accessibility settings from **System Settings ▸
Accessibility** — no separate in-app switches to find:

| Setting | What Quoin does |
| :--- | :--- |
| **Larger text** (Dynamic Type) | The app chrome — sidebar, outline, document tabs, status bar, inspector, and dialogs — scales with your preferred text size. The design's type ramp is preserved (everything grows together, in proportion), so nothing looks lopsided at large sizes. |
| **Reduce Motion** | Sidebar and outline reveals, the formatting pill, and block flip transitions apply instantly instead of animating. |
| **Reduce Transparency** | Vibrant surfaces (Quick Open, the find and replace bars) fall back to opaque backgrounds. |

Dynamic Type scales the *chrome*; the document body has its own independent
reading zoom (⌘= / ⌘−, above). The two never fight, and neither changes the
bytes on disk.

### VoiceOver and the rendered structure

The document is one text view, but VoiceOver hears its structure:

- **Jump between headings.** With VoiceOver on, the document exposes a
  **Headings** rotor. Open the rotor (VO‑U), pick **Headings**, and flick
  up/down (or VO‑←/→) to move directly from one heading to the next — each is
  announced with its level and title (*"Heading level 2, Introduction"*), so
  you can skim the outline without arrowing through every line.
- **Move by structure.** A companion **Landmarks** rotor flicks through the
  other structural blocks — code blocks, tables, lists, callouts, quotes,
  diagrams, and equations — announcing what each region is (*"Table, 3 columns,
  4 rows"*, *"Note callout"*, *"Ordered list, 2 items"*, *"Code block, swift,
  12 lines"*) so you can navigate the document's shape, not just its lines.
- **Equations and diagrams speak.** A rendered equation reads its spoken‑math
  description (*"Equation, x squared plus one"*) and a diagram reads a
  narration of its type and leading content (*"Flowchart with 3 nodes and 2
  connections: Start, Decision, Done"*) — never an unnamed "image."
- **The ✓ done chip is a real control.** When a block is open for editing,
  VoiceOver finds the *Done editing* button and can press it to commit.

Deferred for a later pass: per‑*element* rotors that step through individual
tables, links, and tasks (beyond the block‑level Landmarks rotor);
accessibility containers grouping the sidebar / outline / find bar; and
alternate actions on hover‑only controls (tab close, copy‑code).

---

## Reference: math & diagrams

Math and diagrams are rendered natively — no MathJax, no KaTeX, no Mermaid.js.
Quoin edits them in place with a live side-panel preview (see
[embed editing](../design/embed-editing-ux.md) for how the source and preview
panes stay in sync): the source reveals beside a rendered pane, and the last
good render is held while your mid-edit source is temporarily invalid, so the
panel never flashes blank. Anything unsupported degrades to a labeled source
card with a specific reason — never a blank, never a crash.

```mermaid
flowchart LR
    src["Edit source<br/>(⌘↩ on a math/diagram block)"] --> preview["Live side-panel<br/>preview"]
    src -. mid-edit, source invalid .-> held["Last-good render held"]
    preview --> done["Done — re-render inline"]
```

- **Math** — LaTeX via
  **[Vinculum](https://github.com/2389-research/Vinculum)**, Quoin's own
  TeX-style typesetting engine (~400 commands: fractions, roots, scripts, big
  operators with correct limits, matrices, alignment environments). Inline
  `$…$` and `\(…\)`, display `$$…$$` and `\[…\]`. The full coverage matrix
  lives in Vinculum's docs.

  ![Gallery of LaTeX math rendered natively by Vinculum: fractions, roots, matrices, alignment environments](../images/gallery-math.png)

- **Diagrams** — Mermaid via
  **[MermaidKit](https://github.com/2389-research/MermaidKit)**, parsed and laid
  out natively (flowcharts, sequence, state, and more). Front-matter
  `title`/`config` and `accTitle`/`accDescr` are supported. The full
  diagram-type catalog lives in MermaidKit's docs.

  ![Gallery of Mermaid diagrams rendered natively by MermaidKit: flowchart, sequence, and state diagrams](../images/gallery-diagrams.png)

Both engines are first-party, GitHub-hosted dependencies — see
[dependencies](../reference/dependencies.md) for why Quoin keeps its
dependency list this short.

### Why native rendering, not a web view

A web view would mean bundling a JavaScript engine, shipping third-party
renderers, and paying a startup and memory cost on every diagram and equation —
plus a privacy surface Quoin refuses. Native first-party engines keep everything
local, fast, and consistent with the rest of the document's typography, and they
degrade predictably instead of failing in an opaque sandbox.

---

## Export & interop

- Export to **PDF**, **HTML**, **Markdown** (round-trip), **RTF**, or **plain
  text** (via **Export…**, ⇧⌘E), and **Print…** with ⌘P. **Page Setup…** (⇧⌘P)
  sets the paper size and orientation the print job uses. Exports render at
  100% regardless of the reading-view zoom.

  ![Export sheet with PDF, HTML, Markdown, RTF, and plain-text options](../images/export-sheet.png)

- **Share** the current document through the system share sheet (AirDrop, Mail,
  Messages, or any share extension) from the toolbar Share button.

- Everything is a plain file. Any tool that writes markdown — or RDFM /
  CriticMarkup — produces Quoin documents. There is no lock-in and no service:
  files on disk are the whole story.
