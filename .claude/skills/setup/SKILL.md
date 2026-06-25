---
name: setup
description: Set up flowcode (the macOS voice layer for Claude Code) on this Mac — install the Kokoro/Whisper voice services, build the app, and grant permissions. Use when the user wants to install flowcode, set it up after cloning, or fix a broken setup.
---

## What this does

flowcode is a macOS menu-bar app that reads Claude Code's replies aloud (Kokoro TTS) and
lets you dictate prompts by push-to-talk (Whisper STT). Setup is one idempotent script.

## Run it

From the repo root, run the setup script and report its phase output to the user:

```sh
scripts/setup.sh
```

It is safe to re-run. Useful flags:

- `--skip-services` — the Kokoro/Whisper services are already running.
- `--with-core` — also build the embedded Python voice core (only for the experimental
  socket/barge-in mode; NOT needed for the default read-aloud + dictation).
- `--model small` — pick a different Whisper model (default `base`).
- `SIGN_IDENTITY=flowcode-dev scripts/setup.sh` — sign with a stable cert so the
  macOS permission grants survive rebuilds (otherwise the build is ad-hoc signed).

## The one part the script can't do: permissions

macOS does not allow Microphone/Accessibility to be granted from a script. After the
script opens the System Settings panes, walk the user through enabling **flowcode** under:

- **Privacy & Security → Microphone** (needed for dictation)
- **Privacy & Security → Accessibility** (needed to paste the dictated text)

Read-aloud needs neither — it works the moment the app launches.

## Verify it worked

- `curl -fsS http://127.0.0.1:8880/v1/audio/voices` → returns a voice list (Kokoro up).
- `curl -fsS http://127.0.0.1:2022/health` (or check `~/.voicemode/logs/whisper`) → Whisper up.
- Launch `dist/flowcode.app`; the orb appears in the menu bar; a new Claude Code message
  is read aloud.

## Troubleshooting

- **No audio:** the voice services aren't running — re-run `scripts/setup.sh` or
  `voicemode service status`; check `~/.voicemode/logs/`.
- **Dictation silent:** Accessibility/Microphone not granted — re-open the panes and grant,
  then relaunch the app. After an ad-hoc rebuild, grants may need to be re-given.
