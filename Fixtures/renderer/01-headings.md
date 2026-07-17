# Headings & Thematic Breaks

> ATX/Setext levels, trailing hashes, inline emphasis in headings, id/attribute syntax, duplicate headings, horizontal rules.

## 1. Headings

# H1: ATX HeadingZZ

## H2: ATX Heading

### H3: ATX Heading

#### H4: ATX Heading

##### H5: ATX Heading

###### H6: ATX Heading

Heading with trailing hashes ###

##

Empty ATX heading above (title-less, legal markdown): projects to a zero-width placeholder so it still carries its level for the VoiceOver Headings rotor (#10).

# Heading with *inline emphasis*, `code`, and [a link](#links-inline-heading)

Setext Heading Level 1
======================

Setext Heading Level 2
----------------------

### Heading IDs as plain text or extension syntax {#custom-heading-id .large .important}

Some renderers treat `{#custom-heading-id .large .important}` as attributes. CommonMark and GFM should usually render it as text.

#### Repeated heading

Text under first repeated heading.

#### Repeated heading

Text under second repeated heading. Anchor generation differs by platform.

---


## 8. Thematic Breaks

Three hyphens:

---

Three asterisks:

***

Three underscores:

___

Hyphens with spaces:

- - -

Asterisks with spaces:

* * *

Underscores with spaces:

_ _ _

Not a thematic break because there is text:

--- not a thematic break

---

