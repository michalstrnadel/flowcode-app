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
#   3. Build + sign dist/flowcode.app (reusing preflight.sh / build_app.sh; ad-hoc sign
#      unless SIGN_IDENTITY is set).
#   4. Guide the one-time Microphone + Accessibility grants (macOS can't script these).
#   5. Remove the now-unused voicemode MCP from ~/.claude.json (Model B doesn't use it).
#   6. Health-check and print a PASS/FAIL summary.
#
# Flags / env:
#   --with-core        also build the embedded Python voice core (make_venv.sh; NOT
#                      needed for Model B — only the experimental socket path uses it)
#   --skip-services    don't install/start Kokoro/Whisper
#   --skip-build       don't build the app
#   --skip-mcp-cleanup don't touch ~/.claude.json
#   --model NAME       Whisper model for the service install (default: base)
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
SKIP_MCP=0
WHISPER_MODEL="base"
while [ $# -gt 0 ]; do
    case "$1" in
        --with-core)        WITH_CORE=1 ;;
        --skip-services)    SKIP_SERVICES=1 ;;
        --skip-build)       SKIP_BUILD=1 ;;
        --skip-mcp-cleanup) SKIP_MCP=1 ;;
        --model)            shift; WHISPER_MODEL="${1:-base}" ;;
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

# Wait up to ~60s for a port to come up (services compile/download on first run).
wait_for_port() {
    local port="$1" i
    for i in $(seq 1 30); do
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
    if command -v uvx >/dev/null 2>&1; then VM_CMD=(uvx --from voice-mode voicemode); return 0; fi
    return 1
}

# ==============================================================================
# Phase 1 — prerequisites
# ==============================================================================
sect "prerequisites"
if command -v brew >/dev/null 2>&1; then ok "Homebrew present"; else
    warn "Homebrew not found — install it: https://brew.sh (then re-run)"
fi
if command -v uv >/dev/null 2>&1; then ok "uv present"; else
    warn "uv not found — install it: https://docs.astral.sh/uv/ (or: brew install uv)"
fi
if command -v swift >/dev/null 2>&1; then ok "swift present ($(swift --version 2>/dev/null | head -1))"; else
    fail "swift not found — install Xcode or the Command Line Tools: xcode-select --install"
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
        log "installing Whisper (STT) service (model: ${WHISPER_MODEL})…"
        "${VM_CMD[@]}" service install whisper --model "${WHISPER_MODEL}" \
            || "${VM_CMD[@]}" service install whisper \
            || fail "voicemode service install whisper failed"
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

    SIGN_ID="${SIGN_IDENTITY:-}"
    if [ -z "${SIGN_ID}" ]; then
        if security find-identity -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
            SIGN_ID="$(security find-identity -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
            log "found Developer ID — signing with it"
        else
            SIGN_ID="-"
            warn "no signing identity — using ad-hoc (-). Gatekeeper warns on first open; TCC re-prompts each rebuild."
            warn "Tip: set SIGN_IDENTITY (e.g. your stable self-signed 'flowcode-dev') so grants survive rebuilds."
        fi
    fi
    CODESIGN_ARGS=(--force --sign "${SIGN_ID}")
    if [ -n "${SIGN_KEYCHAIN:-}" ]; then
        security unlock-keychain "${SIGN_KEYCHAIN}" 2>/dev/null || true
        CODESIGN_ARGS=(--keychain "${SIGN_KEYCHAIN}" "${CODESIGN_ARGS[@]}")
    fi
    # Inside-out: helper first, bundle last.
    codesign "${CODESIGN_ARGS[@]}" "${APP}/Contents/Helpers/flowcode-watchdog" 2>/dev/null || true
    codesign "${CODESIGN_ARGS[@]}" "${APP}"
    if codesign --verify --strict "${APP}" 2>/dev/null; then ok "signed (${SIGN_ID}) + verified"; else fail "codesign verify failed"; fi
fi

# ==============================================================================
# Phase 4 — permissions (guided; macOS can't grant TCC from a script)
# ==============================================================================
sect "permissions (one-time, manual)"
log "Read-aloud needs NO permissions. Dictation (hold Right Option ⌥) needs Microphone + Accessibility."
log "Opening the System Settings panes — enable 'flowcode' in BOTH, then relaunch the app:"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" 2>/dev/null || true

# ==============================================================================
# Phase 5 — remove the unused voicemode MCP (Model B doesn't use it)
# ==============================================================================
if [ "${SKIP_MCP}" = 1 ]; then
    sect "voicemode MCP cleanup (skipped)"
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
# Phase 6 — health + summary
# ==============================================================================
sect "health"
if [ "${SKIP_SERVICES}" != 1 ]; then
    if wait_for_port 8880 kokoro; then ok "Kokoro :8880 listening"; else fail "Kokoro :8880 not listening (see ~/.voicemode/logs/kokoro)"; fi
    if kokoro_responds; then ok "Kokoro responding to /v1/audio/voices"; else warn "Kokoro port open but /v1/audio/voices not ready yet (still warming up?)"; fi
    if wait_for_port 2022 whisper; then ok "Whisper :2022 listening"; else fail "Whisper :2022 not listening (see ~/.voicemode/logs/whisper)"; fi
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
