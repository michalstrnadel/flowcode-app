# Launch kit — flowcode

Goal: maximize GitHub **stars + forks**. This is a growth doc, not product docs. Copy below is
ready to paste. Be honest everywhere — HN and Reddit punish hype and reward candor.

> **Realistic expectations:** a well-executed launch lands **200–800 stars in the first months**.
> 1k+ needs a front-page/influencer pickup; treat 5k+ as upside, not the plan. ~92% of any HN
> spike's star impact happens in the first **48h**, so have follow-up ready to convert it.

---

## 0. The one decision that gates everything — install funnel

The single highest-leverage lever is **how a curious visitor installs it**. Today the only paths are
"build from source" or "let Claude Code install it" — that gates *every* star behind clone → have
Claude Code → run a setup command. Comparable 2026 dictation apps **without** a one-click download
cluster at **20–100 stars** regardless of quality.

The honest tradeoff (don't pick the middle):

| Option | What it takes | Result |
|---|---|---|
| **A. Notarized one-click download** | Apple Developer ID **$99/yr** + notarize (`notarytool` + `stapler`) in the release pipeline | Clean "Open" — zero friction for non-builders. **The biggest star unlock.** |
| **B. Build-from-source only** | Nothing (current state). Locally built apps are **never** quarantined → no Gatekeeper prompt | Honest, $0, but caps reach at the technical crowd (~20–100 floor). |
| ~~C. Ad-hoc-signed `.zip` Release~~ | — | **Don't.** On Tahoe 26 it throws *"App is damaged"* with a broken "Open Anyway" → reads as "broken app" on launch day. Worst option. |

**Decision needed from Michal.** Everything else below works either way.

---

## 1. Pre-launch checklist (do before posting anywhere)

- [ ] **Social preview image** — upload `assets/social-preview.png` at GitHub → repo **Settings → General → Social preview**. This is the image that unfurls on HN/X/Reddit/LinkedIn. (Can't be set via CLI.)
- [x] Repo **description + topics** set (20 topics, keyword-rich).
- [x] **Demo GIF** in README above the fold. *(Optional: trim the 49s clip to a punchy ~12–15s loop so value lands in <2s.)*
- [ ] **Fresh-clone test:** on a clean Mac, `git clone` → `scripts/setup.sh` → confirm it builds and the orb appears. HN clicks straight into the code; a broken first-run on launch day is fatal.
- [ ] Confirm the demo GIF actually **autoplays** on the rendered GitHub page.
- [ ] `LICENSE`, `README`, `THIRD-PARTY-NOTICES.md` visible; consider `CONTRIBUTING.md` + `SECURITY.md`.
- [ ] Clarify the dormant experimental code (socket/barge-in/swarm) so visitors don't misread the repo as half-built — the README "Experimental / dormant" note helps; keep it.

## 2. Get listed in registries (free, durable traffic — several comps' early stars came from here, not a launch post)

- **awesome-claude-code** — submit a PR adding flowcode.
- **awesome-claude-code-toolkit** / ClaudePluginHub / aitmpl directories.
- **sindresorhus/awesome-whisper** (~2.3k⭐) — high-traffic; submit under tools.
- **Claude Code plugin marketplace** — if any slice can be packaged as a plugin, list it (this is the wave that took claude-hud to ~26k⭐).
- **Product Hunt** — schedule a launch (see copy below).

## 3. The one coordinated launch moment

**Primary: Show HN.** Best slot from a 188k-post analysis: **Sunday 7:00pm US Eastern (Mon 00:00 UTC)**
— 10.8% chance of 50+ points. Alt for max newsletter pickup: **Tue/Wed ~8:30–9:30am Pacific**. Submit
the **repo URL** (not a landing page). Be free to babysit the thread for ~3 hours.

Same day: an **X thread** with the demo GIF + outreach to AI newsletters (AlphaSignal-style). Use the
Czech UX network (UX Monday, Asociace UX, LinkedIn) as a **secondary wave**, not the dev driver.

First-hour tactics: aim for ~8–10 organic upvotes + 2–3 real comments in 30 min. Post the maker
comment within 5 min. Reply to every substantive comment within ~15 min for the first hour. Concede
valid criticism; never be defensive. **Never** ask for upvotes (public or private) — instant flag/ban risk.

---

## 4. Copy — paste-ready

### Show HN

**Title**
```
Show HN: flowcode – a local-first voice layer for Claude Code (Kokoro TTS + Whisper)
```
*(Alt: `Show HN: flowcode – give Claude Code a voice, fully local on your Mac`)*

**Maker first comment (post within 5 min)**
> Author here. flowcode is a small native macOS menu-bar app (Swift 6, MIT) that gives Claude Code and the Claude desktop app a voice, fully locally.
>
> Two things it does:
> - Read-aloud: it speaks each new assistant reply via a local Kokoro TTS server (127.0.0.1). It tails the JSONL transcript Claude Code already writes, so your Claude Code session is completely unmodified — no plugin, no wrapper. For the Claude desktop app it reads the on-screen text via the macOS Accessibility tree. It skips tool-call noise and code blocks, so you only hear the prose.
> - Dictation: hold Right Option, speak, release. Local Whisper transcribes it and pastes into whatever app is focused. It never presses Enter — you commit.
>
> Nothing leaves your Mac: TTS and STT are localhost services, no account, no cloud. English works out of the box; Czech is an optional ~350MB neural voice you download only if you pick it.
>
> Honest install caveat, please read before trying it: there is intentionally NO prebuilt/notarized download right now. I don't have a paid Apple Developer ID, and I'd rather ship nothing than ship an ad-hoc-signed zip that throws macOS's "app is damaged" dialog on launch day. So today it's build-from-source: `git clone`, then `scripts/setup.sh` (checks Homebrew/uv/Swift, sets up Kokoro + Whisper as launchd agents, builds and ad-hoc-signs locally so there's no quarantine). Or you can let Claude Code itself install it — clone, run `claude`, say "set up flowcode". A clean one-click signed download is the obvious next step if there's interest.
>
> Also honest: the Claude Desktop read-aloud relies on the Accessibility tree, so a Claude UI update could break it. Claude Code read-aloud (the JSONL path) is the solid one.
>
> It's a fork of mbailey/voicemode for the voice services, with a new Swift menu-bar app and orb HUD on top. Repo, code, and a demo GIF: https://github.com/michalstrnadel/flowcode-app — happy to answer anything.

### Reddit — r/LocalLLaMA (lead hard on local/no-cloud)

**Title:** flowcode — fully local voice layer for Claude Code: Kokoro TTS read-aloud + Whisper push-to-talk, no cloud (macOS, MIT)

> Built this for my own workflow and it's all local, so figured this sub would care most.
>
> flowcode is a native macOS menu-bar app that gives Claude Code (and the Claude desktop app) a voice, with zero cloud calls:
>
> - **Read-aloud** via **local Kokoro** TTS (`127.0.0.1:8880`) — speaks each new assistant reply, skips tool calls and code blocks so you only hear the prose. For Claude Code it just tails the JSONL transcript the CLI already writes (session stays unmodified); for Claude Desktop it reads the Accessibility tree.
> - **Push-to-talk dictation** via **local Whisper** (`127.0.0.1:2022`) — hold Right Option, speak, release, it pastes the transcript into the focused app. Never hits Enter.
>
> TTS + STT are both localhost services started as launchd agents. No account, no API key, nothing leaves the machine. English works out of the box; Czech is an optional ~350MB neural Coqui VITS voice + multilingual Whisper, downloaded only if you switch language (English users download nothing).
>
> Voice stack is a fork of mbailey/voicemode; the Swift 6 menu-bar app + audio-reactive orb HUD are new. MIT licensed.
>
> Install reality up front: no notarized binary yet (no paid Apple Dev ID), so it's build-from-source — `git clone` then `scripts/setup.sh` builds and ad-hoc-signs locally (no quarantine that way). Whisper model defaults to `small`; `setup.sh --model medium` if you want more accuracy.
>
> Repo: https://github.com/michalstrnadel/flowcode-app — feedback on the local services welcome, especially anyone who's swapped in a different Kokoro voice or Whisper model.

### Reddit — r/ClaudeAI

**Title:** I built flowcode — read-aloud + voice dictation for Claude Code and Claude Desktop, fully local (open source, MIT)

> I wanted Claude Code to talk back while I'm reading or away from the screen, and to dictate prompts without typing — so I built flowcode, a tiny native macOS menu-bar app.
>
> What it does:
> - **Reads each new assistant reply aloud** (local Kokoro TTS), skipping tool calls and code blocks so you hear the actual answer, not the plumbing. There's a little Jarvis-style orb that pulses to the speech.
> - **Push-to-talk dictation**: hold Right Option, speak, release — local Whisper transcribes and pastes into whatever's focused (terminal, editor, the Claude desktop app). It never presses Enter, so you always review before sending.
>
> It works with **completely unmodified Claude Code** — it just tails the JSONL transcript the CLI already writes, so there's no plugin or wrapper. It also reads the **Claude desktop app** (Chat / Cowork / Code) via the macOS Accessibility tree. Fully local and private — no cloud, no account. English out of the box, Czech one click away.
>
> Fair warning on install: there's no notarized download yet (I don't have a paid Apple Developer ID), so it's build-from-source. Either `git clone` + `scripts/setup.sh`, or — fittingly — let Claude Code install it: clone, run `claude`, and say "set up flowcode". It reads the bundled AGENTS.md and sets up everything (voice services, build, permissions).
>
> One honest caveat: the Claude Desktop read-aloud reads the Accessibility tree, so a future Claude UI change could break it. The Claude Code path is the rock-solid one.
>
> Repo + demo: https://github.com/michalstrnadel/flowcode-app — would love feedback from people who live in Claude Code all day.

### LinkedIn — English

> I built a small open-source thing this month: flowcode — a voice layer for Claude Code.
>
> It's a native macOS menu-bar app that does two things, both fully on-device:
> → Reads each new Claude reply aloud (local Kokoro TTS), skipping tool calls and code so you hear the actual answer
> → Lets you dictate prompts by holding a key (local Whisper) — it pastes, never sends, so you stay in control
>
> It works with unmodified Claude Code and the Claude desktop app, with a little audio-reactive orb that pulses to the speech. No cloud, no account — your voice and Claude's words never leave the Mac. English out of the box, Czech one click away.
>
> It's MIT licensed and, honestly, still build-from-source for now (no notarized download yet). If you're a Claude Code user and want to try it, the repo and a demo are here — stars and rough feedback both very welcome:
> https://github.com/michalstrnadel/flowcode-app

### LinkedIn — Czech (UX network)

> Víkendový (no, spíš měsíční) side project, kterým jsem se docela bavil.
>
> Hodně teď žiju v Claude Code a chtěl jsem dvě věci: aby mi odpovědi předčítal nahlas, když zrovna nekoukám do obrazovky, a abych mohl diktovat zadání místo psaní. Tak jsem si to postavil — jmenuje se to flowcode.
>
> Je to malá nativní menu-bar appka pro Mac:
> → Předčítá nahlas každou novou odpověď (lokální Kokoro TTS) — přeskakuje volání nástrojů a kód, takže slyšíš samotnou odpověď
> → Podržíš pravý Option, mluvíš, pustíš → lokální Whisper to přepíše a vloží do toho, co máš zrovna otevřené. Enter nikdy nezmáčkne, odeslání necháš na sobě
>
> Celé to běží lokálně — žádný cloud, žádný účet, hlas ani odpovědi z Macu neodejdou. Funguje to s Claude Code i s desktopovou Claude appkou, a u toho ti v menu baru pulzuje takový „orb" do rytmu řeči. Defaultně anglicky, čeština na jedno kliknutí.
>
> Je to open source (MIT). Upozornění na rovinu: zatím to nemá hotový instalátor, staví se to ze zdrojáku (zatím nemám placený Apple Developer účet na notarizaci). Kdyby to někoho z vás zajímalo nebo měl zpětnou vazbu, budu rád:
> https://github.com/michalstrnadel/flowcode-app

### X / Twitter

> Built flowcode: a local-first voice layer for Claude Code.
>
> 🔊 reads each reply aloud (local Kokoro TTS)
> 🎙️ hold ⌥ to dictate (local Whisper)
> ✦ a little orb that pulses to the speech
>
> Works with unmodified Claude Code + Claude Desktop. No cloud, no account. MIT.
>
> github.com/michalstrnadel/flowcode-app

### Product Hunt

**Tagline:** The voice of Claude Code — read-aloud + dictation, fully local

**Description:** flowcode is a tiny native macOS menu-bar app that reads Claude Code and the Claude desktop app's replies aloud (local Kokoro TTS) and lets you dictate prompts by holding a key (local Whisper) — with a Jarvis-style audio-reactive orb. No cloud, no account, no plugin. English + Czech. Open source, MIT. (Build-from-source for now — no notarized download yet.)

---

## 5. How it's different (use in comments / a README table if you want)

- vs **superwhisper / WisprFlow** — those are paid; flowcode is MIT + free + fully local.
- vs **OpenWhispr / pindrop** — those are dictation-only; flowcode adds **read-aloud**, Claude Code/Desktop integration, the orb HUD, and Czech.
- vs Electron tools — flowcode is **native Swift**, not Electron; nothing leaves the Mac.

## Sources / data behind this plan

Gatekeeper (Sequoia 15 / Tahoe 26 behavior, `xattr -dr com.apple.quarantine`), Show HN timing
(188k-post analysis → Sun 7pm ET), and comparable repos (claude-hud ~26k, OpenWhispr ~4k,
OpenSuperWhisper ~1.1k, pindrop ~540, ethanplusai/jarvis ~640) were researched and verified
2026-06-26. See the linked sources in the research run if you want the receipts.
