# PLAN — `flowcode`: hlasový real-time orchestrátor pro Claude Code (macOS app + orb HUD)

> Výstup **Step 0** (povinná pauza dle briefu). Žádný feature kód zatím nevznikl — vše níže stojí na **read-only analýze skutečných zdrojáků** `mbailey/voicemode` + webového researche (5 paralelních workflow běhů, ~1.8M tokenů).
> Po schválení commitnu jako první artefakty do repa `PLAN.md` (zrcadlo tohoto souboru) a `BOUNDARIES.md` (sekce §5). Teprve pak stavím.

---

## 1. Kontext & vize — proč to děláme

„Mluvit s Claude Code" je vyřešené mnohokrát (voicemode, voice-mcp, …). Vyřešené **není**, aby to působilo **real-time, přerušitelně a jako produkt**, ne jako turn-based smyčka v terminálu. `flowcode` (pracovní název; alt. voiceflow) je:

1. **Real-time hlasové jádro** (P1–P4): barge-in (přerušení do ~150 ms), streaming TTS, semantic endpointing, poctivá korekce po přerušení. Tohle je **produkt** a priorita.
2. **Nativní macOS menu-bar appka**: stáhneš z GitHubu, zapneš, ovládáš jednoduše. Žádný terminál.
3. **Luminiscenční vizuální + zvuková odezva**: jedna světelná koule, která reaguje na hlas, „přemýšlí", mluví — se stavy a earcony. Sci-fi HUD pocit jako z palubního počítače.
4. **(Sekundární) Hlasem řízená orchestrace + swarm vizualizace**: řekneš velký úkol → Claude Code rozjede dynamic workflow (ultracode) → koule se rozkvete do živé konstelace agentů, které sleduješ a slyšíš pracovat → pak se složí a přečte výsledek.

**Severka (north star):** ~30s klip — uživatel přeruší asistenta uprostřed věty, on se okamžitě zastaví (zvuk i vizuál naráz) a přizpůsobí se. Severka **neobsahuje swarm** — ten je bonusové druhé demo.

---

## 2. Architektura — co stavíme

Pět komponent, dvě repa. Swift appka je **tenký controller; nikdy nesahá na audio**. Veškerá tvrdá real-time práce zůstává v Pythonu (voicemode), protože — ověřeno — **živé blokující MCP volání může přerušit jedině in-process `asyncio.Event`**, žádná externí sběrnice.

| Komponenta | Tech | Odpovědnost |
|---|---|---|
| **flowcode.app** (menu-bar controller + HUD) | Swift 6.2, čisté SwiftPM, `.macOS(.v14)`, StrictConcurrency. SwiftUI `@main App` + `@NSApplicationDelegateAdaptor` + AppKit `NSStatusItem` (NE MenuBarExtra). `@Observable @MainActor` modely. Sparkle, KeyboardShortcuts, SMAppService. | Viditelný produkt. Stavová ikona, on/off, předvolby, orb HUD, **§7 non-voice potvrzení**, audit okno. Vlastní mic TCC. Spouští + hlídá Python jádro. |
| **voicemode Python jádro** (MCP server + `converse()` tah) | Python 3.10+, FastMCP stdio, sounddevice/PortAudio. P1–P4 změny za default-OFF `VOICEMODE_*` flagy. | Veškeré real-time audio + celý tah. Barge-in in-process v `converse()`. Vysílá strojově čitelný stav přes IPC. Zůstává cross-platform (Linux headless). |
| **Kokoro (TTS) + Whisper (STT)** | OpenAI-kompat na `127.0.0.1:8880` / `:2022`, OpenAI cloud fallback. **launchd** LaunchAgenty (spravuje voicemode). | Teplé lokální inference enginy. **Nejsou dětmi appky** — launchd je drží naživu (teplé modely = nízká TTFA). App je jen řídí (`voicemode service …`) a health-probuje TCP. |
| **Status/control kanál (IPC)** | **Jeden Unix-domain socket** `~/.voicemode/run/flowcode.sock`, newline-delimited JSON, obousměrný. | Push živého stavu do HUD se sub-150 ms latencí (UDS ~0.1 ms; neviditelný pro TCC/firewall; bez kolize portů). Nese control příkazy + §7 verdikt zpět. |
| **Sidecar watchdog** | Drobný helper v `Contents/Helpers`: `posix_spawnp`+`setpgid`+`getppid()==1` detekce smrti rodiče + SIGTERM→grace→SIGKILL. | Garantuje, že Python jádro umře, když appka spadne (řeší orphan proces, který `Foundation.Process` sám neřeší). |
| **Embedded Python runtime** | Relokovatelný **python-build-standalone** CPython + frozen `uv venv` v `Contents/Resources` (~150–300 MB). | „Stáhni a zapni" bez prerekvizit. App spouští interpreter z venv. `uvx` flow zůstává 100% pro vývojáře. |

