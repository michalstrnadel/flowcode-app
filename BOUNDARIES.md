# BOUNDARIES — what is and isn't achievable from outside Claude Code

This documents the hard limits the flowcode architecture respects. It exists so we never
build on a capability that doesn't exist. Verified against the real source of
`mbailey/voicemode` (the `converse()` MCP turn) and Claude Code's documented surfaces.

## Voice core / barge-in

**Achievable**
- Self-contained barge-in *inside* a single `converse()` call: a concurrent in-process
  `asyncio` listener (second input stream + VAD) during TTS playback that sets an
  `asyncio.Event` and aborts the output. This works because `converse()` is one already-running
  tool call that owns the audio for its whole duration.
- Cancellable TTS playback on the **default** path: `stream_pcm_audio`'s
  `async for chunk in response.iter_bytes()` loop is cancellable between chunks; adding
  `if stop_event.is_set(): stream.abort(); break` stops it.
- ~100–150ms kill latency **only** after reconfiguring the `sd.OutputStream` (small
  `blocksize`, `latency='low'`) and using `stream.abort()` (discard) instead of the current
  `stream.close()` (drain).

**Not achievable**
- Interrupting a running `converse()` from **outside** via MCP — MCP is synchronous,
  request/response, and `converse()` is non-re-entrant. No server-initiated push enters a live call.
- Barge-in driven by Claude Code **hooks** — they are fire-and-forget subprocesses that only
  play a local sound and self-silence during a converse turn; they cannot reach the audio loop
  or the LLM token stream.
- ~150ms kill on the **current** default config (default blocksize + `stop()`/drain).
- Reliable talk-over **during** the assistant's speech **without** AEC — an open mic
  self-triggers on the assistant's own TTS. Both true talk-over and no-self-trigger require AEC.
- Tunneling barge-in into the **LLM's token generation** — voicemode only ever sees the finished
  reply text. P2 overlaps TTS *synthesis* with *playback*, not with LLM generation.

## P4 interruption-correction

- **Injected-message only.** There is no mechanism to edit, truncate, or roll back already-emitted
  conversation context. The only honest correction is to compute how much audio was actually
  played and append a concise note ("you heard ~the first N words: …") to the string `converse()`
  returns — a next message the model reads on its following turn.
- Caveat: audio *written* to the output stream ≠ audio *heard* (host buffering); subtract playout
  latency or the reported offset overstates what the user heard.

## macOS app / IPC

- **Achievable:** one Unix-domain socket (NDJSON) carrying status + control + assistant amplitude +
  the out-of-band barge-in event; Swift owns the microphone TCC grant; `launchd` keeps Kokoro/Whisper
  warm; an embedded relocatable Python venv enables offline "download and run".
- **Not achievable:** speaking MCP to voicemode over its stdio (Claude Code owns it); App Sandbox /
  Mac App Store (incompatible with a Python sidecar + LaunchAgents + localhost services); hiding the
  HUD from ScreenCaptureKit on macOS 15+ (and we don't want to — it should appear in the demo).

## Orchestration / swarm (secondary pillar)

- **Achievable:** steering toward orchestration by **text injection only** (prepend `ultracode: `,
  or `/effort ultracode`, or a spoken-keyword alias to the same injection); **observing** a live run
  by tailing the on-disk session JSONL via FSEvents
  (`~/.claude/projects/<project>/<session>/subagents/` + the parent `<session>.jsonl`), which is the
  only authoritative *and* live source; deriving agent identity from `agent-<id>.jsonl` filenames and
  the parent `toolUseResult`; a thin async hook as a "re-read now" ping.
- **Not achievable from outside:** starting/pausing/stopping a workflow or individual agents
  programmatically; injecting a task into a running workflow; reading the `/workflows` TUI state
  programmatically; a reliable mid-run token feed (cost is authoritative only at agent completion);
  relying on `agent_id`/`agent_type` in hook payloads (inconsistent in the CLI). Build around this.
