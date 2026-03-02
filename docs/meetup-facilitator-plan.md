# Meetup Facilitator — Dreamfinder in Google Meet

## Vision

Dreamfinder joins a Google Meet call as a live participant, facilitates a structured
build-sprint meetup using voice (TTS) and listening (caption scraping), and keeps things
moving with personality. Think: an AI MC that talks, listens, and gently interrupts
over-runners.

## Meetup Format (2 hours)

| Phase | Duration | Dreamfinder's Role |
|-------|----------|--------------------|
| Project Intros | 5 min total | Prompt each participant (1 min hard stop), interrupt gracefully if over |
| Sprint 1 | 25 min | Announce start, silence, announce "5 min left", call time |
| Break 1 | 10 min | "Share progress, ask questions!", casual, call time |
| Sprint 2 | 25 min | Same as Sprint 1 |
| Break 2 | 10 min | Same as Break 1 |
| Sprint 3 | 25 min | Same as Sprint 1 |
| Break 3 | 10 min | Same as Break 1 |
| Demos | 5 min total | Prompt each participant (1 min hard stop), wrap up |

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Google Meet (Playwright-controlled Chrome browser)          │
│                                                             │
│  ┌─────────────────┐  ┌──────────────────────────────────┐  │
│  │ speechSynthesis  │  │ Caption/transcript scraping      │  │
│  │ .speak()         │  │ (MutationObserver on caption DOM)│  │
│  │                  │  │                                  │  │
│  │ Dreamfinder      │  │ Real-time text of who's talking  │  │
│  │ TALKS            │  │ Dreamfinder LISTENS              │  │
│  └────────┬─────────┘  └──────────────┬───────────────────┘  │
│           │                           │                      │
│  ┌────────┴───────────────────────────┴───────────────────┐  │
│  │ Meet Chat (fallback text + commands)                    │  │
│  └────────────────────────┬───────────────────────────────┘  │
└───────────────────────────┼─────────────────────────────────┘
                            │
                  ┌─────────┴──────────┐
                  │  Meetup Orchestrator │
                  │  (Dart)             │
                  ├─────────────────────┤
                  │ • Session state     │
                  │   machine           │
                  │ • Phase timer       │
                  │ • Participant       │
                  │   tracker           │
                  │ • Interrupt logic   │
                  └─────────┬──────────┘
                            │
                  ┌─────────┴──────────┐
                  │  Claude Agent Loop  │
                  │                     │
                  │ Decides WHAT to say │
                  │ (personality, tone, │
                  │  context-aware)     │
                  └─────────────────────┘
```

## Speaking — Browser TTS

Use Playwright's `page.evaluate()` to call the Web Speech API:

```javascript
// Dreamfinder speaks
const utterance = new SpeechSynthesisUtterance("Time's up! Great work everyone.");
utterance.rate = 1.0;
utterance.pitch = 1.0;
// Pick a good voice (enumerate with speechSynthesis.getVoices())
speechSynthesis.speak(utterance);
```

The browser's audio output routes into Google Meet's audio. No virtual audio device
needed — Meet picks up system audio from the browser tab.

**Key detail**: Chrome may need `--autoplay-policy=no-user-gesture-required` flag or a
user gesture before TTS works. Playwright can click something first to satisfy this.

**Voice selection**: Enumerate voices on startup, pick one that sounds good. Save the
preference. macOS Chrome has decent options (Samantha, Daniel, etc.).

## Listening — Caption Scraping

Google Meet shows live captions. Playwright can observe the caption DOM:

```javascript
// Watch for caption updates
const observer = new MutationObserver((mutations) => {
  const captionContainer = document.querySelector('[class*="caption"]');
  if (captionContainer) {
    const speaker = captionContainer.querySelector('[class*="name"]')?.textContent;
    const text = captionContainer.querySelector('[class*="text"]')?.textContent;
    // Send to Dart via a callback or polling mechanism
    window.__dreamfinderCaptions = window.__dreamfinderCaptions || [];
    window.__dreamfinderCaptions.push({ speaker, text, timestamp: Date.now() });
  }
});
observer.observe(document.body, { childList: true, subtree: true });
```

**Polling from Dart**: Every 1-2 seconds, Playwright evaluates
`window.__dreamfinderCaptions.splice(0)` to drain the buffer and process in Dart.

**Alternative**: If caption scraping is flaky, fall back to Web Speech API
`SpeechRecognition` — but this requires mic access and may conflict with Meet's own
audio handling.

**Caption selectors will need discovery** — Google Meet's DOM changes. Use Playwright
snapshot tool to find the right selectors at build time.

## Session State Machine

```
IDLE → INTROS → SPRINT_1 → BREAK_1 → SPRINT_2 → BREAK_2 → SPRINT_3 → BREAK_3 → DEMOS → DONE
```

Each state has:
- `duration`: how long the phase lasts
- `onEnter`: what Dreamfinder says/does when entering
- `onTick`: periodic checks (time warnings, interrupt logic)
- `onExit`: what Dreamfinder says when transitioning

```dart
enum MeetupPhase {
  idle,
  intros,
  sprint1, break1,
  sprint2, break2,
  sprint3, break3,
  demos,
  done,
}

