# flowcode

Real-time, interruptible voice for Claude Code — as a native macOS app.

`flowcode` makes voice-coding with Claude Code feel real-time and interruptible instead of a
turn-based "record → wait → speak" loop. You talk, it listens, thinks, and talks back — with a
Jarvis/Siri-style luminous orb that reacts to your voice and stops **instantly** the moment you
interrupt it.

It is a thin native macOS menu-bar app (CodexBar-style) wrapped around an enhanced fork of
[voicemode](https://github.com/mbailey/voicemode) (the Python core that owns all real-time
audio, STT/TTS, and the MCP link to Claude Code). Local-first: TTS via Kokoro, STT via Whisper.

> The flowcode behaviour described here lives behind **default-OFF** feature flags. With every
> flag at its default, the Python core behaves exactly like upstream voicemode and the macOS app
> is a passive status viewer. You opt in, one flag at a time.

---

## The four pillars

1. **Barge-in** (`P1`) — start talking while it's speaking and it stops within ~100–150ms
   (audio and visual cut together).
2. **Streaming TTS** (`P2`) — it starts speaking at the first clause instead of buffering the
   whole reply, so audio starts sooner and a barge-in can stop cleanly between clauses.
3. **Semantic endpointing** (`P3`) — it ends your turn sooner when your sentence reads complete,
   using a shortened semantic-silence window gated by a completeness signal, with the existing
   hard silence threshold as an unconditional fallback (so it can never get *slower* than today).
4. **Honest interruption-correction** (`P4`) — when you cut it off, it prepends an advisory note
   to the model telling it roughly how many words actually played out loud, so it never assumes
   you heard the rest. Injection-only; no context editing.

Plus a **Jarvis HUD** (audio-reactive orb with state + sound cues) and an optional, default-off
**voice-driven orchestration / swarm mode** that visualizes Claude Code multi-agent workflows
live.

**North-star demo:** a ~30s clip where the user interrupts the assistant mid-sentence, it stops
instantly (sound and visual at once) and adapts. The swarm view is a separate, bonus demo — the
north star does **not** involve swarm mode.

---

## Architecture

```
┌──────────────────────────────┐         ┌───────────────────────────────────┐
│  flowcode (Swift, macOS)     │         │  voicemode core (Python)          │
│  ─ menu-bar control shell    │         │  ─ owns ALL real-time audio       │
│  ─ Jarvis orb HUD            │  UDS    │  ─ VAD / STT (Whisper) / TTS      │
│  ─ confirm gate (§7)         │ <─────> │    (Kokoro)                       │
│  ─ swarm HUD (read-only)     │ NDJSON  │  ─ MCP link to Claude Code        │
│                              │ status  │  ─ barge-in, endpointing, etc.    │
│  NEVER touches audio         │ +control│                                   │
└──────────────────────────────┘         └───────────────────────────────────┘
```

The Swift app **never touches audio**. All hard real-time work (capture, VAD, STT, TTS,
barge-in timing) stays in the Python core. The two are joined by a single **Unix-domain socket**
carrying **newline-delimited JSON** (NDJSON):

- **Status (core → app):** `event` frames (e.g. `TTS_PLAYBACK_START`), `amplitude` frames
  (`rms` for the orb), and state (`idle` / `listening` / `processing` / `speaking` /
  `interrupted`). Unknown frame types and unknown state strings are tolerated (forward-compatible
  decode that never throws).
- **Control (app → core):** `start`, `stop`, `setFlag`, and `confirm` commands as one JSON
  object per line.

The default socket path is `~/.voicemode/run/flowcode.sock` (overridable in settings). See
[`PLAN.md`](PLAN.md) for the full design and [`BOUNDARIES.md`](BOUNDARIES.md) for what is and
isn't achievable from outside Claude Code.

---

## Build & run

Requirements: **macOS 14+**, **Swift 6** (Xcode 16 toolchain or Command Line Tools).

```sh
swift build                 # builds flowcodeKit + the menu-bar app
swift run flowcode          # runs the menu-bar app (status icon reflects the voice core)
swift run flowcode-selftest # runs the headless verification harness
```

