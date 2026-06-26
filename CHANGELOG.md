# Changelog

All notable changes to flowcode are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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

### Notes
- The real-time voice core (barge-in / converse / swarm) is present but **experimental and off by
  default**; the shipping experience is read-aloud + dictation.

[Unreleased]: https://github.com/michalstrnadel/flowcode-app/commits/main
