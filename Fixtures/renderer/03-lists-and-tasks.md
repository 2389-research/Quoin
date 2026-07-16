# Lists & Task Lists

> Ordered/unordered, nesting, loose vs tight, marker edge cases, definition lists; GFM checkboxes.

## 6. Lists

### 6.1 Unordered Lists

- Dash item 1
- Dash item 2
  - Nested dash item 2.1
  - Nested dash item 2.2
    - Nested dash item 2.2.1
      - Nested dash item 2.2.1.1
        - Nested dash item 2.2.1.1.1
- Dash item 3

+ Plus item 1
+ Plus item 2
  + Nested plus item
+ Plus item 3

* Asterisk item 1
* Asterisk item 2
  * Nested asterisk item
* Asterisk item 3

### 6.2 Ordered Lists

1. First item
2. Second item
3. Third item

7. Ordered list that starts at seven
8. Item eight
9. Item nine

1999. Large ordered marker
2000. Next large ordered marker

1) Ordered list using right parenthesis
2) Second item
3) Third item

### 6.3 Mixed and Nested Lists

1. Prepare parser fixtures.
   - CommonMark core
   - GFM extensions
   - Extension zoo
2. Run renderer snapshots.
   1. HTML snapshot
   2. PDF export
   3. Plain-text extraction
3. Compare output.
   - Visual diffs
   - DOM diffs
   - Accessibility tree diffs

### 6.4 Loose Lists

- Loose item one.

  This paragraph belongs to loose item one.

- Loose item two.

  > A quote inside a loose list item.

- Loose item three.

  ```python
  print("code inside loose list item")
  ```

### 6.5 Tight Lists

- Tight item one
- Tight item two
- Tight item three

### 6.6 List Marker Edge Cases

1986\. This should be a paragraph beginning with "1986." because the dot is escaped.

- - -

The line above may render as a thematic break or as nested list markers depending on exact parsing context. In CommonMark, `- - -` is a thematic break.

1. Item one

   1. Nested item one

      Paragraph under nested item.

   2. Nested item two

2. Item two after nested list.

### 6.7 Definition List Extension

Term One
: Definition one. This syntax is supported by some renderers, not CommonMark/GFM.

Term Two
: Definition two, paragraph one.

  Definition two, paragraph two.

---


## 10. Task Lists

- [x] Checked task item
- [X] Checked task item using uppercase X
- [ ] Unchecked task item
- [ ] Task with **bold**, `code`, and [a link](https://example.com)
- [ ] Parent task
  - [x] Nested completed subtask
  - [ ] Nested incomplete subtask
    - [ ] Deeply nested subtask
- [ ] Task item with a very long line that should wrap properly without misaligning the checkbox or making the text collide with the marker area in narrow viewports.

Regular list item that merely contains `[ ]` in the middle should not become a checkbox.

---

