---
title: A cost model for incremental Markdown reparse
author: clint
date: 2026-07-15
tags: [performance, parsing, editor-internals]
status: draft
---

# A cost model for incremental Markdown reparse

## Problem

Every keystroke in the editor mutates the source string and, in the naive
design, triggers a full reparse of the document into an AST. For a scratch
note this is free. For the 40k-word design doc I keep open all day it is
not: a full cmark-gfm parse of that file measures around 6 ms on my machine,
and at a sustained typing rate that is 6 ms of main-thread work landing on
top of every projection pass. The question is whether a *block-scoped*
reparse — reparsing only the block the caret sits in — actually pays for
itself once you account for the bookkeeping it forces on us.

I want a back-of-the-envelope model before I write any code, so I can tell
whether this is a 2x win or a 20% win.

## A model

Let the document be $n$ blocks $b_1, \dots, b_n$ with sizes $s_i$ (bytes),
so the total size is $S = \sum_{i=1}^{n} s_i$. Assume the parser is roughly
linear in input size with a per-byte constant $c$ and a fixed per-invocation
overhead $k$ (allocation, setup, the walk that builds our own node structs).
A full parse then costs

$$
T_{\text{full}} = k + c \sum_{i=1}^{n} s_i = k + c\,S.
$$

A block-scoped parse reparses one block of size $s_j$ but pays an extra
*reconciliation* cost $r(n)$ to splice the new subtree back into the document
and fix up block IDs and source offsets downstream of the edit:

$$
T_{\text{inc}} = k + c\,s_j + r(n).
$$

If edits are uniformly distributed across blocks, the expected reparsed size
is the mean block size $\bar{s} = S/n$, and reconciliation is dominated by the
offset fix-up, which is linear in the number of trailing blocks — on average
$n/2$ of them. Writing $r(n) = \rho\, n$ for a per-block splice constant
$\rho$, the expected speedup is

$$
\begin{aligned}
\mathbb{E}[T_{\text{inc}}]
  &= k + c\,\bar{s} + \rho\,\frac{n}{2} \\
  &= k + \frac{c\,S}{n} + \frac{\rho\,n}{2}.
\end{aligned}
$$

The interesting term is the last one: reconciliation *grows* with block count
while the parse term *shrinks*. There is a crossover. Minimising
$\mathbb{E}[T_{\text{inc}}]$ over $n$ by setting the derivative to zero,

$$
\frac{d}{dn}\left( \frac{cS}{n} + \frac{\rho n}{2} \right)
  = -\frac{cS}{n^2} + \frac{\rho}{2} = 0
\quad\Longrightarrow\quad
n^\star = \sqrt{\frac{2cS}{\rho}},
$$

which says the model only helps when documents are *chunky* — few, large
blocks — relative to $\rho$. For my design doc, $S \approx 240\text{k}$ and
$n \approx 900$, so $S/n \approx 267$ bytes per block. That puts the mean
parse term at roughly $c \cdot 267$ against the naive $c \cdot 240{,}000$: a
~900x reduction in *parse* work, before reconciliation eats into it.

> [!WARNING]
> The uniform-edit assumption is a lie. Real editing is bursty and local —
> you hammer one paragraph, not a random block each time. That makes the
> average case look *worse* than reality (you keep re-hitting the same warm
> block) but it also means a single pathological block — a 5k-line embedded
> table — dominates its own reparse cost no matter how clever the splice is.
> Model the tail, not the mean, before trusting any of this.

## Reconciliation, concretely

The splice cost $\rho n$ is not hypothetical hand-waving; it is the offset
fix-up. When block $j$ changes size by $\Delta$, every downstream block's
source range shifts by $\Delta$. We can make this $O(1)$ amortised with a
lazy offset base per block rather than absolute offsets, which is what turns
$r(n)$ from linear into near-constant and moves $n^\star$ out of the picture
entirely.

```swift
/// Reparse only the block under the edit and shift downstream offsets lazily.
func reparse(_ document: inout Document, editedBlock j: Int, delta: Int) {
    let source = document.blocks[j].sourceSlice
    let subtree = MarkdownParser.parseBlock(source)      // c * s_j
    document.blocks[j].replaceContents(with: subtree)

    // Instead of rewriting every downstream absolute offset (the ρ·n term),
    // bump a shared base the trailing blocks resolve against on demand.
    document.offsetBase(after: j).shift(by: delta)       // O(1)

    // Block IDs are stable across a same-kind reparse, so revealed carets
    // and comment anchors survive the splice untouched.
    document.reindexIfBlockCountChanged(around: j)
}
```

With the lazy base, $r(n) \to \rho'$ (a constant), and the expected cost
collapses to

$$
\mathbb{E}[T_{\text{inc}}] \approx k + \frac{c\,S}{n} + \rho',
$$

monotonically decreasing in $n$: more blocks is strictly better, and the
crossover disappears. That is the design I want.

## What this ignores

Two things the model quietly drops. First, $k$ is not actually constant — a
cold parser invocation touches allocator paths a warm one skips, so the very
first reparse after opening a document is an outlier and should not anchor a
benchmark.[^bench] Second, the projection pass that turns the AST into an
attributed string is a *separate* cost from parsing, and for large tables it
can dwarf the parse itself; a fast reparse feeding a slow projection is a
wash.[^project] The honest conclusion is that block-scoped reparse is
necessary but not sufficient — it has to be paired with a patch-level
projection that only re-renders the changed block, which we already do.

## Conclusion

The napkin math says block-scoped reparse with lazy offset bases is worth it:
it turns a $c\,S$ term into a $c\,\bar{s}$ term (a three-orders-of-magnitude
cut on a large document) and, crucially, removes the reconciliation crossover
so the win *grows* with document size instead of capping out. The risk is not
the mean case, which is comfortable, but the tail — one gigantic block — and
the adjacent projection cost, which no parsing trick addresses. Next step is
to instrument an actual reparse under `QUOIN_EDIT_PERF_LOG` and check whether
the measured $\bar{s}$ term matches $c\,S/n$ within a factor of two. If it
does, the model is trustworthy enough to design against.

[^bench]: Cold-vs-warm skew is why the performance suite discards the first
    three iterations of any parse benchmark and reports the median of the
    remaining runs, not the mean.

[^project]: Measured separately: table projection is roughly $O(\text{rows}
    \times \text{cols})$ in attributed-string construction, independent of how
    the table's source was parsed.
