# Vendored CLIs

Zero-dependency Node CLIs that Dreamfinder shells out to via the `run_cli`
tool (`lib/src/tools/cli_tools.dart`), replacing the old hand-maintained
kan + outline MCP servers.

| File | Wraps | Env it reads |
|------|-------|--------------|
| `kan.mjs` | Kan.bn REST API (`/api/v1`) | `KAN_API_KEY`, `KAN_BASE_URL` |
| `outline.mjs` | Outline RPC API | `OUTLINE_API_KEY`, `OUTLINE_API_URL` |
| `radicale.mjs` | Radicale CalDAV events (RFC 4791 expand) | `RADICALE_BASE_URL`, `RADICALE_USERNAME`, `RADICALE_PASSWORD` |

**Why CLIs instead of MCP servers?** The MCP servers were a hand-maintained
*subset* of these CLIs and drifted behind — they lacked onboarding tools
(invite links, user invites) the CLIs already had, which is why River couldn't
onboard people. Shelling out to the full CLIs makes capability gaps
structurally impossible and collapses ~50 MCP tool schemas into one tool.

**Provenance:** these are copies of Nick's canonical CLIs at
`~/.claude/cli-tools/{kan,outline,radicale}/`. They have **no npm dependencies** (only
node builtins), so they're copied verbatim into the image — no `npm install`.
If you change behaviour, change the canonical copy first, then re-vendor here
with one command (run on the **dev machine** — the canonical CLIs are not in CI):

```sh
./scripts/vendor-clis.sh
git add cli-tools/   # commit BOTH the *.mjs and .vendored-manifest.sha256
```

`vendor-clis.sh` re-copies from `~/.claude/cli-tools/` (override the root with
`CLAUDE_CLI_TOOLS=...`) **and** regenerates `.vendored-manifest.sha256`.

## Drift guard

`cli-tools/.vendored-manifest.sha256` pins the SHA256 of each vendored file as
committed. CI runs `scripts/check-vendored-clis.sh` (`shasum -c`) on every PR.

**What it catches:**
- Accidental in-repo edits to a vendored `*.mjs` (file changed, manifest not).
- Tampering / merge mistakes that mutate a vendored file.
- A manifest bump committed *without* the matching file change.

It does this by forcing the re-vendor to be a **deliberate two-part commit**
(the file *and* the manifest, regenerated together by `vendor-clis.sh`).

**What it CANNOT catch:** whether the *canonical upstream* CLI has moved ahead.
The canonical copies live only on the dev machine and aren't available in CI, so
freshness vs upstream is impossible to verify there. Resolving that drift means
running `./scripts/vendor-clis.sh` on the dev machine and committing the result —
the guard only keeps the in-repo copy and its manifest internally consistent.

**Note — `OUTLINE_API_URL` vs `OUTLINE_BASE_URL`:** the outline CLI reads
`OUTLINE_API_URL`, but Dreamfinder's env/secrets use `OUTLINE_BASE_URL` (the
old MCP server's name). The `run_cli` executor translates between them.
