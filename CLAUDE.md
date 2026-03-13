# Dreamfinder

> See [README.md](README.md) for full project documentation, architecture diagrams,
> Signal integration details, MCP integration details, and deployment guide.

**Dreamfinder** is a Signal-based PM bot for the Imagineering org. Every message flows
through a Claude agent loop with access to MCP tools (Kan.bn, Outline, Radicale,
Playwright) plus custom tools. No slash commands — natural language only.

Adapted from **xdeca-pm-bot** (Telegram). Key difference: Signal has no official bot
API, no message editing, no inline keyboards, and stricter rate limiting.

**Status**: Active sprint — end-to-end bot is runnable. Signal client, agent loop,
conversation history (DB-backed), tool registry, MCP manager, system prompt, SQLite
persistence (13 domain tables), custom tools (identity + chat config + memory),
standup orchestration, deploy announcements, OAuth auth, RAG-based long-term
memory (all 4 phases complete), and calendar event awareness are implemented
with 427+ tests. Speed is a primary
concern. Prefer working code over perfect abstractions. Skip plan mode for
straightforward tasks, minimize over-engineering, and keep momentum high. Still
respect correctness and type safety, but bias toward shipping.

## Tech Stack

| Layer           | Technology                             |
| --------------- | -------------------------------------- |
| Language        | Dart 3.6+                              |
| Runtime         | Dart VM                                |
| Messaging       | Signal (via signal-cli-rest-api)       |
| LLM             | Claude Sonnet 4.6 (anthropic_sdk_dart) |
| MCP             | dart_mcp ^0.4.1                        |
| Database        | SQLite (via sqlite3 package)            |
| MCP Tools       | Kan.bn, Outline, Radicale, Playwright  |
| Deployment      | Docker on GCP                          |
| Package Manager | dart pub                               |

## Project Structure

```
lib/
  src/
    signal/         # Signal client, message models
    agent/          # Agent loop, system prompt, tool registry, conversation history
    mcp/            # MCP subprocess manager
    memory/         # RAG long-term memory (embedding client, pipeline, retriever)
    config/         # Environment config
    tools/          # Custom tool definitions (identity, chat config, standup)
    db/             # SQLite database, schema, queries (10 mixins), message repository
    cron/           # Scheduled jobs (standup orchestration)
    bot/            # Message handler, rate limiting, health check, deploy announcer
bin/                # Entry point (dreamfinder.dart)
test/               # Tests mirroring lib/src/ structure
data/               # SQLite database (gitignored)
docker/             # Dockerfiles and compose configs
```

## Development Commands

```bash
dart pub get                    # Install dependencies
dart run bin/dreamfinder.dart     # Run the bot
dart test                       # Run tests
dart analyze                    # Static analysis
dart format .                   # Format code
dart compile exe bin/dreamfinder.dart # Compile for production
```

## Environment Variables

```bash
ANTHROPIC_API_KEY=            # Claude API key
CLAUDE_REFRESH_TOKEN=         # OAuth refresh token (alternative to API key)
SIGNAL_PHONE_NUMBER=          # Bot's registered Signal phone number
SIGNAL_API_URL=               # signal-cli-rest-api base URL
KAN_BASE_URL=                 # Kan.bn instance URL
KAN_API_KEY=                  # Kan.bn API key
OUTLINE_BASE_URL=             # Outline instance URL
OUTLINE_API_KEY=              # Outline API key
RADICALE_BASE_URL=            # Radicale CalDAV/CardDAV server URL
RADICALE_USERNAME=            # Radicale auth username
RADICALE_PASSWORD=            # Radicale auth password
VOYAGE_API_KEY=               # Voyage AI key for RAG memory embeddings (optional)
CALENDAR_URL=                 # CalDAV calendar URL for event awareness (optional)
EVENT_TIMEZONE=               # IANA timezone for event display (e.g., Australia/Melbourne)
BOT_NAME=                     # Display name (default: "Dreamfinder")
DATABASE_PATH=                # SQLite path (default: ./data/bot.db)
LOG_LEVEL=                    # Logging level (default: info)
```

## Coding Rules

### Dart

- **Strict analysis** enabled (`strict-casts`, `strict-inference`, `strict-raw-types`).
  No `dynamic` unless unavoidable.
- Use **extension types** for domain IDs
  (e.g., `extension type CardId(String value) implements String`).
- Dart's **sound type system** plus factory constructors with validation for external
  inputs (Signal messages, API responses, environment variables). Never trust
  unvalidated external data.
- **Doc comments** (`///`) on all public APIs per Effective Dart. Inline comments only
  for non-obvious logic.
- Library exports via `package:` imports and `export` directives.
- Prefer **sealed classes** for union types and **enhanced enums** with fields/methods.

### Error Handling

- Wrap external calls (Signal API, MCP servers, Anthropic API) in try/catch with
  structured error logging. Never swallow errors silently.
- Use custom exception classes implementing `Exception` for recoverable domain-specific
  failures (Dart convention: `Exception` for recoverable, `Error` for programmer bugs).
- Signal-specific: responses must be complete on first send (no editing). If an
  operation fails mid-way, send a clear error message to the user.

### Testing (ATDD)

- **Write acceptance tests first**, then implement to make them pass.
- Tests mirror the `lib/src/` directory structure inside `test/`.
- Integration tests for MCP tools use recorded fixtures — never hit live services.
- Unit test business logic in isolation; mock external boundaries (Signal, MCP, DB).
- Use `mocktail` for mocking.

### Imports & Modules

- Use `package:` imports for cross-package references; relative imports within
  `lib/src/`.
- No circular dependencies — enforced by `dart analyze`.

### Database

- SQLite via the `sqlite3` package (synchronous API). No ORM — raw SQL with
  parameterized queries in `Queries` class and `MessageRepository`.
- Schema defined in `database.dart` with versioned migrations (`_migrateToV1()` through
  `_migrateToV4()`). Version tracked in `schema_version` table. Current: v4.
- Never store secrets or API keys in SQLite.

## Git & Workflow

- **Conventional Commits**: `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`
- **ATDD**: acceptance test → red → implement → green → refactor.
- PR-based workflow. CI checks (`dart analyze`, `dart test`) must pass before merge.
- Branch naming: `feat/description`, `fix/description`, `chore/description`.
- **Always work on a feature branch** — never commit directly to `main`. Create a
  new branch before starting work, even for small changes.

## Future Directions

Prioritized by value/effort ratio. These are the next features to build.

### 1. ~~Timezone support for standup prompts~~ (DONE)
The `timezone` package converts server UTC to the group's configured IANA timezone
before comparing against `config.promptHour`. Weekend checks and session dedup also
use local time. Calendar event display in the system prompt uses `EVENT_TIMEZONE`.

### 2. ~~Calendar event awareness~~ (DONE)
Upcoming events from the Radicale calendar are injected into the system prompt
alongside memories. Set `CALENDAR_URL` to enable. The `CalendarRetriever` fetches
events via MCP with a 7-day lookahead on every message.

### 3. Proactive task nudges
The scheduler + Kan MCP tools exist but Dreamfinder never proactively reminds about
overdue or stale cards. Add a scheduled job that queries Kan for overdue tasks and
sends reminder messages via the agent loop (in-character). The `sent_reminders` table
already tracks dedup for this — it just needs to be wired up.

### 4. sqlite-vec migration (deferred)
Brute-force cosine similarity is <10ms for 10K vectors. Only revisit if the memory
store exceeds ~100K records. The current design doesn't paint us into a corner — the
swap is well-contained in `getVisibleMemories` + the retriever's scoring loop.
