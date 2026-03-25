# Dreamfinder

> See [README.md](README.md) for full project documentation, architecture diagrams,
> Signal integration details, MCP integration details, and deployment guide.

**Dreamfinder** is a chat-based PM bot for the Imagineering org, migrating from Signal
to Matrix. Every message flows through a Claude agent loop with access to MCP tools
(Kan.bn, Outline, Radicale, Playwright) plus custom tools. No slash commands — natural
language only. A separate "matrix chat superbridge" handles relay between Matrix and
Signal/Discord/Telegram/WhatsApp using puppet accounts — Dreamfinder only connects to
Matrix.

Adapted from **xdeca-pm-bot** (Telegram).

**Status**: Active sprint — Signal → Matrix migration in progress (branch:
`feat/discord-migration`). See **Migration Plan** below for phases. 519+ tests.
Speed is a primary concern. Prefer working code over perfect abstractions. Skip plan
mode for straightforward tasks, minimize over-engineering, and keep momentum high.
Still respect correctness and type safety, but bias toward shipping.

## Tech Stack

| Layer           | Technology                             |
| --------------- | -------------------------------------- |
| Language        | Dart 3.6+                              |
| Runtime         | Dart VM                                |
| Messaging       | Matrix (migrating from Signal)         |
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
    signal/         # Signal client, message models (being replaced by matrix/)
    matrix/         # Matrix client, models, auth (Phase 2)
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
SIGNAL_PHONE_NUMBER=          # (deprecated) Bot's registered Signal phone number
SIGNAL_API_URL=               # (deprecated) signal-cli-rest-api base URL
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
  `_migrateToV6()`). Version tracked in `schema_version` table. Current: v6.
- V6 migration renames Signal-specific tables/columns to platform-agnostic names.
- Never store secrets or API keys in SQLite.

## Git & Workflow

- **Conventional Commits**: `feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`
- **ATDD**: acceptance test → red → implement → green → refactor.
- PR-based workflow. CI checks (`dart analyze`, `dart test`) must pass before merge.
- Branch naming: `feat/description`, `fix/description`, `chore/description`.
- **Always work on a feature branch** — never commit directly to `main`. Create a
  new branch before starting work, even for small changes.

## Signal → Matrix Migration Plan

Dreamfinder is moving from Signal to Matrix. A "matrix chat superbridge" relays
between Matrix and Signal/Discord/Telegram/WhatsApp using puppet accounts, so
Dreamfinder only needs to connect to Matrix.

```
Signal ──┐
Discord ──┤── Matrix Superbridge ──── Matrix ──── Dreamfinder
Telegram ─┤      (puppets)
WhatsApp ──┘
```

**Branch**: `feat/discord-migration`
**PR strategy**: PR 1 (Phase 1 rename) → PR 2 (Phase 2 Matrix client) → PR 3 (Phases 3–5 switchover)

### Phase 1: Platform-Agnostic Rename (IN PROGRESS)

Pure rename — no behavioral changes. Bot still runs on Signal after this phase.

- **1a. Schema V6 migration** — `ALTER TABLE RENAME TO/COLUMN` for Signal-specific
  names → generic names (`signal_group_id` → `group_id`, `signal_uuid` → `user_id`,
  `signal_workspace_links` → `workspace_links`, `signal_user_links` → `user_links`)
- **1b. Schema record classes** — `SignalWorkspaceLink` → `WorkspaceLink`,
  `SignalUserLink` → `UserLink`, all `signalGroupId` → `groupId` fields, etc.
- **1c. Query mixins** — SQL strings, method signatures, param names in all 7 files
- **1d. Tool parameter names** — `signal_group_id` → `group_id` in tool input schemas
- **1e. Agent model renames** — `senderUuid` → `senderId`, `adminUuids` → `adminIds`,
  `ADMIN_UUIDS` → `ADMIN_IDS` (keep fallback)
- **1f. Kickstart prompt** — replace Signal references in prompt text
- **1g. System prompt** — `UUID:` → `ID:` label change
- **1h. Update tests + verify** — all 519+ tests pass, `dart analyze` clean

### Phase 2: Matrix Client Layer

New code, no behavioral changes. Uses `http` package (already a dependency) for direct
HTTP to the Matrix Client-Server API — same lightweight pattern as `SignalClient`.

- **2a.** No new dependencies needed
- **2b. Matrix models** — `MatrixEvent`, `MatrixSyncResponse`, `MatrixInvite`
- **2c. Matrix client** — `whoAmI()`, `sync()`, `sendMessage()`, `sendTypingIndicator()`,
  `joinRoom()`, `getRoomMembers()`. Sync token persisted in `bot_metadata` table.
  DM detection via member count. Mention detection via Matrix pills + name regex.
- **2d. Matrix auth** — `MATRIX_ACCESS_TOKEN` or `MATRIX_USERNAME`+`MATRIX_PASSWORD`
- **2e. Tests** — mock `http.Client`, cover sync parsing, DM detection, mentions,
  auto-join, send, token persistence, initial sync skip, login flow

### Phase 3: Main Loop Refactor

Replace Signal polling with Matrix sync loop in `bin/dreamfinder.dart`.

- **3a.** Config changes — remove `signalApiUrl`/`signalPhoneNumber`, add Matrix env vars
- **3b.** Replace polling loop with `/sync` long-polling loop
- **3c.** Field mapping: `sourceUuid` → `event.sender`, `chatId` → `event.roomId`
- **3d.** All `signalClient.sendMessage()` → `matrixClient.sendMessage()` callsites
- **3e.** DM detection in RateLimiter — `isDm` parameter instead of `chatId.startsWith('+')`
- **3f.** Remove Signal auto-recovery, add Matrix reconnect with exponential backoff
- **3g.** Delete `lib/src/signal/` and `test/signal/`

### Phase 4: System Prompt Updates

- "a Signal bot" → "a chat bot"
- Add Markdown formatting guidance (Matrix supports it)
- Remove "no message editing" / Signal-specific caveats

### Phase 5: Deployment

- Remove `signal-api` service and `signal_data` volume from Docker Compose
- Update env vars on VPS
- V6 migration runs automatically; old Signal chat IDs become orphaned
- Optional one-time SQL script to remap old Signal chat_ids → Matrix room IDs

## Other Future Directions

### Kickstart guided onboarding (IN PROGRESS)
5-step guided setup triggered by "kickstart" / "get started" / "let's set up":
Workspace Setup → Team Roster → Project Seeding → Knowledge Dump → Dream Primer.
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
