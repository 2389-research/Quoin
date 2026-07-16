# Inline Formatting, Links & Images

> Paragraphs and hard breaks; emphasis/strong/strikethrough/code/emoji; inline HTML; autolinks, reference links, images, weird labels.

## 2. Paragraphs, Line Breaks, and Entities

A normal paragraph can span multiple physical lines
without becoming separate paragraphs. A renderer should wrap this as a single paragraph unless a hard break is requested.

This line ends with two spaces.  
This line should appear after a hard line break.

This line ends with a backslash.\
This line should also appear after a hard line break in CommonMark.

A new paragraph begins after a blank line.

HTML entities: &amp; &lt; &gt; &quot; &apos; &copy; &trade; &mdash; &ndash; &#169; &#x1F680;.

Named entities without semicolon can be tricky: &copy and &amp and &notin; and &notin.

Escaped Markdown punctuation: \\ backslash, \` backtick, \* asterisk, \_ underscore, \{ braces \}, \[ brackets \], \( parens \), \# hash, \+ plus, \- minus, \. dot, \! bang, \| pipe.

Consecutive spaces: one two  three    four. Some renderers collapse these in prose but preserve them in code.

A very long unbroken token follows. It should not destroy layout: pneumonoultramicroscopicsilicovolcanoconiosis_pneumonoultramicroscopicsilicovolcanoconiosis_pneumonoultramicroscopicsilicovolcanoconiosis_pneumonoultramicroscopicsilicovolcanoconiosis.

---

## 3. Inline Formatting

### 3.1 Emphasis and Strong Emphasis

- *asterisk emphasis*
- _underscore emphasis_
- **asterisk strong**
- __underscore strong__
- ***asterisk strong emphasis***
- ___underscore strong emphasis___
- **strong with *nested emphasis***
- *emphasis with **nested strong***
- __strong with _nested emphasis___
- _emphasis with __nested strong___
- word_with_underscores should usually remain a single word
- mid*word*emphasis can be surprising
- mid_word_emphasis is not usually emphasis
- **bold _italic `code` italic_ bold**

### 3.2 Strikethrough and Highlight-Like Extensions

- ~~GFM strikethrough~~
- ~single tilde is not always strikethrough~
- ==highlight syntax is extension-only==
- H~2~O subscript syntax is extension-only
- x^2^ superscript syntax is extension-only

### 3.3 Code Spans

- `simple code span`
- ``code span containing ` one backtick``
- ```code span containing `` two backticks```
- ` leading and trailing spaces `
- ``  multiple spaces inside code span  ``
- Code with Markdown punctuation: `**not bold** [not a link](#nope) <not-html>`
- Code with entities: `&amp; &lt; &gt;` should display literally.

### 3.4 Inline HTML

This sentence includes <kbd>⌘</kbd> + <kbd>K</kbd>, <abbr title="HyperText Markup Language">HTML</abbr>, <mark>marked text</mark>, <small>small text</small>, <sup>superscript</sup>, <sub>subscript</sub>, and <span data-test="inline-span">a custom span</span>.

### 3.5 Emoji and Shortcodes

Native emoji: 😀 😎 🛰️ 🧬 🦕 🧪 🧰 🫠.

Shortcodes may render on GitHub-like platforms: :smile: :rocket: :shipit: :octocat:.

---

## 4. Links, References, and Images

### 4.1 Inline Links

- [Example domain](https://example.com)
- [Example with title](https://example.com "The example domain")
- [Link with parentheses](https://example.com/a_(b))
- [Link with escaped paren](https://example.com/a_\(b\))
- [Empty link destination]()
- [Fragment link](#markdown-renderer-stress-test-)
- [Relative link](./relative/path/to/file.md)
- [Path with spaces](<./relative path/with spaces.md>)
- [Mailto link](mailto:test@example.com)

### 4.2 Autolinks and GFM Bare URLs

Autolinks: <https://example.com>, <http://example.org>, <mailto:test@example.com>.

GFM-style bare autolinks: https://github.com, www.example.com, test@example.com, xmpp:user@example.com, and http://example.com/trailing-punctuation).

### 4.3 Reference Links

- [Full reference link][full-reference]
- [Collapsed reference link][]
- [shortcut-reference]
- [Case Insensitive Reference][CASE insensitive reference]
- [Reference with spaces][reference    with    spaces]
- [Reference to heading-like label][heading-like]

### 4.4 Images

Inline image with remote placeholder:

![Placeholder image: 600 by 160, saying Markdown Renderer Test](https://placehold.co/600x160/png?text=Markdown+Renderer+Test "Placeholder title")

Reference image:

![Tiny SVG reference image][tiny-svg]

Linked image:

[![Linked placeholder image](https://placehold.co/300x90/png?text=Clickable+Image)](https://example.com)

Image with a deliberately long alt text:

![This is a deliberately long alt text string meant to test wrapping, accessibility extraction, exports, tooltips, missing image display, and whether the renderer handles verbose image descriptions gracefully.](https://placehold.co/480x120/png?text=Long+Alt+Text)

### 4.5 Link Labels That Look Weird

[Reference label containing punctuation][a *weird* [label] (yes)]

---