Layout (mirrors CodexBar's Core/app split):

- `flowcodeKit` — testable library (models, IPC client, stores, orb/HUD, confirm gate, swarm).
- `flowcode` — thin menu-bar executable that wires it together.
- `flowcode-selftest` — runnable verification harness.

> **Why a self-test executable instead of `swift test`?** `XCTest` ships with Xcode and is
> **unavailable under the bare Command Line Tools**. `flowcode-selftest` is a plain executable
> that runs everywhere — it asserts the IPC wire contract (status decode, control encode,
> AF_UNIX loopback round-trip), the orb state mapping / Metal pipeline build, and the swarm
> decode/cap/collapse logic, then exits non-zero on any failure.

The voice core is a separate repo (the voicemode fork, branch `flowcode-overlay`). For local
development run it pointed at the same socket path; for distribution it is frozen into the app
bundle (see [`DISTRIBUTION.md`](DISTRIBUTION.md)).

---

## Feature flags (all default OFF)

flowcode features are gated on both sides. The **Python core** reads `VOICEMODE_*` environment
variables (the single source of truth for behaviour). The **macOS app** persists user intent in
`SettingsStore` (UserDefaults) and pushes the corresponding flag to the core over the control
channel via `setFlag`.

### Python core (`VOICEMODE_*`)

| Env var | Default | Pillar | Effect |
| --- | --- | --- | --- |
| `VOICEMODE_STATUS_SOCKET` | `""` (off) | — | Path to the UDS the app connects to for live status + control. Empty = disabled. |
| `VOICEMODE_BARGEIN_ENABLED` | `false` | P1 | Concurrent VAD during playback + instant stop. |
| `VOICEMODE_TTS_SENTENCE_CHUNKING` | `false` | P2 | Split the reply into clauses and synthesize/play sequentially. |
| `VOICEMODE_INTERRUPTION_CORRECTION` | `false` | P4 | Prepend an advisory note about how many words actually played. |
| `VOICEMODE_SEMANTIC_ENDPOINTING` | `false` | P3 | Enable early end-of-turn on a completeness signal. |
| `VOICEMODE_SEMANTIC_SILENCE_MS` | `500` | P3 | Shortened silence window (ms); clamped ≤ the hard silence threshold. |
| `VOICEMODE_ENDPOINT_COMPLETENESS_THRESHOLD` | `0.6` | P3 | Completeness probability at/above which the early stop may fire. |
| `VOICEMODE_SMART_TURN_MODEL_PATH` | `""` (off) | P3 | Path to a smart-turn-v3 ONNX completeness model. If unset/unavailable, endpointing falls back to pure silence-threshold behaviour. |
| `VOICEMODE_CONFIRM_GATE` | `false` | §7 | Require a non-voice gesture to commit side-effectful commands. |
| `VOICEMODE_CONFIRM_GATE_TIMEOUT` | `30` | §7 | Seconds to wait for a verdict before auto-denying (timeout = DENY). |

> `VOICEMODE_SMART_TURN_MODEL_PATH` is read directly by the endpointing module (not declared in
> `config.py`). The numeric flags (`_SILENCE_MS`, `_COMPLETENESS_THRESHOLD`, `_TIMEOUT`) only take
> effect once their parent boolean is enabled.

Enable, e.g.:

```sh
export VOICEMODE_STATUS_SOCKET="$HOME/.voicemode/run/flowcode.sock"
export VOICEMODE_BARGEIN_ENABLED=true
export VOICEMODE_TTS_SENTENCE_CHUNKING=true
# (start the voice core as usual)
```

### macOS app (`SettingsStore`)

| Setting | Default | Maps to |
| --- | --- | --- |
| `bargeInEnabled` | `false` | `VOICEMODE_BARGEIN_ENABLED` |
| `streamingChunking` | **`true`** | `VOICEMODE_TTS_SENTENCE_CHUNKING` |
| `semanticEndpointing` | `false` | `VOICEMODE_SEMANTIC_ENDPOINTING` |
| `swarmMode` | `false` | swarm observer + `ultracode:` prefix (see below) |
| `launchAtLogin` | `false` | login-item intent (SMAppService) |
| `language` | `"en"` | STT/TTS language tag |
| `socketPathOverride` | `nil` → `~/.voicemode/run/flowcode.sock` | IPC socket path |

> **Honest note on `streamingChunking`:** the app-side setting defaults to **`true`** (better
> perceived latency), whereas the Python flag `VOICEMODE_TTS_SENTENCE_CHUNKING` defaults to
> `false`. The Python core is the ground truth: chunking only happens once the core actually
> receives the flag (the app pushes it on connect). With the core launched standalone and no
> control connection, chunking stays off. All other settings default OFF on both sides.

The control channel never enables a flag the core didn't already expose; the app just toggles
existing `VOICEMODE_*` gates over the socket.

---

## The Jarvis orb

An audio-reactive HUD orb (Metal shader) that encodes the session state primarily through
**motion and shape**, and only secondarily through color (a calm deep-cyan → violet drift, kept
within one cohesive accent rather than switching hues abruptly).

States (`OrbMotion`):

| State | Motion | Tint |
| --- | --- | --- |
| `idle` | 0 | deep cyan, resting |
| `listening` | 1 | brighter cyan, live `amplitude` from `rms` frames |
| `processing` | 2 | cyan → blue-violet ("thinking") |
| `speaking` | 3 | warmer violet |
| `interrupted` | 4 | dimmed, slightly-magenta violet — a brief flash that signals the break in flow without an alarming red |

**Earcons:** three short low-latency cues — `startListening`, `endTurn`, `interrupted`. Audio
assets are optional: if no sound file is found at construction time, that cue is a silent no-op
(the HUD ships before any assets land).

**Reduce Motion:** when `NSWorkspace.accessibilityDisplayShouldReduceMotion` is on, the orb's
time-driven animation is frozen (animation time held at 0) so the orb still reflects state
through its static parameters without continuous motion.

---

## §7 security model — voice proposes, a gesture commits

flowcode's zero-trust rule: **voice can only propose; a deliberate non-voice gesture commits.**
Ambient audio can never trigger an irreversible action or auto-approve a permission prompt.

When `VOICEMODE_CONFIRM_GATE` is on, a side-effectful / irreversible command proposed by voice is
held and surfaced in the app for an explicit verdict:

- **Commit** requires a non-voice gesture: a **click**, the **commit hotkey**, or — for elevated
  requests — a successful **Touch ID** (`deviceOwnerAuthenticationWithBiometrics`).
- **Timeout = DENY.** A hard timeout (`VOICEMODE_CONFIRM_GATE_TIMEOUT`, default 30s) auto-denies.
- Cancel / Esc / no explicit approval → **DENY** (deny is always the default outcome).
- There is deliberately **no `.voice` approval path** in the decision logic.
- The verdict is returned to the core as a `confirm` control command echoing the request `id`.
- Decisions are recorded to an **audit log**. The displayed command is already redacted by the
  core before it reaches the app.

The pure decision logic is factored out and verified headlessly (no biometric hardware needed);
the live Touch ID prompt and popover UI are exercised manually (see "Verified vs deferred").

---

## Swarm / ultracode mode (default OFF, bonus demo)

An optional view that visualizes a Claude Code multi-agent run live. It is **default OFF** and
fully inert until `swarmMode` is enabled — with it off the observer is never even constructed.

**What it does:** when on, it starts a **read-only** `SwarmObserver` that tails session files via
a single FSEvents stream — new `agent-<id>.jsonl` spawns and appended `tool_use` lines under
`<session>/subagents/`, and `Task` completions (authoritative tokens/cost/status) in the parent
`<session>.jsonl`. It also toggles an `ultracode:` transcript prefix via the control channel so a
turn can be routed into orchestration. The HUD caps at 16 visible nodes (with aggregated arcs for
evicted completions) and collapses on a `Stop`.

**Honest limits (by design):**

- It is **read-only observe + text-injection control only.** It reads appended file bytes; it
  does **not** start/stop/pause workflows or read a mid-run token stream.
- A `Stop` collapse is **best-effort** — driven by a session-end summary or an external hook ping
  forwarded into the observer.
- Default OFF guarantees a normal turn never silently triggers a swarm.

---

## Verified headlessly vs deferred to a live/manual demo

**Verified by `flowcode-selftest` (headless, no Apple creds, no mic):**

- Status-frame decode (events, amplitude/`rms`, unknown-state tolerance, missing-key tolerance).
- Control-command encode (`start` / `stop` / `setFlag` / `confirm`) and an AF_UNIX loopback
  round-trip through `IPCClient`.
- Voice-state → orb-param mapping and the Metal orb pipeline building at runtime.
- Swarm JSONL decode, node-cap (16), eviction-arc accounting, and stop-collapse.
- Python-side flag gating, clause splitting, endpointing decision, etc. are covered by the
  dependency-free test suite in the voicemode core repo.

**Deferred to a manual / live demo (NOT verified in CI):**

- **Live-mic barge-in** end-to-end timing and full mid-clause talk-over. The dependency-free
  day-1 baseline gates the mic during playback (stop happens in the gap between clauses); true
  mid-clause talk-over needs the opt-in **AEC extra** (WebRTC APM / `livekit-rtc` + silero-vad).
- **Touch ID** prompt and the **confirm-gate popover** UI (the decision logic *is* tested).
- **Smart-turn model** inference (requires the ONNX model + `onnxruntime`; absent → silence-only
  fallback).
- **Notarization / signing / Sparkle update** flow (release-only).

---

## Distribution

flowcode ships as a **notarized universal `.zip`** on GitHub Releases, with a **Sparkle**
self-update feed and a **Homebrew cask** (no DMG, no Mac App Store — the app is unsandboxed by
design: embedded Python sidecar + localhost STT/TTS + LaunchAgents are incompatible with App
Sandbox). Release scripts and CI are default-off relative to development — `swift build` /
`swift run` are unaffected. See [`DISTRIBUTION.md`](DISTRIBUTION.md) for the full pipeline and
[`version.env`](version.env) for the pinned versions + voicemode commit.

---

## License

MIT (inherits voicemode's MIT license for the forked core).
