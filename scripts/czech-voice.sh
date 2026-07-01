#!/usr/bin/env bash
#
# czech-voice.sh — provision + serve the optional Czech neural voice (Coqui VITS).
#
# Czech read-aloud is OPTIONAL. Most users never need it, so flowcode does NOT bundle
# or download it by default. This script pulls a small PyTorch runtime + a Czech VITS
# model (~350 MB, one-time) ONLY when the user asks for Czech — from the menu (a
# Download? prompt) or via the /czech-voice skill / `setup.sh --czech`.
#
# English read-aloud (Kokoro) never needs any of this.
#
# Single source of truth for the uvx incantation. Commands:
#   czech-voice.sh check          -> exit 0 if the voice is installed, else non-zero
#   czech-voice.sh install        -> download the runtime + model (idempotent)
#   czech-voice.sh serve [port]   -> run the local HTTP TTS server (default :8771)
#
# Requires `uv` (https://docs.astral.sh/uv/). All output is English.
#
set -euo pipefail

MODEL="tts_models/cs/cv/vits"
PORT="${2:-8771}"
PIN_TRANSFORMERS="transformers==4.49.0"   # coqui-tts needs isin_mps_friendly (>=4.46)
export COQUI_TOS_AGREED=1                  # model is CC-permissive; skip the interactive prompt

UVX_ARGS=(--with torch --with torchaudio --with flask --with "${PIN_TRANSFORMERS}" --from coqui-tts)

have_uv()       { command -v uvx >/dev/null 2>&1; }
model_dir()     { printf '%s' "${HOME}/Library/Application Support/tts"; }
is_installed()  { have_uv && ls -d "$(model_dir)"/*cs*cv*vits* >/dev/null 2>&1; }

case "${1:-}" in
    check)
        if is_installed; then echo "installed"; exit 0; else echo "not-installed"; exit 1; fi
        ;;
    install)
        have_uv || { echo "error: 'uv' is required — install it from https://docs.astral.sh/uv/"; exit 3; }
        echo "Preparing the Czech neural voice (one-time, ~350 MB: PyTorch runtime + model)…"
        # Synthesize one short clip: this resolves the uvx environment AND downloads the
        # model into the Coqui cache, so the first real use is instant.
        tmp="$(mktemp -d)"
        trap 'rm -rf "${tmp}"' EXIT
        uvx "${UVX_ARGS[@]}" tts --text "Příprava hlasu." --model_name "${MODEL}" --out_path "${tmp}/warm.wav"
        if is_installed; then echo "Czech voice ready."; exit 0; else echo "error: install finished but the model is missing"; exit 4; fi
        ;;
    serve)
        have_uv || { echo "error: 'uv' is required"; exit 3; }
        # SECURITY: tts-server hardcodes app.run(host="::") — ALL interfaces, no
        # --host flag — which would expose the Czech TTS to the local network.
        # The server module parses argv and loads the model at IMPORT time, so a
        # tiny wrapper can import it and bind the same Flask app to loopback only.
        # exec so signals (and the watchdog's process-group kill) reach the server directly.
        FLOWCODE_TTS_MODEL="${MODEL}" FLOWCODE_TTS_PORT="${PORT}" \
        exec uvx "${UVX_ARGS[@]}" python -c '
import os, sys
port = os.environ["FLOWCODE_TTS_PORT"]
sys.argv = ["tts-server", "--model_name", os.environ["FLOWCODE_TTS_MODEL"], "--port", port]
from TTS.server import server   # parses argv + loads the model at import time
server.app.run(host="127.0.0.1", port=int(port))
'
        ;;
    *)
        echo "usage: czech-voice.sh {check|install|serve} [port]"; exit 2
        ;;
esac
