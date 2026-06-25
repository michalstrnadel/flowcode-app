#!/usr/bin/env python3
"""flowcode persistent voice runner — the CORE side of the menu<->core control loop.

Binds the HUD status socket, registers an inbound CONTROL handler, and runs the real
voice session on demand from the macOS menu:

  {"cmd":"start"}   -> begin a converse() session loop (speak + listen turns); orb shows
  {"cmd":"stop"}    -> cancel the in-flight turn + return to idle; orb hides
  {"cmd":"set_flag","key":"VOICEMODE_...","value":"true"|"false"}
                    -> WHITELIST-checked: os.environ[key]=value + reload_configuration()
                       so the flag applies LIVE to the next turn. Acks with
                       {"type":"flag_applied","key":...,"value":...,"effective":bool}.
  {"cmd":"confirm", ...} -> §7 verdict; the confirm gate owns its own handler, so ignored here.

Run from the voicemode fork:  uv run --frozen python flowcode_runner.py [--dry]
  --dry : STUB turns (no mic/speaker) so the control loop is testable without audio.
Stop with Ctrl-C / TaskStop.
"""
import os
import sys
import asyncio
import logging
import itertools

SOCK = os.path.expanduser("~/.voicemode/run/flowcode.sock")
DRY = "--dry" in sys.argv

# Must be set before importing voice_mode (config reads env at import).
os.environ["VOICEMODE_STATUS_SOCKET"] = SOCK
# Flags START OFF — the menu toggles drive them via set_flag. Only non-flag demo
# defaults are pre-seeded here.
os.environ.setdefault("VOICEMODE_WHISPER_LANGUAGE", "en")
# Barge-in sensitivity: low gate + few onset frames so "stop" cuts easily. Works
# cleanly on HEADPHONES (no TTS bleed); on speakers it may self-trigger.
os.environ.setdefault("VOICEMODE_BARGEIN_ENERGY_GATE", "0.03")
os.environ.setdefault("VOICEMODE_BARGEIN_ONSET_FRAMES", "3")

from voice_mode import config  # noqa: E402
from voice_mode.utils.status_broadcaster import (  # noqa: E402
    init_status_broadcaster,
    set_control_handler,
    broadcast,
)

log = logging.getLogger("flowcode.runner")

# §7 hygiene: ONLY these flags may be flipped over the control socket. Never let the
# control channel mutate arbitrary env or disable the confirm gate. key -> config global.
_FLAG_WHITELIST = {
    "VOICEMODE_BARGEIN_ENABLED": "BARGEIN_ENABLED",
    "VOICEMODE_TTS_SENTENCE_CHUNKING": "TTS_SENTENCE_CHUNKING",
    "VOICEMODE_SEMANTIC_ENDPOINTING": "SEMANTIC_ENDPOINTING_ENABLED",
}


def _emit(event_type, state):
    broadcast({"type": "event", "event_type": event_type, "state": state})


def _install_parent_death_watchdog():
    """Exit if our parent process dies, so the voice core never orphans when the
    flowcode app (which spawns us DIRECTLY as a venv-python child) crashes. Gated on
    FLOWCODE_PARENT_WATCHDOG=1 (set by the app) so manual shell runs are unaffected."""
    if os.environ.get("FLOWCODE_PARENT_WATCHDOG") != "1":
        return
    import threading
    import time as _time
    orig_ppid = os.getppid()

    def _watch():
        while True:
            _time.sleep(1.0)
            ppid = os.getppid()
            if ppid != orig_ppid or ppid == 1:
                os._exit(0)

    threading.Thread(target=_watch, name="flowcode-parent-watchdog", daemon=True).start()