class MeetupSession {
  MeetupPhase phase = MeetupPhase.idle;
  DateTime? phaseStartedAt;
  List<String> participants = [];
  int currentSpeakerIndex = -1;  // For intros/demos
  Map<String, Duration> speakingTime = {};  // Track per-person speaking time
}
```

## Interrupt Logic

During intros and demos (1 min per person):

| Time | Action |
|------|--------|
| 0:00 | "Next up: [name]! Tell us what you're building." |
| 0:45 | (internal) Start listening for natural pause |
| 0:55 | "15 seconds!" (quick, light) |
| 1:00 | If still talking: "Thanks [name]! Love it. Let's keep it moving — [next name], you're up!" |
| 1:10 | If STILL talking: "Alright, we gotta move! [next name], take it away." (firmer) |

The LLM decides the exact wording — personality-driven, not robotic. Context-aware:
if someone's sharing something genuinely important, maybe give 5 extra seconds.

During sprints:
- 5 min warning: "Five minutes left in this sprint!"
- 1 min warning: "One minute! Start wrapping up."
- Time: "Time! Great sprint. 10-minute break starts now — share what you built!"

## Participant Tracking

Option A: **Pre-configured** — admin sets participant list before the meetup.
Option B: **Auto-detect** — scrape the Meet participant list via Playwright.
Option C: **Both** — pre-configure, but verify against Meet participants.

For intros/demos, Dreamfinder needs to know the order. Could be:
- Fixed order (alphabetical, or configured)
- Volunteer-based ("Who wants to go first?") — harder to automate
- Round-robin from participant list

**Recommendation**: Pre-configured list, configurable order. Keep it simple.

## Project Structure

```
lib/src/
  meetup/
    meetup_session.dart       # State machine, phase transitions
    meetup_facilitator.dart   # Orchestrator — ties Meet interaction to session
    meet_browser.dart         # Playwright/browser interaction (join, speak, listen)
    participant_tracker.dart  # Who's spoken, who's next, timing
