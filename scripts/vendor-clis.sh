#!/usr/bin/env bash
#
# Re-vendor the zero-dependency Node CLIs that Dreamfinder shells out to
# (kan.mjs, outline.mjs, radicale.mjs) FROM Nick's canonical copies at
# ~/.claude/cli-tools/,
# then regenerate the committed SHA256 manifest so the CI drift guard passes.
#
# Run this on the DEV MACHINE (the canonical CLIs are not in CI) whenever you
# change the canonical copy and want the change reflected here:
#
#     ./scripts/vendor-clis.sh
#
# Then commit BOTH the updated cli-tools/*.mjs AND cli-tools/.vendored-manifest.sha256
# in the same commit. Committing the manifest separately defeats the guard.
#
# See cli-tools/README.md for the provenance / "why CLIs not MCP" rationale.
set -euo pipefail

# Repo root = parent of this script's dir, so the script works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/cli-tools"
CANONICAL_ROOT="${CLAUDE_CLI_TOOLS:-$HOME/.claude/cli-tools}"
MANIFEST="$VENDOR_DIR/.vendored-manifest.sha256"

# Each entry: "<canonical-relative-path> <vendored-filename>". Add a line here
# to vendor a new CLI; the manifest + guard pick it up automatically.
VENDORED=(
  "kan/kan.mjs kan.mjs"
  "outline/outline.mjs outline.mjs"
  "radicale/radicale.mjs radicale.mjs"
)

echo "Vendoring CLIs from $CANONICAL_ROOT into $VENDOR_DIR"
for entry in "${VENDORED[@]}"; do
  # shellcheck disable=SC2086
  set -- $entry
  src="$CANONICAL_ROOT/$1"
  dst="$VENDOR_DIR/$2"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: canonical CLI not found: $src" >&2
    echo "       (set CLAUDE_CLI_TOOLS if your cli-tools live elsewhere)" >&2
    exit 1
  fi
  cp "$src" "$dst"
  echo "  copied $1 -> cli-tools/$2"
done

# Regenerate the manifest deterministically (sorted by vendored filename) so the
# committed file is stable regardless of array order.
echo "Regenerating manifest: cli-tools/.vendored-manifest.sha256"
(
  cd "$VENDOR_DIR"
  files=()
  for entry in "${VENDORED[@]}"; do
    # shellcheck disable=SC2086
    set -- $entry
    files+=("$2")
  done
  # shellcheck disable=SC2207
  IFS=$'\n' sorted=($(printf '%s\n' "${files[@]}" | sort))
  shasum -a 256 "${sorted[@]}"
) > "$MANIFEST"

echo "Done. Commit BOTH cli-tools/*.mjs and cli-tools/.vendored-manifest.sha256 together."
