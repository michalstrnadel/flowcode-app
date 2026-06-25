#!/usr/bin/env python3
"""flowcode REAL voice harness.

Drives the genuine voicemode converse() turn so the flowcode orb reacts to REAL
Kokoro TTS + REAL mic/Whisper STT + REAL barge-in. Binds the HUD status socket
(the macOS app connects to it as a client and auto-reconnects).

converse() itself emits SESSION_START -> (TTS_PLAYBACK_START=speaking) ->
RECORDING_START=listening -> STT_*=processing -> SESSION_END, and barge-in emits
INTERRUPTED + an out-of-band barge_in. Our streaming.py edit also streams a TTS
amplitude envelope so the speaking orb lip-syncs.

Modes:
  speak     one-shot: speak a line, no listen. Verifies TTS + speaking orb. (default)
  bargein   speak a LONG line with wait_for_response -> talk over it to cut it.
  converse  loop: speak a prompt, listen, print the transcript (interactive).

Run from the voicemode fork:  uv run --frozen python <thisfile> [mode]
Stop with Ctrl-C / TaskStop.
"""
import os
import sys
import asyncio

SOCK = os.path.expanduser("~/.voicemode/run/flowcode.sock")

# Flags MUST be set before importing voice_mode (config reads env at import time).
os.environ["VOICEMODE_STATUS_SOCKET"] = SOCK
os.environ.setdefault("VOICEMODE_BARGEIN_ENABLED", "true")
os.environ.setdefault("VOICEMODE_TTS_SENTENCE_CHUNKING", "true")
os.environ.setdefault("VOICEMODE_INTERRUPTION_CORRECTION", "true")
os.environ.setdefault("VOICEMODE_VOICES", "af_sky")
# This room's measured ambient mic floor is high (p99 ~0.07, max ~0.09); set the
# barge-in energy gate well above it so only real speech (>0.12) cuts the TTS.
os.environ.setdefault("VOICEMODE_BARGEIN_ENERGY_GATE", "0.12")
# English STT for accurate transcription on the base Whisper model.
os.environ.setdefault("VOICEMODE_WHISPER_LANGUAGE", "en")

from voice_mode.utils.status_broadcaster import init_status_broadcaster  # noqa: E402
from voice_mode.tools.converse import converse  # noqa: E402

_conv = getattr(converse, "fn", converse)
VOICE = "af_sky"


async def speak(msg, wait=False, lmax=30):
    return await _conv(
        message=msg,
        wait_for_response=wait,
        tts_provider="kokoro",
        voice=VOICE,
        listen_duration_max=lmax,
        listen_duration_min=2.0,
        timeout=lmax + 10,
        chime_enabled=False,
    )


async def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "speak"
    b = init_status_broadcaster(SOCK)
    print(f"[harness] broadcaster active={b is not None} socket={SOCK}", flush=True)
    print("[harness] waiting ~6s for the flowcode app to (re)connect…", flush=True)
    await asyncio.sleep(6)

    if mode == "speak":
        r = await speak(
            "Ahoj Michale. Tady flowcode. Tohle je živý Kokoro hlas, ne demo loop. "
            "Koukni jak se koule vlní přesně s tím, jak teď mluvím.",
            wait=False,
        )
        print("[harness] speak result:", r, flush=True)

    elif mode == "bargein":
        r = await speak(
            "Tohle je naschvál hodně dlouhá věta, abys mě stihl přerušit uprostřed. "
            "Jakmile do mě promluvíš, okamžitě se zastavím, zvuk i koule úplně naráz, "
            "a hned začnu poslouchat tebe, takže klidně skoč do řeči kdykoliv teď hned, "
            "a uvidíš i uslyšíš ten tvrdý střih během chvilky.",
            wait=True,
            lmax=20,
        )
        print("[harness] bargein turn result:\n", r, flush=True)

    elif mode == "monolog":
        # A long, slow, continuous monologue -> a generous window to talk over,
        # even with 1-3s TTFA. Say "STOP" loudly anywhere in the middle.
        r = await speak(
            "Okay, let me walk you through the entire plan in detail, nice and slowly. "
            "First I will set up the environment, then I will configure both services, "
            "then I will run every test one by one, and after that I will go through "
            "each result very carefully, step by step, taking my time, because the whole "
            "point here is that you can interrupt me at literally any moment you want, "
            "so please go right ahead and stop me whenever you like, because otherwise "
            "I will just keep talking and talking and talking until you finally cut in.",
            wait=True,
            lmax=15,
        )
        print("[harness] monolog turn result:\n", r, flush=True)

    elif mode == "converse":
        prompts = [
            "Ahoj, jsem flowcode. Řekni mi něco a já ti to zopakuju.",
            "Slyším tě. Teď zkus přerušit tuhle dlouhou větu, budu mluvit a mluvit "
            "a mluvit, dokud do mě nepromluvíš a nezastavíš mě.",
            "Díky. Můžeš mluvit dál, poslouchám.",
        ]
        i = 0
        while True:
            r = await speak(prompts[i % len(prompts)], wait=True, lmax=20)
            print(f"[harness] turn {i} -> USER said: {r!r}", flush=True)
            i += 1

    await asyncio.sleep(1.0)  # let final events flush to the socket


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[harness] stopped", flush=True)
