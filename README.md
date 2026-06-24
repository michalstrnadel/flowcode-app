# flowcode

Real-time, interruptible voice for Claude Code — as a native macOS app.

> Status: **early build (Step 0 complete, scaffolding)**. Not yet usable.

`flowcode` makes voice-coding with Claude Code feel real-time and interruptible instead of a
turn-based "record → wait → speak" loop. You talk to it, it listens, thinks, and talks back —
with a Jarvis/Siri-style luminous orb that reacts to your voice and stops **instantly** the
moment you interrupt it.

It is a thin native macOS menu-bar app (CodexBar-style) wrapped around an enhanced fork of
[voicemode](https://github.com/mbailey/voicemode) (the Python core that owns all real-time
audio, STT/TTS, and the MCP link to Claude Code). Local-first: TTS via Kokoro, STT via Whisper.

## The four pillars

1. **Barge-in** — start talking while it's speaking and it stops within ~100–150ms.
2. **Streaming TTS** — it starts speaking at the first clause instead of buffering the whole reply.
3. **Semantic endpointing** — it fires your turn as soon as your sentence reads complete.
4. **Honest interruption-correction** — when you cut it off, it knows roughly what you actually
   heard and continues accordingly (never assumes you heard the rest).

Plus a **Jarvis HUD** (audio-reactive orb with state + sound cues) and an optional, default-off
**voice-driven orchestration swarm** that visualizes Claude Code multi-agent workflows live.

## Architecture

The Swift app never touches audio — all hard real-time work stays in the Python core, joined by
a single Unix-domain socket (status + control). See [`PLAN.md`](PLAN.md) for the full design and
[`BOUNDARIES.md`](BOUNDARIES.md) for what is and isn't achievable from outside Claude Code.

## Develop

```sh
swift build                 # builds flowcodeKit + the menu-bar app (Swift 6, macOS 14+)
swift run flowcode          # runs the menu-bar app (status icon reflects the voice core)
swift run flowcode-selftest # verifies the IPC layer (wire contract + AF_UNIX loopback)
```

Layout: `flowcodeKit` (testable library — models, IPC client, stores, status UI),
`flowcode` (thin executable), `flowcode-selftest` (runnable checks). `swift test`/XCTest
needs full Xcode; the self-test executable runs everywhere, including Command Line Tools.

## Security

Voice **proposes**; a deliberate **non-voice** gesture (click / hotkey / Touch ID) **commits**.
Ambient audio can never trigger an irreversible action or auto-approve a permission prompt.

## License

MIT (inherits voicemode's MIT license for the forked core).
