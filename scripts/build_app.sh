#!/usr/bin/env bash
#
# build_app.sh — build flowcode for both arches, lipo into a universal binary,
# and assemble the flowcode.app bundle.
#
# Idempotent: re-running rebuilds cleanly into the same dist/ layout. Does NOT
# sign, notarize, or build the venv (see sign_notarize.sh / make_venv.sh).
#
# Produces:
#   dist/flowcode.app/Contents/
#     Info.plist
#     MacOS/flowcode                 (universal arm64 + x86_64)
#     Helpers/flowcode-watchdog      (universal sidecar)
#     Resources/python/              (placeholder; filled by make_venv.sh)
#     Frameworks/                    (placeholder; Sparkle.framework dropped in later)
#
# Usage:
#   scripts/build_app.sh                  # build both arches (default)
#   ARCHES="arm64" scripts/build_app.sh   # single arch (faster local iteration)
#
set -euo pipefail

# --- locate repo + load version pins ------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/version.env"

DIST="${REPO_ROOT}/dist"
APP="${DIST}/flowcode.app"
CONTENTS="${APP}/Contents"
ARCHES="${ARCHES:-arm64 x86_64}"
PRODUCT="flowcode"            # executable product name (Package.swift)
WATCHDOG="flowcode-watchdog"  # Helpers/flowcode-watchdog/main.swift

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }

# --- preconditions ------------------------------------------------------------
command -v swift >/dev/null || { echo "error: swift not found" >&2; exit 1; }
command -v lipo  >/dev/null || { echo "error: lipo not found"  >&2; exit 1; }

# --- clean the bundle (but keep an already-built venv if present) --------------
log "assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${CONTENTS}/MacOS" \
         "${CONTENTS}/Helpers" \
         "${CONTENTS}/Resources/python" \
         "${CONTENTS}/Frameworks"

# --- per-arch swift build -c release ------------------------------------------
declare -a APP_SLICES=()
declare -a WD_SLICES=()
for arch in ${ARCHES}; do
    log "swift build -c release (${arch})"
    swift build \
        --configuration release \
        --arch "${arch}" \
        --package-path "${REPO_ROOT}" \
        --product "${PRODUCT}"
    BIN_DIR="$(swift build --configuration release --arch "${arch}" \
                 --package-path "${REPO_ROOT}" --show-bin-path)"
    APP_SLICES+=("${BIN_DIR}/${PRODUCT}")

    # Watchdog: standalone swiftc (no SwiftPM target, no flowcodeKit dep).
    log "swiftc watchdog (${arch})"
    WD_OUT="${DIST}/.watchdog-${arch}"
    swiftc -O -target "${arch}-apple-macos14.0" \
        "${REPO_ROOT}/Helpers/${WATCHDOG}/main.swift" \
        -o "${WD_OUT}"
    WD_SLICES+=("${WD_OUT}")
done

# --- lipo universal binaries --------------------------------------------------
log "lipo -> universal flowcode"
lipo -create "${APP_SLICES[@]}" -output "${CONTENTS}/MacOS/${PRODUCT}"
chmod +x "${CONTENTS}/MacOS/${PRODUCT}"

log "lipo -> universal watchdog"
lipo -create "${WD_SLICES[@]}" -output "${CONTENTS}/Helpers/${WATCHDOG}"
chmod +x "${CONTENTS}/Helpers/${WATCHDOG}"
rm -f "${DIST}"/.watchdog-*

# --- Info.plist (token substitution from version.env) -------------------------
log "writing Info.plist"
PLIST_SRC="${REPO_ROOT}/Sources/flowcode/Info.plist"
# Substitute ${TOKENS}. SPARKLE_PUBLIC_ED_KEY may be empty at build time and is
# patched in by sign_notarize.sh; leaving it blank here is fine for unsigned dev.
sed \
    -e "s|\${BUNDLE_ID}|${BUNDLE_ID}|g" \
    -e "s|\${VERSION}|${VERSION}|g" \
    -e "s|\${BUILD}|${BUILD}|g" \
    -e "s|\${APPCAST_URL}|${APPCAST_URL}|g" \
    -e "s|\${SPARKLE_PUBLIC_ED_KEY}|${SPARKLE_PUBLIC_ED_KEY:-}|g" \
    "${PLIST_SRC}" > "${CONTENTS}/Info.plist"

# Validate the plist actually parses (catches a bad sed substitution early).
plutil -lint "${CONTENTS}/Info.plist" >/dev/null

# --- placeholders so the layout is self-documenting ---------------------------
cat > "${CONTENTS}/Resources/python/.placeholder" <<'EOF'
This directory holds the relocatable embedded CPython venv with the voicemode
core. It is populated by scripts/make_venv.sh (network-gated) and is NOT
committed. If empty, the app cannot start the voice core.
EOF
cat > "${CONTENTS}/Frameworks/.placeholder" <<'EOF'
Sparkle.framework is dropped here by CI (or a local fetch) before signing.
Kept out of git; signed inside-out by scripts/sign_notarize.sh.
EOF

log "done: ${APP}"
log "next: scripts/make_venv.sh then scripts/sign_notarize.sh"
