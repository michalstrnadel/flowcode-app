# flowcode core (Python side)

The macOS app (`CoreSupervisor`) spawns **`flowcode_runner.py`** as a direct child
to run the real voice core (the [voicemode](https://github.com/mbailey/voicemode)
overlay fork). It binds the HUD status socket (`~/.voicemode/run/flowcode.sock`),
registers the inbound control handler, and runs `converse()` turns on demand.

## Control contract (app → core, NDJSON over the UDS)

- `{"cmd":"start"}` — begin a converse session loop (speak + listen); orb shows.
- `{"cmd":"stop"}` — cancel the in-flight turn, return to idle; orb hides.
- `{"cmd":"set_flag","key":"VOICEMODE_…","value":"true"|"false"}` — apply a flag
  **live** (`os.environ` + `reload_configuration()`). **Whitelisted only**
  (`VOICEMODE_BARGEIN_ENABLED`, `VOICEMODE_TTS_SENTENCE_CHUNKING`,
  `VOICEMODE_SEMANTIC_ENDPOINTING`) — the channel can't disable the §7 confirm gate.
- `{"cmd":"confirm","id":…,"verdict":"allow"|"deny"}` — §7 verdict (gate owns it).

## Run / install

The app runs the copy at `~/.voicemode/flowcode/flowcode_runner.py` using the
voicemode fork's venv python (`<fork>/.venv/bin/python`, cwd = fork). Paths are
overridable via `FLOWCODE_CORE_PYTHON` / `FLOWCODE_CORE_CWD` / `FLOWCODE_RUNNER`.
The app sets `FLOWCODE_PARENT_WATCHDOG=1` so the core self-exits if the app dies
(no orphan). Set `FLOWCODE_MANAGE_CORE=0` to make the app connect to a manually
started core instead.

Manual (from the voicemode fork dir):

```bash
uv run --frozen python core/flowcode_runner.py        # real voice
uv run --frozen python core/flowcode_runner.py --dry  # no audio (state arc only)
```

## Tests (no audio, no pytest)

```bash
python3 core/test_responsive_abort.py   # barge-in cut is immediate (race loop)
python3 core/flowcode_runner.py --dry &  # then:
python3 core/test_control_loop.py        # start/stop/set_flag + §7 whitelist
```
