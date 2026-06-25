# DISTRIBUTION — building, signing, notarizing & shipping flowcode

flowcode ships as a **notarized universal `.zip`** on GitHub Releases, with a
**Sparkle** self-update feed and a **Homebrew cask**. No DMG, no Mac App Store
(the app is unsandboxed by design — embedded Python sidecar + localhost STT/TTS
+ LaunchAgents are incompatible with App Sandbox; see `PLAN.md` / `BOUNDARIES.md`).

Everything here is **default-off relative to development**: nothing in this folder
runs unless you invoke a release script or push a `v*` tag. `swift build` /
`swift run` are unaffected.

---

## TL;DR

```sh
# 1. Headless smoke checks (no Apple creds, no network) — run this anytime.
scripts/preflight.sh

# 2. Full local release (needs creds in env; see "Required secrets").
scripts/build_app.sh          # per-arch swift build -> lipo -> assemble .app
scripts/make_venv.sh          # download CPython + freeze voicemode into the bundle
scripts/sign_notarize.sh      # inside-out sign -> notarytool --wait -> staple -> zip

# CI does all of the above on a `v*` tag (.github/workflows/release.yml).
```

The single source of truth for versions + the pinned voicemode commit is
[`version.env`](version.env). Bump `VERSION` + `BUILD` + `VOICEMODE_COMMIT`
together; tag `v${VERSION}`.

---

## Required secrets

Set as environment variables locally, or as GitHub repository secrets for CI.

| Purpose | Local env var | CI secret | How to obtain |
| --- | --- | --- | --- |
| Code signing identity | `SIGN_IDENTITY` | `APPLE_SIGN_IDENTITY` | `"Developer ID Application: NAME (TEAMID)"`. Create the cert in Apple Developer → Certificates → **Developer ID Application**. The string is what `security find-identity -p codesigning` prints. |
| Signing cert (CI only) | — (in keychain) | `APPLE_CERT_P12_BASE64`, `APPLE_CERT_P12_PASSWORD` | Export the Developer ID Application cert **+ private key** from Keychain as `.p12`, then `base64 -i cert.p12`. The password protects the `.p12`. |
| Notarization key | `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | `APPLE_NOTARY_KEY_P8_BASE64`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID` | App Store Connect → Users and Access → **Integrations / Keys** → generate an API key with the **Developer** role. Download the `.p8` once. `KEY_ID` is shown next to the key; `ISSUER_ID` is at the top of that page. |
| Sparkle signing | (local: file) | `SPARKLE_ED_PRIVATE_KEY`, `SPARKLE_PUBLIC_ED_KEY` | Run Sparkle's `generate_keys` once. Keep the **private** key secret (signs the appcast); the **public** key is patched into `Info.plist` (`SUPublicEDKey`). Both base64. |
| Homebrew cask bump | — | `HOMEBREW_TAP_TOKEN` | A GitHub PAT (fine-grained, `contents:write`) on the tap repo so CI can push the `version`/`sha256` bump to `Casks/flowcode.rb`. |

**Never** echo these into logs. The CI workflow decodes secrets into
`$RUNNER_TEMP` and shreds them after use.

---

## What each script does

### `scripts/build_app.sh`
- `swift build -c release --arch arm64` and `--arch x86_64` for the `flowcode`
  product, then `lipo -create` into a single universal `Contents/MacOS/flowcode`.
- Compiles `Helpers/flowcode-watchdog/main.swift` standalone with `swiftc` per
  arch, lipos into `Contents/Helpers/flowcode-watchdog`.
- Substitutes `version.env` tokens into `Info.plist` and `plutil -lint`s it.
- Lays down `Contents/Resources/python/` (venv placeholder) and
  `Contents/Frameworks/` (Sparkle placeholder).
- Idempotent, `set -euo pipefail`. Does **not** sign or build the venv.

