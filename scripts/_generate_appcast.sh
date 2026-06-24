#!/usr/bin/env bash
#
# _generate_appcast.sh — wrap Sparkle's `generate_appcast` to produce an
# EdDSA-signed appcast.xml for the zips in a directory.
#
# Called by .github/workflows/release.yml. Kept separate so the signing logic is
# testable and the workflow stays declarative.
#
# Usage:
#   scripts/_generate_appcast.sh <dir-with-zips> <ed25519-private-key-file>
#
# generate_appcast ships in the Sparkle release tarball (bin/generate_appcast).
# CI fetches Sparkle (the same framework it bundles) and exposes that binary on
# PATH, or sets SPARKLE_BIN to its directory. We resolve it from either.
#
set -euo pipefail

DIR="${1:?usage: _generate_appcast.sh <dir> <ed-private-key-file>}"
KEY="${2:?usage: _generate_appcast.sh <dir> <ed-private-key-file>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/version.env"

# Resolve the generate_appcast tool.
GEN=""
if [ -n "${SPARKLE_BIN:-}" ] && [ -x "${SPARKLE_BIN}/generate_appcast" ]; then
    GEN="${SPARKLE_BIN}/generate_appcast"
elif command -v generate_appcast >/dev/null 2>&1; then
    GEN="$(command -v generate_appcast)"
else
    echo "error: generate_appcast not found (set SPARKLE_BIN or add it to PATH)" >&2
    echo "       fetch Sparkle's release tarball; bin/generate_appcast is inside." >&2
    exit 1
fi

[ -d "${DIR}" ] || { echo "error: ${DIR} is not a directory" >&2; exit 1; }
[ -f "${KEY}" ] || { echo "error: private key file ${KEY} missing" >&2; exit 1; }

# generate_appcast scans DIR for *.zip, signs each with the Ed25519 key, and
# writes ${DIR}/appcast.xml with the download URL prefix we pass.
"${GEN}" \
    --ed-key-file "${KEY}" \
    --download-url-prefix "${DOWNLOAD_URL_BASE}/v${VERSION}/" \
    "${DIR}"

echo "wrote ${DIR}/appcast.xml"
