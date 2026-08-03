#!/usr/bin/env bash
#
# Deploy Dreamfinder with correct build-time version stamping.
#
# WHY THIS SCRIPT EXISTS: docker-compose.yml passes three build args from the
# host environment — VERSION, GIT_COMMIT, BUILD_TIME — into the Dockerfile,
# which bakes them into lib/src/config/version.dart (and thence into
# /health.commit). If those env vars are unset at `docker compose build` time,
# compose falls back to the literal defaults `dev` / `local` / `unknown`, and
# prod reports commit "local" — you can no longer tell which commit is live.
#
# The old runbook told operators to `export BUILD_VERSION=… BUILD_SHA=…`, but
# compose reads ${VERSION} and ${GIT_COMMIT} — a name mismatch that silently
# left every hand-built image un-stamped. This script is the stamped entrypoint:
# it sets exactly the names compose reads, computed from git, and asserts compose
# resolved them before building. SCOPE (proven, not overclaimed): running THIS
# script always stamps correctly; a bare `docker compose build` still produces a
# `dev+local` image — that unsafe path is not removed, only made avoidable. Deploy
# via this script, not bare compose.
#
# The tell that stamping is broken: `/health` shows version "dev+local".
#
# Usage (from the directory containing docker-compose.yml):
#     ./scripts/deploy.sh
#
# On the prod box the git checkout lives in a `src/` subdir alongside the
# compose file, so point the script at it:
#     SRC_DIR=src ./src/scripts/deploy.sh
#
set -euo pipefail

# Where the git checkout lives (default: current dir; prod: ./src).
SRC_DIR="${SRC_DIR:-.}"
# Where docker-compose.yml lives (default: current dir).
COMPOSE_DIR="${COMPOSE_DIR:-.}"
# Compose service to build/recreate.
SERVICE="${SERVICE:-bot}"

if ! git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: $SRC_DIR is not a git checkout — cannot compute a commit stamp." >&2
  echo "       Set SRC_DIR to the Dreamfinder source tree." >&2
  exit 1
fi

# jq is a hard dependency of the pre-build stamp assertion (structured, scoped,
# exact — see below). Fail loudly here rather than letting a missing jq surface
# downstream as a misleading "stamp desync" (empty RESOLVED_SHA). Docker + jq are
# the tool contract for this script.
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not found — required for the pre-build stamp assertion." >&2
  echo "       Install jq (e.g. 'apt-get install jq' / 'brew install jq') and re-run." >&2
  exit 1
fi

if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  echo "ERROR: no docker-compose.yml in COMPOSE_DIR=$COMPOSE_DIR." >&2
  echo "       Run from the compose directory, or set COMPOSE_DIR to it." >&2
  exit 1
fi

# Compute the stamp, THEN export — assigning first and exporting the finished
# names on one line closes the export-before-assignment footgun (a command
# inserted between a bare `export VERSION` and its later assignment would leak a
# stale caller-provided VERSION into compose).
#
# `--dirty`: prod checkouts get hot-patched out-of-band (see the deployment
# notes / "prod snowflake" lesson), so a clean HEAD short-SHA can misreport a
# tree that actually carries uncommitted edits. `--dirty` appends a suffix so
# /health.commit stays HONEST about what was really built — the whole point of
# stamping is that the observable commit conserves information about the artifact.
DIRTY=""
git -C "$SRC_DIR" diff --quiet 2>/dev/null && git -C "$SRC_DIR" diff --cached --quiet 2>/dev/null || DIRTY="-dirty"
[ -n "$DIRTY" ] && echo "WARNING: $SRC_DIR has uncommitted changes — stamping as '-dirty' so /health is honest." >&2
VERSION="$(git -C "$SRC_DIR" describe --tags --always --dirty 2>/dev/null || echo dev)"
GIT_COMMIT="$(git -C "$SRC_DIR" rev-parse --short HEAD)${DIRTY}"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Compose reads exactly these three names (see docker-compose.yml build.args).
export VERSION GIT_COMMIT BUILD_TIME

echo "Deploying $SERVICE"
echo "  VERSION=$VERSION"
echo "  GIT_COMMIT=$GIT_COMMIT"
echo "  BUILD_TIME=$BUILD_TIME"

cd "$COMPOSE_DIR"

# Trust → measurement: prove compose actually resolved GIT_COMMIT into the build
# args of the SELECTED service BEFORE building, so a name/context desync (compose
# reading a different var, or a build context that doesn't see our exports) fails
# closed here instead of silently baking a `local` stamp.
#
# The check is a SCOPED, EXACT equality — `.services[$SERVICE].build.args.BUILD_SHA`
# must EQUAL $GIT_COMMIT. An earlier revision grepped the whole rendered project for
# `BUILD_SHA: <sha>`: unscoped (any other service matching passed a broken `bot`)
# and a prefix match (`f065eb0` satisfied `f065eb0deadbeef`). The structured jq path
# closes both holes. Stderr is captured and shown on failure so a compose error
# isn't hidden behind the stamp-desync story.
CONFIG_ERR="$(mktemp)"
RESOLVED_SHA="$(docker compose config --format json 2>"$CONFIG_ERR" \
  | jq -r --arg s "$SERVICE" '.services[$s].build.args.BUILD_SHA // ""' 2>/dev/null || true)"
