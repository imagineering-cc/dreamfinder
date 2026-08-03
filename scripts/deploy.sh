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
# resolved them before building.
#
# The un-stamped path is now closed AT THE MUTATOR too: the Dockerfile FAILS a
# build whose BUILD_SHA is the `local` default unless ALLOW_UNSTAMPED=1, so a bare
# `docker compose build` / `up -d --build` can no longer silently ship a lying
# `dev+local` prod image (compose keeps soft defaults so `logs`/`restart`/`ps`
# still work — a `${VAR:?}` there would break them). This script simply supplies a
# real stamp, so it always passes that guard.
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

# Tool contract: jq (host-side, for the pre-build stamp assertion) is a hard
# dependency. Fail loudly HERE rather than letting a missing jq surface downstream as
# a bogus "stamp desync". (curl is used only INSIDE the container for the /health
# check, where the runtime image already provides it — no host curl needed.)
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

# Canonicalize BOTH to absolute paths ONCE, up front, before any `cd`. A relative
# SRC_DIR would otherwise re-bind under COMPOSE_DIR after the `cd` below (stamping
# tree A but comparing tree B in the context check). Fixing the data flow at the
# root — rather than guarding each downstream use — is why every later reference
# can be a plain absolute path.
SRC_DIR="$(cd "$SRC_DIR" && pwd -P)"
COMPOSE_DIR="$(cd "$COMPOSE_DIR" && pwd -P)"

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
# ONE dirty source (`git status --porcelain`, untracked-aware — not `describe
# --dirty`, which misses untracked files). Applied to GIT_COMMIT only: appVersion
# is baked as `BUILD_VERSION+BUILD_SHA`, so a single `-dirty` on the SHA leg already
# surfaces in both appCommit AND the combined appVersion — putting it on both legs
# just doubled the suffix (`v1.2.3-dirty+f065eb0-dirty`). Both legs still agree on
# dirtiness (they share the one detection); only the display is de-duplicated.
DIRTY=""
[ -n "$(git -C "$SRC_DIR" status --porcelain 2>/dev/null)" ] && DIRTY="-dirty"
[ -n "$DIRTY" ] && echo "WARNING: $SRC_DIR has uncommitted or untracked changes — stamping as '-dirty' so /health is honest." >&2
# Sanitize VERSION at the source: it comes from a git TAG (via describe), and a tag
# may legally contain a single quote or backslash, which the Dockerfile writes
# UNescaped into a single-quoted Dart string literal in version.dart — breaking the
# build. SHA and timestamp are safe by construction; the tag-derived VERSION is the
# only untrusted leg, so strip Dart-hostile chars here (sanitize once at the boundary).
VERSION="$(git -C "$SRC_DIR" describe --tags --always 2>/dev/null | tr -d "'\\\\" | tr -d '\n' || true)"
[ -z "$VERSION" ] && VERSION="dev"
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
trap 'rm -f "$CONFIG_ERR"' EXIT
# Fail on a real `docker compose config` error (no daemon, bad compose file,
# unsupported --format) instead of collapsing it into a misleading "not passing
# our exports" arg-mismatch against an empty model.
if ! CONFIG_JSON="$(docker compose config --format json 2>"$CONFIG_ERR")"; then
  echo "ERROR: 'docker compose config' failed — cannot validate the build model." >&2
  [ -s "$CONFIG_ERR" ] && sed 's/^/       /' "$CONFIG_ERR" >&2
  exit 1
fi

# NOTE: an earlier revision also asserted SRC_DIR == the compose build.context here.
# It was removed: it fought the real prod topology (SRC_DIR is a `src/` subdir while
# prod compose sets a separate context) and became a recurring source of false
# failures. The /health terminal check below is the real guard that the built
# artifact carries the stamp; the operator owns pointing SRC_DIR at the right tree.

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

