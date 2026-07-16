#!/usr/bin/env bash
set -euo pipefail

# Quoin direct-distribution pipeline: archive → Developer ID sign →
# notarize → staple → zip (launch ledger, DIRECT-distro consequences).
#
# Prerequisites (one-time):
#   1. A "Developer ID Application" certificate in the login keychain.
#   2. Stored notary credentials:
#        xcrun notarytool store-credentials quoin-notary \
#          --apple-id YOU@example.com --team-id TEAMID
#
# Usage:
#   scripts/notarize.sh "Developer ID Application: Clint Ecker (TEAMID)"
#
# Output: build/notarized/Quoin.app + Quoin-<version>.zip, stapled and
# Gatekeeper-clean (verified at the end).

identity="${1:?usage: notarize.sh \"Developer ID Application: … (TEAMID)\"}"
profile="${QUOIN_NOTARY_PROFILE:-quoin-notary}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/notarized"
archive="$out/Quoin.xcarchive"

rm -rf "$out"
mkdir -p "$out"

echo "==> Regenerating project + archiving (Release)"
(cd "$root/App/macOS" && xcodegen -q)
xcodebuild -project "$root/App/macOS/Quoin.xcodeproj" \
  -scheme Quoin -configuration Release \
  -archivePath "$archive" archive \
  CODE_SIGN_IDENTITY="$identity" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  | tail -2

app="$archive/Products/Applications/Quoin.app"
[ -d "$app" ] || { echo "error: archive produced no Quoin.app" >&2; exit 1; }
cp -R "$app" "$out/Quoin.app"
app="$out/Quoin.app"

echo "==> Verifying signature (hardened runtime required for notarization)"
codesign --verify --deep --strict "$app"
codesign -d --entitlements - "$app" >/dev/null

version="$(defaults read "$app/Contents/Info" CFBundleShortVersionString)"
zip="$out/Quoin-$version.zip"

echo "==> Submitting to the notary service"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait

echo "==> Stapling the ticket + re-zipping"
xcrun stapler staple "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$app"

echo "DONE: $zip"
