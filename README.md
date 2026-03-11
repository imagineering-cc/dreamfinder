# Dreamfinder

> _"One little spark of inspiration is at the heart of all creation."_

An AI-powered project management bot for Signal, built for the Imagineering organization. Named after the Dreamfinder from EPCOT's Journey Into Imagination — the imaginative mentor who dreamed Figment into existence — **Dreamfinder** turns sparks of ideas into organized tasks, docs, and team coordination.

The bot processes every message through a Claude LLM agent loop with access to ~75 tools across task management (Kan.bn), knowledge base (Outline), calendar (Radicale), web automation (Playwright), and custom bot tools. No slash commands — just natural language.

> **Status**: End-to-end bot is runnable. Signal client, agent loop, DB-backed conversation history, tool registry, MCP manager, system prompt, SQLite persistence (10 domain tables), and custom tools (identity + chat config, 10 tools) are implemented with 106+ tests. Cron scheduler, standup orchestration, and dedicated message handler are next. Adapted from xdeca-pm-bot, a production Telegram bot with the same architecture.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Signal Messenger                             │
│                  (Users / Group Conversations)                      │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     Signal Bridge                                   │
│                  signal-cli-rest-api                                 │
│                (Dockerized REST API)                                 │
└──────────────────────────┬──────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        Dreamfinder                                    │
│                                                                     │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────────────┐  │
│  │   Message     │    │  Agent Loop  │    │    Cron Scheduler     │  │
│  │   Handler     │───▶│  (Claude     │    │  - Overdue tasks      │  │
│  │  - Rate limit │    │   Sonnet)    │    │  - Stale tasks        │  │
│  │  - History    │    │              │    │  - Standup prompts    │  │
│  │  - Context    │    │  ┌────────┐  │    │  - Unassigned tasks   │  │
│  └──────────────┘    │  │ Tools  │  │    └───────────┬───────────┘  │
│                       │  └───┬────┘  │                │              │
│                       └──────┼───────┘                │              │
│                              │                        │              │
│  ┌───────────────────────────┼────────────────────────┼───────────┐  │
│  │                     Tool Layer                                 │  │
│  │                                                                │  │
│  │  ┌──────────┐ ┌─────────┐ ┌──────────┐ ┌────────────────────┐ │  │
│  │  │  Kan.bn  │ │ Outline │ │ Radicale │ │    Playwright      │ │  │
│  │  │  (Tasks) │ │ (Wiki)  │ │ (Cal)    │ │    (Browser)       │ │  │
│  │  └──────────┘ └─────────┘ └──────────┘ └────────────────────┘ │  │
│  │                                                                │  │
│  │  ┌────────────────────────────────────────────────────────────┐│  │
│  │  │ Custom Tools: chat config, user mapping, sprint info,     ││  │
│  │  │ standups, bot identity, deploy info, server ops           ││  │
│  │  └────────────────────────────────────────────────────────────┘│  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  SQLite (sqlite3 package)                                       │  │
│  │  Conversations, config, user mappings, standups, bot state    │  │
│  └────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

## Features (Planned)

### Task Management (via Kan.bn)

- Create, update, and close tasks through natural conversation
- List tasks by board, list, assignee, or label
- Manage checklists, comments, and labels
- Sprint planning and tracking
- Automatic reminders for overdue and stale tasks

### Knowledge Base (via Outline)

- Search and retrieve documents
- Create and update wiki pages from chat
- Browse collections and recent documents

### Calendar (via Radicale)

- View upcoming events and deadlines
- Create and manage calendar events
- Todo list management

### Team Coordination

- Async daily standups — bot prompts team members and collects responses
- Standup summaries posted to group
- User identity mapping (Signal UUID to Kan.bn user)

### Bot Intelligence

- Full natural language understanding — no slash commands needed
- Conversation history with 20-message window and 30-minute TTL
- Rate limiting in group chats to avoid noise
- Configurable per-chat settings (enabled tools, response style)
- Bot personality/identity customization

### Reminders (Cron-based)

- Overdue task alerts
- Stale task nudges
- Unassigned task notifications
- Standup prompts at configured times

## Tech Stack

| Component       | Technology                             |
| --------------- | -------------------------------------- |
| Language        | Dart 3.6+                              |
| Runtime         | Dart VM                                |
| Messaging       | Signal (via signal-cli-rest-api)       |
| LLM             | Claude Sonnet 4.6 (anthropic_sdk_dart) |
| MCP             | dart_mcp ^0.4.1                        |
| Database        | SQLite (via sqlite3 package)            |
| Task Management | Kan.bn (MCP)                           |
| Knowledge Base  | Outline (MCP)                          |
| Calendar        | Radicale (MCP)                         |
| Web Automation  | Playwright (MCP)                       |
| Deployment      | Docker + Docker Compose on GCP         |
| Package Manager | dart pub                               |

## Getting Started

### Prerequisites

- Dart SDK 3.6+
- Docker and Docker Compose (for Signal bridge and deployment)
- A dedicated phone number for the bot's Signal account
- Anthropic API key
- Running instances of Kan.bn, Outline, and Radicale

### Installation

```bash
# Clone the repo
git clone git@github.com:imagineering-cc/dreamfinder.git
cd dreamfinder

# Install dependencies
dart pub get

# Set up environment
cp .env.example .env
# Edit .env with your credentials

# Run the bot
dart run bin/dreamfinder.dart
```

### Environment Configuration

All environment variables are documented in `.env.example`:

