import "dotenv/config";
import { initEnv, env } from "./config/env.js";

function main(): void {
  // Validate environment first — fails fast on bad config
  initEnv();

  console.log(`Starting ${env.BOT_NAME} (imagineering-pm-bot)...`);
  console.log(`  Environment: ${env.NODE_ENV}`);
  console.log(`  Log level:   ${env.LOG_LEVEL}`);
  console.log(`  Database:    ${env.DATABASE_PATH}`);
  console.log(`  Signal API:  ${env.SIGNAL_API_URL}`);
  console.log(`  Playwright:  ${String(env.PLAYWRIGHT_ENABLED)}`);

  // TODO: Initialize database (Phase 1)
  // TODO: Register custom tools (Phase 2)
  // TODO: Initialize MCP servers (Phase 2)
  // TODO: Start Signal message handler (Phase 3)
  // TODO: Start cron schedulers (Phase 4)

  console.log(`${env.BOT_NAME} is ready!`);
}

try {
  main();
} catch (err: unknown) {
  console.error("Failed to start bot:", err);
  process.exit(1);
}

// Graceful shutdown
function shutdown(): void {
  console.log("Shutting down...");
  // TODO: Shutdown MCP servers
  // TODO: Close database connection
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
