# imagineering-pm-bot (Figment)

> See [README.md](README.md) for full project documentation, architecture diagrams,
> Signal framework evaluation, MCP integration details, and deployment guide.

**Figment** is a Signal-based PM bot for the Imagineering org. Every message flows
through a Claude agent loop with access to MCP tools (Kan.bn, Outline, Radicale,
Playwright) plus custom tools. No slash commands — natural language only.

Adapted from **xdeca-pm-bot** (Telegram). Key difference: Signal has no official bot
API, no message editing, no inline keyboards, and stricter rate limiting.

**Status**: Early-stage planning. No source code yet — only docs.

## Tech Stack

| Layer             | Technology                                       |
| ----------------- | ------------------------------------------------ |
| Runtime           | Node.js 22+ / TypeScript 5.x                    |
| Messaging         | Signal (framework TBD — see README)              |
| LLM               | Claude Sonnet 4.6 (Anthropic API)                |
| Database          | SQLite via Drizzle ORM                           |
| MCP Tools         | Kan.bn, Outline, Radicale, Playwright            |
| Deployment        | Docker on GCP                                    |
| Package Manager   | pnpm                                             |

## Project Structure

```
src/
  bot/            # Signal bot setup, message handling, rate limiting
  agent/          # Claude agent loop, system prompt, tool orchestration
  tools/          # Custom MCP tool definitions
  db/             # Drizzle schema, migrations, queries
  cron/           # Scheduled jobs (reminders, standups)
  config/         # Environment config, constants
  types/          # Shared TypeScript types
  utils/          # Shared utilities
mcp-servers/      # Git submodule: Kan, Outline, Radicale MCP servers
data/             # SQLite database (gitignored)
drizzle/          # Generated migrations
tests/            # Test files mirroring src/ structure
docker/           # Dockerfiles and compose configs
```

## Development Commands

```bash
pnpm install          # Install dependencies
pnpm dev              # Development with watch mode
pnpm build            # Production build
pnpm start            # Run production build
pnpm test             # Run tests
pnpm test:watch       # Run tests in watch mode
pnpm lint             # ESLint
pnpm format           # Prettier
pnpm typecheck        # tsc --noEmit
pnpm db:generate      # Generate migration from schema changes
pnpm db:migrate       # Apply pending migrations
pnpm db:studio        # Open Drizzle Studio
```

## Environment Variables

```bash
ANTHROPIC_API_KEY=            # Claude API key
SIGNAL_PHONE_NUMBER=          # Bot's registered Signal phone number
SIGNAL_API_URL=               # signal-cli-rest-api base URL (if using REST approach)
KAN_BASE_URL=                 # Kan.bn instance URL
KAN_API_KEY=                  # Kan.bn API key
OUTLINE_BASE_URL=             # Outline instance URL
OUTLINE_API_KEY=              # Outline API key
RADICALE_BASE_URL=            # Radicale CalDAV/CardDAV server URL
RADICALE_USERNAME=            # Radicale auth username
RADICALE_PASSWORD=            # Radicale auth password
BOT_NAME=                     # Display name (default: "Figment")
DATABASE_PATH=                # SQLite path (default: ./data/bot.db)
LOG_LEVEL=                    # Logging level (default: info)
NODE_ENV=                     # production | development
```

## Coding Rules

### TypeScript
- **Strict mode**, no `any` — prefer `unknown` and narrow with type guards.
- Use **branded types** for domain IDs (e.g., `type CardId = string & { __brand: 'CardId' }`).
- **Zod schemas** for all external input validation (Signal messages, API responses,
  environment variables). Never trust unvalidated external data.
- **Doc comments** (`/** */`) on all public APIs. Inline comments only for non-obvious logic.
- **Barrel exports** via `index.ts` in each module directory.
- Prefer `const` assertions and discriminated unions over enums.

### Error Handling
- Wrap external calls (Signal API, MCP servers, Anthropic API) in try/catch with
  structured error logging. Never swallow errors silently.
- Use custom error classes extending `Error` for domain-specific failures.
- Signal-specific: responses must be complete on first send (no editing). If an
  operation fails mid-way, send a clear error message to the user.

### Testing (ATDD)
- **Write acceptance tests first**, then implement to make them pass.
- Tests mirror the `src/` directory structure inside `tests/`.
- Integration tests for MCP tools use recorded fixtures — never hit live services.
- Unit test business logic in isolation; mock external boundaries (Signal, MCP, DB).

### Imports & Modules
- Use `import type` for type-only imports.
- Relative imports within a module; barrel imports across modules
  (e.g., `import { AgentLoop } from '../agent'`).
- No circular dependencies — enforce with ESLint rules.

### Database (Drizzle)
- Schema changes go in `src/db/schema.ts`, then run `pnpm db:generate`.
- Never modify generated migration files in `drizzle/`.
- Use Drizzle's query builder — no raw SQL strings.
- Never store secrets or API keys in SQLite.

## Git & Workflow

- **Conventional Commits**: `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`
- **ATDD**: acceptance test → red → implement → green → refactor.
- PR-based workflow. CI checks (lint, typecheck, test) must pass before merge.
- Branch naming: `feat/description`, `fix/description`, `chore/description`.
