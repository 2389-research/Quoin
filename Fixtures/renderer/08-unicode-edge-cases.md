# Unicode, Directionality & Ambiguity

> Mixed scripts, RTL, combining marks, typography; ambiguous/lazy-continuation and backslash-escape edge cases.

## 14. Unicode, Directionality, and Typography

### 14.1 Mixed Scripts

English, Español, Français, Deutsch, Ελληνικά, Русский, Українська, हिन्दी, বাংলা, ไทย, Tiếng Việt, 中文, 日本語, 한국어, العربية, עברית.

### 14.2 Right-to-Left Text

Arabic: هذا نص عربي لاختبار اتجاه الكتابة داخل فقرة Markdown.

Hebrew: זהו טקסט בעברית לבדיקת כיוון הכתיבה בתוך פסקה.

Mixed direction: English before العربية in the middle and עברית near the end.

### 14.3 Combining Marks and Emoji Sequences

Combining marks: café vs café, a̐éö̲, Z̪̫̜͑͗͛̈́͒ͣ̋͝a̩̲͚͗͋l͓̩͌͌ͦ̏͜g̛̦̒o̪̿̔.

Emoji ZWJ sequences: 👨‍👩‍👧‍👦, 🧑‍💻, 🏳️‍🌈, 🏴‍☠️, 👩🏽‍🚀.

Variation selectors: ♥ vs ♥️, ☎ vs ☎️, 1 vs 1️⃣.

### 14.4 Typography Stress

Straight quotes "like this" and apostrophes 'like this'. Curly quotes “like this” and apostrophes ‘like this’. En dash – em dash — ellipsis … primes ′ ″ arrows ← ↑ → ↓ ↔ ⇒ ⇢.

Math-ish symbols: ± × ÷ ≈ ≠ ≤ ≥ ∑ ∏ ∫ √ ∞ ∂ ∆ ∇ ∈ ∉ ∩ ∪ ⊂ ⊆ ⊕ ⊗.

Box drawing:

```text
┌──────────────┬──────────────┐
│ Parser       │ Renderer     │
├──────────────┼──────────────┤
│ CommonMark   │ HTML         │
│ GFM          │ PDF          │
└──────────────┴──────────────┘
```

---

## 15. Edge Cases and Ambiguity

### 15.1 Punctuation Around Links and URLs

Visit https://example.com/path_(with_parens), then compare https://example.com/path_(with_parens). Also test <https://example.com/path_(with_parens)>.

A URL followed by punctuation: https://example.com/one, https://example.com/two. https://example.com/three! https://example.com/four? https://example.com/five).

### 15.2 HTML vs Markdown Ambiguity

<div>
Markdown-looking **bold** inside an HTML block may not parse as Markdown.
</div>

After the HTML block, **bold** should parse normally.

### 15.3 Lazy Continuation in Lists

- First item starts here
continuation line without indentation
- Second item starts here

### 15.4 Blank Lines in Lists

- Item with paragraph one.

  Paragraph two belongs to the same item.

- Next item.

### 15.5 Backslash Escapes That Do and Do Not Work

\*escaped asterisk\*

\a backslash before a normal letter usually remains visible.

\😀 backslash before emoji usually remains visible.

### 15.6 Raw Angle Brackets

This is not necessarily an HTML tag: <maybe>. This is a comparison: 2 < 3 and 5 > 4. This is an autolink: <https://example.com>.

### 15.7 Nested Brackets

[Link text with [nested brackets] inside](https://example.com)

![Alt text with [brackets] and (parens)](https://placehold.co/240x80/png?text=Nested)

### 15.8 Empty and Odd Blocks

>
> Quote after an empty quoted line.

-

A single dash above may be a list item with empty content.

1.

An ordered marker above may be a list item with empty content.

### 15.9 Tabs and Spaces

The following code block includes visible tab markers as text rather than literal tabs:

```text
<TAB>Indented with a tab marker
    Indented with four spaces
  Indented with two spaces
```

A real tab follows between the arrows: →	←

### 15.10 Backslash at End of File-Like Line

This line ends with a backslash to force break.\
The next line should be visibly separated by a hard break.

---

