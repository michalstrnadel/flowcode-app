# Contributing to flowcode

Thanks for your interest in flowcode! 🎉 This is a small, focused macOS app — contributions of
all sizes are welcome, from typo fixes to features.

## Ground rules

- Be kind and constructive (see [Code of Conduct](CODE_OF_CONDUCT.md)).
- Open an [issue](https://github.com/michalstrnadel/flowcode-app/issues) or a
  [discussion](https://github.com/michalstrnadel/flowcode-app/discussions) before large changes, so
  we can agree on the approach first.
- Keep PRs small and focused — one logical change per PR is much easier to review.

## Project layout

flowcode ships **Model B**: read-aloud of Claude Code's replies (Kokoro TTS) + push-to-talk
dictation (Whisper STT). It talks to the two local HTTP services directly — no socket, no Python
core, no MCP in the default path.

- `Sources/flowcodeKit` — the testable library (stores, voice pipeline, orb HUD, the **experimental**
  socket/IPC/swarm code, which is default-off).
- `Sources/flowcode` — the menu-bar executable.
- `Sources/flowcodeSelfTest` — a plain-executable test harness (XCTest is unavailable under the bare
  Command Line Tools).
- `scripts/` — `setup.sh` (clone → it works), plus the release pipeline (`preflight`, `build_app`,
  `make_venv`, `sign_notarize`).

See [`CLAUDE.md`](CLAUDE.md) for conventions and [`DISTRIBUTION.md`](DISTRIBUTION.md) for releases.

## Develop & test

Requires **macOS 14+** and **Swift 6** (Xcode 16 toolchain or Command Line Tools).

```sh
swift build                 # build flowcodeKit + the app
swift run flowcode          # run from the build dir (dev, ad-hoc signed)
swift run flowcode-selftest # headless verification — must print "ALL PASS"
scripts/preflight.sh        # the full gate: build + selftest + watchdog typecheck
```

Run `scripts/preflight.sh` before opening a PR — CI runs the same thing.

To run the whole thing locally (engines + app + permissions): `scripts/setup.sh`.

## Coding guidelines

- **Swift 6, strict concurrency.** UI/AppKit types are `@MainActor`. Don't introduce data races.
- **Match the surrounding code** — comment density, naming, and idiom. Read the file before editing.
- **Add a test** to `flowcodeSelfTest` when it fits (especially for pure logic).
- **Don't hardcode** the bundle id or URLs — `version.env` is the single source of truth.
- Keep the **experimental** voice-core code (barge-in / converse / swarm) compiling and default-off.
- Update docs (`README.md`, `CHANGELOG.md`) for user-visible changes.

## Commits & PRs

- Use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`,
  `refactor:`, `chore:`, `test:`, `build:`, `ci:`, `perf:`, `style:`.
- Fill in the PR template; link the issue it closes.
- A green CI run + a passing `flowcode-selftest` are required to merge.

## Reporting bugs / requesting features

Use the [issue forms](https://github.com/michalstrnadel/flowcode-app/issues/new/choose). For security
issues, **do not** open a public issue — see [`SECURITY.md`](SECURITY.md).
