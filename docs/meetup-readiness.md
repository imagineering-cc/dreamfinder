# River — Pre-Meetup Readiness Checklist

**Time budget: 5 minutes.** Execute top-to-bottom before any demo where real humans
will message River from their phones. Learned from the 2026-05-11 AMR meetup
near-miss: `not_mentioned: 1` in `drop_reasons` — the meetup room wasn't on
`MATRIX_ALWAYS_RESPOND_ROOMS`. Fixed in ~90 seconds once diagnosed.

---

## 1. Health check — bot is alive and polling

```bash
ssh nick@149.118.69.221 'curl -s http://localhost:8081/health' | python3 -m json.tool
```

**Expected output:**
```json
{
  "status": "ok",
  "last_poll": "2026-...",
  "error_count": 0,
  ...
}
```

**Pass:** `status: ok`, `last_poll` timestamp is within the last 60 seconds.

**Fail — `status: degraded`:** Poll has stalled or a message is stuck in the agent
loop. Check `docker logs dreamfinder --tail 50` for the error. Recreate the container:
`docker compose up -d dreamfinder`.

**Fail — connection refused:** Bot is down. `docker compose up -d dreamfinder`.

---

## 2. Enumerate joined rooms

```bash
ssh nick@149.118.69.221 \
  'source /opt/dreamfinder/.env && \
   curl -s -H "Authorization: Bearer $MATRIX_ACCESS_TOKEN" \
   "$MATRIX_HOMESERVER/_matrix/client/v3/joined_rooms"' | python3 -m json.tool
```

**Expected output:** JSON object with a `joined_rooms` array of room IDs.

**Save the list** — you'll use it in steps 3 and 4.

**Fail — 401 Unauthorized:** `MATRIX_ACCESS_TOKEN` is expired or wrong. Re-auth via
`MATRIX_USERNAME`+`MATRIX_PASSWORD` and update the env file, then recreate the
container.

---

## 3. Confirm demo room(s) are on MATRIX_ALWAYS_RESPOND_ROOMS

For each room ID where real people will be messaging River during the demo:

```bash
ssh nick@149.118.69.221 'grep MATRIX_ALWAYS_RESPOND_ROOMS /opt/dreamfinder/.env'
```

**Expected:** The demo room ID(s) appear in the comma-separated list.

**Fail — demo room missing:** Append the room ID to `MATRIX_ALWAYS_RESPOND_ROOMS` in
`/opt/dreamfinder/.env`, then recreate the container:

```bash
# On the VPS:
sed -i 's/MATRIX_ALWAYS_RESPOND_ROOMS=\(.*\)/MATRIX_ALWAYS_RESPOND_ROOMS=\1,!your-room-id:imagineering.cc/' /opt/dreamfinder/.env
docker compose up -d dreamfinder
```

**Alternative to config change:** Coach all demo participants to `@River` (or
`@dreamfinder`) in every message. Mention detection fires on the bot's display name or
Matrix pill. Only use this as a fallback — silent drops are harder to debug mid-demo.

> **Why this step exists:** The incident. `MATRIX_ALWAYS_RESPOND_ROOMS` is a
> whitelist — rooms not on it require a mention or River being the last speaker.
> A freshly created meetup room will never be on the list unless you add it.

---

## 4. Confirm demo room is not on MATRIX_IGNORE_ROOMS

```bash
ssh nick@149.118.69.221 'grep MATRIX_IGNORE_ROOMS /opt/dreamfinder/.env'
```

**Expected:** The demo room ID is NOT in the list (or the var is empty).

**Fail:** Remove the room ID from `MATRIX_IGNORE_ROOMS`, recreate the container.
`ignored_room` drops are silent and immediate — no log warning, just the counter.

---

## 5. Send a test message from a non-bot account

From your own Matrix account (or a test account that is NOT the bot), send any message
to the demo room. Wait up to 15 seconds for a reply.

**Expected:** River responds within 15 seconds.

**Fail — no reply within 15s:** Go to step 6.

---

## 6. Re-check drop_reasons after the test message

```bash
ssh nick@149.118.69.221 'curl -s http://localhost:8081/health' | python3 -c \
  "import sys,json; h=json.load(sys.stdin); print('processed:', h['messages_processed']); print('drops:', h['drop_reasons'])"
```

**Pass:** `messages_processed` incremented (or `drop_reasons` unchanged from before
the test).

**Diagnostic flowchart:**

