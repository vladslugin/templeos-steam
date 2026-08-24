#!/usr/bin/env bash
# Fetch the primary analysis object: the cia-foundation mirror of the final
# TempleOS 5.03 snapshot (public domain). Everything in analysis/ cites paths
# relative to vendor/TempleOS/.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/vendor"
if [ -d "$ROOT/vendor/TempleOS/.git" ]; then
  echo "vendor/TempleOS already present; pulling"
  git -C "$ROOT/vendor/TempleOS" pull --ff-only
else
  git clone --depth 1 https://github.com/cia-foundation/TempleOS.git "$ROOT/vendor/TempleOS"
fi
git -C "$ROOT/vendor/TempleOS" rev-parse HEAD > "$ROOT/vendor/TempleOS.commit"
echo "Pinned commit: $(cat "$ROOT/vendor/TempleOS.commit")"
