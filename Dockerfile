# Multi-stage Dockerfile for Dreamfinder (Dart)
#
# Stage 1: Compile Dart to native AOT binary
# Stage 2: Minimal runtime with Node.js (for MCP server subprocesses)

# --- Build stage ---
FROM dart:stable AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock* ./
RUN dart pub get

COPY lib/ lib/
COPY bin/ bin/

# ARG ORDER IS LOAD-BEARING: these are declared immediately BEFORE the RUN that
# consumes them, so a changed BUILD_SHA cache-busts the version.dart layer and the
# stamp can never be a stale cached value. Do not move a cacheable COPY/RUN between
# these ARGs and the generation step below, or a wrong stamp could survive in cache.
ARG BUILD_VERSION=dev
ARG BUILD_SHA=local
ARG BUILD_TIME=unknown
ARG BUILD_CHANGELOG=
ARG BUILD_DIFF_STAT=
# Set to 1 for a deliberate un-stamped (dev) image; scripts/deploy.sh always stamps.
ARG ALLOW_UNSTAMPED=0

# FAIL CLOSED on an un-stamped build at the mutator itself. compose keeps soft
# defaults (BUILD_SHA=local) so routine `docker compose logs/restart/ps/config`
# still work when GIT_COMMIT is unset (a `${VAR:?}` in build.args breaks ALL of
# those — verified) — but a bare `docker compose build` / `up -d --build` that
# would ship a lying `dev+local` prod image now fails HERE unless the operator
# explicitly opts into an un-stamped dev image with ALLOW_UNSTAMPED=1. This closes
# the un-stamped path at the build boundary without a wrapper being the only guard.
RUN if [ "$ALLOW_UNSTAMPED" != "1" ] && { [ "$BUILD_SHA" = "local" ] || [ -z "$BUILD_SHA" ]; }; then \
      echo "REFUSING un-stamped build: BUILD_SHA='$BUILD_SHA'. Deploy via scripts/deploy.sh," >&2; \
      echo "or pass --build-arg ALLOW_UNSTAMPED=1 for a deliberate dev image." >&2; \
      exit 1; \
    fi

# Generate version.dart with build metadata and changelog baked in.
# Uses raw triple-quoted strings (r'''...'''). Sanitize inputs to prevent
# triple-quote sequences in commit messages from breaking the Dart literal.
RUN SAFE_CHANGELOG=$(printf '%s' "$BUILD_CHANGELOG" | sed "s/'''/'' '/g") && \
    SAFE_DIFF_STAT=$(printf '%s' "$BUILD_DIFF_STAT" | sed "s/'''/'' '/g") && \
    printf "/// Build version info — generated at Docker build time.\n" > lib/src/config/version.dart && \
    printf "const String appVersion = '%s+%s';\n" "$BUILD_VERSION" "$BUILD_SHA" >> lib/src/config/version.dart && \
    printf "const String appCommit = '%s';\n" "$BUILD_SHA" >> lib/src/config/version.dart && \
    printf "const String appBuildTime = '%s';\n" "$BUILD_TIME" >> lib/src/config/version.dart && \
    printf "const String appChangelog = r'''\n%s\n''';\n" "$SAFE_CHANGELOG" >> lib/src/config/version.dart && \
    printf "const String appDiffStat = r'''\n%s\n''';\n" "$SAFE_DIFF_STAT" >> lib/src/config/version.dart

RUN dart compile exe bin/dreamfinder.dart -o bin/dreamfinder

# --- Runtime stage ---
FROM node:22-slim

# Install native dependencies needed by Dart AOT binary.
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev curl ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Kan + Outline + Radicale are driven by the vendored zero-dependency CLIs (no
# npm install needed — they import only node builtins). The `run_cli` tool
# shells out to these; CLI_TOOLS_DIR tells it where to find them. The radicale
# MCP server is fully retired (mcp-config.json is []), so it is no longer copied
# or npm-installed into the image.
COPY cli-tools/ /app/cli-tools/
ENV CLI_TOOLS_DIR=/app/cli-tools

# Copy compiled binary and MCP config from build stage.
COPY --from=build /app/bin/dreamfinder /app/bin/dreamfinder
COPY mcp-config.json /app/mcp-config.json

RUN mkdir -p /app/data

CMD ["/app/bin/dreamfinder"]
