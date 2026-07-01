#!/usr/bin/env bash
#
# setup.sh — "clone → it just works" for flowcode (Model B: read-aloud + dictation).
#
# Idempotent: re-run any time. Each phase health-checks first and skips work that is
# already done. Exits nonzero if any phase fails so a wrapper (or the setup skill) can
# report which step needs attention.
#
# What it does:
#   1. Check prerequisites (Homebrew, uv, Swift toolchain) — guidance only, no sudo.
#   2. Install + start Kokoro (TTS, :8880) and Whisper (STT, :2022) as launchd agents,
#      delegating to the voicemode service installer (it renders per-user launchd plists
#      with the current $HOME — no hardcoded paths).
#   3. Build + sign dist/flowcode.app (reusing preflight.sh / build_app.sh) with
#      Hardened Runtime. Signing identity: SIGN_IDENTITY if set, else Developer ID,
#      else an existing self-signed cert, else a stable self-signed 'flowcode-local'
#      cert is created once — so TCC grants survive rebuilds (ad-hoc is last resort).
#   4. Guide the one-time Microphone + Accessibility grants (macOS can't script these).
#   5. Optionally (--mcp-cleanup) remove the voicemode MCP from ~/.claude.json —
#      opt-in, because users may run the voicemode MCP independently of flowcode.
#   6. Health-check and print a PASS/FAIL summary.
#
# Flags / env:
#   --with-core        also build the embedded Python voice core (make_venv.sh; NOT
#                      needed for Model B — only the experimental socket path uses it)
#   --skip-services    don't install/start Kokoro/Whisper
#   --skip-build       don't build the app
#   --mcp-cleanup      remove the voicemode MCP entry from ~/.claude.json (backed up)
#   --skip-mcp-cleanup accepted for compatibility (cleanup is already opt-in)
#   --model NAME       Whisper model for the service install (default: small). Use a
#                      MULTILINGUAL model (no ".en" suffix) — Czech dictation needs it.
#                      "small" gives roughly 2x better Czech accuracy than "base".
#   SIGN_IDENTITY=...  codesign identity (e.g. "flowcode-dev" or a Developer ID); ad-hoc if unset
#   SIGN_KEYCHAIN=...  keychain holding SIGN_IDENTITY (optional)
#   FLOWCODE_CORE_CWD  path to a local voicemode checkout (for the voicemode entrypoint)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/version.env"

# --- options ------------------------------------------------------------------
WITH_CORE=0
SKIP_SERVICES=0
SKIP_BUILD=0
DO_MCP=0       # --mcp-cleanup: OPT-IN — editing ~/.claude.json breaks users who run the voicemode MCP independently
SKIP_PERMISSIONS=0   # --skip-permissions: don't reopen the System Settings panes (used by the in-app updater)
WITH_CZECH=0   # --czech: pre-install the optional Czech neural voice (else on-demand from the menu)
# Default to a MULTILINGUAL model so Czech dictation works out of the box. "small" is
# the sweet spot (~0.5 GB, ~2x better Czech than "base"). Never default to a ".en" model.
WHISPER_MODEL="small"
while [ $# -gt 0 ]; do
    case "$1" in
        --with-core)        WITH_CORE=1 ;;
        --skip-services)    SKIP_SERVICES=1 ;;
        --skip-build)       SKIP_BUILD=1 ;;
        --mcp-cleanup)      DO_MCP=1 ;;
        --skip-mcp-cleanup) DO_MCP=0 ;;   # compatibility (older docs / the in-app updater)
        --skip-permissions) SKIP_PERMISSIONS=1 ;;
        --czech)            WITH_CZECH=1 ;;
        --model)            shift; WHISPER_MODEL="${1:-small}" ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# --- output helpers (match the other scripts' style) --------------------------
