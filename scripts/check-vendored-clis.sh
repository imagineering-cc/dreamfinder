#!/usr/bin/env bash
#
# CI drift guard for the vendored CLIs (cli-tools/*.mjs).
#
# Recomputes the SHA256 of each vendored file and compares against the committed
# manifest (cli-tools/.vendored-manifest.sha256). Fails if they differ.
#
# WHAT THIS CATCHES:
#   - Accidental in-repo edits to a vendored *.mjs (the file changed but nobody
#     updated the manifest).
#   - Tampering / merge mistakes that mutate a vendored file.
#   - A manifest update committed WITHOUT the corresponding file change.
#
# WHAT THIS CANNOT CATCH:
#   - Whether the CANONICAL upstream CLI (~/.claude/cli-tools/) has moved ahead.
#     The canonical copies live only on the dev machine and are NOT available in
#     CI, so freshness vs upstream is impossible to verify here. That drift is
#     resolved by running ./scripts/vendor-clis.sh on the dev machine (which
#     re-copies AND regenerates this manifest), then committing the result.
#
# Run locally: ./scripts/check-vendored-clis.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/cli-tools"
MANIFEST="$VENDOR_DIR/.vendored-manifest.sha256"

if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: manifest not found: $MANIFEST" >&2
  exit 1
fi

# `shasum -c` reads "<sha>  <relative-path>" lines and verifies each file.
# We cd into cli-tools so the relative paths in the manifest resolve.
cd "$VENDOR_DIR"
if shasum -a 256 -c "$(basename "$MANIFEST")"; then
  echo "Vendored CLIs match the committed manifest."
else
  cat >&2 <<'EOF'

Vendored CLI drift detected.

A file under cli-tools/ no longer matches cli-tools/.vendored-manifest.sha256.

If you intentionally changed a vendored CLI, re-vendor and regenerate the
manifest on your dev machine, then commit BOTH together:

    ./scripts/vendor-clis.sh
    git add cli-tools/

If you did NOT intend to change it, restore the file from the canonical copy
(or git) — the in-repo copy has drifted.
EOF
  exit 1
fi
