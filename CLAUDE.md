# Dreamfinder

> See [README.md](README.md) for full project documentation, architecture diagrams,
> MCP integration details, and deployment guide.

**Dreamfinder** is a chat-based PM bot for the Imagineering org running on Matrix.
Every message flows through a Claude agent loop with access to MCP tools
(Kan.bn, Outline, Radicale, Playwright) plus custom tools. No slash commands — natural
language only. A separate "matrix chat superbridge" handles relay between Matrix and
Signal/Discord/Telegram/WhatsApp using puppet accounts — Dreamfinder only connects to
Matrix.

Adapted from **xdeca-pm-bot** (Telegram).

**Status**: Active development. 795+ tests.
Speed is a primary concern. Prefer working code over perfect abstractions. Skip plan
mode for straightforward tasks, minimize over-engineering, and keep momentum high.
Still respect correctness and type safety, but bias toward shipping.

## Tech Stack

| Layer           | Technology                             |
| --------------- | -------------------------------------- |
| Language        | Dart 3.6+                              |
| Runtime         | Dart VM                                |
| Messaging       | Matrix                                 |
| LLM             | Claude Sonnet 4.6 (anthropic_sdk_dart) |
| MCP             | dart_mcp ^0.4.1                        |
| Database        | SQLite (via sqlite3 package)            |
| MCP Tools       | Kan.bn, Outline, Radicale, Playwright  |
| Deployment      | Docker on OCI                          |
| Package Manager | dart pub                               |

## Project Structure

```
lib/
  src/
    matrix/         # Matrix client, models, auth
    agent/          # Agent loop, system prompt, tool registry, conversation history
    mcp/            # MCP subprocess manager
    memory/         # RAG long-term memory (embedding client, pipeline, retriever)
    config/         # Environment config
    tools/          # Custom tool definitions (identity, chat config, standup, kickstart)
    db/             # SQLite database, schema, queries (11 mixins), message repository
    dream/          # Dream cycle orchestrator, sleep stage prompts
    kickstart/      # Guided onboarding detection, state, prompts
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
MATRIX_HOMESERVER=            # Matrix homeserver URL (e.g., https://matrix.imagineering.cc)
MATRIX_ACCESS_TOKEN=          # Matrix bot access token (or use username+password)
MATRIX_USERNAME=              # Matrix login username (alternative to access token)
MATRIX_PASSWORD=              # Matrix login password (alternative to access token)
MATRIX_IGNORE_ROOMS=          # Comma-separated room IDs to ignore (optional)
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
RATE_LIMIT_PER_USER_SECONDS=  # Per-user cooldown in seconds (default: 5; raise to 1 for demos)
RATE_LIMIT_GROUP_MAX=         # Max bot responses per group window (default: 5; raise to 20+ for demos)
RATE_LIMIT_GROUP_WINDOW_SECONDS= # Rolling window for group rate limit in seconds (default: 30)
```

## Coding Rules

### Dart

- **Strict analysis** enabled (`strict-casts`, `strict-inference`, `strict-raw-types`).
  No `dynamic` unless unavoidable.
- Use **extension types** for domain IDs
  (e.g., `extension type CardId(String value) implements String`).
- Dart's **sound type system** plus factory constructors with validation for external
  inputs (Matrix events, API responses, environment variables). Never trust
  unvalidated external data.
- **Doc comments** (`///`) on all public APIs per Effective Dart. Inline comments only
  for non-obvious logic.
- Library exports via `package:` imports and `export` directives.
- Prefer **sealed classes** for union types and **enhanced enums** with fields/methods.

### Error Handling

- Wrap external calls (Matrix API, MCP servers, Anthropic API) in try/catch with
  structured error logging. Never swallow errors silently.
- Use custom exception classes implementing `Exception` for recoverable domain-specific
  failures (Dart convention: `Exception` for recoverable, `Error` for programmer bugs).
- If an operation fails mid-way, send a clear error message to the user.

### Testing (ATDD)