### `scripts/make_venv.sh` (network-gated)
- Downloads a **relocatable** CPython from
  [python-build-standalone](https://github.com/astral-sh/python-build-standalone),
  pinned by `PBS_RELEASE` + `PYTHON_VERSION`, for the requested `ARCH`.
- Creates a `uv venv` against it and installs the voicemode core **frozen at**
  `VOICEMODE_COMMIT` (the reproducibility input — never a moving branch/tag).
- Smoke-imports `voice_mode` inside the venv before placing it in the bundle.
- Refuses to run offline.
- The venv is **per-arch** (native interpreter + native wheels: PortAudio,
  onnxruntime, numpy). CI builds one venv per matrix arch and ships one zip per
  arch.

### `scripts/sign_notarize.sh`
- **Inside-out** codesign, **not** `--deep`:
  1. every nested Mach-O under `Resources` (the interpreter + every wheel `.so` /
     `.dylib`) and `Frameworks`,
  2. `Sparkle.framework` (its XPC services + `Autoupdate` first, then the bundle),
  3. the `flowcode-watchdog` helper,
  4. the main executable, then the `.app` bundle **last**.
- Every signature: **Hardened Runtime** (`--options runtime`), `--timestamp`, and
  the `flowcode.entitlements` (which includes
  `com.apple.security.cs.disable-library-validation` so the interpreter can
  `dlopen` our-signed wheels).
- `xcrun notarytool submit --wait` then `xcrun stapler staple`, then re-`ditto`
  the stapled bundle into `dist/flowcode-${VERSION}.zip`.
- `SKIP_NOTARIZE=1` signs + zips without notarizing — for a local Gatekeeper
  smoke test only.

### `scripts/preflight.sh`
Runs **now**, no creds, no network. Verifies tools, `bash -n` + shellcheck on all
scripts, `version.env` sanity (incl. that `VOICEMODE_COMMIT` is a 40-char sha),
`Info.plist` has `LSUIElement` + `NSMicrophoneUsageDescription`, `swift build`,
`flowcode-selftest` **passes**, and the watchdog typechecks. Nonzero on failure.

---

## The known-hard parts

1. **Notarizing embedded Python + native wheels.** This is the riskiest piece.
   The bundle contains hundreds of nested Mach-O files (the interpreter and every
   `.so` from PortAudio / onnxruntime / numpy). `--deep` is unreliable here and
   Apple advises against it — hence the explicit inside-out walk in
   `sign_notarize.sh`. Each `.so` must carry our Developer ID signature, and the
   interpreter needs `disable-library-validation` to load them. If notarization
   fails, `xcrun notarytool log <submission-id> --key ...` lists the exact
   offending unsigned/badly-signed binary.

2. **Re-sign after ANY `Info.plist` edit (TCC trap).** Editing `Info.plist`
   invalidates the code signature, and an invalid signature makes macOS silently
   drop the **microphone TCC grant** — the prompt just never appears again and
   the app looks broken with no error. That's why `sign_notarize.sh` patches
   `SUPublicEDKey` **before** signing and never touches the plist afterward. If
   you hand-edit the plist in a built bundle, you **must** re-run the full sign.

3. **flowcode must be the responsible process for the mic.** `main.swift` calls
   `AVCaptureDevice.requestAccess(.audio)` *before* spawning Python, and
   `Info.plist` carries `NSMicrophoneUsageDescription` + the audio-input
   entitlement. Combined with notarization, the grant attaches to `flowcode` and
   survives updates. The Python core inherits access; it never prompts.

4. **Per-arch venv vs universal binary.** The Swift binary is universal, but the
   embedded venv is not. We ship one zip per arch. Don't try to lipo Python — the
   wheels' `.so` files are single-arch and the interpreter expects matching ABI.

5. **Watchdog ownership of the core.** `Foundation.Process` does not reap a
   grandchild when the app is force-killed; the Python core would orphan to
   launchd holding the mic. `flowcode-watchdog` `posix_spawnp`s the core in its
   own process group and `SIGTERM`→grace→`SIGKILL`s it the moment
   `getppid() == 1` (parent died). It is signed with the same entitlements.

6. **Sparkle key hygiene.** The Ed25519 **private** key signs the appcast; a leak
   lets an attacker push a malicious update. Keep it in secrets only, shred it
   after use in CI (the workflow does). `SUPublicEDKey` in `Info.plist` must match.

7. **Bundle-id change ⇒ one-time TCC re-grant.** macOS keys the Microphone and
   Accessibility grants to the codesign **Designated Requirement (DR)**, which embeds
   `BUNDLE_ID`. The id was changed from `cz.slevomat.flowcode` to
   `io.github.michalstrnadel.flowcode` for the open-source release, so the DR's
   identifier changed and **every existing install/dev machine must re-grant both
   permissions once**. Until then, dictation (Accessibility) and the mic path silently
   fail. The stable self-signed dev cert is **reused** — only the identifier part of the
   DR changes, so this is a one-time re-grant, not a cert recreation. Migration on a dev
   machine:

   ```sh
   tccutil reset Microphone    io.github.michalstrnadel.flowcode
   tccutil reset Accessibility io.github.michalstrnadel.flowcode
   # relaunch flowcode, then grant once when prompted
   ```

   (If a build of the OLD id was ever distributed, an id + feed-URL change also breaks
   Sparkle update continuity — those users must reinstall. Safe here: `BUILD=1` has not
   been publicly shipped.)

---

## Build-from-source vs notarized release

The open-source v1 ships a **build-from-source** path (`scripts/setup.sh`): contributors
clone, build, and run with an **ad-hoc** signature when no Developer ID is present. An
ad-hoc build re-prompts for Mic/Accessibility on every rebuild (TCC is keyed to the
signature) and Gatekeeper warns on first open (`xattr -dr com.apple.quarantine
dist/flowcode.app` clears it). A **notarized Developer-ID `.zip`** (the secrets + scripts
below) is the only friction-free path for end users — that is a later milestone and
requires a paid Apple Developer account.

---

## Release checklist

1. Bump `VERSION`, `BUILD`, `VOICEMODE_COMMIT` in `version.env`.
2. `scripts/preflight.sh` — green.
3. Commit, then `git tag v${VERSION} && git push --tags`.
4. CI: preflight → per-arch build/venv/sign/notarize → appcast → GitHub release →
   cask bump.
5. Verify: download the zip on a clean Mac, open — no Gatekeeper fight, mic prompt
   attributed to **flowcode**, Sparkle "Check for Updates" works.
