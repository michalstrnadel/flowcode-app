#!/usr/bin/env bash
#
# make_venv.sh — build the relocatable embedded Python venv that ships inside
# flowcode.app/Contents/Resources/python.
#
# Steps:
#   1. Download a relocatable CPython from python-build-standalone (PBS), pinned
#      by PBS_RELEASE + PYTHON_VERSION in version.env, for the requested arch.
#   2. Create a uv venv against that interpreter.
#   3. Install the voicemode core FROZEN at VOICEMODE_COMMIT (version.env) into it.
#   4. Drop the result into the app bundle's Resources/python.
#
# NETWORK-GATED: this downloads CPython and pip/uv wheels. It refuses to run if
# offline (preflight.sh / CI guards this). The pinned VOICEMODE_COMMIT is the
# reproducibility input — bump it in version.env, never use a moving ref.
#
# Usage:
#   scripts/make_venv.sh                  # arch = host arch
#   ARCH=x86_64 scripts/make_venv.sh      # cross-fetch a specific arch
#
# NOTE: the venv is per-arch (it embeds a native interpreter + native wheels:
# PortAudio, onnxruntime, numpy). A universal app ships the venv matching the
# slice you distribute; if you want one bundle that runs both arches you must
# ship two venvs and select at launch, OR build/notarize two bundles. CI builds
# per-arch and the default flow ships the host-arch venv for that runner.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/version.env"

ARCH="${ARCH:-$(uname -m)}"          # arm64 | x86_64
APP="${REPO_ROOT}/dist/flowcode.app"
DEST="${APP}/Contents/Resources/python"
WORK="${REPO_ROOT}/dist/.venv-build-${ARCH}"

log() { printf '\033[1;35m[venv]\033[0m %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# --- offline guard ------------------------------------------------------------
if ! curl -fsI --max-time 8 https://github.com >/dev/null 2>&1; then
    die "network unreachable — make_venv.sh needs to download CPython + wheels. Run online."
fi

command -v uv    >/dev/null || die "uv not found (install: https://docs.astral.sh/uv/)"
command -v curl  >/dev/null || die "curl not found"
command -v tar   >/dev/null || die "tar not found"

[ -d "${APP}" ] || die "no app bundle at ${APP} — run scripts/build_app.sh first"

# --- map arch -> python-build-standalone asset triple -------------------------
case "${ARCH}" in
    arm64|aarch64) PBS_TRIPLE="aarch64-apple-darwin" ;;
    x86_64)        PBS_TRIPLE="x86_64-apple-darwin"  ;;
    *) die "unsupported arch: ${ARCH}" ;;
esac

# python-build-standalone asset naming, e.g.
#   cpython-3.12.5+20240814-aarch64-apple-darwin-install_only.tar.gz
PBS_ASSET="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-${PBS_TRIPLE}-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_ASSET}"

rm -rf "${WORK}"
mkdir -p "${WORK}"

# --- 1. download + extract relocatable CPython --------------------------------
log "downloading CPython ${PYTHON_VERSION} (${PBS_TRIPLE})"
curl -fL --retry 3 -o "${WORK}/cpython.tar.gz" "${PBS_URL}" \
    || die "failed to download ${PBS_URL}"
tar -xzf "${WORK}/cpython.tar.gz" -C "${WORK}"
PBS_PY="${WORK}/python/bin/python3"
[ -x "${PBS_PY}" ] || die "extracted CPython missing bin/python3"

# --- 2. create a uv venv against that interpreter -----------------------------
log "creating uv venv"
VENV="${WORK}/venv"
uv venv --python "${PBS_PY}" --relocatable "${VENV}" \
    || uv venv --python "${PBS_PY}" "${VENV}"   # older uv: no --relocatable flag

# --- 3. install voicemode core frozen at the pinned commit --------------------
log "installing voicemode @ ${VOICEMODE_COMMIT}"
VOICEMODE_SPEC="voice-mode @ git+${VOICEMODE_REPO}@${VOICEMODE_COMMIT}"
VIRTUAL_ENV="${VENV}" uv pip install --python "${VENV}/bin/python" "${VOICEMODE_SPEC}" \
    || die "voicemode install failed"

# Smoke-import in the venv so we fail here, not at runtime on a user's machine.
"${VENV}/bin/python" -c "import voice_mode; print('voice_mode ok', voice_mode.__file__)" \
    || die "voice_mode import failed in built venv"

# --- 4. place into the bundle -------------------------------------------------
log "installing venv -> ${DEST}"
rm -rf "${DEST}"
mkdir -p "$(dirname "${DEST}")"
# Ship the interpreter + venv together; the venv references python by relative
# path thanks to PBS relocatable layout + --relocatable.
cp -R "${WORK}/python" "${DEST}-cpython"
cp -R "${VENV}" "${DEST}"
# Re-point the venv at the bundled interpreter via a relative symlink so the
# whole tree survives being moved to /Applications.
rm -rf "${DEST}/bin/python" "${DEST}/bin/python3"
ln -s "../../python-cpython/bin/python3" "${DEST}/bin/python3" 2>/dev/null || true
ln -s "python3" "${DEST}/bin/python" 2>/dev/null || true
mv "${DEST}-cpython" "${APP}/Contents/Resources/python-cpython"

log "done. embedded python at ${DEST}"
log "remember: each nested .so + the interpreter must be codesigned (sign_notarize.sh)"
