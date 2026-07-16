# Automating App Store releases from GitHub Actions

A forward-looking guide for a **future** project that ships through the **Mac
App Store (MAS)** or the **iOS App Store**, rather than Quoin's current model.
Quoin distributes a **Developer ID**-signed, **notarized** app *outside* the
store and self-updates via **Sparkle** (see [distribution.md](distribution.md)).
The App Store is a different pipeline end to end — this doc maps the differences
and gives a working CI recipe. Nothing here is wired into Quoin today.

## How App Store distribution differs from what Quoin does now

| | Quoin today (Developer ID) | App Store (MAS / iOS) |
| --- | --- | --- |
| Signing identity | `Developer ID Application` | `Apple Distribution` (+ an App Store provisioning profile) |
| Gatekeeper step | `notarytool` notarize + `stapler` staple | none — the store signs the final binary |
| Delivery | attach `.dmg`/`.zip` to a GitHub Release | **upload** the archive to App Store Connect |
| Updates | Sparkle appcast (EdDSA-signed) | the store's own update mechanism |
| Human gate | none | **App Review** (hours–days) |
| Sandbox | not required | **required** for MAS (`com.apple.security.app-sandbox`) |
| Artifact | `.app` in a `.dmg` | `.pkg` (macOS) / `.ipa` (iOS) |

Two consequences worth internalizing before committing to the store:

- **`notarytool` is NOT part of the App Store path.** Notarization is only for
  software distributed outside the store; the App Store notarizes server-side.
  (`altool` was removed from *notarization* on 2023-11-01 — migrate any
  notarizing to `notarytool` — but `altool` still *uploads to the store*.)
- **Review can't be fully automated.** You can automate build → upload →
  *submit for review* → *auto-release after approval* / phased release, but a
  human reviews it in between. Plan releases around that latency.

## One-time provisioning (human, done once in App Store Connect)

1. **App record** in App Store Connect with the app's bundle id, name, primary
   language, category, price tier.
2. An **App Store Connect API key** (Users and Access → Integrations → App Store
   Connect API): note the **Issuer ID**, the **Key ID**, and download the
   `AuthKey_<KEYID>.p8` **once** (it can't be re-downloaded). This is the CI
   credential for both signing and upload — no Apple ID password / 2FA in CI.
3. **Signing.** Two viable strategies:
   - **Cloud-managed (recommended for CI simplicity):** let Xcode create and
     manage the `Apple Distribution` cert + App Store profile, and in CI pass
     `-allowProvisioningUpdates` with the API key so `xcodebuild` fetches/renews
     them headlessly. No profiles to store.
   - **fastlane `match`:** store the distribution cert + profiles encrypted in a
     private git repo; CI decrypts them into an ephemeral keychain. More setup,
     but fully reproducible and team-shareable.
4. **Metadata + screenshots** live in App Store Connect (or as files under
   `fastlane/metadata` + `fastlane/screenshots` if you use `deliver`).

## The pipeline, in five steps

```
archive (App Store method)  →  export .pkg/.ipa  →  upload to App Store Connect
   →  (optional) submit for review  →  (optional) auto-release / phased release
```

### Path A — fastlane (recommended)

fastlane is the de-facto standard and hides most of the sharp edges.

`fastlane/Fastfile` (macOS example):

```ruby
lane :release do
  api_key = app_store_connect_api_key(
    key_id: ENV["ASC_KEY_ID"],
    issuer_id: ENV["ASC_ISSUER_ID"],
    key_content: ENV["ASC_KEY_P8"],   # the .p8 contents, base64 or raw
  )
  sync_code_signing(type: "appstore", api_key: api_key)  # match; or use cloud signing
  build_mac_app(                                          # gym: archive + export
    scheme: "MyApp",
    export_method: "app-store",
  )
  upload_to_app_store(                                    # deliver: binary + metadata
    api_key: api_key,
    submit_for_review: true,
    automatic_release: true,        # release once Apple approves
    precheck_include_in_app_purchases: false,
    force: true,                    # skip the HTML preview in CI
  )
end
```

For iOS, swap `build_mac_app` → `build_app` and add `pilot`/`upload_to_testflight`
for beta builds. `precheck` catches metadata rejections before upload.

### Path B — Apple-native (`xcodebuild` + `altool`)

No fastlane; useful when you want to understand every step or minimize deps.

```sh
# 1. Archive with App Store signing (cloud-managed profiles via the API key)
xcodebuild -project MyApp.xcodeproj -scheme MyApp -configuration Release \
  -archivePath build/MyApp.xcarchive archive \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$RUNNER_TEMP/AuthKey.p8" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

# 2. Export a store-ready package (ExportOptions.plist below)
xcodebuild -exportArchive -archivePath build/MyApp.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$RUNNER_TEMP/AuthKey.p8" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

# 3. Upload to App Store Connect (still supported; App Store Connect API auth)
xcrun altool --upload-app -f build/export/MyApp.pkg -t macos \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
# (Transporter's iTMSTransporter is the alternative uploader.)
```

`ExportOptions.plist`:

```xml
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>   <!-- export can upload directly -->
  <key>teamID</key><string>ABCDE12345</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
```

Submit-for-review and auto-release in Path B go through the **App Store Connect
API** directly (create a new App Store Version, attach the build, POST a review
submission) — which is exactly the machinery fastlane's `deliver` wraps, so Path
A is usually less code for the same result.

## GitHub Actions workflow sketch

Mirrors Quoin's `release.yml` shape (tag-driven, ephemeral keychain, secrets
supply credentials). The API `.p8` replaces Quoin's Developer ID `.p12` +
notary key.

