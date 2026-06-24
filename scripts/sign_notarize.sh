#!/usr/bin/env bash
#
# sign_notarize.sh — inside-out codesign the flowcode.app bundle (including the
# embedded Python interpreter and every native wheel .so), then notarize +
# staple. Produces a distributable, Gatekeeper-clean universal .zip.
#
# Why inside-out and NOT `--deep`:
#   `codesign --deep` is unreliable for bundles with hundreds of nested Mach-O
#   files (an embedded interpreter + dozens of .so wheels) and Apple explicitly
#   recommends against it for distribution. We sign leaves first, the framework,
#   the helper, then the app last, so each signature covers already-signed
#   contents.
#
# Required env (see DISTRIBUTION.md):
#   SIGN_IDENTITY        "Developer ID Application: NAME (TEAMID)"  (in login keychain)
#   NOTARY_KEY_PATH      path to AuthKey_XXXX.p8  (App Store Connect API key)
#   NOTARY_KEY_ID        the key id (the XXXX)
#   NOTARY_ISSUER_ID     issuer UUID from App Store Connect
# Optional:
#   SPARKLE_PUBLIC_ED_KEY  base64 Ed25519 public key to patch into Info.plist
#   SKIP_NOTARIZE=1        sign + staple-skip (ad-hoc smoke test only)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/version.env"

APP="${REPO_ROOT}/dist/flowcode.app"
CONTENTS="${APP}/Contents"
ENTITLEMENTS="${SCRIPT_DIR}/flowcode.entitlements"
ZIP_OUT="${REPO_ROOT}/dist/flowcode-${VERSION}.zip"

log() { printf '\033[1;32m[sign]\033[0m %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[ -d "${APP}" ] || die "no app at ${APP} — run build_app.sh + make_venv.sh first"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY (see DISTRIBUTION.md)}"
command -v codesign >/dev/null || die "codesign not found"

# Common codesign flags for every Mach-O: Hardened Runtime + runtime options +
# stable timestamp.
CS_COMMON=(--force --options runtime --timestamp --sign "${SIGN_IDENTITY}")

# --- 0. (re)patch Sparkle public key into Info.plist, then it is FROZEN --------
# CRITICAL: any Info.plist edit invalidates the signature and silently breaks the
# mic TCC grant. So we patch BEFORE signing and never touch it after.
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
    log "patching SUPublicEDKey into Info.plist (pre-sign)"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${SPARKLE_PUBLIC_ED_KEY}" \
        "${CONTENTS}/Info.plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${SPARKLE_PUBLIC_ED_KEY}" \
        "${CONTENTS}/Info.plist"
fi

# --- 1. sign every nested Mach-O leaf first (interpreter + wheel .so + dylibs) -
# Find all Mach-O files under Resources (the embedded python) and sign each.
# `file` is too slow over thousands of files; match by magic via a quick filter
# on candidate extensions + executables, then verify each is actually Mach-O.
log "signing embedded python interpreter + native wheels (inside-out)"
sign_macho() {
    local f="$1"
    # Skip non-Mach-O fast.
    if ! /usr/bin/file -b "${f}" 2>/dev/null | grep -q "Mach-O"; then return 0; fi
    codesign "${CS_COMMON[@]}" \
        --entitlements "${ENTITLEMENTS}" \
        "${f}"
}

# Order matters only in that leaves must precede the containers that enclose
# them; within Resources every file is a leaf, so order among them is free.
while IFS= read -r -d '' f; do
    sign_macho "${f}"
done < <(find "${CONTENTS}/Resources" "${CONTENTS}/Frameworks" \
            -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 2>/dev/null)

# --- 2. sign Sparkle.framework (if bundled) -----------------------------------
if [ -d "${CONTENTS}/Frameworks/Sparkle.framework" ]; then
    log "signing Sparkle.framework (XPC services first)"
    # Sparkle ships nested XPC services + an autoupdate tool — sign each, then the
    # framework bundle itself.
    while IFS= read -r -d '' nested; do
        codesign "${CS_COMMON[@]}" "${nested}"
    done < <(find "${CONTENTS}/Frameworks/Sparkle.framework" \
                \( -name '*.xpc' -o -name 'Autoupdate' -o -name 'Updater.app' \) -print0 2>/dev/null)
    codesign "${CS_COMMON[@]}" "${CONTENTS}/Frameworks/Sparkle.framework"
fi

# --- 3. sign the watchdog helper ----------------------------------------------
log "signing watchdog helper"
codesign "${CS_COMMON[@]}" \
    --entitlements "${ENTITLEMENTS}" \
    "${CONTENTS}/Helpers/flowcode-watchdog"

# --- 4. sign the main executable + the app bundle LAST ------------------------
log "signing main executable + app bundle (outermost)"
codesign "${CS_COMMON[@]}" \
    --entitlements "${ENTITLEMENTS}" \
    "${CONTENTS}/MacOS/flowcode"
codesign "${CS_COMMON[@]}" \
    --entitlements "${ENTITLEMENTS}" \
    "${APP}"

# --- 5. verify the signature locally ------------------------------------------
log "verifying signature (strict)"
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign --display --entitlements - "${APP}" >/dev/null

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    log "SKIP_NOTARIZE=1 -> packaging signed (un-notarized) zip for smoke test"
    /usr/bin/ditto -c -k --keepParent "${APP}" "${ZIP_OUT}"
    log "wrote ${ZIP_OUT} (NOT notarized — Gatekeeper will warn)"
    exit 0
fi

# --- 6. notarize --------------------------------------------------------------
: "${NOTARY_KEY_PATH:?set NOTARY_KEY_PATH}"
: "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"
command -v xcrun >/dev/null || die "xcrun not found"

log "zipping for notarization"
/usr/bin/ditto -c -k --keepParent "${APP}" "${ZIP_OUT}"

log "submitting to notarytool (this waits)"
xcrun notarytool submit "${ZIP_OUT}" \
    --key "${NOTARY_KEY_PATH}" \
    --key-id "${NOTARY_KEY_ID}" \
    --issuer "${NOTARY_ISSUER_ID}" \
    --wait \
    || die "notarization failed — run 'xcrun notarytool log <id> ...' for details"

# --- 7. staple + re-zip the stapled app ---------------------------------------
log "stapling ticket to ${APP}"
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"

# Re-zip so the distributed archive contains the stapled bundle.
rm -f "${ZIP_OUT}"
/usr/bin/ditto -c -k --keepParent "${APP}" "${ZIP_OUT}"

# Final Gatekeeper assessment (what a user's machine will do on first open).
log "spctl assessment"
spctl --assess --type execute --verbose=2 "${APP}" || true

log "done: ${ZIP_OUT}"
