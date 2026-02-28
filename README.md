# Figment — imagineering-pm-bot

> _"One little spark of inspiration is at the heart of all creation."_

An AI-powered project management bot for Signal, built for the Imagineering organization. Named after the beloved purple dragon from EPCOT's Journey Into Imagination — the mascot of Walt Disney Imagineering — **Figment** turns sparks of ideas into organized tasks, docs, and team coordination.

The bot processes every message through a Claude LLM agent loop with access to ~75 tools across task management (Kan.bn), knowledge base (Outline), calendar (Radicale), web automation (Playwright), and custom bot tools. No slash commands — just natural language.

> **Status**: Early-stage planning. No source code yet — docs and architecture only. Adapted from xdeca-pm-bot, a production Telegram bot with the same architecture.

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
│           signal-cli-rest-api  OR  signal-sdk                       │
│         (Dockerized REST API)    (TypeScript SDK)                   │
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
│  │  SQLite + Drizzle ORM                                         │  │
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
| Language        | TypeScript 5.x                                 |
| Runtime         | Node.js 22+                                    |
| Messaging       | Signal (via signal-cli-rest-api or signal-sdk) |
| LLM             | Claude Sonnet 4.6 (Anthropic API)              |
| Database        | SQLite + Drizzle ORM                           |
| Task Management | Kan.bn (MCP)                                   |
| Knowledge Base  | Outline (MCP)                                  |
| Calendar        | Radicale (MCP)                                 |
| Web Automation  | Playwright (MCP)                               |
| Deployment      | Docker + Docker Compose on GCP                 |
| Package Manager | pnpm                                           |

## Getting Started

### Prerequisites

- Node.js 22+
- pnpm 9+
- Docker and Docker Compose (for Signal bridge and deployment)
- A dedicated phone number for the bot's Signal account
- Anthropic API key
- Running instances of Kan.bn, Outline, and Radicale

### Installation

> **Note**: The project is in early planning. These steps will work once scaffolding
> is complete.

```bash
# Clone with submodules (MCP servers)
git clone --recurse-submodules git@github.com:enspyrco/imagineering-pm-bot.git
cd imagineering-pm-bot

# Install dependencies
pnpm install

# Set up environment
cp .env.example .env
# Edit .env with your credentials

# Generate database
pnpm db:generate
pnpm db:migrate

# Start in development mode
pnpm dev
```

### Environment Configuration

All environment variables (will be documented in `.env.example` once scaffolding is
complete):

```bash
# Required
ANTHROPIC_API_KEY=            # Claude API key
SIGNAL_PHONE_NUMBER=          # Bot's registered Signal phone number
SIGNAL_API_URL=               # signal-cli-rest-api base URL (if using REST approach)
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
NODE_ENV=                     # production | development
```

## Signal Bot Setup (TBD)

Signal does not have an official bot API. We are evaluating two approaches:

### Option A: signal-cli-rest-api (Sidecar Container)

[signal-cli-rest-api](https://github.com/bbernhard/signal-cli-rest-api) is the most
mature solution — actively maintained with a large community. It wraps signal-cli in a
Docker container exposing REST endpoints.

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

### Option B: signal-sdk (Native TypeScript)

[signal-sdk](https://github.com/benoitpetit/signal-sdk) is a TypeScript-native SDK
that bundles signal-cli binaries and provides an event-driven bot framework.

```typescript
import { SignalBot } from "signal-sdk";

const bot = new SignalBot({ phoneNumber: "+1234567890" });

bot.on("message", async (message) => {
  // Process through agent loop
  const response = await agentLoop(message);
  await bot.sendMessage(message.sender, response);
});

bot.start();
```

**Pros**: Native TypeScript, event-driven, built-in bot framework, no sidecar needed.

**Cons**: Newer project, smaller community, bundles JVM binaries (large).

### Decision Criteria

- Group message handling (mentions, reactions, replies)
- Reliability and error recovery
- Attachment support (images, files)
- Long-term maintenance and community
- Docker deployment ergonomics
- Message delivery guarantees

## MCP Integration

MCP (Model Context Protocol) servers will run as child processes and expose tools that
Claude can invoke during the agent loop. They will be included as a git submodule at
`mcp-servers/` (not yet set up).

```bash
# Initialize MCP servers (once submodule is added)
git submodule update --init --recursive
```

### Available Tool Sets (~75 tools total)

| Server     | Tools | Examples                                             |
| ---------- | ----- | ---------------------------------------------------- |
| Kan.bn     | ~15   | List boards, create card, update card, manage labels |
| Outline    | ~15   | Search docs, create document, list collections       |
| Radicale   | ~15   | List events, create todo, manage contacts            |
| Playwright | ~20   | Navigate, screenshot, fill form, click element       |
| Custom     | ~10   | Chat config, user mapping, sprint info, standups     |

### Custom Tools

In addition to MCP server tools, the bot defines its own tools in `src/tools/`:

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

### Commands

```bash
pnpm dev              # Development with watch mode
pnpm build            # Production build
pnpm start            # Run production build
pnpm test             # Run tests
pnpm test:watch       # Run tests in watch mode
pnpm lint             # ESLint
pnpm format           # Prettier
pnpm typecheck        # tsc --noEmit
pnpm db:generate      # Generate migration from schema
pnpm db:migrate       # Apply migrations
pnpm db:studio        # Drizzle Studio GUI
```

### Testing

We follow **ATDD** (Acceptance Test-Driven Development):

1. Write an acceptance test describing the desired behavior
2. Watch it fail
3. Implement the feature
4. Watch the test pass
5. Refactor

Tests are organized to mirror the `src/` directory structure. Integration tests
for MCP tools use recorded fixtures to avoid hitting live services.

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

- **bot** — The Node.js application
- **signal-api** — signal-cli-rest-api container (if using Option A)

### GCP

Deployment target is Google Cloud Platform. Specific infrastructure (Cloud Run, GCE,
GKE) is TBD based on Signal bridge requirements. The signal-cli-rest-api container
needs persistent storage for Signal account state, which influences the deployment
model.

## Relationship to xdeca-pm-bot

This project is a direct adaptation of **xdeca-pm-bot** (private repo), a production
Telegram bot serving the xDeca organization. The core architecture is identical:

| Aspect             | xdeca-pm-bot           | imagineering-pm-bot    |
| ------------------ | ---------------------- | ---------------------- |
| Messaging          | Telegram (grammY)      | Signal (TBD)           |
| Organization       | xDeca                  | Imagineering           |
| LLM                | Claude Sonnet 4.6      | Claude Sonnet 4.6      |
| MCP Tools          | Kan, Outline, Radicale | Kan, Outline, Radicale |
| Database           | SQLite + Drizzle       | SQLite + Drizzle       |
| Agent Architecture | Same                   | Same                   |
| Deployment         | Docker on GCP          | Docker on GCP          |

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