```yaml
name: App Store Release
on:
  push:
    tags: ["v*"]
jobs:
  appstore:
    runs-on: macos-15
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v7
        with: { fetch-depth: 0 }          # build number from commit count
      - run: sudo xcode-select -s "$(ls -d /Applications/Xcode_*.app | sort -V | tail -1)"

      - name: App Store Connect API key
        run: |
          umask 077
          printf '%s' "${{ secrets.ASC_KEY_P8 }}" | base64 -d > "$RUNNER_TEMP/AuthKey.p8"

      - name: Build, export, upload
        env:
          ASC_KEY_ID:    ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
        run: |
          export ASC_KEY_P8="$(cat "$RUNNER_TEMP/AuthKey.p8")"
          bundle exec fastlane release        # Path A
          # …or the three xcodebuild/altool commands from Path B
```

For **fastlane `match`** signing (Path A variant), add a step that checks out
the encrypted certs repo and set `MATCH_PASSWORD` + `MATCH_GIT_BASIC_AUTHORIZATION`
secrets; for **cloud-managed** signing, the API key alone is enough thanks to
`-allowProvisioningUpdates`.

## What is and isn't automatable

- **Automatable:** archive, export, code signing (cloud or match), binary
  upload, TestFlight distribution, metadata + screenshot upload, *submitting for
  review*, and *automatic release after approval* (or phased/manual release).
- **Not automatable:** Apple's **App Review** itself (human, hours–days), and
  the first-ever setup of the app record, agreements, tax/banking.
- **Version/build numbers:** the store requires **monotonically increasing**
  `CFBundleVersion` per upload — Quoin already derives it from the commit count
  (`git rev-list --count HEAD`), which ports directly.

## If Quoin itself ever went to the Mac App Store

It would mean, concretely: add the **app-sandbox** entitlement (and audit file
access — the security-scoped bookmarks Quoin already uses are MAS-friendly);
switch the signing identity and export method; **drop Sparkle** (the store owns
updates — `SoftwareUpdater`/appcast/`SUPublicEDKey` would compile out for the MAS
target); and replace the notarize+DMG+GitHub-Release tail of `release.sh` with an
export+upload. The build/version-stamping front half (`xcodegen` + `xcodebuild`
+ tag-derived `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`) is reusable as-is.
Shipping **both** (Developer ID direct download *and* MAS) is common and means
two export/sign/deliver tails over one shared archive.

## Secrets checklist (repo → Settings → Secrets)

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key id |
| `ASC_ISSUER_ID` | App Store Connect issuer UUID |
| `ASC_KEY_P8` | the `AuthKey_*.p8` contents (base64) |
| `MATCH_PASSWORD` | *(match only)* passphrase for the encrypted certs repo |
| `MATCH_GIT_BASIC_AUTHORIZATION` | *(match only)* token to read that repo |

## Sources

- [Apple — Upload builds (App Store Connect Help)](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Apple TN3147 — Migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [`altool(1)` man page](https://keith.github.io/xcode-man-pages/altool.1.html)
- [fastlane discussion — altool deprecation](https://github.com/fastlane/fastlane/discussions/21347)