class Runner:
    def __init__(self, loop):
        self.loop = loop
        self.cmds = asyncio.Queue()
        self.session_task = None

    # --- inbound control handler (runs on the broadcaster DAEMON thread) ---
    def on_control(self, msg):
        cmd = (msg or {}).get("cmd")
        if cmd == "set_flag":
            self._apply_flag(str(msg.get("key", "")), msg.get("value", ""))
        elif cmd in ("start", "stop"):
            # Hand off to the asyncio loop (thread-safe). The broadcaster is a daemon
            # thread that can outlive the loop during shutdown, so a command arriving
            # mid-teardown must not crash the handler — tolerate a closed/closing loop.
            try:
                if not self.loop.is_closed():
                    self.loop.call_soon_threadsafe(self.cmds.put_nowait, cmd)
            except RuntimeError:
                pass  # event loop already closed mid-shutdown; nothing to do
        elif cmd == "confirm":
            pass  # §7 gate owns its own handler; not our concern here.
        # unknown -> ignore

    def _apply_flag(self, key, value):
        """Apply a whitelisted flag live (broadcaster-thread safe: env set + global
        reassignment are atomic under the GIL; converse() reads globals per call)."""
        if key not in _FLAG_WHITELIST:
            log.warning("set_flag ignored — not whitelisted: %r", key)
            broadcast({"type": "flag_applied", "key": key, "value": str(value),
                       "effective": False, "reason": "not_whitelisted"})
            return
        truthy = str(value).strip().lower() in ("true", "1", "yes", "on")
        os.environ[key] = "true" if truthy else "false"
        try:
            config.reload_configuration()
        except Exception:
            log.exception("reload_configuration failed")
        effective = bool(getattr(config, _FLAG_WHITELIST[key], None))
        log.info("set_flag %s=%s -> config.%s=%s", key, value, _FLAG_WHITELIST[key], effective)
        broadcast({"type": "flag_applied", "key": key, "value": os.environ[key],
                   "effective": effective})

    async def run(self):
        # Register the control handler FIRST so set_flag/start/stop from the app are
        # never dropped during the (slow) warm-up below.
        set_control_handler(self.on_control)
        if not DRY:
            await _warm_kokoro()
        log.info("runner ready (dry=%s) socket=%s", DRY, SOCK)
        while True:
            cmd = await self.cmds.get()
            if cmd == "start":
                if self.session_task and not self.session_task.done():
                    continue  # already running
                self.session_task = asyncio.ensure_future(self._session())
            elif cmd == "stop":
                await self._stop_session()

    async def _stop_session(self):
        t = self.session_task
        if t and not t.done():
            t.cancel()
            try:
                await t
            except asyncio.CancelledError:
                pass
        self.session_task = None  # SESSION_END is emitted by _session's finally

    async def _session(self):
        _emit("SESSION_START", "idle")  # panel shows; sessionActive=true
        try:
            await (self._dry_turns() if DRY else self._real_turns())
        finally:
            _emit("SESSION_END", "idle")  # panel hides; runs on cancel too

    async def _dry_turns(self):
        """No audio: emit the state arc so the control loop is observable/testable."""
        arc = [("RECORDING_START", "listening"), ("STT_START", "processing"),
               ("TTS_PLAYBACK_START", "speaking"), ("TTS_PLAYBACK_END", "idle")]
        for _ in itertools.count():
            for ev, st in arc:
                _emit(ev, st)
                await asyncio.sleep(0.4)

    async def _real_turns(self):
        from voice_mode.tools.converse import converse
        conv = getattr(converse, "fn", converse)
        # First turn is a long monologue so 'Start Voice' gives a generous window to
        # barge in (say "stop" loudly); later turns are short conversational acks.
        intro = (
            "Okay, here is the plan, and I am going to keep talking for a while so you "
            "can interrupt me whenever you like. First I will set everything up, then I "
            "will run the tests one by one, and after that I will walk through every "
            "single result slowly and carefully, so please just go right ahead and say "
            "stop at any moment to cut me off and I will switch to listening instantly."
        )
        prompts = [intro, "Go ahead, I'm listening.", "Okay, what else?"]
        for i in itertools.count():
            await conv(message=prompts[i % len(prompts)], wait_for_response=True,
                       tts_provider="kokoro", voice="af_sky",
                       listen_duration_max=20, listen_duration_min=2.0,
                       timeout=30, chime_enabled=False)


async def _warm_kokoro():
    """Best-effort: prime the Kokoro model so the first real turn's TTFA is low.
    Hits the HTTP endpoint and discards the bytes — NO audio is played."""
    try:
        import httpx
        async with httpx.AsyncClient(timeout=20) as c:
            r = await c.post(
                "http://127.0.0.1:8880/v1/audio/speech",
                json={"model": "kokoro", "input": "ok", "voice": "af_sky", "response_format": "pcm"},
            )
            _ = r.content
        log.info("kokoro warmed (TTFA primed)")
    except Exception as e:
        log.info("kokoro warm-up skipped: %s", e)


async def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    _install_parent_death_watchdog()
    init_status_broadcaster(SOCK)
    await Runner(asyncio.get_running_loop()).run()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[runner] stopped", flush=True)
