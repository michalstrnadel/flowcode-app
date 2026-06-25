# CLAUDE.md — flowcode

Guidance for Claude Code when working in this repo.

## What flowcode is

A native macOS menu-bar app: a **voice layer for Claude Code**. The shipping product
("Model B") reads Claude Code's transcript replies aloud via **Kokoro** TTS and lets you
dictate prompts by push-to-talk via **Whisper** STT. Claude Code is unmodified; flowcode
tails the session JSONL it already writes and talks to the two local HTTP services
(Kokoro `:8880`, Whisper `:2022`). There is **no socket, no Python core, no MCP** in this
default path.

`readAloudEnabled` (default true → `SettingsStore`) selects Model B in `main.swift`. The
experimental socket/barge-in/converse/swarm code is present but **off by default** and
needs `readAloudEnabled = false` plus a running voicemode core.

## Build & test

```sh
swift build                 # flowcodeKit + the app
swift run flowcode          # run from the build dir (dev, ad-hoc signed)
swift run flowcode-selftest # headless tests (no mic, no creds) — must print ALL PASS
scripts/preflight.sh        # build + selftest + watchdog typecheck gate (run before tagging)
```

XCTest is unavailable under the bare Command Line Tools, so tests live in the
`flowcode-selftest` executable, not `swift test`.

## Setup / packaging order

- `scripts/setup.sh` — clone → it works (services + build + sign + permissions guide).
- Release path: `preflight.sh` → `build_app.sh` → (`make_venv.sh` only `--with-core`) →
  `sign_notarize.sh`. See `DISTRIBUTION.md`. Single source of truth: `version.env`.

## Conventions

- Swift 6, strict concurrency; UI/AppKit types are `@MainActor`.
- `version.env` is the only place for `BUNDLE_ID` / versions / URLs — it cascades to
  `Info.plist` via the `build_app.sh` sed substitution. Don't hardcode the bundle id.
- Keep the experimental voice-core code compiling (the selftest covers its IPC/orb/swarm
  contracts) but default-off.
- License: MIT. Keep `THIRD-PARTY-NOTICES.md` accurate when adding dependencies.
