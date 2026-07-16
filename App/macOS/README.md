# Quoin macOS app

The app target is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
so no `.xcodeproj` lives in git.

```sh
brew install xcodegen        # once
cd App/macOS
xcodegen                     # generates Quoin.xcodeproj
open Quoin.xcodeproj
```

The app links the `QuoinCore` and `QuoinRender` products from the Swift
package at the repository root. Document types are registered as a *viewer*
for markdown (`net.daringfireball.markdown`: .md, .markdown, .mdown, .mkd)
and plain text.

Sandboxed with user-selected file access; the read-write entitlement exists
solely for the byte-precise task-checkbox write-back.
