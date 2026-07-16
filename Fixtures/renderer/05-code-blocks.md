# Code Spans & Code Blocks

> Indented and fenced blocks, language info strings, tilde fences, fence-length edge cases, long lines.

## 7. Code Spans and Code Blocks

### 7.1 Indented Code Block

    This is an indented code block.
    It preserves leading spaces.
    Markdown inside it is not parsed: **not bold**, [not link](#nope).

### 7.2 Fenced Code Blocks

```text
Plain text fenced code block.
No highlighting should be required.
```

```json
{
  "name": "markdown-renderer-stress-test",
  "features": ["CommonMark", "GFM", "HTML", "Unicode"],
  "nested": {
    "pipes": "a | b | c",
    "backticks": "```",
    "emoji": "🧪"
  },
  "valid": true
}
```

```python
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class Fixture:
    """Tiny example used to test syntax highlighting."""

    name: str
    features: tuple[str, ...]


def render_queue(fixtures: Iterable[Fixture]) -> list[str]:
    """Return fixture names sorted by length, then alphabetically."""
    return sorted((f.name for f in fixtures), key=lambda s: (len(s), s))


if __name__ == "__main__":
    print(render_queue([Fixture("tables", ("gfm",)), Fixture("html", ("commonmark",))]))
```

```ruby
Fixture = Struct.new(:name, :features, keyword_init: true)

fixtures = [
  Fixture.new(name: "links", features: %i[commonmark gfm]),
  Fixture.new(name: "tables", features: %i[gfm])
]

puts fixtures.map(&:name).sort.join(", ")
```

```javascript
const fixture = {
  name: "markdown-renderer-stress-test",
  ok: true,
  examples: ["tables", "task-lists", "autolinks"],
};

console.log(`${fixture.name}: ${fixture.examples.length} examples`);
```

```bash
#!/usr/bin/env bash
set -euo pipefail

markdown_file="markdown_renderer_stress_test.md"
renderer="./bin/render"

"$renderer" "$markdown_file" > out.html
printf 'Rendered %s\n' "$markdown_file"
```

```diff
- old renderer dropped task list checkboxes
+ new renderer preserves task list checkboxes
+ new renderer escapes raw HTML in safe mode
```

```html
<section aria-label="Example HTML in a code fence">
  <h1>This is code, not live HTML</h1>
  <p>Markdown **inside** a code fence is not parsed.</p>
</section>
```

### 7.3 Tilde Fences

~~~markdown
# Markdown inside a code fence

- This bullet should appear literally.
- `inline code` remains text.
~~~

### 7.4 Fence Length Stress

````markdown
A four-backtick fence can contain a three-backtick fence:

```js
console.log("nested fenced block");
```
````

### 7.5 Code Block with Long Lines

```text
0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ
```

---

