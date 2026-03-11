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

ARG BUILD_VERSION=dev
ARG BUILD_SHA=local
ARG BUILD_TIME=unknown
RUN printf "/// Build version info — generated at Docker build time.\nconst String appVersion = '%s+%s';\nconst String appCommit = '%s';\nconst String appBuildTime = '%s';\n" \
    "$BUILD_VERSION" "$BUILD_SHA" "$BUILD_SHA" "$BUILD_TIME" \
    > lib/src/config/version.dart

RUN dart compile exe bin/dreamfinder.dart -o bin/dreamfinder

# --- Runtime stage ---
FROM node:22-slim

# Install native dependencies needed by Dart AOT binary.
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev curl && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install MCP server dependencies (if submodule exists).
COPY mcp-servers/packages/kan/package.json mcp-servers/packages/kan/
COPY mcp-servers/packages/kan/ mcp-servers/packages/kan/
RUN cd mcp-servers/packages/kan && npm install --omit=dev 2>/dev/null || true

COPY mcp-servers/packages/outline/package.json mcp-servers/packages/outline/
COPY mcp-servers/packages/outline/ mcp-servers/packages/outline/
RUN cd mcp-servers/packages/outline && npm install --omit=dev 2>/dev/null || true

COPY mcp-servers/packages/radicale/package.json mcp-servers/packages/radicale/
COPY mcp-servers/packages/radicale/ mcp-servers/packages/radicale/
RUN cd mcp-servers/packages/radicale && npm install --omit=dev 2>/dev/null || true

# Copy compiled binary from build stage.
COPY --from=build /app/bin/dreamfinder /app/bin/dreamfinder

RUN mkdir -p /app/data

CMD ["/app/bin/dreamfinder"]
