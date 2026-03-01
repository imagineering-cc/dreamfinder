# Multi-stage Dockerfile for Dreamfinder (Dart)
#
# Stage 1: Compile Dart to native AOT binary
# Stage 2: Minimal runtime with Node.js (for MCP server subprocesses)

# --- Build stage ---
FROM dart:3.6 AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock* ./
RUN dart pub get

COPY lib/ lib/
COPY bin/ bin/

RUN dart compile exe bin/dreamfinder.dart -o bin/dreamfinder

# --- Runtime stage ---
FROM node:22-slim

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
