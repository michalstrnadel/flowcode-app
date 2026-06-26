---
name: czech-voice
description: Install (or repair) flowcode's optional Czech neural read-aloud voice (Coqui VITS). Use when the user wants Czech text-to-speech, asks to pre-download the Czech voice, or Czech read-aloud isn't working.
---

## What this does

flowcode reads English aloud with Kokoro. **Czech** uses a separate, higher-quality neural
voice (Coqui VITS, female) that is **optional** and **downloaded on demand** — it pulls a small
PyTorch runtime + model (~350 MB, one-time), so it is never bundled or forced on English users.

Normally the user just picks **Language ▸ Čeština** in the menu and clicks **Download** in the
prompt. This skill is for pre-installing it from the command line (e.g. before going offline) or
fixing a broken install.

## Prerequisites

- `uv` / `uvx` on PATH (https://docs.astral.sh/uv/). The Czech voice cannot install without it.

## Install / repair

From the repo root:

```sh
scripts/czech-voice.sh install
```

Idempotent and safe to re-run. It downloads the runtime + model, then verifies the model landed.
Report the script's output to the user.

To check whether it is already installed:

```sh
scripts/czech-voice.sh check   # prints "installed" / "not-installed"
```

## How it runs

Once installed, the app starts a small local HTTP server (`scripts/czech-voice.sh serve`, default
port 8771) the moment the user selects Czech, and stops it when they switch back to English or quit
(so the runtime's memory is only used while Czech is active). You do not normally run `serve`
yourself — the app manages it.

## Verify

1. `scripts/czech-voice.sh check` → `installed`.
2. In flowcode: **Language ▸ Čeština** → a Czech reply is read aloud in the neural female voice.
3. Logs (if it misbehaves): `~/.flowcode/logs/coqui-install.log` and `coqui-serve.log`.

## Notes

- This is **English-only friendly**: users who never pick Czech never download any of this.
- The model + runtime live in `uv`'s cache and `~/Library/Application Support/tts`.
