# Third-party software & licenses

flowcode is licensed under the [MIT License](LICENSE) (© 2026 Michal Strnadel).
It builds on, and interoperates with, the third-party software below. This file
records the attributions that those licenses require.

---

## Bundled / forked into flowcode

### voicemode (Mike Bailey) — MIT

flowcode grew out of, and the **experimental** voice-core path embeds, a fork of
[voicemode](https://github.com/mbailey/voicemode) by Mike Bailey. The default
shipping product (Model B: read-aloud + dictation) does **not** run the voicemode
Python core — it talks to the Kokoro and Whisper HTTP services directly. The fork is
only built into the bundle when the optional embedded core is requested (`make_venv.sh`,
pinned via `VOICEMODE_COMMIT` in `version.env`).

voicemode is distributed under the MIT License. Its license text is reproduced in full:

```
MIT License

Copyright (c) 2026 Mike Bailey

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Used via local HTTP services (not bundled by flowcode-app)

flowcode's read-aloud and dictation call two local, OpenAI-compatible HTTP services.
flowcode-app does **not** redistribute these engines or their model weights; it expects
them to be installed and running on `127.0.0.1` (see the README and `scripts/setup.sh`).

- **Kokoro TTS** (`127.0.0.1:8880`) — text-to-speech. flowcode sends text and plays the
  returned audio. **The Kokoro model weights are governed by their own license, which you
  must review before redistributing any weights.** flowcode-app neither ships nor downloads
  the weights itself.
- **Whisper** (`127.0.0.1:2022`) — speech-to-text (whisper.cpp / a Whisper model) for
  push-to-talk dictation. Whisper is from OpenAI (MIT); the local server and model are
  installed separately.

The two services are most easily installed via the voicemode service installer
(`voicemode service install kokoro|whisper`), which sets up the launchd agents.

---

## Planned / distribution-time dependencies

These are referenced by the release pipeline or roadmap but are **not** currently linked
into the app binary (no `import` of them exists in the sources yet). They are listed here
for completeness; their notices apply to release artifacts that actually include them.

- **Sparkle** (Andy Matuschak et al.) — in-app updates. MIT-licensed; dropped into
  `Contents/Frameworks` at release time.
- **KeyboardShortcuts** (Sindre Sorhus) — planned, MIT.
- **DynamicNotchKit** (MrKai77) — planned, MIT.
- **python-build-standalone** (Astral) — relocatable CPython used only by the optional
  embedded-core build (`make_venv.sh`). See its repository for licensing.
