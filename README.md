# Figment — imagineering-pm-bot

> _"One little spark of inspiration is at the heart of all creation."_

An AI-powered project management bot for Signal, built for the Imagineering organization. Named after the beloved purple dragon from EPCOT's Journey Into Imagination — the mascot of Walt Disney Imagineering — **Figment** turns sparks of ideas into organized tasks, docs, and team coordination.

The bot processes every message through a Claude LLM agent loop with access to ~75 tools across task management (Kan.bn), knowledge base (Outline), calendar (Radicale), web automation (Playwright), and custom bot tools. No slash commands — just natural language.

> **Status**: Core architecture scaffolded in Dart — Signal client, agent loop, conversation history, tool registry, MCP manager, and system prompt are implemented. Custom tools, database layer, cron scheduler, and bot message handler are not yet built. Adapted from xdeca-pm-bot, a production Telegram bot with the same architecture.

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
│                    imagineering-pm-bot                               │
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
│  │  SQLite (ORM TBD)                                              │  │
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

| Component       | Technology                                     |
| --------------- | ---------------------------------------------- |
| Language        | Dart 3.6+                                      |
| Runtime         | Dart VM                                        |
| Messaging       | Signal (via signal-cli-rest-api)               |
| LLM             | Claude Sonnet 4.6 (anthropic_sdk_dart)         |
| MCP             | dart_mcp ^0.4.1                                |
| Database        | SQLite (ORM TBD)                               |
| Task Management | Kan.bn (MCP)                                   |
| Knowledge Base  | Outline (MCP)                                  |
| Calendar        | Radicale (MCP)                                 |
| Web Automation  | Playwright (MCP)                               |
| Deployment      | Docker + Docker Compose on GCP                 |
| Package Manager | dart pub                                       |

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
git clone git@github.com:enspyrco/imagineering-pm-bot.git
cd imagineering-pm-bot

# Install dependencies
dart pub get

# Set up environment
cp .env.example .env
# Edit .env with your credentials

# Run the bot
dart run bin/main.dart
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
BOT_NAME=                     # Display name (default: "Figment")
DATABASE_PATH=                # SQLite path (default: ./data/bot.db)
LOG_LEVEL=                    # Logging level (default: info)
```

## Signal Bot Setup

Signal does not have an official bot API. Figment uses
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
      - MODE=json-rpc # Fastest mode

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

In addition to MCP server tools, the bot defines its own tools in `lib/src/tools/`
(not yet scaffolded):

- **chat_config** — Per-chat settings (enabled features, response style, timezone)
- **user_mapping** — Map Signal UUIDs to Kan.bn users and display names
- **sprint_info** — Current sprint metadata (dates, goals, velocity)
- **standup** — Collect and summarize daily standup responses
- **bot_identity** — Bot name, personality, and response guidelines
- **deploy_info** — Current deployment version, uptime, health
- **server_ops** — Diagnostic tools (MCP server status, latency, connection health)

## Development

### Project Structure

```
lib/
  src/
    signal/         # Signal client, message models
    agent/          # Agent loop, system prompt, tool registry, conversation history
    mcp/            # MCP subprocess manager
    config/         # Environment config (not yet scaffolded)
    tools/          # Custom tool definitions (not yet scaffolded)
    db/             # Database layer (not yet scaffolded)
    cron/           # Scheduled jobs (not yet scaffolded)
    bot/            # Message handler, rate limiting (not yet scaffolded)
bin/                # Entry point (not yet scaffolded)
test/               # Tests mirroring lib/src/ structure (not yet scaffolded)
data/               # SQLite database (gitignored)
docker/             # Dockerfiles and compose configs
```

### Commands

```bash
dart pub get                    # Install dependencies
dart run bin/main.dart          # Run the bot
dart test                       # Run tests
dart analyze                    # Static analysis
dart format .                   # Format code
dart compile exe bin/main.dart  # Compile for production
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

| Aspect             | xdeca-pm-bot           | imagineering-pm-bot       |
| ------------------ | ---------------------- | ------------------------- |
| Language           | TypeScript             | Dart                      |
| Messaging          | Telegram (grammY)      | Signal (signal-cli-rest-api) |
| Organization       | xDeca                  | Imagineering              |
| LLM                | Claude Sonnet 4.6      | Claude Sonnet 4.6         |
| MCP Tools          | Kan, Outline, Radicale | Kan, Outline, Radicale    |
| Database           | SQLite + Drizzle       | SQLite (ORM TBD)          |
| Agent Architecture | Same                   | Same                      |
| Deployment         | Docker on GCP          | Docker on GCP             |

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
