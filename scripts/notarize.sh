#!/usr/bin/env bash
set -euo pipefail

# Quoin direct-distribution pipeline: archive → Developer ID sign →
# notarize → staple → zip + dmg (launch ledger, DIRECT-distro consequences).
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. Notary credentials, either stored locally:
#        xcrun notarytool store-credentials quoin-notary \
#          --apple-id YOU@example.com --team-id TEAMID
#      or passed as an App Store Connect API key (what CI does):
#        QUOIN_NOTARY_KEY      path to the AuthKey_*.p8 file
#        QUOIN_NOTARY_KEY_ID   the key's ID
#        QUOIN_NOTARY_ISSUER   the issuer UUID
#
# Usage:
#   scripts/notarize.sh "Developer ID Application: Clint Ecker (TEAMID)"
#
# Env:
#   QUOIN_NOTARY_PROFILE  keychain profile name (default quoin-notary);
#                         ignored when QUOIN_NOTARY_KEY is set.
#   QUOIN_VERSION         override CFBundleShortVersionString (CI stamps the
#                         git tag here; local builds keep project.yml's default).
#   QUOIN_BUILD           override CFBundleVersion. Sparkle compares this, so
#                         it must grow every release (CI uses the commit count).
#
# Output: build/notarized/Quoin.app + Quoin-<version>.zip (the Sparkle
# update archive) + Quoin-<version>.dmg (the drag-install download), all
# stapled and Gatekeeper-clean (verified at the end).

identity="${1:?usage: notarize.sh \"Developer ID Application: … (TEAMID)\"}"
profile="${QUOIN_NOTARY_PROFILE:-quoin-notary}"

# Submit one artifact to the notary service and wait for the verdict.
# notarytool --wait exits 0 even when the verdict is Invalid; gate on the
# printed status ourselves so the pipeline can't ship a rejected build.
notarize_file() {
  local file="$1" submit_out id
  if [ -n "${QUOIN_NOTARY_KEY:-}" ]; then
    submit_out=$(xcrun notarytool submit "$file" --wait \
      --key "$QUOIN_NOTARY_KEY" \
      --key-id "${QUOIN_NOTARY_KEY_ID:?QUOIN_NOTARY_KEY is set but QUOIN_NOTARY_KEY_ID is not}" \
      --issuer "${QUOIN_NOTARY_ISSUER:?QUOIN_NOTARY_KEY is set but QUOIN_NOTARY_ISSUER is not}" \
      | tee /dev/stderr)
  else
    submit_out=$(xcrun notarytool submit "$file" --keychain-profile "$profile" --wait \
      | tee /dev/stderr)
  fi
  if ! grep -q "status: Accepted" <<<"$submit_out"; then
    id=$(sed -n 's/^ *id: //p' <<<"$submit_out" | head -1)
    echo "error: notarization of ${file##*/} was not Accepted. Details:" >&2
    echo "  xcrun notarytool log $id <same auth flags>" >&2
    exit 1
  fi
}

version_args=()
[ -n "${QUOIN_VERSION:-}" ] && version_args+=("MARKETING_VERSION=$QUOIN_VERSION")
[ -n "${QUOIN_BUILD:-}" ] && version_args+=("CURRENT_PROJECT_VERSION=$QUOIN_BUILD")
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/notarized"
archive="$out/Quoin.xcarchive"

rm -rf "$out"
mkdir -p "$out"

echo "==> Regenerating project + archiving (Release)"
(cd "$root/App/macOS" && xcodegen -q)
# ${arr[@]+…} keeps the empty-array expansion safe under macOS bash 3.2's
# set -u.
xcodebuild -project "$root/App/macOS/Quoin.xcodeproj" \
  -scheme Quoin -configuration Release \
  -archivePath "$archive" archive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$identity" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  ${version_args[@]+"${version_args[@]}"} \
  | tail -2

app="$archive/Products/Applications/Quoin.app"
[ -d "$app" ] || { echo "error: archive produced no Quoin.app" >&2; exit 1; }
cp -R "$app" "$out/Quoin.app"
app="$out/Quoin.app"

# Sparkle ships its nested helpers pre-signed by the Sparkle team, and
# Xcode's embed-and-sign does NOT recurse into a binary framework — so they
# arrive without our Developer ID or a secure timestamp and the notary
# service rejects the whole app. Re-sign them exactly as Sparkle's
# sandboxing guide prescribes: helpers first (keeping their entitlements —
# Downloader.xpc's own sandbox depends on them), then the framework, then
# the app, whose signature seals the nested code it embeds.
echo "==> Re-signing Sparkle's nested helpers with our identity"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sv="$sparkle/Versions/Current"
for nested in "$sv/XPCServices/Downloader.xpc" "$sv/XPCServices/Installer.xpc" \
  "$sv/Autoupdate" "$sv/Updater.app"; do
  [ -e "$nested" ] || { echo "error: expected Sparkle helper missing: $nested" >&2; exit 1; }
  codesign --force --options runtime --timestamp \
    --preserve-metadata=entitlements --sign "$identity" "$nested"
done
codesign --force --options runtime --timestamp --sign "$identity" "$sparkle"
codesign --force --options runtime --timestamp \
  --preserve-metadata=entitlements --sign "$identity" "$app"

echo "==> Verifying signature (hardened runtime required for notarization)"
codesign --verify --deep --strict "$app"
codesign -d --entitlements - "$app" >/dev/null

version="$(defaults read "$app/Contents/Info" CFBundleShortVersionString)"
zip="$out/Quoin-$version.zip"

echo "==> Submitting the app to the notary service"
ditto -c -k --keepParent "$app" "$zip"
notarize_file "$zip"

echo "==> Stapling the ticket + re-zipping"
xcrun stapler staple "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

# The zip is what Sparkle serves; humans get a drag-install DMG. Built from
# the already-stapled app, but the image itself still needs its own
# signature, notarization, and staple — Gatekeeper assesses the downloaded
# container, not just the app inside.
echo "==> Building the drag-install DMG"
dmg="$out/Quoin-$version.dmg"
staging="$out/dmg-staging"
rm -rf "$staging"
mkdir "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Quoin" -srcfolder "$staging" -ov -quiet -format UDZO "$dmg"
rm -rf "$staging"
codesign --force --timestamp --sign "$identity" "$dmg"

echo "==> Submitting the DMG to the notary service"
notarize_file "$dmg"
xcrun stapler staple "$dmg"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$app"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

echo "DONE: $zip + $dmg"
