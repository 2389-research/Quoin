# Tables

> Basic GFM tables, column alignment, escaped pipes, empty/wide cells, large tables.

## 9. Tables

### 9.1 Basic GFM Table

| Feature | Syntax | Expected broad behavior |
| --- | --- | --- |
| Heading | `# H1` | Creates a heading |
| Emphasis | `*text*` | Italic/emphasis |
| Strong | `**text**` | Bold/strong |
| Link | `[x](url)` | Clickable anchor |
| Code | `` `x` `` | Inline monospace |

### 9.2 Alignment

| Left aligned | Center aligned | Right aligned |
| :--- | :---: | ---: |
| alpha | beta | gamma |
| 1 | 2 | 3 |
| long left cell with wrapping text | centered-ish content | 1234567890 |

### 9.3 Escaped Pipes and Inline Code

| Case | Markdown | Result expectation |
| --- | --- | --- |
| Escaped pipe | `a \| b` | One cell containing a pipe |
| Code pipe | `` `a | b` `` | Inline code may contain a literal pipe |
| Link pipe | `[a \| b](https://example.com)` | Link text contains pipe |
| HTML break | `line<br>break` | Break inside cell if HTML allowed |

### 9.4 Empty Cells and Wide Unicode

| Name | Value | Notes |
| --- | --- | --- |
| Empty middle |  | Nothing in the middle cell |
| Empty end | value |  |
| CJK | 日本語, 中文, 한국어 | Wide glyph alignment varies by renderer |
| Emoji | 🦖🧪🚀 | Emoji width varies |
| RTL | العربية עברית | Directionality can affect layout |

### 9.5 Large Table

| # | Key | Status | Description |
| ---: | --- | :---: | --- |
| 1 | headings | ✅ | ATX and Setext headings, repeated anchors, inline content. |
| 2 | paragraphs | ✅ | Soft breaks, hard breaks, entities, escapes, long tokens. |
| 3 | emphasis | ✅ | Nested asterisk and underscore emphasis. |
| 4 | links | ✅ | Inline, reference, autolinks, mailto, relative, fragments. |
| 5 | images | ✅ | Inline images, reference images, linked images, long alt text. |
| 6 | blockquotes | ✅ | Nested quotes, lazy continuations, alerts. |
| 7 | lists | ✅ | Ordered, unordered, mixed, loose, tight, nested, task list. |
| 8 | code | ✅ | Inline code, indented blocks, fenced blocks, syntax hints. |
| 9 | tables | ✅ | GFM table syntax, alignment, escaped pipes. |
| 10 | html | ✅ | Inline HTML, block HTML, details, kbd, comments. |
| 11 | footnotes | ⚠️ | GitHub and other renderers support them; CommonMark core does not. |
| 12 | math | ⚠️ | Extension-only; often KaTeX/MathJax. |
| 13 | diagrams | ⚠️ | Extension-only; often Mermaid. |
| 14 | front matter | ⚠️ | Static-site generators often parse it. |
| 15 | attributes | ⚠️ | Pandoc/kramdown extension syntax. |

---

