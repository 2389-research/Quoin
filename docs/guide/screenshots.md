# Screenshot manifest

Quoin's screenshots are **automated**, not hand-captured. Every push to
`main` runs the `ScreenshotTests` UI-test bundle
(`App/macOS/UITests/ScreenshotTests.swift`) on the CI macOS runner
(`.github/workflows/ci.yml`, the *Capture screenshots* step). The bundle
launches the real app against the fixture library and writes one PNG per
state to `$QUOIN_SCREENSHOT_DIR`; CI uploads them as the `screenshots`
artifact **and** force-pushes them to the `ci-screenshots` branch (fetchable
anywhere the repo is). This file is the durable record of what each shot is,
how it is produced, and where — if anywhere — its curated copy lives under
`docs/images/`.

## How a shot is produced

Chrome and feature surfaces are preset by **launch arguments**, never by
synthetic keyboard events (flaky on headless runners):

- `-QuoinLibraryPath <dir>` — point the app at the fixture library. CI copies
  `Fixtures/*.md` into `/tmp/quoin-fixtures` first, so every fixture below is
  available by name.
- `-QuoinShotOpen <name.md>` — open a library file at launch.
- `-QuoinShotState <state>` — preset a specific chrome/feature state
  (see the state table). Review/properties/footnote/code states open their
  own default fixture when `-QuoinShotOpen` is omitted, so a single
  `-QuoinShotState review` is enough to drive them.
- `-QuoinForceDarkMode YES` — render in dark appearance.
- `-QuoinCodeTheme <id>` — select a code-block syntax theme (argument-domain
  only, so it does not persist). Valid ids live in `CodePalette.registry`
  (`Sources/QuoinRender/Theme.swift`): `graphite`, `one-dark`, `dracula`,
  `github-dark`, `solarized-dark`, `nord`, `tokyo-night`, `catppuccin-mocha`,
  `one-light`, `github-light`, `solarized-light`, `catppuccin-latte`, or
  `match` (follows the app appearance).

`-QuoinShotState` is dispatched in two places by ownership:

- **Window chrome** (`App/macOS/Sources/MainWindow.swift`, `applyShotState`):
  `quickopen`, `libsearch`, plus the default-fixture routing
  (`defaultShotFixture`).
- **Editor chrome** (`App/macOS/Sources/ReaderScreen.swift`, the
  `QuoinShotState` switch in `windowChrome`): `find`, `export`,
  `mermaidResilience`, `codeEdit`, and the new `review`, `properties`,
  `reviewmode`, `codethemes`, `footnotes`.

## `-QuoinShotState` values

| State | Fixture (default) | Presets |
| --- | --- | --- |
| `find` | `engines.md`* | Find bar open, query `math` |
| `export` | `engines.md`* | Export sheet presented |
| `quickopen` | — | Quick-open panel, query `show`, results run |
| `libsearch` | — | Library-search panel, query `engine`, results run |
| `mermaidResilience` | (opened doc)* | Self-drives break/fix of a mermaid header (diagnostic) |
| `codeEdit` | `showcase.md`* | Activates first code block + types (diagnostic) |
| `review` | `demo-product-spec.md` | Review inspector on a real spec under review (suggestion + comment cards) |
| `properties` | `demo-daily-note.md` | Properties inspector on a note with rich front matter (typed fields) |
| `reviewmode` | `demo-product-spec.md` | `SUGGESTING` status chip active + Review inspector |
| `codethemes` | `demo-research-note.md` | Scrolls first code block into view (pair with `-QuoinCodeTheme`) |
| `footnotes` | `demo-research-note.md` | Scrolls first footnote reference into view |

\* States marked with an asterisk are driven with an explicit
`-QuoinShotOpen` in the UI test; the others fall back to
`MainWindow.defaultShotFixture`.

## Shot catalogue

Every PNG the bundle writes. **Committed path** is the curated copy under
`docs/images/` that README/PRODUCT reference (blank = artifact/CI-branch
only, not committed).