# The terminal observable is "the running container reports this commit", not
# "compose exited 0". We check /health from INSIDE the container via
# `docker compose exec` (curl is installed in the runtime image and is what the
# compose healthcheck itself uses), so this works regardless of whether the health
# port is published to the host — the repo compose has no `ports:` mapping, so a
# host-side `curl localhost:8081` would fail every time and turn STRICT into a
# guaranteed red. In-container is topology-independent.
#
# Because a soft check that always exits 0 can't gate automation, under STRICT_HEALTH
# (default on) BOTH a confirmed persistent mismatch AND never-getting-a-response FAIL
# non-zero. A single early mismatch is NOT fatal — during --force-recreate the old
# container can still answer, so we keep polling and only fail if the WRONG commit
# persists. Opt-outs: STRICT_HEALTH=0 downgrades everything to a warning;
# ALLOW_UNVERIFIED_HEALTH=1 treats *no response* (but not a mismatch) as a warning.
HEALTH_URL="${HEALTH_URL:-http://localhost:8081/health}"  # in-container URL
STRICT_HEALTH="${STRICT_HEALTH:-1}"
ALLOW_UNVERIFIED_HEALTH="${ALLOW_UNVERIFIED_HEALTH:-0}"
# Acceptance window = HEALTH_RETRIES × HEALTH_INTERVAL (default 12 × 5s = 60s).
# A tired VPS doing a slow image load / migration may need a wider window — raise
# these rather than reaching for STRICT_HEALTH=0 (which blinds the check entirely).
HEALTH_RETRIES="${HEALTH_RETRIES:-12}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"
echo
echo "Verifying the stamp via 'compose exec $SERVICE' $HEALTH_URL (expect commit=$GIT_COMMIT; window ${HEALTH_RETRIES}x${HEALTH_INTERVAL}s)..."
last_reported=""
saw_body=0        # did the endpoint EVER return a body (reachable)?
saw_bad_body=0    # ...that we could not parse a commit from (bad health contract)?
for (( _i = 1; _i <= HEALTH_RETRIES; _i++ )); do
  # Bound every poll: a half-open TCP accept or wedged proxy would otherwise block
  # one iteration forever, so retries never run and STRICT_HEALTH never fires
  # (fail-open into a hang — the opposite of the doctrine). curl runs INSIDE the
  # container (topology-independent); -T disables TTY alloc for non-interactive use.
  body="$(docker compose exec -T "$SERVICE" curl -fs --connect-timeout 3 --max-time 5 "$HEALTH_URL" 2>/dev/null || true)"
  if [ -n "$body" ]; then
    saw_body=1
    # jq only — a hard dependency; the handler emits a JSON object with a "commit"
    # field. A body that doesn't parse to a commit is a broken contract, tracked
    # separately (saw_bad_body) so it fails even when unreachable is tolerated.
    reported="$(printf '%s' "$body" | jq -r '.commit // empty' 2>/dev/null || true)"
    if [ -n "$reported" ]; then
      saw_bad_body=0
      last_reported="$reported"
      if [ "$reported" = "$GIT_COMMIT" ]; then
        echo "  OK — /health reports commit=$reported."
        exit 0
      fi
      # Wrong commit — keep polling; the recreate may still be swapping containers.
    else
      saw_bad_body=1
    fi
  fi
  # Don't burn an interval after the final attempt.
  [ "$_i" -lt "$HEALTH_RETRIES" ] && sleep "$HEALTH_INTERVAL"
done

if [ -n "$last_reported" ]; then
  echo "  MISMATCH — /health still reports commit=$last_reported, expected $GIT_COMMIT" >&2
  echo "             after all polls. The new container did not take, or the stamp did" >&2
  echo "             not land. Investigate before trusting this deploy." >&2
  [ "$STRICT_HEALTH" = "1" ] && exit 1
  echo "  (STRICT_HEALTH=0 — downgrading mismatch to a warning.)" >&2
  exit 0
fi
if [ "$saw_body" = "1" ] && [ "$saw_bad_body" = "1" ]; then
  # Reachable but never emitted a parseable commit — a broken health CONTRACT, NOT
  # an unreachable bind. ALLOW_UNVERIFIED_HEALTH covers private/unreachable binds,
  # not malformed responses, so it does NOT excuse this: fail under STRICT.
  echo "  BAD CONTRACT — /health at $HEALTH_URL is reachable but returned no parseable" >&2
  echo "                 '.commit' field. The stamp cannot be confirmed." >&2
  [ "$STRICT_HEALTH" = "1" ] && exit 1
  echo "  (STRICT_HEALTH=0 — downgrading to a warning.)" >&2
  exit 0
fi
echo "  UNVERIFIED — no response from 'compose exec $SERVICE' $HEALTH_URL (container" >&2
echo "               not up yet, curl missing in image, or wrong URL). Could NOT confirm." >&2
echo "               Verify manually: docker compose exec $SERVICE curl -s $HEALTH_URL | jq .commit" >&2
if [ "$STRICT_HEALTH" = "1" ] && [ "$ALLOW_UNVERIFIED_HEALTH" != "1" ]; then
  echo "               Failing (STRICT_HEALTH=1). Fix HEALTH_URL/SERVICE, or set" >&2
  echo "               ALLOW_UNVERIFIED_HEALTH=1 / STRICT_HEALTH=0 to allow." >&2
  exit 1
fi
echo "               (Not failing — STRICT_HEALTH=$STRICT_HEALTH ALLOW_UNVERIFIED_HEALTH=$ALLOW_UNVERIFIED_HEALTH.)" >&2