FAILURES=0
log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup] WARN\033[0m %s\n' "$*"; }
sect() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# --- service probes -----------------------------------------------------------
# Bash /dev/tcp connect probe: 0 if something is listening on the port.
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
kokoro_responds() { curl -fsS --max-time 4 "http://127.0.0.1:8880/v1/audio/voices" >/dev/null 2>&1; }

# Wait up to ~180s for a port to come up. A FIRST install compiles whisper.cpp and
# downloads models (can take many minutes on slow networks) — 60s produced false
# FAILs while the install was still legitimately progressing.
wait_for_port() {
    local port="$1" i
    for i in $(seq 1 90); do
        if port_open "${port}"; then return 0; fi
        sleep 2
    done
    return 1
}

# --- voicemode entrypoint detection -------------------------------------------
VM_CMD=()
detect_voicemode() {
    if command -v voicemode >/dev/null 2>&1; then VM_CMD=(voicemode); return 0; fi
    local cand
    for cand in "${FLOWCODE_CORE_CWD:-}/.venv/bin/voicemode" "${REPO_ROOT}/../voicemode/.venv/bin/voicemode"; do
        if [ -x "${cand}" ]; then VM_CMD=("${cand}"); return 0; fi
    done
    # Pinned: a fresh clone always lands here, and an unpinned `uvx --from voice-mode`
    # tracks upstream-latest — a moving target this repo never tests against. Bump the
    # pin deliberately (and re-test setup) rather than implicitly.
    if command -v uvx >/dev/null 2>&1; then VM_CMD=(uvx --from 'voice-mode==8.10.2' voicemode); return 0; fi
    return 1
}

# ==============================================================================
# Phase 1 — prerequisites
# ==============================================================================
sect "prerequisites"
# The local TTS stack (Kokoro-FastAPI) pins a PyTorch with no macOS x86_64 wheels —
# on an Intel Mac the service install fails deep inside a launchd log. Fail up front
# with a clear message instead.
if [ "$(uname -m)" = "arm64" ]; then ok "Apple Silicon ($(uname -m))"; else
    fail "unsupported CPU ($(uname -m)) — flowcode's local voice stack requires Apple Silicon (PyTorch dropped macOS x86_64 builds)"
fi
if command -v brew >/dev/null 2>&1; then ok "Homebrew present"; else
    warn "Homebrew not found — install it: https://brew.sh (then re-run)"
fi
if command -v uv >/dev/null 2>&1; then ok "uv present"; else
    # Without uv there is no uvx fallback for the service installer — on a machine
    # with no voicemode checkout that means Phase 2 cannot install Kokoro/Whisper.
    if [ "${SKIP_SERVICES}" = 1 ] || command -v voicemode >/dev/null 2>&1; then
        warn "uv not found — install it: https://docs.astral.sh/uv/ (or: brew install uv)"
    else
        fail "uv not found and no voicemode on PATH — the voice services cannot be installed. Install uv first: brew install uv"
    fi
fi
# `command -v swift` passes even on a CLT-less Mac (the /usr/bin shim exists);
# actually running it is the honest probe.
if swift --version >/dev/null 2>&1; then ok "swift present ($(swift --version 2>/dev/null | head -1))"; else
    fail "swift toolchain not usable — install Xcode or the Command Line Tools: xcode-select --install (Swift 6 / Xcode 16+ required)"
fi
if command -v jq >/dev/null 2>&1; then ok "jq present"; else
    warn "jq not found — voicemode MCP cleanup will be skipped (brew install jq)"
fi

# ==============================================================================
# Phase 2 — voice services (Kokoro :8880 + Whisper :2022) via voicemode
# ==============================================================================
if [ "${SKIP_SERVICES}" = 1 ]; then
    sect "voice services (skipped)"
else
    sect "voice services"
    if detect_voicemode; then
        log "using voicemode entrypoint: ${VM_CMD[*]}"
    else
        warn "no voicemode entrypoint found — cannot auto-install Kokoro/Whisper."
        warn "Install voicemode first (https://github.com/mbailey/voicemode), or run with --skip-services"
        warn "if the services are already running."
    fi

    if port_open 8880; then
        ok "Kokoro already serving on :8880 — skipping install"
    elif [ "${#VM_CMD[@]}" -gt 0 ]; then
        log "installing Kokoro (TTS) service…"
        "${VM_CMD[@]}" service install kokoro || fail "voicemode service install kokoro failed"
    fi

    if port_open 2022; then
        ok "Whisper already serving on :2022 — skipping install"
    elif [ "${#VM_CMD[@]}" -gt 0 ]; then
        # A ".en" model is English-only and CANNOT transcribe Czech. Warn loudly so a
        # Czech user isn't left wondering why dictation produces gibberish.
        case "${WHISPER_MODEL}" in
            *.en) warn "model '${WHISPER_MODEL}' is English-only — Czech dictation will NOT work. Use a multilingual model (e.g. 'small')." ;;
        esac
        log "installing Whisper (STT) service (model: ${WHISPER_MODEL})…"
        # NOTE: `service install whisper` has NO --model option (it rejected the flag and
        # a || fallback silently installed the default model — the promised model never
        # landed). The model-aware installer is `whisper service install`; the env var
        # covers the runtime config for either path.
        VOICEMODE_WHISPER_MODEL="${WHISPER_MODEL}" "${VM_CMD[@]}" whisper service install --model "${WHISPER_MODEL}" \
            || fail "voicemode whisper service install failed"
        # Verify the requested model actually landed instead of trusting the exit code.
        if ls "${HOME}/.voicemode/services/whisper/models/ggml-${WHISPER_MODEL}"*.bin >/dev/null 2>&1 \
           || ls "${HOME}/.voicemode/whisper.cpp/models/ggml-${WHISPER_MODEL}"*.bin >/dev/null 2>&1; then
            ok "whisper model '${WHISPER_MODEL}' present"
        else
            warn "whisper model '${WHISPER_MODEL}' not found on disk — dictation may run a default model (try: voicemode whisper model install ${WHISPER_MODEL})"
        fi
    fi
