# AGENTS.md — install flowcode for the user

You are an AI coding agent (Claude Code or similar) and the user has asked you to **install
flowcode** on this Mac. This file is your runbook. Work from the repo root.

flowcode is a macOS **menu-bar voice layer** for Claude Code and the Claude desktop app: it reads
each new assistant reply **aloud** (local Kokoro TTS; optional Czech neural voice) and lets the user
**dictate** by holding Right Option ⌥ (local Whisper STT). Everything runs locally.

## The goal (definition of done)

1. The two local voice services are running: **Kokoro** (`127.0.0.1:8880`) and **Whisper**
   (`127.0.0.1:2022`).
2. **flowcode.app** is built, signed, and launched — the orb is in the menu bar.
3. You have told the user exactly which **permission toggles** to flip (you cannot do this for them).
4. You have verified the above and reported the result.

## Do this

1. **Check prerequisites** (don't silently `sudo`-install; if one is missing, tell the user the
   one command to run): `brew`, `uv` (https://docs.astral.sh/uv/), and `swift` (`xcode-select -p`).
   macOS must be 14+ on **Apple Silicon** (the local TTS stack has no Intel builds). Warn the
   user that a first install downloads/builds ~3–5 GB and can take 15–45 minutes.

2. **Run the setup script and report its phase output to the user:**
   ```sh
   scripts/setup.sh
   ```
   It installs Kokoro + Whisper (via the voicemode installer), builds + signs the app, and opens
   the right System Settings panes. It is idempotent and exits non-zero on failure. It does NOT
   touch `~/.claude.json` unless you pass `--mcp-cleanup` — ask the user before using that flag.
   (Equivalent: the bundled **`/setup`** skill.)

3. **Hand the permissions to the user** — macOS (TCC/SIP) makes these *impossible* to grant from a
   script or by an agent. Tell the user to open **System Settings → Privacy & Security** and enable
   **flowcode** in:
   - **Accessibility** — needed for dictation (to paste) and for reading the **Claude desktop app**
     aloud. *Claude Code read-aloud needs nothing.*
   - **Microphone** — needed for dictation.

   Then have them **relaunch** the app. (Dev builds are signed with a stable local cert, so the
   grant survives rebuilds on this machine.)

4. **Launch it** (if setup didn't): `open dist/flowcode.app` — the app is built into the
   repo's `dist/`; nothing is installed to /Applications.

5. **Optional — Czech voice.** Only if the user wants Czech. It's downloaded on demand (the menu
   prompts), or pre-install it now:
   ```sh
   scripts/czech-voice.sh install     # ~350 MB one-time (neural voice + runtime); needs uv
   scripts/setup.sh --model medium    # better Czech dictation accuracy (larger Whisper model)
   ```
   (Equivalent: the **`/czech-voice`** skill.) English users need none of this.

## Verify

```sh
curl -fsS http://127.0.0.1:8880/v1/audio/voices >/dev/null && echo "Kokoro OK"
curl -fsS http://127.0.0.1:2022/health           >/dev/null && echo "Whisper OK"
swift run flowcode-selftest    # must print: ALL PASS
```

Then ask the user to confirm they **hear Claude's next reply read aloud**, and (if they granted the
permissions) that **holding ⌥ dictates** into the focused app.

## You CANNOT do these — hand them to the user

- **Grant Accessibility / Microphone.** macOS requires a human in System Settings (SIP blocks
  scripting it). Guide them; never claim it's done until they confirm.
- **Notarized download.** There is none by design — this OSS version installs from source via an
  agent. (A notarized Developer-ID build needs a paid Apple account; see `DISTRIBUTION.md`. Out of
  scope for install.)

## If something breaks

- **No audio** → a service is down. Re-run `scripts/setup.sh`; logs in `~/.voicemode/logs/`.
- **Dictation silent** → Accessibility + Microphone not granted, or a rebuild reset the grant →
  have the user re-grant, then relaunch.
- **Czech voice issues** → `~/.flowcode/logs/coqui-install.log` / `coqui-serve.log`; ensure `uv`
  is installed. `scripts/czech-voice.sh check` reports install state.
- **Reads the wrong session** → flowcode reads only the *most-recently-active* Claude Code session;
  switch the user's focus to the session they want spoken.

## Contributing to the code (not installing)

If instead you're modifying flowcode's source, read [`CLAUDE.md`](CLAUDE.md) for build/test
conventions (`swift build`, `swift run flowcode-selftest`, `scripts/preflight.sh`).
