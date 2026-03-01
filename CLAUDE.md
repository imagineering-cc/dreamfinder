# imagineering-pm-bot (Dreamfinder)

> See [README.md](README.md) for full project documentation, architecture diagrams,
> Signal integration details, MCP integration details, and deployment guide.

**Dreamfinder** is a Signal-based PM bot for the Imagineering org. Every message flows
through a Claude agent loop with access to MCP tools (Kan.bn, Outline, Radicale,
Playwright) plus custom tools. No slash commands — natural language only.

Adapted from **xdeca-pm-bot** (Telegram). Key difference: Signal has no official bot
API, no message editing, no inline keyboards, and stricter rate limiting.

**Status**: Active sprint — end-to-end bot is runnable. Signal client, agent loop,
conversation history (DB-backed), tool registry, MCP manager, system prompt, SQLite
persistence (10 domain tables), and custom tools (identity + chat config) are
implemented with 106+ tests. Cron scheduler, standup orchestration, and dedicated
message handler are next. Speed is a primary concern. Prefer working code over perfect
abstractions. Skip plan mode for straightforward tasks, minimize over-engineering, and
keep momentum high. Still respect correctness and type safety, but bias toward shipping.

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
    config/         # Environment config
    tools/          # Custom tool definitions (identity, chat config)
    db/             # SQLite database, schema, queries, message repository
    cron/           # Scheduled jobs (not yet built)
    bot/            # Message handler, rate limiting (not yet built)
bin/                # Entry point (figment.dart)
test/               # Tests mirroring lib/src/ structure
data/               # SQLite database (gitignored)
docker/             # Dockerfiles and compose configs
```

## Development Commands

```bash
dart pub get                    # Install dependencies
dart run bin/figment.dart        # Run the bot
dart test                       # Run tests
dart analyze                    # Static analysis
dart format .                   # Format code
dart compile exe bin/figment.dart # Compile for production
```

## Environment Variables

```bash
ANTHROPIC_API_KEY=            # Claude API key
SIGNAL_PHONE_NUMBER=          # Bot's registered Signal phone number
SIGNAL_API_URL=               # signal-cli-rest-api base URL
KAN_BASE_URL=                 # Kan.bn instance URL
KAN_API_KEY=                  # Kan.bn API key
OUTLINE_BASE_URL=             # Outline instance URL
OUTLINE_API_KEY=              # Outline API key
RADICALE_BASE_URL=            # Radicale CalDAV/CardDAV server URL
RADICALE_USERNAME=            # Radicale auth username
RADICALE_PASSWORD=            # Radicale auth password
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
- Schema defined in `database.dart` via `CREATE TABLE IF NOT EXISTS`. No formal
  migration system yet — add one before the first schema change on production data.
- Never store secrets or API keys in SQLite.

## Git & Workflow

- **Conventional Commits**: `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`
- **ATDD**: acceptance test → red → implement → green → refactor.
- PR-based workflow. CI checks (`dart analyze`, `dart test`) must pass before merge.
- Branch naming: `feat/description`, `fix/description`, `chore/description`.
- **Always work on a feature branch** — never commit directly to `main`. Create a
  new branch before starting work, even for small changes.
