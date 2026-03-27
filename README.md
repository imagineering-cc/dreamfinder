# Dreamfinder

> _"One little spark of inspiration is at the heart of all creation."_

An AI-powered project management bot for the Imagineering organization, built on
Matrix. Named after the Dreamfinder from EPCOT's Journey Into Imagination — the
imaginative mentor who dreamed Figment into existence — **Dreamfinder** turns sparks
of ideas into organized tasks, docs, and team coordination.

Every message flows through a Claude LLM agent loop with access to ~75 tools across
task management (Kan.bn), knowledge base (Outline), calendar (Radicale), web
automation (Playwright), and custom bot tools. No slash commands — just natural
language.

> **Status**: Deployed and running. 710+ tests, 16 domain tables, schema v7.
> Migrating from Signal to Matrix — a
> [matrix chat superbridge](https://github.com/imagineering-cc/matrix-chat-superbridge)
> relays between Matrix and Signal/Discord/Telegram/WhatsApp using puppet accounts,
> so Dreamfinder only connects to Matrix.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Chat Platforms                                │
│       Signal  ·  Discord  ·  Telegram  ·  WhatsApp  ·  Matrix       │
└──────────┬───────────┬────────────┬────────────┬─────────┬───────────┘
           │           │            │            │         │
           ▼           ▼            ▼            ▼         │
┌──────────────────────────────────────────────────────┐  │
│              Matrix Chat Superbridge                  │  │
│         (puppet accounts per platform)                │  │
└──────────────────────────┬───────────────────────────┘  │
                           │                              │
                           ▼                              │
┌──────────────────────────────────────────────────────────┤
│                     Matrix Homeserver                     │
│                  (matrix.imagineering.cc)                 │
└──────────────────────────┬───────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│                         Dreamfinder                                   │
│                                                                      │
│  ┌──────────────┐    ┌──────────────┐    ┌────────────────────────┐  │
│  │   Message     │    │  Agent Loop  │    │    Cron Scheduler      │  │
│  │   Handler     │───▶│  (Claude     │    │  - Task nudges         │  │
│  │  - Rate limit │    │   Sonnet)    │    │  - Standup prompts     │  │
│  │  - History    │    │              │    │  - Repo radar digest   │  │
│  │  - Context    │    │  ┌────────┐  │    └────────────┬───────────┘  │
│  └──────────────┘    │  │ Tools  │  │                 │              │
│                       │  └───┬────┘  │                 │              │
│                       └──────┼───────┘                 │              │
│                              │                         │              │
│  ┌───────────────────────────┼─────────────────────────┼──────────┐  │
│  │                     Tool Layer                                  │  │
│  │                                                                 │  │
│  │  ┌──────────┐ ┌─────────┐ ┌──────────┐ ┌───────────────────┐   │  │
│  │  │  Kan.bn  │ │ Outline │ │ Radicale │ │    Playwright     │   │  │
│  │  │  (Tasks) │ │ (Wiki)  │ │ (Cal)    │ │    (Browser)      │   │  │
│  │  └──────────┘ └─────────┘ └──────────┘ └───────────────────┘   │  │
│  │                                                                 │  │
│  │  ┌───────────────────────────────────────────────────────────┐  │  │
│  │  │ Custom Tools: chat config, user mapping, standups,       │  │  │
│  │  │ bot identity, memory (RAG), repo radar, session, GitHub  │  │  │
│  │  └───────────────────────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │  SQLite (sqlite3 package) — 16 domain tables, schema v7        │  │
│  │  Conversations, config, user mappings, standups, dreams,       │  │
│  │  radar repos, bot state, RAG memory                            │  │
│  └─────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

## Features

### Task Management (via Kan.bn)

- Create, update, and close tasks through natural conversation
- List tasks by board, list, assignee, or label
- Manage checklists, comments, and labels
- Sprint planning and tracking

### Knowledge Base (via Outline)

- Search and retrieve documents
- Create and update wiki pages from chat
- Browse collections and recent documents

### Calendar (via Radicale)

- View upcoming events and deadlines — 7-day lookahead injected into system prompt
- Create and manage calendar events
- Todo list management
- Timezone-aware display (`EVENT_TIMEZONE`)

### Team Coordination

- Async daily standups — bot prompts team members and collects responses
- Standup summaries posted to group
- Timezone-aware prompt scheduling (per-group IANA timezone config)
- Proactive task nudges — overdue and stale Kan cards flagged daily at configurable hour
- User identity mapping (platform user ID to Kan.bn user)
- Auto-onboard — welcomes new members joining rooms and invites them to DM for setup

### Bot Intelligence

- Full natural language understanding — no slash commands needed
- Conversation history with 20-message window and 30-minute TTL
- RAG long-term memory — Voyage AI embeddings, cosine similarity retrieval, context
  injection
- Agentic RAG — `deep_search` fans out across memory, Outline, and Kan in parallel
- Rate limiting in group chats to avoid noise
- Configurable per-chat settings (enabled tools, response style)
- Bot personality/identity customization

### Dream Cycle

Autonomous multi-phase agent session triggered by "goodnight" messages, modeled after
real sleep stages:

```
Light (N1→N2) → Deep (N2→N3) → Branch per spark (parallel) → REM (converge) → Wake
```

- **Light Sleep**: Files obvious items from chat history into Kan/Outline
- **Deep Sleep**: Finds connections, surfaces `[SPARK]` tags for creative threads
- **Dream Branching**: Each spark becomes a parallel agent thread (`Future.wait`)
- **REM Convergence**: Merges branch reports, finds meta-patterns
- **Waking Message**: In-character summary with dream stats
- Adaptive depth — quiet days skip deeper phases
- Token usage tracked across all phases and branches

### Session Facilitation

Dreamfinder facilitates co-working sessions with an 8-phase state machine:

```
Pitch → Build 1 → Chat 1 → Build 2 → Chat 2 → Build 3 → Chat 3 → Demo
```

- Detected via natural language ("let's do a session", etc.)
- 4 custom tools for session management
- State machine with prompt injection per phase
- Encourages focused build sprints with check-in conversations

### Kickstart Guided Onboarding

6-step guided setup triggered by natural language ("kickstart", "get started", etc.):

1. **Workspace Setup** — Link Kan workspace and default board
2. **Team Roster** — Map chat users to Kan members
3. **Project Seeding** — Create cards and docs for active projects
4. **Knowledge Dump** — Capture decisions, conventions, context
5. **Dream Primer** — Summarize setup and introduce the dream cycle
6. **First Nudge** — Demonstrate proactive task awareness

Users DM Dreamfinder to onboard — the bridge can't initiate DMs to native platforms.

### Repo Radar

Track and discover GitHub repositories relevant to the org:

- Star, search, and crawl repos
- Draft contribution ideas
- Daily digest via scheduler
- Context injected into system prompt

### MCP Configuration

MCP servers are loaded from `mcp-config.json` — add a new MCP server to the config,
restart, and the tools are available. No code changes needed.

## Tech Stack

| Component       | Technology                             |
| --------------- | -------------------------------------- |
| Language        | Dart 3.6+                              |
| Runtime         | Dart VM                                |
| Messaging       | Matrix (via Client-Server API)         |
| LLM             | Claude Sonnet 4.6 (anthropic_sdk_dart) |
| MCP             | dart_mcp ^0.4.1                        |
| Database        | SQLite (via sqlite3 package)           |
| Task Management | Kan.bn (MCP)                           |
| Knowledge Base  | Outline (MCP)                          |
| Calendar        | Radicale (MCP)                         |
| Web Automation  | Playwright (MCP)                       |
| Deployment      | Docker + Docker Compose on GCP         |
| Package Manager | dart pub                               |

## Getting Started

### Prerequisites

- Dart SDK 3.6+
- Docker and Docker Compose (for deployment)
- Anthropic API key (or Claude Max OAuth via `CLAUDE_REFRESH_TOKEN`)
- A Matrix homeserver with an account for the bot
- Running instances of Kan.bn, Outline, and Radicale

### Installation

```bash
# Clone the repo (--recurse-submodules pulls the shared MCP servers)
git clone --recurse-submodules git@github.com:imagineering-cc/dreamfinder.git
cd dreamfinder

# If you already cloned without --recurse-submodules:
git submodule update --init

# Install Dart dependencies
dart pub get

# Install MCP server dependencies
for pkg in kan outline radicale; do
  (cd mcp-servers/packages/$pkg && npm install)
done

# Set up environment
cp .env.example .env
# Edit .env with your credentials

# Run the bot
dart run bin/dreamfinder.dart
```

### Environment Configuration

All environment variables are documented in `.env.example`:

```bash
# Required — LLM
ANTHROPIC_API_KEY=            # Claude API key
CLAUDE_REFRESH_TOKEN=         # OAuth refresh token (alternative to API key)

# Required — Matrix
MATRIX_HOMESERVER=            # Matrix homeserver URL (e.g., https://matrix.imagineering.cc)
MATRIX_ACCESS_TOKEN=          # Matrix bot access token (or use username+password)
MATRIX_USERNAME=              # Matrix login username (alternative to access token)
MATRIX_PASSWORD=              # Matrix login password (alternative to access token)
MATRIX_IGNORE_ROOMS=          # Comma-separated room IDs to ignore (optional)

# Required — MCP tools
KAN_BASE_URL=                 # Kan.bn instance URL
KAN_API_KEY=                  # Kan.bn API key
OUTLINE_BASE_URL=             # Outline instance URL
OUTLINE_API_KEY=              # Outline API key

# Radicale (optional — calendar/contacts features)
RADICALE_BASE_URL=            # Radicale CalDAV/CardDAV server URL
RADICALE_USERNAME=            # Radicale auth username
RADICALE_PASSWORD=            # Radicale auth password

# Optional
VOYAGE_API_KEY=               # Voyage AI key for RAG memory embeddings
CALENDAR_URL=                 # CalDAV calendar URL for event awareness
EVENT_TIMEZONE=               # IANA timezone for event display (e.g., Australia/Melbourne)
BOT_NAME=                     # Display name (default: "Dreamfinder")
DATABASE_PATH=                # SQLite path (default: ./data/bot.db)
LOG_LEVEL=                    # Logging level (default: info)
```

## Matrix Integration

Dreamfinder connects directly to a Matrix homeserver using the
[Client-Server API](https://spec.matrix.org/latest/client-server-api/) via the `http`
package — the same lightweight approach used for the original Signal client. No
Matrix SDK dependency.

A separate [matrix chat superbridge](https://github.com/imagineering-cc/matrix-chat-superbridge)
handles relay between Matrix and other platforms (Signal, Discord, Telegram, WhatsApp)
using puppet accounts. Dreamfinder only sees Matrix rooms and events.

```
Signal user ──puppet──┐
Discord user ─puppet──┤── Matrix Room ──── Dreamfinder
Telegram user ─puppet─┤
WhatsApp user ─puppet─┘
```

### Matrix Client Capabilities

- **Auth**: Access token or username/password login
- **Sync**: Long-polling `/sync` with persisted sync token
- **Send**: Messages, typing indicators
- **Rooms**: Auto-join on invite, room member queries, DM detection via member count
- **Mentions**: Matrix pills + name regex

## MCP Integration

MCP (Model Context Protocol) servers run as child processes managed by `McpManager`.
The `dart_mcp` package provides the Dart client for MCP protocol communication via
STDIO transport. Server configuration is loaded from `mcp-config.json`.

The MCP server packages (Kan, Outline, Radicale) live in a
[git submodule](https://github.com/nickmeinhold/mcp-servers) at `mcp-servers/`.
Run `git submodule update --remote` to pull the latest.

### Available Tool Sets (~75 tools total)

| Server     | Tools | Examples                                             |
| ---------- | ----- | ---------------------------------------------------- |
| Kan.bn     | ~15   | List boards, create card, update card, manage labels |
| Outline    | ~15   | Search docs, create document, list collections       |
| Radicale   | ~15   | List events, create todo, manage contacts            |
| Playwright | ~20   | Navigate, screenshot, fill form, click element       |
| Custom     | ~10   | Chat config, user mapping, standups, memory, radar   |

### Custom Tools

In addition to MCP server tools, the bot defines its own tools in `lib/src/tools/`:

- **chat_config** — Workspace linking, default board/list config per group
- **user_mapping** — Map platform user IDs to Kan.bn users and display names
- **bot_identity** — Get/set bot name, pronouns, and communication tone
- **memory** — Save, search, and manage long-term RAG memories
- **standup** — Collect and summarize daily standup responses
- **kickstart** — Advance and complete guided onboarding steps
- **radar** — Track, search, star repos; crawl for contribution ideas
- **session** — Facilitate co-working sessions with phase management
- **github** — GitHub integration tools

## Development

### Project Structure

```
lib/
  src/
    matrix/         # Matrix client, models, auth
    signal/         # Signal client, message models (legacy, being replaced)
    agent/          # Agent loop, system prompt, tool registry, conversation history
    mcp/            # MCP subprocess manager
    memory/         # RAG long-term memory (embedding client, pipeline, retriever)
    config/         # Environment config
    tools/          # Custom tool definitions (8 modules)
    db/             # SQLite database, schema, queries (12 mixins), message repository
    dream/          # Dream cycle orchestrator, sleep stage prompts
    session/        # Session facilitation state machine, prompts
    kickstart/      # Guided onboarding detection, state, prompts
    cron/           # Scheduled jobs (standup, nudges, radar digest)
    bot/            # Message handler, rate limiting, health check, deploy announcer
    logging/        # Structured logging
    meetup/         # Meetup event integration
bin/                # Entry point (dreamfinder.dart)
test/               # Tests mirroring lib/src/ structure (54 test files)
data/               # SQLite database (gitignored)
docker/             # Dockerfiles and compose configs
```

### Commands

```bash
dart pub get                       # Install dependencies
dart run bin/dreamfinder.dart      # Run the bot
dart test                          # Run tests
dart analyze                       # Static analysis
dart format .                      # Format code
dart compile exe bin/dreamfinder.dart  # Compile for production
```

### Testing

We follow **ATDD** (Acceptance Test-Driven Development):

1. Write an acceptance test describing the desired behavior
2. Watch it fail
3. Implement the feature
4. Watch the test pass
5. Refactor

Tests are organized to mirror the `lib/src/` directory structure inside `test/`.
Integration tests for MCP tools use recorded fixtures to avoid hitting live services.
We use `mocktail` for mocking.

## Deployment

### Docker

```bash
# Build and start
docker compose up -d

# View logs
docker compose logs -f bot

# Restart bot only
docker compose restart bot
```

Deployed on GCP Compute Engine. The bot container connects to the Matrix homeserver
over HTTPS — no sidecar containers needed for messaging.

## License

TBD

---

Built with one little spark and Claude Code by the Imagineering team.