fi

# ==============================================================================
# Phase 3 — build + sign the app
# ==============================================================================
if [ "${SKIP_BUILD}" = 1 ]; then
    sect "build (skipped)"
else
    sect "build + sign"
    if "${REPO_ROOT}/scripts/preflight.sh"; then ok "preflight passed"; else fail "preflight failed"; fi
    "${REPO_ROOT}/scripts/build_app.sh"
    if [ "${WITH_CORE}" = 1 ]; then
        log "building embedded voice core (make_venv.sh)…"
        "${REPO_ROOT}/scripts/make_venv.sh" || fail "make_venv.sh failed"
    fi

    APP="${REPO_ROOT}/dist/flowcode.app"
    # The placeholder text files break codesign; drop them before signing.
    find "${APP}/Contents/Frameworks" "${APP}/Contents/Resources/python" \
        -name '.placeholder' -delete 2>/dev/null || true

    # Create (once) a stable self-signed codesigning cert. Ad-hoc signing gets a new
    # code hash every build, so macOS silently DROPS the Accessibility + Microphone
    # grants after each rebuild/update — dictation "randomly stops working". A stable
    # identity keeps the grants across rebuilds. Falls back to ad-hoc on any failure.
    ensure_local_identity() {
        local name="flowcode-local" tmp keychain="${HOME}/Library/Keychains/login.keychain-db"
        if security find-identity -p codesigning 2>/dev/null | grep -q "\"${name}\""; then
            printf '%s' "${name}"; return 0
        fi
        command -v openssl >/dev/null 2>&1 || return 1
        tmp="$(mktemp -d)" || return 1
        (
            cd "${tmp}" || exit 1
            cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = flowcode-local
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
CNF
            openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
                -keyout key.pem -out cert.pem -config cert.cnf >/dev/null 2>&1 \
            && openssl pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem \
                -name "${name}" -passout pass:flowcode >/dev/null 2>&1 \
            && security import id.p12 -k "${keychain}" -P flowcode -T /usr/bin/codesign >/dev/null 2>&1 \
            && security add-trusted-cert -p codeSign -k "${keychain}" cert.pem >/dev/null 2>&1
        ) || { rm -rf "${tmp}"; return 1; }
        rm -rf "${tmp}"
        security find-identity -p codesigning 2>/dev/null | grep -q "\"${name}\"" || return 1
        printf '%s' "${name}"
    }

    # True if codesign can ACTUALLY sign with this identity (covers trust + key
    # access, which find-identity alone doesn't prove).
    can_sign_with() {
        local id="$1" t rc
        t="$(mktemp -d)" || return 1
        cp /bin/ls "${t}/probe" 2>/dev/null || { rm -rf "${t}"; return 1; }
        codesign --force --sign "${id}" "${t}/probe" >/dev/null 2>&1
        rc=$?
        rm -rf "${t}"
        return "${rc}"
    }

    SIGN_ID="${SIGN_IDENTITY:-}"
    if [ -z "${SIGN_ID}" ]; then
        if security find-identity -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
            SIGN_ID="$(security find-identity -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
            log "found Developer ID — signing with it"
        elif security find-identity -p codesigning 2>/dev/null | grep -q '"flowcode-dev"'; then
            SIGN_ID="flowcode-dev"   # pre-existing dev cert on this machine
            log "using existing self-signed 'flowcode-dev'"
        else
            log "no signing identity — creating a stable self-signed 'flowcode-local' cert"
            log "(one-time; macOS may ask for your login password to trust it)"
            if SIGN_ID="$(ensure_local_identity)" && can_sign_with "${SIGN_ID}"; then
                ok "signing with 'flowcode-local' — TCC grants will survive rebuilds"
            else
                SIGN_ID="-"
                warn "could not create a stable cert — using ad-hoc (-). Gatekeeper warns on first open; TCC re-prompts each rebuild."
                warn "Tip: set SIGN_IDENTITY to a stable self-signed cert so grants survive rebuilds."
            fi
        fi
    fi
    # Hardened Runtime + entitlements (mic, library validation for the optional Python
    # sidecar): without --options runtime the app is a TCC-privileged (Accessibility +
    # Mic) process that any same-user process can inject code into (DYLD_INSERT_LIBRARIES).
    ENTITLEMENTS="${SCRIPT_DIR}/flowcode.entitlements"
    CODESIGN_ARGS=(--force --options runtime --entitlements "${ENTITLEMENTS}" --sign "${SIGN_ID}")
    if [ -n "${SIGN_KEYCHAIN:-}" ]; then
        security unlock-keychain "${SIGN_KEYCHAIN}" 2>/dev/null || true
        CODESIGN_ARGS=(--keychain "${SIGN_KEYCHAIN}" "${CODESIGN_ARGS[@]}")
    fi
    # Inside-out: helper first, bundle last.
    codesign "${CODESIGN_ARGS[@]}" "${APP}/Contents/Helpers/flowcode-watchdog" 2>/dev/null || true
    codesign "${CODESIGN_ARGS[@]}" "${APP}"
    if codesign --verify --strict "${APP}" 2>/dev/null; then ok "signed (${SIGN_ID}, hardened runtime) + verified"; else fail "codesign verify failed"; fi
