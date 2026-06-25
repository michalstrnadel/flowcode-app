# flowcode

**A voice layer for Claude Code, as a native macOS menu-bar app.**

flowcode reads Claude Code's replies **aloud** and lets you **dictate** prompts by voice —
so you can drive a coding session hands-free while a luminous Jarvis-style orb reacts to the
conversation. Claude Code runs completely unmodified; flowcode sits beside it in the menu bar.

- 🔊 **Read-aloud** — every new assistant message is spoken via local **Kokoro** TTS, with the
  orb pulsing to the speech. Tool-call narration and code blocks are skipped; you hear the prose.
- 🎙️ **Push-to-talk dictation** — hold **Right Option (⌥)**, speak, release; your words are
  transcribed via local **Whisper** STT and pasted into the focused app (Claude Code in your
  terminal, an editor, anywhere). It never presses Enter — you commit.
- ⏯️ **Pause/Resume** the whole voice layer with **⌃⌥Space** or the menu, without quitting.
- 🛰️ **Local-first & private** — audio never leaves your Mac. TTS and STT are localhost services.

> Everything runs on `127.0.0.1`: Kokoro (TTS) on `:8880`, Whisper (STT) on `:2022`. flowcode
> talks to them directly over HTTP — there is **no cloud, no account, and no Claude Code plugin**.

---

## Quick start

**Requirements:** macOS 14+ (Sonoma), and the two local voice services running. A one-shot
setup script installs the services, builds the app, and walks you through permissions:

```sh
git clone https://github.com/michalstrnadel/flowcode-app.git
cd flowcode-app
scripts/setup.sh
```

`setup.sh` is idempotent — re-run it any time. It will:

