# Changelog

All notable changes to flowcode are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] — 2026-06-26

### Added
- **Claude Desktop read-aloud now actually works.** Electron/Chromium apps don't expose their web
  content to Accessibility until a client asks, so flowcode now sets `AXManualAccessibility` on the
  Claude app — previously the AX path read an empty tree and nothing was spoken (what you heard was
  always the Claude Code transcript). The latest reply is located by anchoring on Claude's own
  per-turn headings ("Claude responded:" vs "You said:"), so it reads exactly the assistant reply —
  never the sidebar, never your own prompt.
- **Block-streaming infrastructure** (Full mode): a tested `MessageStreamer` speaks finished blocks
  as they appear — content-hash de-dup (no re-speak on reflow), prefix-growth suffix emit, and a
  guard that only speaks a reply it has seen stream in. It streams where the app exposes the reply
  incrementally; **Claude Code in the desktop app commits its reply to the tree only at completion**,
  so there it reads the whole reply once finished (cleanly, low-latency) rather than word-by-word.
- **Source coordination:** when a Claude Desktop window is frontmost the AX source reads it and the
  Claude Code JSONL reader stays quiet, so a reply is never read twice.

### Changed
- **Compact read-aloud is now structure-aware** (was first + last sentence): it speaks the reply's
  actual points — whole bullets / paragraphs — drops code blocks, tables, headings and rules,
  demotes tool-narration openers ("Let me read…", "Tady to máš…"), keeps a trailing question as
  the closer, and caps to a short budget so it stays a gist. Still fully offline, instant, and
  diacritic-safe (Czech and English).
- Read-aloud now **strips emoji, pictographs and arrows** before speaking (Full and Compact), so
  TTS no longer vocalises "party popper" or hiccups on an emoji variation selector.

### Fixed
- The relative-time stamp Claude appends to each reply ("just now", "3m ago", …) is no longer read
  aloud, and — because it ticks over time — no longer triggers a spurious re-read every minute.

## [0.1.0] — 2026-06-26

First public release. 🎉

### Added
- **Agent-driven install:** an [`AGENTS.md`](AGENTS.md) runbook so an AI coding agent (Claude Code)
  installs flowcode end-to-end (services + build + permissions hand-off). This OSS version installs
  from source via an agent — there is no prebuilt download by design.
- **Claude Desktop support:** flowcode can now read the **Claude desktop app's** replies aloud
  (Chat, Cowork, and Code-in-desktop) by observing its Accessibility tree, and push-to-talk
  dictation pastes into it. Pick the target with **Listen to ▸ Claude Code / Claude Desktop / Both**
  (default Both; the Claude Code path is unchanged).
- **Czech voice (optional):** **Language ▸ English / Čeština** in the menu. Czech read-aloud uses an
  **on-demand neural female voice** (Coqui VITS) that downloads only when you first pick Czech
  (~350 MB, fully offline) — English (Kokoro) users never download anything. Czech **dictation**
  works via the multilingual Whisper model. Pre-install from the CLI with `scripts/setup.sh --czech`
  or the **`/czech-voice`** skill.
- **Read-aloud modes:** **Read replies ▸ Off / Full / Compact** (live). *Compact* speaks just the
  gist — the first and last sentence — for when a reply is long.
- **Read-aloud (Model B):** speaks each new Claude Code assistant reply via local Kokoro TTS,
  reading only the active session and skipping tool-call narration and code blocks.
- **Push-to-talk dictation:** hold Right Option (⌥) to transcribe speech via local Whisper and paste
  it into the focused app (never auto-submits).
- **Menu:** Pause / Resume Voice (menu + global ⌃⌥Space), Stop Speaking, a Kokoro **voice picker**,
  real **Launch at Login** (`SMAppService`), and Open Log.
- **Orb HUD:** a luminous, audio-reactive orb reflecting listening / speaking / idle.
- **`scripts/setup.sh`:** one-shot "clone → it works" setup (services + build + sign + permissions
  guide), plus a `/setup` Claude Code skill.
- Open-source scaffolding: MIT `LICENSE`, `THIRD-PARTY-NOTICES.md`, a redesigned README with an SVG
  hero + logo, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue/PR templates, and CI.

### Changed
- Bundle id is now `io.github.michalstrnadel.flowcode`.
- The microphone is opened only during active dictation (previously a continuous tap kept it open).
- `scripts/setup.sh` defaults the Whisper model to multilingual **`small`** (better Czech; was
  `base`) and warns against English-only `.en` models.

### Fixed
- The `flowcode-watchdog` sidecar now reaps its child process group on termination signals
  (SIGTERM/INT/HUP), so the on-demand Czech voice service can never be orphaned when the app quits
  or crashes.
- Czech dictation: the spoken language now actually reaches Whisper (it was hard-coded to English).

### Notes
- The real-time voice core (barge-in / converse / swarm) is present but **experimental and off by
  default**; the shipping experience is read-aloud + dictation.

[Unreleased]: https://github.com/michalstrnadel/flowcode-app/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/michalstrnadel/flowcode-app/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/michalstrnadel/flowcode-app/releases/tag/v0.1.0