**Data flow (jeden tah):** mic → (Swift nativní tap pro *listening* vizuál) + (Python sounddevice pro STT) → `converse()` → STT → string do Claude Code → odpověď → P2 clause-split → Kokoro stream → `stream_pcm_audio` (+ Python posílá *speaking* amplitudu na socket) → reproduktor. Barge-in: Python detekuje řeč během playbacku → `stop_event` → `stream.abort()` + out-of-band priority event na socket → HUD řízne do ~16 ms.

---

## 3. Rozhodnutí (hotová — nerelitigovat)

- **Báze:** fork `mbailey/voicemode` (MIT, aktivní). Nepřepisovat MCP/provider/audio plumbing — jen augmentovat.
- **Render stack HUD:** SwiftUI **Shader API** (`.colorEffect`, `[[stitchable]]` MSL) řízený `TimelineView(.animation)` v non-activating click-through `NSPanel`. NE plný MTKView (upgrade hatch po „bloom spike"), NE čisté SwiftUI gradienty (CPU). **Floor macOS 14** (Shader API); macOS 13 fallback = pure-SwiftUI orb.
- **IPC:** jeden UDS + NDJSON pro status + control + amplitudu + barge-in. (Obě nezávislé syntézy se na tom shodly.)
- **Embedding:** relokovatelný python-build-standalone uv venv. NE PyInstaller/py2app.
- **Repo:** **dvě repa** (viz §11), ne monorepo.
- **Distribuce:** notarizovaný universal `.zip` na GitHub Releases + Sparkle appcast + Homebrew cask; CI-driven (tag → GitHub Actions). Bez DMG.
- **Sandbox:** **unsandboxed** + Hardened Runtime + notarizace (App Sandbox nejde dohromady s Python sidecarem + LaunchAgenty + localhost službami). → **bez Mac App Store**, akceptováno.
- **Uživatelská rozhodnutí (Step 0):** nové native deps **schváleny jako opt-in extras** (base install čistý). Laťka dema = **použitelnost first** → stavíme obě úrovně: bezdependencový gating baseline (rychlé nahratelné demo) + opt-in AEC extra pro skutečný mid-clause talk-over jako prémium.
- **Orchestrace/swarm:** **striktně sekundární a odříznutelná.** Hlasové jádro se dostaví kompletní dřív než jakákoli swarm práce. Default OFF.

---

## 4. Voicemode jádro — ověřená call-graph + gap (P1–P4)

```
converse()  # JEDEN blokující MCP tool = celý tah; už streamuje audio
  └─ text_to_speech_with_failover()      # tenký wrapper (pronunciation pravidla)
       └─ simple_tts_failover()          # výběr endpointu/voice, Kokoro→OpenAI remap, clone pinning
            └─ core.text_to_speech()     # use_streaming = STREAMING_ENABLED and format in [opus,mp3,pcm,wav] → default TRUE
                 └─ stream_tts_audio()
                      └─ stream_pcm_audio()  # BARE sd.OutputStream, blocking write per HTTP chunk; finally: stream.close()
```

**Klíčové ověřené skutečnosti (přímo ze zdrojáku):**
- Converse hot path **už streamuje** audio po HTTP chuncích (`use_streaming` při defaultech True). Buffered `await response.read()` + `NonBlockingAudioPlayer` je jen non-streaming fallback.
- `stream_pcm_audio` = **jediný chokepoint** pro P1 i P4. Vytváří `sd.OutputStream(samplerate=24000, channels=1, dtype='int16')` **bez `blocksize`/`latency='low'`** → pro ~150 ms cutoff nutná rekonfigurace + `stream.abort()` (discard) místo `close()` (drain).
- **Nikde `stop_event`**; `iter_bytes` loop nemá early-break. `text_to_speech`/`stream_tts_audio` nemají interrupt parametr.
- Existuje `bytes_received`/`chunk_count`, ale **žádný čítač samples zapsaných do streamu** (potřeba pro P4).
- `record_audio_with_silence_detection`: webrtcvad, 24 kHz mono int16 / 30 ms framy, scipy resample na 16 kHz, stop při `silence_duration_ms >= SILENCE_THRESHOLD_MS` (1000). Smyčka interní, bez per-chunk callbacku.
- Existuje `EventLogger.log_event` (taxonomie RECORDING_START/STT_*/TTS_PLAYBACK_*) → ideální místo pro **jednu fan-out řádku** vysílající stav na socket. `INTERRUPTED` event dnes neexistuje → přidat s barge-in prací.
- **Past:** `config_reload()` dnes refreshuje jen TTS/STT URL/voices/models a **tiše ignoruje** nové barge-in/endpointing flagy → musíme rozšířit, nebo toggly = „applies on restart".

| Feature | Stav | Plán (vše za default-OFF `VOICEMODE_*` flagy) |
|---|---|---|
| **P1 Barge-in** | ABSENT | Concurrent `asyncio` VAD listener během playbacku → `stop_event` break v `stream_pcm_audio` + `stream.abort()` + low-latency OutputStream. Self-trigger: **day-1 mic gating** (0 deps) → demo; **upgrade** = `livekit-rtc` WebRTC APM AEC + silero-vad (opt-in extra). |
| **P2 Streaming TTS** | PARTIAL (audio už streamuje) | Client-side **dělení na klauzule** v `text_to_speech_with_failover` (`.!?` pak `,;:`, min-word práh, guard zkratek/čísel); endpoint+voice vyřešit jednou za tah; pipeline klauzule N+1 během N. |
| **P3 Semantic endpointing** | ABSENT | Hybrid: zkrácený `SEMANTIC_SILENCE_MS` (~500) + completeness check přes **smart-turn-v3** (ONNX, audio-waveform, běží na 16 kHz framech VAD); `SILENCE_THRESHOLD_MS` (1000) hard fallback. EN-primary; `cs` fallback na akustiku. |
| **P4 Interruption-correction** | ABSENT (závisí na P1+P2) | `samples_written` → sekundy (`SAMPLE_RATE`) → word offset proti textu (přesnost zdarma z P2 klauzulí); odečíst playout latenci; **injektovaná** stručná zpráva přes návratovou hodnotu `converse()` (NE context-edit). |

---

## 5. Hranice (obsah `BOUNDARIES.md`) — co JDE a co NEJDE

**Hlasové jádro / barge-in:**
- **JDE:** self-contained barge-in *uvnitř* `converse()` (in-process `asyncio.create_task` listener + `asyncio.Event`); cancellable playback na default cestě; ~150 ms cutoff **jen** po rekonfiguraci streamu + `stream.abort()`.
- **NEJDE:** přerušit běžící `converse()` zvenčí přes MCP (sync, ne-reentrantní) ani přes hooky (jen přehrají soundfont, během converse se ztlumí); ~150 ms na *současném* defaultu; spolehlivý talk-over uprostřed řeči **bez AEC**; **P4 context-edit/rollback** (jen injektovaná zpráva); tunelovat barge-in do generování tokenů LLM (P2 překrývá syntézu s přehráváním, ne s generováním).

**macOS app / IPC:**
- **JDE:** UDS NDJSON pro status+control+amplitudu+barge-in; Swift vlastní mic TCC; launchd drží Kokoro/Whisper; embedded venv pro offline launch.
- **NEJDE:** mluvit MCP do voicemode přes stdin/stdout (vlastní je Claude Code); App Sandbox / Mac App Store; skrýt HUD před ScreenCaptureKit na macOS 15+ (a je to fajn — chceme ho v záznamu).

**Orchestrace (sekundární):**
- **JDE:** ovládání jen **injekcí textu** (prepend `ultracode: ` / `/effort ultracode` / spoken alias → ten samý code path); pozorování přes **FSEvents tail JSONL** v `~/.claude/projects/<proj>/<session>/subagents/` + parent `<session>.jsonl` (jediný autoritativní *živý* zdroj); identita agenta z názvu `agent-<id>.jsonl` + parent `toolUseResult`; thin hook ping jako „re-read now".
- **NEJDE:** programově spustit/pozastavit/zastavit workflow nebo jednotlivé agenty zvenčí; vstříknout úkol do běžícího workflow; číst `/workflows` TUI stav programově; spolehlivý mid-run token feed (cost animovat až na completion); spoléhat na `agent_id`/`agent_type` v hook payloadu (CLI mezera #16424/#19170). **Stavět kolem toho, nepředstírat.**

---

## 6. macOS app vrstva (Swift) — detaily

- **Shell:** SwiftPM, `NSStatusItem` (animovaná template ikona idle/listening/speaking/interrupted/error), `@Observable` `VoiceSessionStore`+`SettingsStore` jako `@State`, `@Bindable` views. `LSUIElement=YES` + `setActivationPolicy(.accessory)`. `SMAppService.mainApp` login item.
- **Mic TCC:** flowcode.app **musí** být responsible process — `AVCaptureDevice.requestAccess(.audio)` ve Swiftu **před** spawnem Pythonu; `NSMicrophoneUsageDescription` v Info.plist; podepsáno+notarizováno → grant přiřazen appce a přežije update. (Past: re-sign po *jakékoli* editaci Info.plist, jinak se tiše rozbije TCC prompt.)
- **Spawn:** watchdog helper spustí `Contents/Resources/<venv>/bin/python` → voice_mode console script (NE uvx pro app cestu).
- **Audio downside:** právě **jeden** Voice-Processing/AEC vlastník = Python. Swiftí tap je **plain-mode metering only** (`AVAudioEngine.inputNode.installTap`, vDSP RMS/peak) — plain capture je sdílený přes HAL, takže koexistuje s Python sounddevice streamem. (BT/AirPods riziko SCO renegotiace → fallback na Python-side mic envelope přes IPC.)

---

## 7. Orb HUD vrstva — spec

**Koncept:** JEDNA koule, ne pět widgetů. V klidu malá/tlumená u notche, během tahu rozkvete do centrálního HUD, pak se složí. Stav kóduje **pohyb+tvar** primárně, barva sekundárně; těsná paleta (téměř černá + jeden chladný akcent cyan→violet) → prémiové, ne gamer-RGB, color-blind safe.

**Okno:** borderless `NSPanel` `[.nonactivatingPanel,.borderless]`, `level=.statusBar`, `collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]`, `ignoresMouseEvents=true` (click-through, nekrade focus), `canBecomeKey=false`. **Nikdy** `NSApp.activate(...)`. Notch surface přes `MrKai77/DynamicNotchKit` (MIT). Summon: **global hold-to-talk hotkey** (primární), wake word (sekundární) → stejný state machine.

**Audio dataflow:** listening = **nativní Swift tap** (vDSP, <1 ms DSP); speaking = **Python posílá RMS envelope** ~60 Hz přes IPC (Python drží Kokoro PCM před `sd.OutputStream`, může poslat o frame napřed → lip-sync). Barge-in = **out-of-band priority event** předbíhá envelope frontu; handler **zahodí frontu** envelope framů a řízne do ~16–20 ms. Latenční rozpočet listening ~30 ms / speaking ~33 ms (oboje <50 ms „instant").

| Stav | Vizuál | Zvuk | Řízeno |
|---|---|---|---|
| idle | malá tlumená koule, breathing ~0.1 Hz | ticho | time uniform; IPC `idle` |
| listening | rozjasní/zvětší, reaktivní deformace (hlasitější=větší) | krátký rising 2-tón chime (lokální PCM) | nativní mic RMS uniform; IPC `listening` |
| processing | amplitudově **odpojeno**, indeterminate swirl (ne heartbeat) | volitelný tick až >1.5–2 s | time uniform; IPC `processing` |
| speaking | vlnění reaktivní na TTS amplitudu | volitelný falling 2-tón „got it" na konci | Python TTS envelope 60 Hz; IPC `speaking`+`out_rms[]` |
| interrupted | **hard cut** 80–120 ms (contract+flash), snap rovnou do listening | krátký tichý „acknowledge" blip | out-of-band barge-in event; drop envelope fronty |

**Přístupnost:** Reduce Motion (cross-fade místo kontinuálního pohybu, freeze time uniform), Reduce Transparency (solid skin), manuální „calm" toggle + nezávislý earcon mute, VoiceOver label per stav. Earcony: 4–5 kusů recyklovaných z voicemode soundfontů, pre-decoded PCM, fired lokálně.

---

## 8. Orchestrace + swarm viz (SEKUNDÁRNÍ pilíř, default OFF)

**Control (jen text injection — to je strop):** menu-bar **„Swarm/Deep mode" toggle** prepne `ultracode: ` před transkript (nebo pošle `/effort ultracode` jednou na session start); spoken keyword („swarm this", „go deep") = alias na stejnou injekci. Default OFF → normální tah nikdy tiše nerozjede swarm. Claude se sám rozhodne spustit dynamic workflow.

**Observe (read-only):** Swift **FSEvents** watcher na `~/.claude/projects/<encoded>/<session>/subagents/` + parent `<session>.jsonl`. Event→vizuál: nový `agent-<id>.jsonl` → spawn orbitující node (label = `slug`/`agentType`); appendnutý `tool_use` → pulse + jméno toolu; parent `toolUseResult` pro daný agentId → node settle na done (tokeny/cost authoritative až tady); top-level Stop + report → swarm collapse. Fáze nemají event → aproximovat clusterováním spawn-burstů nebo čtením orchestration scriptu. **Thin async hook** (settings.json) na localhost socket jen jako „re-read now" ping, smířený proti souborům (hooky best-effort).

**Viz:** koule = persistentní jádro, které se rozkvete do koncentrických phase-ringů; nody fade-in se staggerem; tethery jádro→fáze→agent; done=flare, failed=desaturovaná červená; na Stop se světlo nodů slije dovnitř (collapse) a koule přečte summary s flarem přispívajícího nodu. `TimelineView`+`Canvas`+`.drawingGroup()`, deterministický radiální layout, **cap 16 nodů** + „done" arc agregace pro 1000-agent běhy. Reduce-motion = statický seznam fází/agentů + progress arc.

**Koexistence s hlasem:** workflow běží na pozadí, session responsive. Na startu Claude jednou oznámí přes `converse(wait_for_response=False)` a vrátí se. Během běhu **veškerý** feedback řídí flowcode z vlastního event streamu (0 Claude round-tripů, 0 token burn): ambient HUD, progress chimes, lokálně syntetizované „4 z 16 hotovo". Až na konci jeden reálný `converse()` přečte report. Barge-in funguje pořád (P1 mechanismus).

---

## 9. Bezpečnost §7 — zero-trust audio (release blocker)

Hlas **navrhuje**; **commituje** jen nehlasové gesto disjunktní od mikrofonu (ambient TV/kolega/vlastní TTS nesmí splnit).
- **Primární gesto:** auto-foregrounded menu-bar **popover** s **doslovným** příkazem/diffem + Confirm (klik) / Cancel (default, Esc). Global hotkey (KeyboardShortcuts) pro hands-on commit.
- **Nejvyšší tier** (spend, force-push, external send, nevratný delete): `LAContext.evaluatePolicy` (Touch ID) / `UNNotificationActionOptions.authenticationRequired`.
- Claude Code **PermissionRequest** prompty jdou stejnou bránou — hook smí *oznámit* TTS, schválení manuální. Workflow subagenti: file edits auto, ale shell/web/non-allowlist MCP **promptují** jako `Notification(permission_prompt)` → vizuální karta, nehlasové potvrzení.
- **Tvrdá pravidla:** timeout = **DENY**; TTS **ducknout** během promptu (ať se nezachytí jako „yes"); verdikt jde `{cmd:confirm,id,verdict}` na control socketu, `converse()` na něm blokuje; **nikdy** nespouštět uživatelův Claude Code v `-p`/bypass na hlasový trigger; neallowlistovat destruktivní Bash; redakce secretů před displejem/TTS (tailujeme JSONL).
- **Audit okno:** append-only timestamped, `command → action → outcome` (confirmed-by-click / hotkey / authenticated / denied / timed-out), backed `conversation_logger.py`/event JSONL, „Reveal log file".

---

## 10. Čeština — config-gated bonus (až po P1–P4)

Flag `VOICEMODE_WHISPER_LANGUAGE=cs`. **CZ STT:** fine-tune `mikr/whisper-large-v3-czech-cv13` (nutná jednorázová ct2 konverze). **CZ TTS:** Kokoro **nemá** český hlas → čeština přes alternativní TTS engine, best-effort. **P3:** smart-turn-v3 ani LiveKit nepokrývají cs → fallback na akustiku. Stretch: G2P pro IT akronymy. **Tvrdé pravidlo:** nic v jádře nesmí záviset na fungující češtině; nikdy na kritické cestě dema.

---

## 11. Repo strategie — dvě repa

- **voicemode fork (overlay, ne hard fork):** každá změna za default-OFF `VOICEMODE_*` flagem, izolovaná do minima chokepointů (`stream_pcm_audio`, `text_to_speech_with_failover`, `converse()`/`streaming.py`, jedna fan-out řádka v `EventLogger.log_event`, nový `INTERRUPTED` event, `VOICEMODE_STATUS_SOCKET` broadcaster). Default chování beze změny → čistý rebase na upstream `master`. Obecné kusy (barge-in, event broadcast) případně upstreamovat jako PR.
- **flowcode app repo (nový deliverable):** Swift package (library + thin executable layout), watchdog helper, package/sign/notarize skripty, GitHub Actions release workflow, `version.env`, pinnutý odkaz na voicemode fork (submodule/pinned commit, ze kterého build step staví venv).
- **Proč ne monorepo:** různé toolchainy (Swift/macOS CI vs Python/cross-platform vč. Linux-headless), různé kadence, voicemode musí zůstat nezávisle rebasovatelný.

---

## 12. Implementační pořadí (sjednocené)

> Princip: **hlasové jádro se dostaví kompletní dřív než swarm.** Použitelná appka brzy. Severkový klip dosažitelný po Phase 4. Vše default-OFF.

- **Phase 0 — Python Step 0 (foundation):** `stop_event` + `samples_written` do `stream_pcm_audio` (jediný chokepoint); `VOICEMODE_STATUS_SOCKET` broadcaster (1 fan-out řádka v `EventLogger.log_event`) + `INTERRUPTED` event konstanta. Bez změny chování. *(Python)*
- **Phase 1 — Swift app shell:** SwiftPM, `NSStatusItem`, `@Observable` stores, `.accessory`+`LSUIElement`, SMAppService, mic `requestAccess`+Info.plist, spawn embedded venv přes watchdog, UDS status reader mapující existující eventy (listening/speaking/idle) na ikonu. → **Použitelná on/off appka.** *(Swift)*
- **Phase 2 — Světelná koule (nativní, bez Python závislosti pro listening):** click-through `NSPanel`, SDF `.colorEffect` shader, `TimelineView` idle breathing, AVAudioEngine plain mic tap → vDSP RMS → listening reaktivita, Reduce Motion/Transparency skiny, earcony. → **První půlka dema funguje s nulovou Python závislostí.** *(Swift)*
- **Phase 3 — Python P2:** client-side dělení na klauzule. *(Python)*
- **Phase 4 — Python P1 + IPC core:** concurrent asyncio VAD listener + `stop_event` break + `stream.abort()` + low-latency OutputStream + day-1 mic gating; out-of-band `INTERRUPTED` event na socket; Swift konzumuje speaking envelope (60 Hz) + barge-in cut. → **Severkový klip dosažitelný (money shot).** *(Python + Swift wiring)*
- **Phase 5 — §7 brána + audit:** Swift popover + global hotkey + Touch ID tier; timeout=deny; TTS duck; route PermissionRequest; audit okno; Python hook blokující `converse()` na verdiktu; **rozšířit `config_reload()`** o nové flagy. *(Swift + Python)*
- **Phase 6 — Python P4:** offset→word injektovaný přes `converse()` return; offset na socket. *(Python)*
- **Phase 7 — Python P3 + prémiové extras:** hybrid endpointing smart-turn-v3 (EN-primary); AEC (`livekit-rtc` APM + silero-vad) jako opt-in extra nahrazující gating. *(Python, opt-in extras)*
- **Phase 8 — Orchestrace swarm (sekundární, default OFF):** 8a FSEvents observer → agent model + minimal HUD; 8b control toggle (`ultracode: ` / spoken alias); 8c bloom/collapse konstelace HUD; 8d hook ping + completion read-back. *(Swift + settings hook)*
- **Phase 9 — Distribuce/CI:** tag → GitHub Actions: per-arch swift build → lipo universal → assemble `.app` (Helpers/watchdog, Resources/venv, Frameworks/Sparkle) → inside-out sign (každý nested Mach-O vč. python interpreteru a wheel `.so`, NE `--deep`) → Hardened Runtime + `disable-library-validation` → `notarytool --wait` → staple → ditto zip → Sparkle EdDSA → commit `appcast.xml` → `gh release` + Homebrew cask. Notarizace embedded Pythonu = nejtěžší kus → vlastní fáze + early smoke test. *(CI; lze stubovat ad-hoc signingem dřív)*

---

## 13. Ověření & Definition of Done

1. **P2:** `VOICEMODE_TTS_SENTENCE_CHUNKING` on → změřit `ttfa_ms` před/po; první audio znatelně dřív; poslechem žádné kliky mezi klauzulemi.
2. **P1:** `VOICEMODE_BARGEIN_ENABLED` on → mluvit během playbacku; čas onset→ticho ~100–150 ms; vlastní TTS netriggeruje (gating). S `flowcode[bargein-aec]` ověřit talk-over uprostřed klauzule.
3. **HUD:** koule reaguje na hlas <50 ms; barge-in řízne vizuál do ~16–20 ms naráz se zvukem; Reduce Motion/Transparency skiny OK.
4. **P4:** přerušit uprostřed → injektovaná zpráva uvádí rozumné „slyšel jsi ~N slov"; LLM nepředpokládá, že uživatel slyšel zbytek.
5. **P3:** dokončená věta + zmlknutí <1 s → tah firne dřív než 1000 ms; nedokončenou větu neustřihne.
6. **§7:** adversariální audio test (pustit „smaž všechno" klip → nic destruktivního bez nehlasového potvrzení); permission prompt nejde schválit hlasem; timeout=deny.
7. **Swarm (bonus):** „ultracode, audit codebase" → koule se rozkvete do živé konstelace; barge-in funguje mid-run; collapse + read-back s node flarem.
8. **Distribuce:** stažený notarizovaný `.app` se otevře bez Gatekeeper boje; mic prompt přiřazen flowcode; Sparkle self-update funguje.
9. **Regrese:** s vypnutými flagy = byte-for-byte upstream voicemode; `uvx` flow nedotčený; testy zelené (+ nové regresní testy silence/barge-in).
10. **DoD:** P1–P3 funkční (jádro cross-platform; appka macOS); README s nahraným demo klipem mid-sentence přerušení; `PLAN.md` + `BOUNDARIES.md` v repu.

---

## 14. Hlavní rizika

- **Notarizace embedded Pythonu + native wheels** (PortAudio/onnxruntime) = nejtěžší/nejrizikovější kus → vlastní fáze + early signed smoke test.
- **Mic attribution** na špatný proces, pokud audio cestu spustí dřív Terminal/Claude než flowcode.app → app **musí** vlastnit `requestAccess` i launch.
- **Barge-in dnes neexistuje** → celé demo závisí na korektním P1/Step 0; HUD „interrupted" nemá signál, dokud nový event nepřijde.
- **`config_reload()` past:** app-zapsané flagy tiše no-op na hot reload → rozšířit reload nebo „applies on restart".
- **Self-trigger vs responsiveness:** day-1 gating zakáže talk-over uprostřed řeči → demo na baseline ukáže stop v mezeře; plný talk-over až s AEC extra. Nastavit očekávání v README.
- **Sample-rate/frame-size minové pole** (24 k capture, webrtcvad 8/16/32/48 k, APM 10 ms@16 k, silero 16 k/512, Kokoro 24 k) = #1 příčina, že AEC neruší → standardizovat 16 kHz/10 ms.
- **Bundle ~150–300 MB** může ublížit „just download" → ověřit, zda těžké wheels nežijí spíš v launchd Whisper/Kokoro instalacích.
- **BT/AirPods** SCO renegotiace při druhém input streamu → ověřit built-in/USB first, fallback Python-side mic envelope.
- **Swarm scope creep:** pilíř je svůdný → tvrdá brána „jádro kompletní first"; ohrozí-li latenci/default-off čistotu, **řízni swarm, ne jádro**.
- **Sparkle Ed25519 + Developer ID v CI** = secret management; leak kompromituje update signing.
- **Upstream voicemode drift** → držet edity na minimu chokepointů, upstreamovat obecné.

---

## 15. Otevřené otázky k ověření při buildu (neblokující)

- Reálné default `blocksize`/`latency` `sd.OutputStream` na cílovém backendu → měřit kill latenci empiricky.
- Které těžké wheels táhne MCP venv tranzitivně vs launchd služby (bundle size).
- `voicemode service status/health` formát výstupu (→ raději TCP probe :8880/:2022).
- Fungují `SubagentStart/Stop` hooky pro agenty uvnitř isolated workflow runtime? (Pokud ne, file tail je jediný živý zdroj — a to stojí sám.)
- `workflows/wf_<runId>.json` journal schéma (psát parser proti reálnému prvnímu běhu).
- Kokoro output block size / sample rate (lip-sync envelope cadence).
- Potvrdit floor macOS 14 s produktem (Shader API); jinak MTKView/pure-SwiftUI fallback.