```

## Implementation Plan (3 Sprints)

### Sprint 1: Join Meet & Speak (25 min)

**Goal**: Dreamfinder joins a Google Meet and announces itself.

1. Create `meet_browser.dart`:
   - Use Playwright MCP to launch Chrome, navigate to Meet link
   - Join as "Dreamfinder" (no-account join flow)
   - Grant mic/camera permissions (camera off, mic on for TTS audio)
   - Implement `speak(String text)` via `speechSynthesis`

2. Create `meetup_session.dart`:
   - Define `MeetupPhase` enum and `MeetupSession` class
   - Phase transition logic with durations

3. Test: Dreamfinder joins a test Meet and says "Hello! I'm Dreamfinder, your
   facilitator today."

**Demo**: "Watch — the bot joins our Meet and introduces itself."

### Sprint 2: Listen & Facilitate Intros (25 min)

**Goal**: Dreamfinder listens via captions and facilitates 1-min intros.

1. Implement caption scraping in `meet_browser.dart`:
   - MutationObserver on caption DOM
   - Poll captions from Dart
   - Detect who's speaking and for how long

2. Create `participant_tracker.dart`:
   - Track current speaker, elapsed time
   - Interrupt triggers at 45s, 55s, 60s

3. Create `meetup_facilitator.dart`:
   - Wire session state + browser + participant tracker
   - Implement intro phase: prompt each person, time them, interrupt/transition

4. Test: Mock caption input, verify interrupt timing and transitions.

**Demo**: "Dreamfinder prompts people for intros and politely cuts them off at 1 minute."

### Sprint 3: Full Session Flow & Polish (25 min)

**Goal**: Complete session flow from intros through demos.

1. Implement sprint/break/demo phases in facilitator
2. Add time warnings during sprints (5 min, 1 min)
3. Wire Claude agent loop for personality-driven announcements
   (instead of hardcoded strings, let Claude generate contextual messages)
4. Integration test the full session flow
5. Ship the PR

**Demo**: "Full meetup facilitation — intros, three sprints with breaks, demos."

## Google Meet Join Flow (Playwright Steps)

1. Navigate to Meet link
2. Click "Enter your name" if prompted → type "Dreamfinder"
3. Turn off camera (click camera toggle)
4. Keep mic on (TTS audio routes through it)
5. Click "Ask to join" or "Join now"
6. Wait for admission (if host has to approve)
7. Enable captions (click CC button)

**Note**: Google Meet's DOM/flow changes periodically. The join sequence will need
Playwright snapshot-based discovery rather than hardcoded selectors. Use the
`browser_snapshot` MCP tool to find elements.

## Configuration

```dart
class MeetupConfig {
  final String meetLink;          // Google Meet URL
  final List<String> participants; // Ordered list of participant names
  final Duration introDuration;    // Per-person intro time (default: 60s)
  final Duration sprintDuration;   // Sprint length (default: 25 min)
  final Duration breakDuration;    // Break length (default: 10 min)
  final Duration demoDuration;     // Per-person demo time (default: 60s)
  final int sprintCount;           // Number of sprints (default: 3)
}
```

Could be stored in the database (new table) or passed as tool args to a
`start_meetup` custom tool.

## Custom Tools

```
start_meetup        — Start a meetup session with a Meet link and participant list
stop_meetup         — End the session early
skip_participant    — Skip to the next person during intros/demos
extend_time         — Give the current speaker more time
get_meetup_status   — Check current phase, time remaining, etc.
```

These let an admin control the session via Signal messages to Dreamfinder,
even while it's facilitating in the Meet.

## Open Questions

1. **Audio routing**: Does Chrome TTS audio actually route into Google Meet's
   outbound audio? Need to test. If not, may need `--use-fake-device-for-media-stream`
   Chrome flag or a virtual audio device.

2. **Caption DOM selectors**: Google Meet's class names are minified/obfuscated.
   Need to discover them via Playwright snapshot. They may change with Meet updates.

3. **Mic permissions**: Playwright can set permissions, but Meet may show its own
   permission dialog. Need to handle this in the join flow.

4. **Latency**: TTS → Meet audio has some latency. Caption scraping → Dart has some
   latency. Total round-trip for "hear someone → decide to interrupt → speak" could be
   3-5 seconds. Acceptable for facilitation but worth measuring.

5. **Multiple voices**: Could Dreamfinder use different voices for different types of
   announcements? (Warm voice for encouragement, brisk voice for time warnings.)

## Phase 1: "It's Sprints All the Way Down"

4 meetups (last Saturday of each month):

| Meetup | Date | Goal |
|--------|------|------|
| 1 | March 28, 2026 | Join Meet + Speak (TTS) |
| 2 | April 25, 2026 | Listen (captions) + Facilitate Intros |
| 3 | May 30, 2026 | Full session flow (sprints, breaks, demos) |
| 4 | June 27, 2026 | Polish, personality tuning, battle-tested |

Each meetup = 3x25min build sprints. By meetup 4, Dreamfinder facilitates
itself facilitating. Maximum recursion achieved.

## Dependencies

- Playwright MCP server (already in stack)
- Chrome with speech synthesis support (standard)
- Google Meet (no API needed — pure browser automation)
- No new Dart packages required (Playwright interaction is via MCP)
