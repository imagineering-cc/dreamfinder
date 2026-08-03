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

# Compose reads exactly these three names (see docker-compose.yml build.args).
export VERSION
export GIT_COMMIT
export BUILD_TIME
VERSION="$(git -C "$SRC_DIR" describe --tags --always 2>/dev/null || echo dev)"
GIT_COMMIT="$(git -C "$SRC_DIR" rev-parse --short HEAD)"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Deploying $SERVICE"
echo "  VERSION=$VERSION"
echo "  GIT_COMMIT=$GIT_COMMIT"
echo "  BUILD_TIME=$BUILD_TIME"

cd "$COMPOSE_DIR"
docker compose build "$SERVICE"
docker compose up -d --force-recreate "$SERVICE"

echo
echo "Deployed. Verify the stamp landed (expect commit=$GIT_COMMIT, not 'local'):"
echo "  curl -s http://localhost:8081/health | grep -o '\"commit\":\"[^\"]*\"'"
