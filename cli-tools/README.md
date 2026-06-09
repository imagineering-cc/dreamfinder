# Vendored CLIs

Zero-dependency Node CLIs that Dreamfinder shells out to via the `run_cli`
tool (`lib/src/tools/cli_tools.dart`), replacing the old hand-maintained
kan + outline MCP servers.

| File | Wraps | Env it reads |
|------|-------|--------------|
| `kan.mjs` | Kan.bn REST API (`/api/v1`) | `KAN_API_KEY`, `KAN_BASE_URL` |
| `outline.mjs` | Outline RPC API | `OUTLINE_API_KEY`, `OUTLINE_API_URL` |

**Why CLIs instead of MCP servers?** The MCP servers were a hand-maintained
*subset* of these CLIs and drifted behind — they lacked onboarding tools
(invite links, user invites) the CLIs already had, which is why River couldn't
onboard people. Shelling out to the full CLIs makes capability gaps
structurally impossible and collapses ~50 MCP tool schemas into one tool.

**Provenance:** these are copies of Nick's canonical CLIs at
`~/.claude/cli-tools/{kan,outline}/`. They have **no npm dependencies** (only
node builtins), so they're copied verbatim into the image — no `npm install`.
If you change behaviour, change the canonical copy first, then re-vendor here:

```sh
cp ~/.claude/cli-tools/kan/kan.mjs       cli-tools/kan.mjs
cp ~/.claude/cli-tools/outline/outline.mjs cli-tools/outline.mjs
```

**Note — `OUTLINE_API_URL` vs `OUTLINE_BASE_URL`:** the outline CLI reads
`OUTLINE_API_URL`, but Dreamfinder's env/secrets use `OUTLINE_BASE_URL` (the
old MCP server's name). The `run_cli` executor translates between them.
