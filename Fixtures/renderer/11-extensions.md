# Non-standard Extensions

> Admonition fences, attribute syntax, wiki links/embeds, GitHub conveniences — mostly should degrade to plain text.

### 13.4 Admonition Fence Extension

:::note
This `:::note` container syntax is supported by some systems, such as certain Markdown-it configurations and documentation generators.
:::

:::warning
Unsupported renderers should display these lines as ordinary paragraphs.
:::

### 13.5 Attributes Extension

![Image with attribute syntax](https://placehold.co/220x80/png?text=Attr){width=220 height=80 .thumbnail #fixture-image}

A paragraph with attributes after it.
{#paragraph-id .lead data-fixture="attributes"}

### 13.6 Wiki Links and Embeds

- Wiki link: [[Renderer Fixture]]
- Wiki link with alias: [[Renderer Fixture|human-readable alias]]
- Embedded note: ![[diagram.png]]

### 13.7 GitHub Conveniences

- Mention-like text: @octocat
- Issue-like text: #123
- Pull request-like text: GH-456
- Commit-like SHA: 0123456789abcdef0123456789abcdef01234567
- Emoji shortcode: :tada:

---

