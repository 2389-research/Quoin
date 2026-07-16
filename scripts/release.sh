#!/usr/bin/env bash
set -euo pipefail

# Quoin full release pipeline: notarize the app, then (re)generate the
# EdDSA-signed Sparkle appcast so existing installs can update to it.
#
# This is `notarize.sh` + appcast signing. Run it for every public build.
#
# Prerequisites (one-time — see docs/reference/distribution.md):
#   1. Apple Developer Program membership + a "Developer ID Application"
#      certificate in the login keychain.
#   2. Stored notary credentials:
#        xcrun notarytool store-credentials quoin-notary \
#          --apple-id YOU@example.com --team-id TEAMID
#   3. A Sparkle EdDSA key pair (Sparkle's `generate_keys` — private half in
#      the keychain, public half already in Info.plist as SUPublicEDKey).
#
# Usage:
#   scripts/release.sh "Developer ID Application: Clint Ecker (TEAMID)"
#
# Env:
#   QUOIN_APPCAST_BASE_URL  Download URL prefix the appcast points at
#                           (e.g. https://github.com/2389-research/Quoin/releases/latest/download).
#   SPARKLE_BIN             Directory holding Sparkle's `generate_appcast`
#                           tool (auto-discovered under DerivedData if unset).
#   SPARKLE_ED_KEY_FILE     Path to the exported EdDSA private key. Set in CI;
#                           when unset the key is read from the keychain.
#   SPARKLE_ACCOUNT         Keychain account holding the key (default Quoin);
#                           ignored when SPARKLE_ED_KEY_FILE is set.
#
# Notary auth + version stamping env is documented in notarize.sh
# (QUOIN_NOTARY_*, QUOIN_VERSION, QUOIN_BUILD) and passes straight through.
#
# Output: build/release/ containing Quoin-<version>.zip (notarized, stapled)
# and appcast.xml (EdDSA-signed). Upload BOTH to your release host.

identity="${1:?usage: release.sh \"Developer ID Application: … (TEAMID)\"}"
root="$(cd "$(dirname "$0")/.." && pwd)"
releases="$root/build/release"
appcast_base="${QUOIN_APPCAST_BASE_URL:-https://github.com/2389-research/Quoin/releases/latest/download}"

# 1. Archive → sign → notarize → staple → zip (delegates to notarize.sh).
"$root/scripts/notarize.sh" "$identity"

mkdir -p "$releases"
cp "$root"/build/notarized/Quoin-*.zip "$releases/"

# 2. Locate Sparkle's generate_appcast (shipped inside the SPM artifact).
generate_appcast="${SPARKLE_BIN:+$SPARKLE_BIN/generate_appcast}"
if [ -z "${generate_appcast:-}" ] || [ ! -x "$generate_appcast" ]; then
  generate_appcast="$(find ~/Library/Developer/Xcode/DerivedData \
    -name generate_appcast -type f -perm -111 2>/dev/null | head -1)"
fi
[ -x "$generate_appcast" ] || {
  echo "error: could not find Sparkle's generate_appcast." >&2
  echo "  Build the app once (so SPM fetches Sparkle) or set SPARKLE_BIN." >&2
  exit 1
}

# 3. Sign every archive in the folder and (re)write appcast.xml. The private
#    EdDSA key comes from a file in CI, from the keychain locally; the tool
#    refuses if it's missing.
echo "==> Generating EdDSA-signed appcast"
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
  "$generate_appcast" "$releases" --download-url-prefix "$appcast_base/" \
    --ed-key-file "$SPARKLE_ED_KEY_FILE"
else
  "$generate_appcast" "$releases" --download-url-prefix "$appcast_base/" \
    --account "${SPARKLE_ACCOUNT:-Quoin}"
fi

echo "DONE. Upload to $appcast_base :"
ls -1 "$releases"/*.zip "$releases"/appcast.xml
