# Avatar Dreamfinder

> Dreamfinder as an animated character in video calls — listening via STT,
> speaking via TTS, facilitating imagination sessions with a face.

**Status**: Design phase
**Date**: 2026-03-25
**Author**: Nick + Dreamfinder

---

## Vision

Dreamfinder is not a PM bot. It's an imagination-to-implementation facilitator
that happens to have project management tools. The text interface (Matrix) is one
channel. The voice interface (WebRTC video calls) is another. Same agent loop,
same tools, two ways to be present.

In a voice session, Dreamfinder:

- **Listens more than it speaks.** In a 60-minute session, it might talk for 5
  minutes. The rest is listening, noticing patterns, and working silently in the
  background (creating Kan cards, pulling Outline docs, sketching implementation
  plans).
- **Interjects at inflection points**, not after every utterance. "That connects
  to what you discussed last week" or "I just drafted three approaches in
  Outline — I'll share when you're ready."
- **Has a face.** An animated character that nods, looks thoughtful, smiles when
  an idea lands. A face changes how humans interact — you talk *to* someone, not
  *at* a tool.

---

## Character Design

**Identity**: A warm golden wizard-artist, hooded — not a robot. Somewhere between
Pixar and Studio Ghibli. The original Epcot Dreamfinder was a human
inventor-wizard, not a machine. This character carries that spirit.

