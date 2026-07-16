#!/usr/bin/env bash
set -euo pipefail

# Reproduce the Linux CI job locally via Docker. QuoinCore is platform-free
# and must build + test on Linux; QuoinRender compiles to a near-empty module
# (all AppKit/UIKit code is canImport-guarded). Wall-clock latency budgets and
# the Darwin-only file watcher self-skip off Darwin.
#
# Usage: scripts/test-linux.sh [swift-image]   (default: swift:6.2)

image="${1:-swift:6.2}"
root="$(cd "$(dirname "$0")/.." && pwd)"

exec docker run --rm -v "$root":/src -w /src "$image" bash -c '
  set -e
  swift --version
  swift build
  swift test
'
