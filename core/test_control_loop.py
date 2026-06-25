#!/usr/bin/env python3
"""No-audio integration test for the flowcode menu<->core control loop.

Assumes flowcode_runner.py --dry is already running and bound to the socket. Acts as
the macOS app would: connects, sends start/set_flag/stop, and asserts the runner
reacts (session events + live flag application + §7 whitelist rejection). Exits 0/1.
"""
import os
import socket
import json
import time
import sys

SOCK = os.path.expanduser("~/.voicemode/run/flowcode.sock")
fails = 0


def check(cond, msg):
    global fails
    print(("  ok   " if cond else "  FAIL ") + msg, flush=True)
    if not cond:
        fails += 1


def connect(timeout=10):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.exists(SOCK):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(SOCK)
                return s
            except OSError:
                pass
        time.sleep(0.2)
    raise SystemExit("socket not available — is flowcode_runner.py --dry running?")


def send(s, obj):
    s.sendall((json.dumps(obj) + "\n").encode("utf-8"))


def collect(s, seconds):
    s.setblocking(False)
    buf = b""
    msgs = []
    end = time.time() + seconds
    while time.time() < end:
        try:
            d = s.recv(65536)
            if not d:
                break
            buf += d
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if line:
                    try:
                        msgs.append(json.loads(line))
                    except ValueError:
                        pass
        except BlockingIOError:
            time.sleep(0.05)
        except OSError:
            break
    return msgs


s = connect()
collect(s, 0.3)  # drain anything already queued

# 1) start -> session begins, orb shows + cycles
send(s, {"cmd": "start"})
m = collect(s, 2.5)
ets = [x.get("event_type") for x in m if x.get("type") == "event"]
sts = [x.get("state") for x in m if x.get("state")]
check("SESSION_START" in ets, f"start -> SESSION_START (events={ets})")
check("listening" in sts, f"start -> listening state seen (states={set(sts)})")

# 2) whitelisted flags apply LIVE
send(s, {"cmd": "set_flag", "key": "VOICEMODE_BARGEIN_ENABLED", "value": "true"})
m = collect(s, 1.5)
fa = [x for x in m if x.get("type") == "flag_applied"]
check(any(x.get("key") == "VOICEMODE_BARGEIN_ENABLED" and x.get("effective") is True for x in fa),
      f"set_flag bargein=true -> flag_applied effective=True (got={fa})")

send(s, {"cmd": "set_flag", "key": "VOICEMODE_TTS_SENTENCE_CHUNKING", "value": "true"})
m = collect(s, 1.5)
fa = [x for x in m if x.get("type") == "flag_applied"]
check(any(x.get("key") == "VOICEMODE_TTS_SENTENCE_CHUNKING" and x.get("effective") is True for x in fa),
      f"set_flag chunking=true -> effective=True (got={fa})")

# 3) §7: a NON-whitelisted flag (e.g. disabling the confirm gate) must be REJECTED
send(s, {"cmd": "set_flag", "key": "VOICEMODE_CONFIRM_GATE", "value": "false"})
m = collect(s, 1.5)
fa = [x for x in m if x.get("type") == "flag_applied"]
check(any(x.get("key") == "VOICEMODE_CONFIRM_GATE" and x.get("effective") is False for x in fa),
      f"set_flag confirm_gate -> REJECTED, effective=False (got={fa})")

# 4) stop -> session ends, orb hides
send(s, {"cmd": "stop"})
m = collect(s, 2.0)
ets = [x.get("event_type") for x in m if x.get("type") == "event"]
check("SESSION_END" in ets, f"stop -> SESSION_END (events={ets})")

print("\nALL PASS" if fails == 0 else f"\n{fails} FAILURE(S)", flush=True)
sys.exit(0 if fails == 0 else 1)
