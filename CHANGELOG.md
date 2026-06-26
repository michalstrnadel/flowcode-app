# Changelog

All notable changes to flowcode are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/michalstrnadel/flowcode-app/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/michalstrnadel/flowcode-app/releases/tag/v0.1.0
