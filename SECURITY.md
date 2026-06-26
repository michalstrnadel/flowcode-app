# Security Policy

flowcode runs locally and is privacy-sensitive: it can use the **microphone** (push-to-talk
dictation), needs **Accessibility** (to paste the transcript into the focused app), and reads your
Claude Code transcript files. We take security and privacy seriously.

## What flowcode does and doesn't do

- Audio and transcripts stay on your Mac — TTS (Kokoro) and STT (Whisper) are **localhost** services.
  flowcode makes no cloud calls for voice.
- The microphone is opened **only while you hold the push-to-talk key**, and released the moment you
  let go. Read-aloud uses no microphone at all.
- Dictation pastes into whatever app is focused and **never presses Enter** — you always commit.

## Supported versions

flowcode is pre-1.0; only the latest `main` / latest release receives fixes.

| Version | Supported |
| --- | :---: |
| latest `main` / release | ✅ |
| older | ❌ |

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately via GitHub's **[Report a vulnerability](https://github.com/michalstrnadel/flowcode-app/security/advisories/new)**
(Security → Advisories → Report a vulnerability). If that isn't available to you, contact the
maintainer [@michalstrnadel](https://github.com/michalstrnadel) privately.

Please include:

- a description of the issue and its impact,
- steps to reproduce (a proof of concept if possible),
- affected version / commit, and your macOS version.

We'll acknowledge your report, investigate, and coordinate a fix and disclosure timeline with you.
Thank you for helping keep flowcode and its users safe. 🙏