fi

# ==============================================================================
# Phase 4 — permissions (guided; macOS can't grant TCC from a script)
# ==============================================================================
if [ "${SKIP_PERMISSIONS}" = 1 ]; then
    sect "permissions (skipped)"
    log "Skipping the System Settings panes (grants survive a re-sign with a stable identity)."
else
    sect "permissions (one-time, manual)"
    log "Read-aloud needs NO permissions. Dictation (hold Right Option ⌥) needs Microphone + Accessibility."
    log "Opening the System Settings panes — enable 'flowcode' in BOTH, then relaunch the app:"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" 2>/dev/null || true
fi

# ==============================================================================
# Phase 5 — optionally remove the unused voicemode MCP (OPT-IN: --mcp-cleanup)
# ==============================================================================
if [ "${DO_MCP}" != 1 ]; then
    sect "voicemode MCP cleanup (skipped)"
    log "Not touching ~/.claude.json. If you don't use the voicemode MCP elsewhere,"
    log "re-run with --mcp-cleanup to remove its (unused-by-flowcode) entry."
elif ! command -v jq >/dev/null 2>&1; then
    sect "voicemode MCP cleanup"
    warn "jq not found — skipping (brew install jq, then re-run)"
else
    sect "voicemode MCP cleanup"
    log "Model B reaches Kokoro/Whisper over HTTP directly; the voicemode MCP is unused."
    ts="$(date +%Y%m%d-%H%M%S)"
    for f in "${HOME}/.claude.json" "${HOME}/.claude-work/.claude.json"; do
        [ -f "${f}" ] || continue
        if [ "$(jq -r '(.mcpServers.voicemode != null)' "${f}" 2>/dev/null)" = "true" ]; then
            cp "${f}" "${f}.bak-${ts}"
            if jq 'del(.mcpServers.voicemode)' "${f}" > "${f}.tmp" && jq empty "${f}.tmp"; then
                mv "${f}.tmp" "${f}"
                ok "removed voicemode MCP from ${f} (backup: ${f}.bak-${ts})"
            else
                rm -f "${f}.tmp"
                fail "could not edit ${f} — left untouched"
            fi
        else
            ok "no voicemode MCP in ${f}"
        fi
    done
    log "Restore (if ever needed): cp <file>.bak-${ts} <file>"