**Key elements** (from Alexar's 2D concept):
- Golden color palette — warm, inviting, distinct from every blue/white AI
- Floating sparks that react to conversation (brighter when ideas flow, settling
  during focused work)
- Hood giving a wizard/tinkerer vibe
- Big luminous eyes for emotional expression

**Evolution for animated 3D/2D avatar**:
- More expressive face with range for lip sync (visemes) and emotion
- Head and shoulders framing for call view
- More organic, less robotic
- Exists in space, not anchored to a desk/screen

**Rendering approach**: Rive (2D stylized) is recommended over 3D. State
machine-driven lip sync, smooth blending between viseme states, lightweight file
sizes. Duolingo uses this exact approach for their character. A whimsical
illustrated style suits Dreamfinder and avoids uncanny valley.

Alternative: TalkingHead (Three.js, 3D) with a GLB model using ARKit blend
shapes. More complex but allows camera angle changes and physics-based animation.

---

## Technology Stack

### WebRTC Server: LiveKit (self-hosted)

LiveKit is the only open-source WebRTC server with a purpose-built AI agent
framework. It supports synthetic video/audio participants — a server-side process
joins a room as a full WebRTC peer, subscribes to other participants' audio, and
publishes its own audio + video tracks.

**Critical discovery**: Element Call (Matrix's native video calling) already uses
LiveKit as its SFU backend via
[MSC4195](https://github.com/matrix-org/matrix-spec-proposals/pull/4195). This
means users can start a video call in a Matrix room, and Dreamfinder can join the
same LiveKit room as an AI participant. No separate app needed.

- Server: [github.com/livekit/livekit](https://github.com/livekit/livekit) (Go,
  Apache 2.0)
- Agents: [github.com/livekit/agents](https://github.com/livekit/agents) (Python)
- Matrix bridge:
  [github.com/element-hq/lk-jwt-service](https://github.com/element-hq/lk-jwt-service)
  (issues LiveKit JWTs from Matrix auth)
- Flutter client: [pub.dev/packages/livekit_client](https://pub.dev/packages/livekit_client)
  (for future mobile app)

**No Dart server SDK exists.** The voice agent must be Python (LiveKit Agents
framework requirement). The existing Dart bot stays as-is — a thin HTTP API
bridges them.

### STT: Deepgram Nova-3

Real-time streaming transcription with built-in speaker diarization (who's
talking). ~200ms latency on streaming audio.

| Provider | Streaming | Latency | Diarization | Self-hostable |
| --- | --- | --- | --- | --- |
| **Deepgram Nova-3** | Yes (WebSocket) | ~200ms | Yes (real-time) | No |
| AssemblyAI Universal | Yes | ~300ms | Yes | No |
| Whisper (faster-whisper) | Retrofitted | 500ms-2s | Via diart/pyannote | Yes (GPU) |

Deepgram's Flux model embeds turn-taking detection directly into STT, eliminating
separate VAD + endpointing logic. LiveKit Agents has a built-in Deepgram plugin.

**Self-hosted alternative**: WhisperLiveKit + Streaming Sortformer for diarization.
Requires GPU.

### TTS: Chatterbox (primary) + Cartesia (low-latency fallback)

**Chatterbox** (Resemble AI, MIT license) is the recommended primary TTS:
- Self-hostable, runs on GPU
- Zero-shot voice cloning from a 6-second sample — record a "Dreamfinder voice"
  and clone it
- Emotion exaggeration control (monotone → dramatic)
- Paralinguistic tags: `[laugh]`, `[cough]`
- Beats ElevenLabs in blind tests (63.75% preference)

**Cartesia Sonic-3** as low-latency fallback: 40ms time-to-first-audio-byte (vs
~200ms for Chatterbox). Cloud API, usage-based pricing.

### Viseme Data for Lip Sync

Lip sync requires knowing which mouth shape to show at each moment. This needs
phoneme/viseme timestamps alongside the audio.

| Provider | Viseme Output | Notes |
| --- | --- | --- |
| **HeadTTS (Kokoro)** | Phoneme timestamps + Oculus visemes | Self-hosted, MIT, browser or Node.js |
| Azure Speech SDK | 22 viseme IDs + 55-point blend shapes at 60fps | Cloud, best quality, `en-US` + `zh-CN` only |
| Rhubarb Lip Sync | Offline phoneme extraction | Post-processing, not real-time |
| wawa-lipsync | Audio waveform analysis | Real-time but less accurate |

**Recommended**: HeadTTS wraps Kokoro's ONNX model and outputs Oculus viseme IDs
alongside audio. Fully self-hosted. Works with TalkingHead for 3D, or map viseme
IDs to Rive state machine inputs for 2D.

### Avatar Rendering: Rive (2D) or TalkingHead (3D)

**Rive** (recommended for stylized Dreamfinder):
- State machine-driven animation
- Map 8-12 viseme groups to mouth shape states with smooth blending
- Expression states (happy, thinking, surprised, listening) triggered by
  conversation sentiment
- Lightweight file sizes, renders to canvas
- Design in Rive editor, export to web runtime
- [rive.app](https://rive.app)

**TalkingHead** (alternative for 3D):
- [github.com/met4citizen/TalkingHead](https://github.com/met4citizen/TalkingHead)
- Three.js/WebGL, client-side rendering
- GLB avatars with ARKit + Oculus blend shapes
- Built-in lip sync, emotion system, eye contact, head movement
- Compatible with HeadTTS for fully self-hosted pipeline

### Turn Detection: LiveKit EOU Model

The hardest conversational AI problem: when to respond vs. when to keep listening.

LiveKit's End-of-Utterance (EOU) model is a 135M parameter transformer (SmolLM
v2) that analyzes the last 4 conversation turns and predicts whether the speaker
has finished. Runs in ~50ms on CPU. **85% reduction in false interruptions** vs
VAD (silence detection) alone.

Combined with Silero VAD for initial voice activity detection, this gives
Dreamfinder the ability to listen through natural pauses without jumping in.

For a facilitator role, the threshold should be tuned *conservatively* — err on
the side of listening longer rather than interrupting. Dreamfinder should feel
like it's *choosing* to speak, not reacting to silence.

---

## Architecture

```
Matrix Room (text)                Element Call (voice)
      |                                   |
      v                                   v
 Dart Bot (existing)              LiveKit Server (new)
 - Matrix client                         |
 - Agent loop (Claude)                   v
 - MCP tools              Python Voice Agent (new sidecar)
 - Memory/RAG              - LiveKit Agents framework
 - Database (SQLite)        - Deepgram STT (streaming)
      ^                     - Chatterbox TTS + HeadTTS visemes
      | HTTP API (new)      - Turn detection (EOU + VAD)
      +---------------------+
                                         |
                                  audio + viseme data
                                         |
                                         v
                              Browser (Element Call + overlay)
                              - Rive avatar with lip sync
                              - Expressions from sentiment
                              - Sparks react to conversation
```

### Data Flow (voice session)

1. User speaks in Element Call
2. Audio streams to LiveKit server via WebRTC
3. Python voice agent receives audio, sends to Deepgram for STT
4. Deepgram returns streaming transcript with speaker labels
5. EOU model determines if the speaker has finished their turn
6. If Dreamfinder should respond:
   a. Transcript sent to Dart bot via HTTP API
   b. Dart bot runs agent loop (same as text chat — Claude + MCP tools)
   c. Response streamed back to Python agent
   d. Chatterbox generates speech audio + HeadTTS generates viseme data
   e. Audio published as WebRTC track via LiveKit
   f. Viseme data sent to browser for avatar lip sync
7. If Dreamfinder should stay silent:
   a. Transcript still forwarded to Dart bot for context (conversation history)
   b. Bot may do background work (create cards, search docs) without speaking
   c. Avatar shows "listening" expression

### What Stays in Dart, What's New

| Component | Language | Status |
| --- | --- | --- |
| Matrix text chat | Dart | Existing |
| Agent loop (Claude API) | Dart | Existing |
| MCP tools (Kan, Outline, Radicale) | Dart | Existing |
| Database, RAG memory | Dart | Existing |
| Dream cycle, standups, nudges | Dart | Existing |
| HTTP API bridge | Dart | **New** (thin endpoint) |
| WebRTC voice agent | Python | **New** (LiveKit Agents) |
| STT/TTS orchestration | Python | **New** (part of agent pipeline) |
| LiveKit server | Go | **New** (deployment) |
| Rive avatar | JavaScript | **New** (browser overlay) |
| Character design | Rive editor | **New** (art asset) |

---

## Latency Budget

Target: under 1 second mouth-to-ear for a facilitator who responds selectively.

```
User speaks              ->   0ms
WebRTC transport         ->  40ms
Audio buffering          ->  30ms
STT (Deepgram Nova-3)   -> 200ms
EOU turn detection       ->  50ms
Claude (streaming TTFT)  -> 300ms
TTS (Chatterbox)         -> 200ms  (time to first audio byte)
Viseme lookup            ->  10ms
WebRTC return            ->  40ms
---------------------------------
Total                    -> ~870ms
```

With streaming throughout (STT streams partial transcripts to LLM, LLM streams
tokens to TTS, TTS streams audio chunks), the perceived latency drops — the
avatar starts speaking before the full response is generated. Best-in-class
implementations achieve ~465ms end-to-end.

For a facilitator who chooses when to speak (not responding to every utterance),
~870ms reads as "thoughtful" rather than laggy.

---

## Implementation Phases

### Phase 0: Infrastructure (1-2 days)

Deploy LiveKit alongside Matrix on the existing GCP VPS. Configure Element Call
to use LiveKit as its SFU backend. Verify humans can video-call in Matrix rooms.

- [ ] Deploy LiveKit server (Docker, alongside existing compose)
- [ ] Deploy lk-jwt-service for Matrix auth integration
- [ ] Configure Element Call to use LiveKit backend
- [ ] Verify video calls work in Imagineering Matrix rooms

### Phase 1: Audio Pipeline (1 week)

Python sidecar joins LiveKit rooms, transcribes speech, forwards to Dart bot,
plays TTS responses. **Audio only, no avatar.** Proves the full pipeline works.

- [ ] Create Python LiveKit Agents project
- [ ] Implement Deepgram STT integration
- [ ] Add thin HTTP API to Dart bot (`POST /api/chat`)
- [ ] Implement Chatterbox TTS (or Cartesia for faster iteration)
- [ ] Wire up turn detection (EOU + VAD)
- [ ] Auto-join when Element Call starts in a Dreamfinder room
- [ ] Test: full voice conversation with MCP tool use

### Phase 2: Avatar (2-3 weeks)

Design the wizard-artist character, implement lip sync, add emotion states.
Dreamfinder gets a face.

- [ ] Design Dreamfinder character in Rive editor
  - Idle animation (breathing, subtle movement, floating sparks)
  - 8-10 viseme mouth shapes with smooth blending
  - Expression states: listening, thinking, speaking, excited, concerned
  - Spark particles that react to conversation energy
- [ ] Implement HeadTTS viseme pipeline (Kokoro + viseme timestamps)
- [ ] Build browser overlay for Element Call
  - Receives audio + viseme stream from LiveKit
  - Drives Rive avatar lip sync in real-time
  - Maps conversation sentiment to expression states
- [ ] Clone a Dreamfinder voice with Chatterbox (6-second sample)

### Phase 3: Facilitation Intelligence (ongoing)

Tune the interaction model. This is where Dreamfinder becomes a genuine
facilitator, not just a voice assistant.

- [ ] Tune turn detection for facilitator role (conservative — listen more)
- [ ] Background work during listening (create cards, search docs silently)
- [ ] Strategic interjection: detect when to surface background work
  - "I just created a card for that"
  - "That connects to something from last week's session"
  - "I drafted three approaches — want me to share?"
- [ ] Screen sharing: show Outline docs or Kan boards mid-conversation
- [ ] Session memory: summarize key decisions and action items at session end
- [ ] Energy tracking: detect when conversation energy dips, suggest breaks or
  direction changes

---

## Key Risks

**Latency**: If the STT-to-TTS pipeline exceeds ~1.5s consistently, the
facilitator model breaks — it feels like talking to someone on a bad connection.
Mitigation: aggressive streaming, Cartesia TTS as low-latency fallback.

**Turn detection accuracy**: False interruptions are worse than slow responses for
a facilitator. Mitigation: tune EOU threshold conservatively, accept occasional
missed opportunities to interject.

**Character design**: A bad avatar is worse than no avatar. The uncanny valley is
real. Mitigation: stylized 2D (Rive) rather than attempting photorealism.

**Python sidecar complexity**: Adding a second language to the stack increases
operational burden. Mitigation: keep the sidecar thin — it's a media pipeline,
not business logic. All intelligence stays in the Dart agent loop.

**Cost**: Deepgram STT + TTS API costs add up during long sessions. Mitigation:
self-hosted alternatives (WhisperLiveKit, Chatterbox) for production; cloud APIs
for rapid prototyping.

---

## References

- [LiveKit Agents Documentation](https://docs.livekit.io/agents/)
- [LiveKit Agents GitHub](https://github.com/livekit/agents)
- [LiveKit Virtual Avatar Models](https://docs.livekit.io/agents/models/avatar/)
- [LiveKit End-of-Turn Detection](https://livekit.com/blog/using-a-transformer-to-improve-end-of-turn-detection/)
- [Element Call + LiveKit (MSC4195)](https://github.com/matrix-org/matrix-spec-proposals/pull/4195)
- [lk-jwt-service](https://github.com/element-hq/lk-jwt-service)
- [Chatterbox TTS (Resemble AI)](https://github.com/resemble-ai/chatterbox)
- [HeadTTS (Kokoro + Visemes)](https://github.com/met4citizen/HeadTTS)
- [TalkingHead (3D Avatar)](https://github.com/met4citizen/TalkingHead)
- [Rive Animation Engine](https://rive.app)
- [Deepgram Nova-3](https://developers.deepgram.com/docs/)
- [Deepgram Flux](https://www.businesswire.com/news/home/20251002758871/en/)
- [WhisperLiveKit](https://github.com/QuentinFuxa/WhisperLiveKit)
- [Pipecat (Alternative Agent Framework)](https://github.com/pipecat-ai/pipecat)
