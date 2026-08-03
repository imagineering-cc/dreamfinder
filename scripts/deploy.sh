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

# Tool contract: jq (pre-build stamp assertion) and curl (post-deploy /health
# check) are hard dependencies. Fail loudly HERE rather than letting a missing tool
# surface downstream as a misdiagnosis — a missing jq as a bogus "stamp desync", a
# missing curl as an empty /health body that STRICT_HEALTH reports as "wrong port /
# still starting" (sending the operator to fix the wrong thing at 2am).
for _tool in jq curl; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    echo "ERROR: $_tool not found — required by this script (jq: stamp assertion; curl: /health check)." >&2
    echo "       Install it (e.g. 'apt-get install $_tool' / 'brew install $_tool') and re-run." >&2
    exit 1
  fi
done

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
# `-dirty`: prod checkouts get hot-patched out-of-band (see the deployment notes /
# "prod snowflake" lesson), so a clean HEAD short-SHA can misreport a tree that
# actually carries edits. We use `git status --porcelain` (NOT just `git diff`),
# because the Docker build context also ships UNTRACKED files unless .dockerignore
# excludes them — a new untracked file changes the artifact but is invisible to
# `git diff`. Any porcelain output → dirty. The `-dirty` suffix keeps /health.commit
# HONEST about what was really built. NOTE: consumers of `commit` must tolerate a
# `<short-sha>-dirty` value, not assume hex-only (health compare here is exact string,
# so it's fine; a hex-only dashboard/label would need to strip the suffix).
DIRTY=""
[ -n "$(git -C "$SRC_DIR" status --porcelain 2>/dev/null)" ] && DIRTY="-dirty"
[ -n "$DIRTY" ] && echo "WARNING: $SRC_DIR has uncommitted or untracked changes — stamping as '-dirty' so /health is honest." >&2
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

# Trust → measurement: prove compose actually reads OUR exports into the build args
# of the SELECTED service BEFORE building, so a name/context desync fails closed here
# instead of silently baking a `dev+local` stamp.
#
# The original defect was a MULTI-name mismatch, so assert ALL THREE legs, not just
# BUILD_SHA — a future compose drift on BUILD_VERSION or BUILD_TIME would otherwise
# green-build. Each is a SCOPED, EXACT equality on `.services[$SERVICE].build.args.*`
# (an earlier revision grepped the whole rendered project: unscoped — any service
# matching passed a broken `bot` — and a prefix match — `f065eb0` satisfied
# `f065eb0deadbeef`; the structured jq path closes both). Claim hygiene: this proves
# compose PASSES the exports into the model — the *baked* artifact is confirmed later
# by the /health gate, which is the real terminal check.
CONFIG_ERR="$(mktemp)"
CONFIG_JSON="$(docker compose config --format json 2>"$CONFIG_ERR" || true)"
assert_arg() {  # $1=arg name  $2=expected value
  local got
  got="$(printf '%s' "$CONFIG_JSON" | jq -r --arg s "$SERVICE" --arg k "$1" '.services[$s].build.args[$k] // ""' 2>/dev/null || true)"
  if [ "$got" != "$2" ]; then
    echo "ERROR: compose build arg $1 for service '$SERVICE' resolved to" >&2
    echo "       '${got:-<empty/unparseable>}', expected '$2' — compose is NOT passing" >&2
    echo "       our exports into this service/context; the stamp would be wrong." >&2
    [ -s "$CONFIG_ERR" ] && { echo "       docker compose config stderr:" >&2; sed 's/^/         /' "$CONFIG_ERR" >&2; }
    echo "       Inspect: docker compose config --format json | jq '.services.$SERVICE.build.args'" >&2
    rm -f "$CONFIG_ERR"
    exit 1
  fi
}
assert_arg BUILD_SHA "$GIT_COMMIT"
assert_arg BUILD_VERSION "$VERSION"
assert_arg BUILD_TIME "$BUILD_TIME"
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
# Acceptance window = HEALTH_RETRIES × HEALTH_INTERVAL (default 12 × 5s = 60s).
# A tired VPS doing a slow image load / migration may need a wider window — raise
# these rather than reaching for STRICT_HEALTH=0 (which blinds the check entirely).
HEALTH_RETRIES="${HEALTH_RETRIES:-12}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"
echo
echo "Verifying the stamp at $HEALTH_URL (expect commit=$GIT_COMMIT; window ${HEALTH_RETRIES}x${HEALTH_INTERVAL}s)..."
last_reported=""
for _i in $(seq 1 "$HEALTH_RETRIES"); do
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
  sleep "$HEALTH_INTERVAL"
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
