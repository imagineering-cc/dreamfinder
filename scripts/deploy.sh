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
# left every hand-built image un-stamped. This script removes the seam: it sets
# exactly the names compose reads, computed from git, so a deploy CANNOT be run
# un-stamped by accident.
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

if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  echo "ERROR: no docker-compose.yml in COMPOSE_DIR=$COMPOSE_DIR." >&2
  echo "       Run from the compose directory, or set COMPOSE_DIR to it." >&2
  exit 1
fi

# Compute the stamp, THEN export — assigning first and exporting the finished
# names on one line closes the export-before-assignment footgun (a command
# inserted between a bare `export VERSION` and its later assignment would leak a
# stale caller-provided VERSION into compose).
VERSION="$(git -C "$SRC_DIR" describe --tags --always 2>/dev/null || echo dev)"
GIT_COMMIT="$(git -C "$SRC_DIR" rev-parse --short HEAD)"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Compose reads exactly these three names (see docker-compose.yml build.args).
export VERSION GIT_COMMIT BUILD_TIME

echo "Deploying $SERVICE"
echo "  VERSION=$VERSION"
echo "  GIT_COMMIT=$GIT_COMMIT"
echo "  BUILD_TIME=$BUILD_TIME"

cd "$COMPOSE_DIR"

# Trust → measurement: prove compose actually resolved GIT_COMMIT into the build
# args BEFORE building, so a name/context desync (compose reading a different var,
# or a build context that doesn't see our exports) fails closed here instead of
# silently baking a `local` stamp. This is the whole failure class the PR exists
# to kill, asserted rather than assumed.
if ! docker compose config 2>/dev/null | grep -qE "BUILD_SHA:[[:space:]]*[\"']?${GIT_COMMIT}"; then
  echo "ERROR: docker compose config does not show BUILD_SHA=$GIT_COMMIT in the" >&2
  echo "       $SERVICE build args — the stamp would NOT land (compose isn't reading" >&2
  echo "       \$GIT_COMMIT for this service/context). Aborting before an un-stamped build." >&2
  echo "       Inspect: docker compose config | grep -A5 args:" >&2
  exit 1
fi

docker compose build "$SERVICE"
docker compose up -d --force-recreate "$SERVICE"

# The terminal observable is "prod reports this commit", not "compose exited 0"
# (Tesla's catch: verify at the proven scope). Best-effort post-deploy check —
# poll /health until the container is up and compare the reported commit. Never
# fails the deploy (the container may bind health elsewhere, or start_period may
# still be elapsing); it converts the closing claim from asserted to observed.
HEALTH_URL="${HEALTH_URL:-http://localhost:8081/health}"
echo
echo "Verifying the stamp at $HEALTH_URL (expect commit=$GIT_COMMIT)..."
for _i in $(seq 1 12); do
  reported="$(curl -fs "$HEALTH_URL" 2>/dev/null | grep -o '"commit":"[^"]*"' | cut -d'"' -f4 || true)"
  if [ -n "$reported" ]; then
    if [ "$reported" = "$GIT_COMMIT" ]; then
      echo "  OK — /health reports commit=$reported."
    else
      echo "  WARN — /health reports commit=$reported, expected $GIT_COMMIT." >&2
      echo "         The running container may predate this deploy; re-check shortly." >&2
    fi
    exit 0
  fi
  sleep 5
done
echo "  NOTE — /health not reachable yet (container still starting?). Verify manually:" >&2
echo "         curl -s $HEALTH_URL | grep -o '\"commit\":\"[^\"]*\"'" >&2
