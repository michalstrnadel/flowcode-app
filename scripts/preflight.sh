#!/usr/bin/env bash
#
# preflight.sh — headless release smoke checks that CAN run without Apple creds,
# without network, and without notarization. Run this in CI on every push and
# locally before tagging. Exits nonzero on the first category that fails.
#
# What it checks:
#   1. Required tools present (swift, lipo, sed, plutil).
#   2. Every release script parses (bash -n) and, if shellcheck is installed, is
#      shellcheck-clean.
#   3. version.env is well-formed and the pins look sane.
#   4. Info.plist (the SOURCE template) has LSUIElement + NSMicrophoneUsageDescription.
#   5. `swift build` succeeds (debug; fast) for the host arch.
#   6. flowcode-selftest builds and PASSES (the project's test surface — XCTest is
#      unavailable under Command Line Tools).
#   7. The watchdog helper compiles standalone with swiftc.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

fails=0
pass() { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }
sect() { printf '\033[1;36m== %s ==\033[0m\n' "$*"; }

# --- 1. tools -----------------------------------------------------------------
sect "required tools"
for t in swift lipo sed plutil swiftc; do
    if command -v "${t}" >/dev/null 2>&1; then pass "found ${t}"; else fail "missing ${t}"; fi
done

# --- 2. scripts parse + shellcheck --------------------------------------------
sect "scripts parse-clean"
SCRIPTS=(build_app.sh make_venv.sh sign_notarize.sh preflight.sh _generate_appcast.sh setup.sh czech-voice.sh)
for s in "${SCRIPTS[@]}"; do
    p="${SCRIPT_DIR}/${s}"
    if [ ! -f "${p}" ]; then fail "missing script ${s}"; continue; fi
    if bash -n "${p}" 2>/dev/null; then pass "bash -n ${s}"; else fail "bash -n ${s}"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
    for s in "${SCRIPTS[@]}"; do
        p="${SCRIPT_DIR}/${s}"
        [ -f "${p}" ] || continue
        if shellcheck -S warning "${p}" >/dev/null 2>&1; then pass "shellcheck ${s}"; else fail "shellcheck ${s}"; fi
    done
else
    printf '  \033[1;33mskip\033[0m shellcheck not installed (bash -n still ran)\n'
fi

# --- 3. version.env -----------------------------------------------------------
sect "version.env"
VE="${REPO_ROOT}/version.env"
if [ -f "${VE}" ]; then
    # shellcheck source=/dev/null
    source "${VE}"
    [ -n "${VERSION:-}" ]          && pass "VERSION=${VERSION}"                     || fail "VERSION unset"
    [ -n "${VOICEMODE_COMMIT:-}" ] && pass "VOICEMODE_COMMIT pinned"               || fail "VOICEMODE_COMMIT unset"
    # commit must be a full 40-char sha, not a moving ref.
    if printf '%s' "${VOICEMODE_COMMIT:-}" | grep -Eq '^[0-9a-f]{40}$'; then
        pass "VOICEMODE_COMMIT is a full sha"
    else
        fail "VOICEMODE_COMMIT is not a 40-char sha (no moving refs)"
    fi
    [ -n "${BUNDLE_ID:-}" ]        && pass "BUNDLE_ID=${BUNDLE_ID}"                || fail "BUNDLE_ID unset"
else
    fail "version.env missing"
fi

# --- 4. Info.plist template ---------------------------------------------------
sect "Info.plist template"
PLIST="${REPO_ROOT}/Sources/flowcode/Info.plist"
if [ -f "${PLIST}" ]; then
    if grep -q "<key>LSUIElement</key>" "${PLIST}"; then pass "LSUIElement present"; else fail "LSUIElement missing"; fi
    if grep -q "<key>NSMicrophoneUsageDescription</key>" "${PLIST}"; then
        pass "NSMicrophoneUsageDescription present"
    else
        fail "NSMicrophoneUsageDescription missing"
    fi
    if grep -q "<key>CFBundleIdentifier</key>" "${PLIST}"; then pass "CFBundleIdentifier present"; else fail "CFBundleIdentifier missing"; fi
else
    fail "Sources/flowcode/Info.plist missing"
fi

# --- 5. swift build -----------------------------------------------------------
sect "swift build"
if swift build --package-path "${REPO_ROOT}" >/tmp/flowcode-preflight-build.log 2>&1; then
    pass "swift build succeeds"
else
    fail "swift build failed:"
    tail -n 50 /tmp/flowcode-preflight-build.log >&2
fi

# --- 6. flowcode-selftest -----------------------------------------------------
sect "flowcode-selftest"
if swift run --package-path "${REPO_ROOT}" flowcode-selftest >/tmp/flowcode-preflight-selftest.log 2>&1; then
    pass "flowcode-selftest passes"
else
    fail "flowcode-selftest failed:"
    tail -n 50 /tmp/flowcode-preflight-selftest.log >&2
fi

# --- 7. watchdog compiles standalone ------------------------------------------
sect "watchdog helper"
WD_SRC="${REPO_ROOT}/Helpers/flowcode-watchdog/main.swift"
if [ -f "${WD_SRC}" ]; then
    if swiftc -O -typecheck "${WD_SRC}" >/tmp/flowcode-preflight-watchdog.log 2>&1; then
        pass "watchdog typechecks (swiftc)"
    else
        fail "watchdog failed to typecheck (see /tmp/flowcode-preflight-watchdog.log)"
    fi
else
    fail "Helpers/flowcode-watchdog/main.swift missing"
fi

# --- summary ------------------------------------------------------------------
echo
if [ "${fails}" -eq 0 ]; then
    printf '\033[1;32mPREFLIGHT PASS\033[0m\n'
    exit 0
else
    printf '\033[1;31mPREFLIGHT: %d FAILURE(S)\033[0m\n' "${fails}"
    exit 1
fi