```bash
# Required
ANTHROPIC_API_KEY=            # Claude API key
SIGNAL_PHONE_NUMBER=          # Bot's registered Signal phone number
SIGNAL_API_URL=               # signal-cli-rest-api base URL

KAN_BASE_URL=                 # Kan.bn instance URL
KAN_API_KEY=                  # Kan.bn API key
OUTLINE_BASE_URL=             # Outline instance URL
OUTLINE_API_KEY=              # Outline API key

# Radicale (optional — calendar/contacts features)
RADICALE_BASE_URL=            # Radicale CalDAV/CardDAV server URL
RADICALE_USERNAME=            # Radicale auth username
RADICALE_PASSWORD=            # Radicale auth password

# Bot Config (all optional, have defaults)
BOT_NAME=                     # Display name (default: "Dreamfinder")
DATABASE_PATH=                # SQLite path (default: ./data/bot.db)
LOG_LEVEL=                    # Logging level (default: info)
```

## Signal Bot Setup

Signal does not have an official bot API. Dreamfinder uses
[signal-cli-rest-api](https://github.com/bbernhard/signal-cli-rest-api) — the most
mature community solution. It wraps signal-cli in a Docker container exposing REST
endpoints that `SignalClient` (in Dart) consumes via HTTP polling.

```yaml
# docker-compose.yml (simplified)
services:
  signal-api:
    image: bbernhard/signal-cli-rest-api:latest
    ports:
      - "8080:8080"
    volumes:
      - ./signal-cli-config:/home/.local/share/signal-cli
    environment:
      - MODE=normal

  bot:
    build: .
    depends_on:
      - signal-api
    environment:
      - SIGNAL_API_URL=http://signal-api:8080
```

**Pros**: Battle-tested, large community, well-documented REST API, runs as a separate
concern.

**Cons**: Extra container to manage, polling-based message receipt (or webhook setup),
indirect communication.

## MCP Integration

MCP (Model Context Protocol) servers run as child processes managed by `McpManager`.
The `dart_mcp` package provides the Dart client for MCP protocol communication — STDIO
transport wiring is in progress.

### Available Tool Sets (~75 tools total)

| Server     | Tools | Examples                                             |
| ---------- | ----- | ---------------------------------------------------- |
| Kan.bn     | ~15   | List boards, create card, update card, manage labels |
| Outline    | ~15   | Search docs, create document, list collections       |
| Radicale   | ~15   | List events, create todo, manage contacts            |
| Playwright | ~20   | Navigate, screenshot, fill form, click element       |
| Custom     | ~10   | Chat config, user mapping, sprint info, standups     |

### Custom Tools

In addition to MCP server tools, the bot defines its own tools in `lib/src/tools/`:

- **chat_config** — Workspace linking, default board/list config per group
- **user_mapping** — Map Signal UUIDs to Kan.bn users and display names
- **bot_identity** — Get/set bot name, pronouns, and communication tone
- **sprint_info** — Current sprint metadata (planned)
- **standup** — Collect and summarize daily standup responses (planned)
- **deploy_info** — Current deployment version, uptime, health (planned)
- **server_ops** — Diagnostic tools (MCP server status, latency) (planned)

## Development

### Project Structure

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
bin/                # Entry point (dreamfinder.dart)
test/               # Tests mirroring lib/src/ structure
data/               # SQLite database (gitignored)
docker/             # Dockerfiles and compose configs
```

### Commands

```bash
dart pub get                    # Install dependencies
dart run bin/dreamfinder.dart      # Run the bot
dart test                       # Run tests
dart analyze                    # Static analysis
dart format .                   # Format code
dart compile exe bin/dreamfinder.dart # Compile for production
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
# Build and start all services
docker compose up -d

# View logs
docker compose logs -f bot

# Restart bot only
docker compose restart bot
```

The Docker Compose setup includes:

- **bot** — The Dart application
- **signal-api** — signal-cli-rest-api container

### GCP

Deployment target is Google Cloud Platform. Specific infrastructure (Cloud Run, GCE,
GKE) is TBD based on Signal bridge requirements. The signal-cli-rest-api container
needs persistent storage for Signal account state, which influences the deployment
model.

## Relationship to xdeca-pm-bot

This project is a direct adaptation of **xdeca-pm-bot** (private repo), a production
Telegram bot serving the xDeca organization. The core architecture is identical:

| Aspect             | xdeca-pm-bot           | Dreamfinder                  |
| ------------------ | ---------------------- | ---------------------------- |
| Language           | TypeScript             | Dart                         |
| Messaging          | Telegram (grammY)      | Signal (signal-cli-rest-api) |
| Organization       | xDeca                  | Imagineering                 |
| LLM                | Claude Sonnet 4.6      | Claude Sonnet 4.6            |
| MCP Tools          | Kan, Outline, Radicale | Kan, Outline, Radicale       |
| Database           | SQLite + Drizzle       | SQLite (sqlite3 package)     |
| Agent Architecture | Same                   | Same                         |
| Deployment         | Docker on GCP          | Docker on GCP                |

### Key Differences from Telegram

Signal presents unique challenges compared to Telegram's mature Bot API:

- **No official bot API** — Relies on unofficial signal-cli tooling
- **Phone number required** — No bot tokens; needs a real phone number
- **No inline keyboards** — Cannot send interactive button menus
- **No message editing** — Cannot update previously sent messages
- **Stricter rate limiting** — Signal is more conservative about message frequency
- **Disappearing messages** — Must handle ephemeral message settings gracefully
- **UUID-based identity** — Users identified by UUID, not numeric ID

These constraints shape the UX: responses must be complete (no editing), interactions
are purely text-based (no buttons), and the bot must be mindful of message frequency.

## License

TBD

---

Built with one little spark and Claude Code by the Imagineering team.