1. Check prerequisites (Homebrew, [uv](https://docs.astral.sh/uv/), the Swift 6 toolchain).
2. Install + start **Kokoro** (`:8880`) and **Whisper** (`:2022`) as launchd agents (via the
   [voicemode](https://github.com/mbailey/voicemode) service installer), so they stay warm and
   restart on login.
3. Build and ad-hoc-sign `dist/flowcode.app`.
4. Open the right **System Settings** panes and tell you which toggles to flip for permissions.

Then launch `dist/flowcode.app`. The orb appears in the menu bar.

### Permissions (one time)

| Feature | Microphone | Accessibility |
| --- | --- | --- |
| **Read-aloud** | — | — |
| **Dictation** (⌥) | ✅ required | ✅ required (to paste the transcript) |

Read-aloud works immediately with **no** permissions. Dictation needs both grants; flowcode
prompts for them the first time you hold ⌥. macOS can't grant these from a script — you flip the
toggles in **System Settings → Privacy & Security**.

> **Heads-up (dev builds):** a from-source build is *ad-hoc signed*, so macOS asks for the
> permissions again after each rebuild, and Gatekeeper warns on first open. Clear the warning with
> `xattr -dr com.apple.quarantine dist/flowcode.app`. A notarized release (a later milestone) is
> the friction-free path. See [`DISTRIBUTION.md`](DISTRIBUTION.md).

---

## The menu

Click the orb in the menu bar:

```
◉  Speaking — reading Claude's reply        ← live status
─────────
Pause Voice            ⌃⌥Space              ← ↔ Resume Voice
Stop Speaking                               ← stop the current message (enabled while speaking)
─────────
✓ Read messages aloud                       ← takes effect after relaunch
  Voice ▸  Sky · Bella · Adam · …           ← pick a Kokoro voice
  Hold Right Option (⌥) to dictate          ← reminder
─────────
✓ Launch at Login                           ← auto-start with macOS
  Open Log…
─────────
Quit flowcode          ⌘Q
```

Pick a different read-aloud **Voice** from the submenu (US/UK, female/male). **Launch at Login**
registers flowcode as a real login item (`SMAppService`), so with the voice services on auto-start
the whole thing "just works" after a reboot.

---

## How it works

flowcode is a thin SwiftUI/AppKit **menu-bar agent** (no Dock icon). For read-aloud it tails the
session transcript Claude Code already writes (`~/.claude*/projects/<project>/<session>.jsonl`),
and speaks each new assistant message. It only reads files it already has access to — Claude Code
itself is never touched or wrapped.

```
Claude Code session JSONL ──tail──▶ flowcode ──HTTP──▶ Kokoro TTS (:8880) ──▶ 🔊 + orb
        ⌥ hold ──▶ mic capture ──HTTP──▶ Whisper STT (:2022) ──paste──▶ focused app
```

No socket, no Python core, no MCP server in this path — read-aloud + dictation are entirely
self-contained in the Swift app plus the two HTTP services.

---

## Troubleshooting

- **Nothing is read aloud** → check the services are up:
  `curl -fsS http://127.0.0.1:8880/v1/audio/voices` and `curl -fsS http://127.0.0.1:2022/health`.
  If they fail, re-run `scripts/setup.sh` (or `voicemode service status`). Logs live under
  `~/.voicemode/logs/`.
- **Dictation does nothing** → grant **Accessibility** and **Microphone** to flowcode in System
  Settings → Privacy & Security, then relaunch. After a dev rebuild you may need to re-grant.
- **It reads "I'll update the file…" preambles** → it shouldn't; flowcode skips messages that
  contain tool calls and reads only pure prose. File an issue with the transcript line.
- **The orb is stuck** → use **Pause Voice** (⌃⌥Space) then Resume, or quit and relaunch.

---

## Does flowcode need the voicemode MCP?

**No.** The default product (read-aloud + dictation) hits Kokoro and Whisper over HTTP directly.
If you previously registered a `voicemode` MCP server in `~/.claude.json` for flowcode, you can
remove it — it only matters for the experimental socket/converse mode below. `setup.sh` offers to
remove it (with a timestamped backup).

---

## Experimental / dormant

flowcode began as a real-time, **interruptible** voice core (barge-in, streaming TTS, semantic
endpointing, a §7 confirmation gate, and a swarm/orchestration HUD), built on a fork of
[voicemode](https://github.com/mbailey/voicemode). That code is **still in the repo** but is **off
by default** — it requires `readAloudEnabled = false` plus a running voicemode voice core and the
control socket, none of which the shipping Model B uses. The menu's Barge-In / Streaming /
Semantic toggles belong to that path and are hidden in the default build.

It's preserved as the roadmap to true barge-in. See [`PLAN.md`](PLAN.md) and
[`BOUNDARIES.md`](BOUNDARIES.md) for that design (they predate Model B and describe the socket
architecture, not the current default).

---

## Building from source / development

```sh
swift build                 # builds flowcodeKit + the menu-bar app
swift run flowcode          # runs the app from the build dir (ad-hoc, dev)
swift run flowcode-selftest # headless verification harness (no mic, no creds)
scripts/preflight.sh        # build + selftest + watchdog typecheck gate
scripts/build_app.sh        # assemble dist/flowcode.app
```

- `flowcodeKit` — testable library (stores, voice pipeline, orb/HUD, the experimental IPC/swarm).
- `flowcode` — the menu-bar executable.
- `flowcode-selftest` — a plain executable test harness (XCTest is unavailable under bare CLT).

The experimental voice core lives in a separate repo (the voicemode fork). Point
`FLOWCODE_CORE_CWD` at your checkout if you build the socket path; it is not needed for Model B.

---

## Distribution

flowcode is built for a notarized universal `.zip` on GitHub Releases with a Sparkle self-update
feed and a Homebrew cask (unsandboxed by design — see [`DISTRIBUTION.md`](DISTRIBUTION.md)). That
signed/notarized path needs a paid Apple Developer account and is a later milestone; today the
supported path is build-from-source via `scripts/setup.sh`.

---

## License

flowcode is [MIT](LICENSE) © 2026 Michal Strnadel.

It builds on and interoperates with third-party software — voicemode (Mike Bailey, MIT), Kokoro,
Whisper, and others. See [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for full attribution.
Kokoro's model weights carry their own license; review it before redistributing any weights.
