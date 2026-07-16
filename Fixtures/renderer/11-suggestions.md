# 11 — Suggestions (CriticMarkup)

Tracked changes live as literal bytes in the source (docs/design/suggestions.md).
Plain renderers show the markup; Quoin renders it as review chrome.

## The five marks

The launch is {++now++} scheduled. The old copy {--was too long and rambling--}
reads better. We {~~cannot~>can~~} ship this quarter.

Please revisit {==this whole sentence==}{>>Needs a citation from the Q3
report.<<}{#c1} before publishing.

## Marks with markdown inside

An insertion can carry {++**bold**, *italic*, and `code`++} spans. A deletion
can strike {--an [old link](https://example.com) entirely--}.

## Metadata references (RDFM)

Anchored comment with an id: {==the metric==}{>>Which metric exactly?<<}{#c2}.
A suggestion with an id: {++per-tenant limits++}{#s1}.

## Degradation (must stay literal)

An {++unclosed insertion stays literal. Marks inside `{--code spans--}` stay
literal. A substitution without an arrow {~~like this~~} stays literal.

```text
{++fenced code is never parsed for marks++}
```

Math is opaque: $a {++b++} c$ stays math, while {++this edit++} and $x^2$
coexist in one paragraph.

---
comments:
  c1: { by: user, at: "2026-04-28T12:00:00Z" }
  c2:
    body: "Q3 numbers, specifically."
    by: AI
    at: "2026-04-28T12:05:00Z"
    re: c1
suggestions:
  s1: { by: AI, at: "2026-04-28T12:01:00Z" }