if [ "$RESOLVED_SHA" != "$GIT_COMMIT" ]; then
  echo "ERROR: compose build arg BUILD_SHA for service '$SERVICE' resolved to" >&2
  echo "       '${RESOLVED_SHA:-<empty/unparseable>}', expected '$GIT_COMMIT' — the stamp" >&2
  echo "       would NOT land. Compose isn't reading \$GIT_COMMIT for this service/context." >&2
  [ -s "$CONFIG_ERR" ] && { echo "       docker compose config stderr:" >&2; sed 's/^/         /' "$CONFIG_ERR" >&2; }
  echo "       Inspect: docker compose config --format json | jq '.services.$SERVICE.build.args'" >&2
  rm -f "$CONFIG_ERR"
  exit 1
fi
rm -f "$CONFIG_ERR"

docker compose build "$SERVICE"
docker compose up -d --force-recreate "$SERVICE"

# The terminal observable is "prod reports this commit", not "compose exited 0".
# Poll /health, compare the reported commit, and — because a soft check that always
# exits 0 can't gate automation or a glance at $? — under STRICT_HEALTH (default on)
# BOTH a confirmed persistent mismatch AND a never-reachable endpoint FAIL non-zero:
# "couldn't verify the one thing this script exists to verify" is not a free green.
# A single early mismatch is NOT fatal — during --force-recreate the old container
# can still be bound, so we keep polling and only fail if the WRONG commit persists.
# Opt-outs: STRICT_HEALTH=0 downgrades everything to a warning; if health binds only
# on a private interface, point HEALTH_URL at it, or set ALLOW_UNVERIFIED_HEALTH=1 to
# treat *unreachable* (but not mismatch) as a warning.
HEALTH_URL="${HEALTH_URL:-http://localhost:8081/health}"
STRICT_HEALTH="${STRICT_HEALTH:-1}"
ALLOW_UNVERIFIED_HEALTH="${ALLOW_UNVERIFIED_HEALTH:-0}"
echo
echo "Verifying the stamp at $HEALTH_URL (expect commit=$GIT_COMMIT)..."
last_reported=""
for _i in $(seq 1 12); do
  body="$(curl -fs "$HEALTH_URL" 2>/dev/null || true)"
  if [ -n "$body" ]; then
    # jq only — it's a hard dependency (checked at startup) and the handler emits a
    # JSON object with a "commit" field. A body that doesn't parse as JSON with a
    # commit is a fault, not a shape to tolerate: `reported` stays empty and we keep
    # polling / eventually fail, rather than a grep fallback papering over broken JSON.
    reported="$(printf '%s' "$body" | jq -r '.commit // empty' 2>/dev/null || true)"
    if [ -n "$reported" ]; then
      last_reported="$reported"
      if [ "$reported" = "$GIT_COMMIT" ]; then
        echo "  OK — /health reports commit=$reported."
        exit 0
      fi
      # Wrong commit — keep polling; the recreate may still be swapping containers.
    fi
  fi
  sleep 5
done

if [ -n "$last_reported" ]; then
  echo "  MISMATCH — /health still reports commit=$last_reported, expected $GIT_COMMIT" >&2
  echo "             after all polls. The new container did not take, or the stamp did" >&2
  echo "             not land. Investigate before trusting this deploy." >&2
  [ "$STRICT_HEALTH" = "1" ] && exit 1
  echo "  (STRICT_HEALTH=0 — downgrading mismatch to a warning.)" >&2
  exit 0
fi
echo "  UNVERIFIED — /health at $HEALTH_URL never became reachable (wrong port/bind," >&2
echo "               or still starting). Could NOT confirm the stamp landed." >&2
echo "               Verify manually: curl -s $HEALTH_URL | jq .commit" >&2
if [ "$STRICT_HEALTH" = "1" ] && [ "$ALLOW_UNVERIFIED_HEALTH" != "1" ]; then
  echo "               Failing (STRICT_HEALTH=1). Set HEALTH_URL to the real endpoint," >&2
  echo "               or ALLOW_UNVERIFIED_HEALTH=1 (private bind) / STRICT_HEALTH=0 to allow." >&2
  exit 1
fi
echo "               (Not failing — STRICT_HEALTH=$STRICT_HEALTH ALLOW_UNVERIFIED_HEALTH=$ALLOW_UNVERIFIED_HEALTH.)" >&2