- **Write acceptance tests first**, then implement to make them pass.
- Tests mirror the `lib/src/` directory structure inside `test/`.
- Integration tests for MCP tools use recorded fixtures — never hit live services.
- Unit test business logic in isolation; mock external boundaries (Matrix, MCP, DB).
- Use `mocktail` for mocking.

### Imports & Modules

- Use `package:` imports for cross-package references; relative imports within
  `lib/src/`.
- No circular dependencies — enforced by `dart analyze`.

### Database

- SQLite via the `sqlite3` package (synchronous API). No ORM — raw SQL with
  parameterized queries in `Queries` class and `MessageRepository`.
- Schema defined in `database.dart` with versioned migrations (`_migrateToV1()` through
  `_migrateToV7()`). Version tracked in `schema_version` table. Current: v7.
- V6 migration renamed Signal-specific tables/columns to platform-agnostic names (historical — must never be removed).
- Never store secrets or API keys in SQLite.

## Git & Workflow

- **Conventional Commits**: `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`
- **ATDD**: acceptance test → red → implement → green → refactor.
- PR-based workflow. CI checks (`dart analyze`, `dart test`) must pass before merge.
- Branch naming: `feat/description`, `fix/description`, `chore/description`.
- **Always work on a feature branch** — never commit directly to `main`. Create a
  new branch before starting work, even for small changes.
- **Git identity**: Commit under the operator's own git/GitHub identity (whatever
  `gh auth status` / ssh resolves to). Do **not** set a cosmetic `Dreamfinder` git
  author, and do **not** use `$DREAMFINDER_GITHUB_TOKEN` — that variable is **unset**
  and silently falls back to the operator's admin `gh` keyring login, disguising who
  actually pushed/merged. (`dreamfindercc` is a real but unused account — 0 repos, not
  an org member — not the actor behind any commit.)
- **Never merge to `main` from a session** (Nick, 2026-06-20): branch, push, open the
  PR, then hand the merge to a human or a real `/cage-match`. Do not `--admin`-merge or
  self-approve your own PR — a same-instance approval through any second identity is
  self-review theater, not review.

## Signal → Matrix Migration (complete)

Migration shipped across PRs #47–#48 (2026-03-16) and went live ~2026-03-25. Dreamfinder
connects only to Matrix; the matrix-chat-superbridge handles relay to Signal, Discord,
Telegram, and WhatsApp via puppet accounts.

```
Signal ──┐
Discord ──┤── Matrix Superbridge ──── Matrix ──── Dreamfinder
Telegram ─┤      (puppets)
WhatsApp ──┘
```

Key milestones: platform-agnostic DB rename (schema v6, PR #47) → Matrix client layer
(PR #48) → main sync loop switchover (~2026-03-25) → Signal scaffolding removed (PR #90).
The v6 migration SQL is preserved in `lib/src/db/database.dart` and must never be removed
(it runs on any pre-v6 database still out there).

## Other Future Directions

### Kickstart guided onboarding (SHIPPED — in-room, PR #84)
6-step guided setup triggered by "kickstart" / "get started" / "let's set up" in the
group room. No DM required — River walks the team through setup in-room.
Workspace Setup → Team Roster → Project Seeding → Knowledge Dump → Dream Primer → First Nudge.
State persisted via `bot_metadata` table (no migration needed). System prompt injection
via `_buildFullSystemPrompt`. Custom tools: `advance_kickstart`, `complete_kickstart`.

### Proactive task nudges (IMPLEMENTED)
The scheduler sends proactive nudges about overdue and stale Kan cards at a
configurable hour (set via `configure_standup` with `nudge_hour`). The agent
queries Kan for cards needing attention and composes an in-character nudge.
Daily dedup via `bot_metadata` (key: `nudge::groupId::date`). Timezone-aware
via the standup config's IANA timezone. Runs through `composeViaAgent` so
nudges land in conversation history.

### sqlite-vec migration (deferred)
Brute-force cosine similarity is <10ms for 10K vectors. Only revisit if the memory
store exceeds ~100K records. The current design doesn't paint us into a corner — the
swap is well-contained in `getVisibleMemories` + the retriever's scoring loop.
