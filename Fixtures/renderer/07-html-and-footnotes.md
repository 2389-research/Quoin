# Raw HTML, Footnotes & Reference Definitions

> Inline/block HTML, details/summary, comments, sanitisation cases; footnotes and reference-style definitions.

<!--
fixture_id: html-and-footnotes
note: multi-line pure comment — its reveal must include this closing marker line (task #71)
-->

## 11. Raw HTML

### 11.1 Inline HTML

Text before <strong>raw strong HTML</strong> and <em>raw emphasis HTML</em> and <code>raw inline code</code> and text after.

### 11.2 Block HTML

<div class="callout" data-fixture="raw-html">
  <h3>Raw HTML Block</h3>
  <p>This block contains <strong>HTML</strong>. Markdown inside raw HTML may or may not be parsed depending on renderer and extension settings.</p>
  <p>Markdown-looking text: **bold?** [link?](https://example.com)</p>
</div>

### 11.3 Details/Summary

<details>
<summary>Expandable details block</summary>

This content is inside a `<details>` element.

- Markdown inside details is supported by some renderers.
- Others may treat it differently depending on blank lines and HTML block parsing.

```text
Code block inside details.
```

</details>

### 11.4 HTML Table

<table>
  <thead>
    <tr><th>HTML feature</th><th>Purpose</th></tr>
  </thead>
  <tbody>
    <tr><td><kbd>kbd</kbd></td><td>Keyboard shortcut styling</td></tr>
    <tr><td><ruby>漢<rt>kan</rt></ruby></td><td>Ruby annotation</td></tr>
    <tr><td><time datetime="2026-07-03">July 3, 2026</time></td><td>Machine-readable time</td></tr>
  </tbody>
</table>

### 11.5 HTML Comments

Visible text before comment.

<!-- This comment should not be visible in rendered output. -->

Visible text after comment.

### 11.6 Potentially Sanitized HTML, Shown Safely as Code

```html
<script>alert("Renderers should sanitize or block this if raw HTML is allowed.");</script>
<iframe src="https://example.com"></iframe>
<object data="https://example.com/example.svg"></object>
```

---

## 12. Footnotes and Definitions

This sentence has a footnote.[^basic-footnote]

This sentence has a longer footnote with multiple paragraphs.[^long-footnote]

This sentence uses an inline-style footnote syntax supported by some renderers.^[Inline footnote text, extension-only.]

Abbreviation definitions are extension-only in many renderers.

*[HTML]: HyperText Markup Language
*[GFM]: GitHub Flavored Markdown

A citation-like reference may render in Pandoc workflows: [@doe2026, pp. 12-15].

[^basic-footnote]: This is a basic footnote. GitHub supports footnotes, but CommonMark core does not define them.

[^long-footnote]: This is the first paragraph of a longer footnote.

    This is an indented second paragraph inside the footnote.

    - A list inside a footnote.
    - Another list item with `code`.

---


## 17. Reference Definitions

[full-reference]: https://example.com/full-reference "Full reference title"
[Collapsed reference link]: https://example.com/collapsed-reference
[shortcut-reference]: https://example.com/shortcut-reference
[case insensitive reference]: https://example.com/case-insensitive
[reference with spaces]: https://example.com/reference-with-spaces
[heading-like]: https://example.com/heading-like
[a *weird* [label] (yes)]: https://example.com/weird-label
[tiny-svg]: data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='320' height='80'><rect width='100%25' height='100%25' fill='%23f3f4f6'/><text x='16' y='48' font-family='monospace' font-size='24'>tiny svg</text></svg> "Tiny inline SVG"

---