| Shot (PNG) | Launch args (beyond `-QuoinLibraryPath`) | Shows | Committed path / used by |
| --- | --- | --- | --- |
| `01-library` | (none) | Library sidebar, empty detail | — |
| `02-document` | click `showcase` | Rendered showcase document | — |
| `03-native-engines` | click `engines` | Math + diagram first viewport | — |
| `04-structure-diagrams` | click `structure` | State / class / ER diagrams | — |
| `05-dark-document` | `-QuoinForceDarkMode YES` | Showcase, dark appearance | — |
| `06-dark-engines` | `-QuoinForceDarkMode YES` | Engines, dark appearance | — |
| `07-syntax-reveal` | click into body | Active-block source reveal | — |
| `07-syntax-reveal-dark` | click into body, `-QuoinForceDarkMode YES` | Active-block source reveal, dark | `docs/images/syntax-reveal-dark.png` — site |
| `08-find-bar` | `-QuoinShotOpen engines.md -QuoinShotState find` | Find bar + match count | — |
| `09-export-sheet` | `-QuoinShotOpen engines.md -QuoinShotState export` | Export (MD/HTML/PDF) sheet | — |
| `10-quick-open` | `-QuoinShotState quickopen` | Quick-open panel with results | — |
| `11-library-search` | `-QuoinShotState libsearch` | Library full-text search | — |
| `12-gallery-diagrams` | `-QuoinShotOpen gallery-diagrams.md` | Diagram gallery | `docs/images/gallery-diagrams.png` — README |
| `12-gallery-diagrams-dark` | `-QuoinShotOpen gallery-diagrams.md -QuoinForceDarkMode YES` | Diagram gallery, dark | `docs/images/gallery-diagrams-dark.png` — site |
| `13-gallery-math` | `-QuoinShotOpen gallery-math.md` | Math gallery | `docs/images/gallery-math.png` — README |
| `13-gallery-math-dark` | `-QuoinShotOpen gallery-math.md -QuoinForceDarkMode YES` | Math gallery, dark | `docs/images/gallery-math-dark.png` — site |
| `14-gallery-blocks` | `-QuoinShotOpen gallery-blocks.md` | Blocks / callouts / tables | `docs/images/gallery-blocks.png` — README |
| `15-review-panel` | `-QuoinShotState review` | Review inspector: suggestion + comment cards (21-suggestion fixture) | `docs/images/review-panel.png` — README, PRODUCT |
| `15-review-panel-dark` | `-QuoinShotState review -QuoinForceDarkMode YES` | Review inspector, dark appearance | `docs/images/review-panel-dark.png` — README |
| `16-properties-panel` | `-QuoinShotState properties` | Properties inspector (front-matter fields) | `docs/images/properties-panel.png` — README, PRODUCT |
| `17-review-mode` | `-QuoinShotState reviewmode` | `SUGGESTING` status chip active | `docs/images/review-mode.png` — README, PRODUCT |
| `18-code-theme` | `-QuoinShotState codethemes -QuoinCodeTheme dracula` | Code block in a selectable syntax theme | `docs/images/code-theme.png` — README |
| `18b-code-theme-light` | `-QuoinShotState codethemes -QuoinCodeTheme github-light` | Code block in a light syntax theme | `docs/images/code-theme-light.png` — README |
| `19-footnotes` | `-QuoinShotState footnotes` | Footnote reference marker | `docs/images/footnotes.png` — README |
| `20-code-editing` | `-QuoinShotOpen showcase.md -QuoinShotState codeEdit` | Active code-block editing (diagnostic) | — |
| `21-code-editing-settled` | same, +1.5s | Settled code-block editing (diagnostic) | — |

Hand-curated images not sourced from a single shot (composed/exported
separately): `docs/images/hero.png`,
`docs/images/architecture-overview.png` (+`-dark`),
`docs/images/data-flow.png` (+`-dark`).

## Updating a committed image

1. Trigger CI (push) or run the bundle locally:
   ```sh
   cd App/macOS && xcodegen
   mkdir -p /tmp/quoin-fixtures && cp ../../Fixtures/*.md /tmp/quoin-fixtures/
   TEST_RUNNER_QUOIN_SCREENSHOT_DIR=/tmp/quoin-shots \
   TEST_RUNNER_QUOIN_FIXTURES=/tmp/quoin-fixtures \
   xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug \
     CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" test
   ```
   (or `git fetch origin ci-screenshots` after a push to `main`).
2. Copy the shot(s) you want to publish into `docs/images/` under the
   **committed path** named above, and commit them.

Never commit a placeholder PNG: a broken image link is worse than a missing
one. Only add an image to `docs/` once the real pixels exist.
