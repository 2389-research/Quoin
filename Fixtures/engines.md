# Native Engines

Inline math like $e^{i\pi} + 1 = 0$ and $\alpha \leq \sum x_i^2$ sits in the text.

$$
\int_0^1 x^2 \, dx = \frac{1}{3}
$$

```mermaid
graph LR
    A[Parse] --> B{Supported?}
    B -->|yes| C(Layout)
    B -->|no| D[Fallback]
    C --> E((Draw))
```

```mermaid
sequenceDiagram
    participant E as Editor
    participant S as Session
    E->>S: apply edit
    S->>S: re-parse
    S-->>E: new snapshot
```

Display-style operators take their limits above and below:

$$
\sum_{i=1}^{n} i = \frac{n(n+1)}{2}
$$

```mermaid
pie title Engine coverage
    "Flowchart" : 40
    "Sequence" : 35
    "Pie" : 25
```
