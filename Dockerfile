FROM node:22-slim

WORKDIR /app

# Install build tools for native modules (better-sqlite3)
RUN apt-get update && apt-get install -y python3 make g++ && rm -rf /var/lib/apt/lists/*

# Enable pnpm via Corepack
RUN corepack enable && corepack prepare pnpm@9.15.4 --activate

# Copy package files
COPY package.json pnpm-lock.yaml* ./

# Install dependencies
RUN pnpm install --frozen-lockfile

# Install Playwright Chromium browser + system deps (for web browsing MCP server)
# Skipped when INSTALL_PLAYWRIGHT=false to keep the image smaller
ARG INSTALL_PLAYWRIGHT=true
RUN if [ "$INSTALL_PLAYWRIGHT" = "true" ]; then npx playwright install --with-deps chromium; fi

# Install MCP server dependencies
COPY mcp-servers/packages/kan/package.json mcp-servers/packages/kan/
RUN cd mcp-servers/packages/kan && pnpm install

COPY mcp-servers/packages/outline/package.json mcp-servers/packages/outline/
RUN cd mcp-servers/packages/outline && pnpm install

COPY mcp-servers/packages/radicale/package.json mcp-servers/packages/radicale/
RUN cd mcp-servers/packages/radicale && pnpm install

# Copy source
COPY . .

# Build TypeScript
RUN pnpm build

# Create data directory for SQLite
RUN mkdir -p /app/data

# Set environment defaults
ENV NODE_ENV=production
ENV DATABASE_PATH=/app/data/bot.db

# Run the bot
CMD ["node", "dist/index.js"]