| `messages_processed` | `drop_reasons` | Diagnosis |
|---|---|---|
| 0 | non-empty | Config/filter gap — see the `drop_reasons` key below |
| 0 | empty | No traffic reaching the bot — Matrix sync issue or wrong room |
| > 0 | empty | Agent loop / LLM issue — check `error_count` and docker logs |

**Per drop_reason remedies:**

| Key | Meaning | Fix |
|---|---|---|
| `not_mentioned` | Room not on always-respond list AND no mention | Add room to `MATRIX_ALWAYS_RESPOND_ROOMS` (step 3) |
| `ignored_room` | Room is on `MATRIX_IGNORE_ROOMS` | Remove from ignore list (step 4) |
| `rate_limited` | >5 messages in 30s from a group, or same user < 5s apart | Wait 30s, then retry. Raise `maxGroupMessages` if needed |
| `no_text` | Event had no text body (e.g. image, state event) | Send a text message |
| `own_message` | Bot's own messages are always skipped | Normal — ignore |
| `member_join` | Join events are skipped after sending welcome | Normal — ignore |
| `bot_skipped` | River deliberately chose not to respond (`[skip]`) | River decided to stay quiet — this is intentional |

---

## 7. Check error_count and last_claude_success

```bash
ssh nick@149.118.69.221 'curl -s http://localhost:8081/health' | python3 -c \
  "import sys,json; h=json.load(sys.stdin); print('errors:', h['error_count']); print('last_claude:', h['last_claude_success'])"
```

**Expected:** `error_count: 0`, `last_claude_success` is recent (within the last few
minutes if the test message in step 5 worked).

**Fail — error_count > 0:** `docker logs dreamfinder --tail 100 | grep ERROR` to see
what failed. Common causes: expired OAuth token, MCP server crash, malformed tool call.

**Fail — last_claude_success null:** Claude API has never responded since last start.
Check `ANTHROPIC_API_KEY` or `CLAUDE_REFRESH_TOKEN`. Verify with:
`docker logs dreamfinder --tail 20`.

---

## 8. Rate-limit awareness for high-traffic demos

The default limits are: **5s per-user cooldown**, **5 messages per group per 30s**.

If you expect rapid-fire messages from many participants simultaneously:

```bash
# Check current env — there are no env vars to override these yet;
# they're hardcoded in RateLimiter. If you need higher limits for a
# specific event, redeploy with a patched RateLimiter constructor.
grep -n 'RateLimiter' /opt/dreamfinder/lib/src/bot/rate_limiter.dart 2>/dev/null || \
  echo "Source not on VPS — check the running image version"
```

**Operational workaround:** During a burst demo, space out messages by at least 5s per
person. River will still process them; group throttle refills every 30s.

---

## 9. Embodied River (df.imagineering.cc) — separate verification required

If the demo includes the 3D voice avatar:

- The embodied avatar (`df.imagineering.cc`) has its **own audio pipeline and gate
  layer** — it is NOT covered by the text bot's `/health` endpoint.
- River's voice brain talks to the text bot via `/api/memory/recent` and
  `/api/conversations/recent`, but those are read-only. A text bot config gap won't
  silence the voice; a voice infra gap won't show in `/health`.
- Before any voice demo: open `df.imagineering.cc`, confirm the WebRTC connection
  establishes, speak a test phrase, confirm audio response.
- See memory file
  `~/.claude/projects/-Users-nick-git-orgs-imagineering-dreamfinder/memory/project_embodied_df_voice_arch.md`
  for substrate details (OpenAI Realtime ↔ LiveKit local Whisper+Haiku+Piper hot-swap).

**Known gap:** There is no automated health check for the embodied avatar. Voice
substrate failures are currently diagnosed by ear only.

---

## Quick-Reference: Incident Replay Commands

If River goes silent mid-demo, execute these in order. Each takes < 10 seconds.

```bash
# 1. Get health snapshot
ssh nick@149.118.69.221 'curl -s http://localhost:8081/health'

# 2. If not_mentioned → add room and bounce
ssh nick@149.118.69.221 'echo "add !ROOMID to MATRIX_ALWAYS_RESPOND_ROOMS in .env, then:"'
ssh nick@149.118.69.221 'cd /opt/dreamfinder && docker compose up -d dreamfinder'

# 3. If container dead
ssh nick@149.118.69.221 'cd /opt/dreamfinder && docker compose up -d dreamfinder'

# 4. If LLM errors
ssh nick@149.118.69.221 'docker logs dreamfinder --tail 50'
```

**Total time from "River is silent" to fix, if cause is `not_mentioned`:** ~90 seconds.