fi

# ==============================================================================
# Phase 5b — optional Czech neural voice (only with --czech; otherwise on-demand)
# ==============================================================================
if [ "${WITH_CZECH}" = 1 ]; then
    sect "Czech voice (optional)"
    log "Pre-installing the Czech neural voice (Coqui, ~350 MB)…"
    if "${SCRIPT_DIR}/czech-voice.sh" install; then
        ok "Czech voice installed — pick 'Language ▸ Čeština' in the menu"
    else
        fail "Czech voice install failed (you can still trigger it later from the menu)"
    fi
else
    sect "Czech voice (optional)"
    ok "skipped — flowcode downloads it on demand when you pick Čeština (or run: scripts/czech-voice.sh install)"
fi

# ==============================================================================
# Phase 6 — health + summary
# ==============================================================================
sect "health"
if [ "${SKIP_SERVICES}" != 1 ]; then
    if wait_for_port 8880 kokoro; then ok "Kokoro :8880 listening"; else
        fail "Kokoro :8880 not listening yet — a FIRST install downloads models for several minutes; re-run scripts/setup.sh later or watch ~/.voicemode/logs/kokoro"
    fi
    if kokoro_responds; then ok "Kokoro responding to /v1/audio/voices"; else warn "Kokoro port open but /v1/audio/voices not ready yet (still warming up?)"; fi
    if wait_for_port 2022 whisper; then ok "Whisper :2022 listening"; else
        fail "Whisper :2022 not listening yet — a FIRST install compiles whisper.cpp + downloads the model; re-run scripts/setup.sh later or watch ~/.voicemode/logs/whisper"
    fi
fi
if [ "${SKIP_BUILD}" != 1 ]; then
    if [ -d "${REPO_ROOT}/dist/flowcode.app" ]; then ok "app built: dist/flowcode.app"; else fail "dist/flowcode.app missing"; fi
fi

sect "done"
if [ "${FAILURES}" -eq 0 ]; then
    printf '\033[1;32mSETUP PASS\033[0m — open dist/flowcode.app, grant Mic + Accessibility once, and start coding.\n'
    exit 0
else
    printf '\033[1;31mSETUP: %d step(s) need attention\033[0m (see FAIL lines above).\n' "${FAILURES}"
    exit 1
fi
