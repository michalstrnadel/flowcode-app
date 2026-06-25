# flowcode app icon

Pixel-art glowing **Orb** — the same cyan→violet Jarvis HUD orb the app renders,
on a dark macOS squircle (ordered-dither pixel gradient + tech rings).

Regenerate:

```bash
uv run --with pillow python design/icon/build_icns.py   # writes flowcode.iconset
iconutil -c icns design/icon/flowcode.iconset -o Resources/flowcode.icns
```

`gen_icons.py` holds the concept generators (orb / waveform / ripple / monogram);
`build_icns.py` renders the Orb at every macOS size (crisp NEAREST upscale for the
large sizes, LANCZOS downscale for 16/32/64). `Resources/flowcode.icns` is wired
into the bundle via `CFBundleIconFile` (see `Sources/flowcode/Info.plist`) and
copied by `scripts/build_app.sh`.
