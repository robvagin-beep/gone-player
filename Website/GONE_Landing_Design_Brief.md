# GONE Player — Landing & App Store Site
## Design + Build Brief for Claude (Design)

> **Your job:** design and build the entire site yourself — layout, hierarchy, motion, copy assembly, responsive behavior. This document is your single source of truth. You do not need any other file.
> **What you receive separately:** product screenshots (different player states), named in the Assets section below. Drop them into the slots marked `[SCREENSHOT: …]`.
> **What you ship:** a static, dependency-free site with three routes — `/` (landing), `/privacy`, `/support`. Public, HTTPS, no login. EN + UK.

---

## 0. Hard constraints (read first)

- **Static only.** Plain HTML + CSS, minimal vanilla JS (only for language toggle, smooth scroll, lazy images). No frameworks, no build step, no external runtime dependencies. The site must open by double-clicking `index.html`.
- **The design IS the product.** GONE is a precise, dark, mono-typed macOS tool. The site must read as a continuation of the app, not a marketing skin over it. Use the exact design tokens in §4. No gradients-for-decoration, no stock photography, no rounded blobs, no emoji, no AI-slop hero illustrations.
- **App Store rule that drives the whole thing:** the `/privacy` and `/support` URLs go into App Store Connect and **must never change after submit**. They must be public, HTTPS, no auth, real text (not a PDF, not an image). Build them as their own stable pages.
- **Two languages, one truth.** English is the source. Ukrainian (uk) is a full mirror. No Russian. See §10 for the i18n approach and translated strings.
- **Voice:** statements, never questions in headlines. No exclamation marks. No em dash in body copy. Confident, adult, calm. Lead the reader to a conclusion; do not sell at them. Think Jony Ive keynote, not SaaS landing.

---

## 1. Deliverables & routes

```
/                 index.html        — the narrative landing
/privacy          privacy/index.html — privacy policy (App Store URL)
/support          support/index.html — FAQ + contact (App Store URL)
/assets/          screenshots, app icon, favicon, og image
/css/             one stylesheet (tokens + components)
/js/              one small script (lang toggle, scroll, lazyload)
/i18n/            en.json, uk.json  (or inline data-attributes — your call, see §10)
```

**URL config:** treat the canonical base as a variable. Put a single constant at the top of the JS (and a comment in the HTML head) named `BASE_URL`. Default it to `https://goneplayer.app`. All absolute links (og:url, canonical, cross-page nav) derive from it. This way the same build deploys to the real domain or to a GitHub Pages fallback (`https://<user>.github.io/gone-player/`) by changing one line.

- Canonical (assumed): `https://goneplayer.app`, `https://goneplayer.app/privacy`, `https://goneplayer.app/support`
- Fallback if domain is not live yet: GitHub Pages from a static branch. Keep relative internal links so both work.

**Favicon / OG:** generate from the app mark (see Assets). OG image: 1200×630, dark `#141414`, the mark + wordmark "GONE PLAYER" centered, one line of tagline. No screenshot in the OG.

---

## 2. The product — what GONE actually is

Write all copy from this. Do not invent features. Do not soften the positioning into "a music player."

**One sentence:** GONE is a focused macOS companion for the thirty minutes before a DJ set — drop a folder, sort by BPM, audition tracks with real effects at the right tempo, decide what fits, then open your DAW or controller.

**The wedge:** it is deliberately *not* a professional DJ platform. It replaces nothing. It lives next to Finder. No library database, no sync, no beat-grid editing, no MIDI, no streaming, no export to Rekordbox/Serato/Spotify. It is the tool you use *before* you open those — to make fast, informed decisions about your own local files.

**Target user:** a DJ who keeps music in folders, working on a MacBook at home or at a side gig. Before a set they open their folders, scan BPMs, audition candidates at the right tempo and EQ, compare two tracks side by side, mark what works.

**Why it exists (the concept — use this for the opening section):** the moment that matters in preparing a set is *judgment* — does this track belong. Rekordbox and Traktor are built for the performance, not for that quiet half hour of deciding. GONE protects that half hour. It gives you exactly the tools that decision needs and nothing that distracts from it. Honest auditioning: hear the track shifted to your tempo, through an EQ, in the context it will actually sit in. Then get out of the way.

**Design principle of the app (mirror it on the site):** minimal but rich, controlled, precise. Mono type for every number. The window gets out of the way when you do not need it. Runs on old MacBooks (macOS 13+) — that is a feature, not an apology.

**Privacy is a product feature, not fine print:** GONE is 100% Apple-native, zero third-party dependencies, and does not connect to the network. Your files never leave your Mac. Nothing is collected, uploaded, tracked, or sold. The `/privacy` page says this plainly and it is true. Use it on the landing too — it is a selling point for a paying, professional audience.

---

## 3. Audience & tone

- **Audience:** paying, adult, professional/semi-pro DJs and producers. People who already own gear and have opinions. They distrust hype.
- **Tone:** strict, modern, confident without pose. Share, do not prove. Marinate, then land the point. Humor only if dry and rare; never explain it.
- **Headlines:** declarative statements. Concrete. Examples of the register (draft, refine):
  - "The thirty minutes before the set."
  - "Drop a folder. Know what fits."
  - "Audition honestly. Decide once."
  - "It does the part nobody else respects."
- **Forbidden copy patterns:** "Let's dive in", "Here's what you need to know", "It's worth noting", "the ultimate", "revolutionary", "game-changer", exclamation marks, rhetorical questions in headlines.

---

## 4. Visual system — use these tokens verbatim

These are the app's real design tokens. The site must use them so it reads as the same object.

### Colors
```
--bg-window:        #141414   /* primary page background */
--bg-page:          #0e0e0e   /* deepest sections / footer */
--bg-panel:         #191919   /* cards, code/snippet blocks, floating panels */
--panel-tint:       rgba(0,0,0,0.18)  /* subtle inset panels */

--text-primary:     #ffffff
--text-secondary:   rgba(255,255,255,0.78)
--text-tertiary:    rgba(255,255,255,0.55)
--text-muted:       rgba(255,255,255,0.40)
--text-faint:       rgba(255,255,255,0.28)
--text-on-light:    #0d0d0d

--accent:           rgba(255,255,255,0.92)  /* the app has no color accent — white is the accent */
--danger:           #ff8a7a
--warning:          #d4a017
--flag-green:       #4caf82
--flag-yellow:      #d4a017
--flag-red:         #ff8a7a

--border-subtle:    rgba(255,255,255,0.06)
--border-default:   rgba(255,255,255,0.08)
--border-strong:    rgba(255,255,255,0.14)
--hover-bg:         rgba(255,255,255,0.04)
--current-bg:       #4C4C4C
```
**Color discipline:** the app is monochrome by design. White and greys carry everything. The only saturated colors are the track flags (green/yellow/red) and danger/warning states. Do not introduce a brand color. If you need emphasis, use weight, size, and the white accent — not hue.

### Radii
```
--r-window-outer: 18px   --r-window-inner: 14px
--r-button:       7px    --r-button-primary: 10px
--r-panel:        10px   --r-pill: 6px   --r-control: 5px
--r-badge:        4px    --r-row: 3px
```
Use `--r-panel` (10px) for snippet/feature cards, `--r-window-outer` (18px) when framing a full app screenshot like a window.

### Typography
- **Mono** (`ui-monospace, SF Mono, Menlo, monospace`): every number, BPM value, tempo %, label, badge, code/snippet, nav, captions. This is the app's signature — numbers are always mono.
- **Sans** (`-apple-system, "SF Pro", Inter, system-ui, sans-serif`): body prose and large narrative headlines.
- **Scale (suggested, refine for rhythm):** hero 56–72px sans tight; section headline 32–40px; lead paragraph 18–20px; body 16px; caption/label 12–13px mono uppercase with +0.06em tracking.
- Headlines: tight line-height (1.05–1.15), letter-spacing slightly negative on sans display.
- Labels/eyebrows: mono, uppercase, muted, letter-spacing positive.

### Layout & spacing
- 8pt grid: 8 / 16 / 24 / 32 / 40 / 48 / 64 / 80.
- Generous vertical rhythm between narrative sections (cinematic pauses — 96–160px on desktop). The app breathes; the page should too.
- Max content width ~1100px; long-form prose measure ~620–680px. Center column.
- Background near-black, content floats on it. Thin 1px borders (`--border-default`) define panels, never heavy shadows. If you use shadow, keep it deep and soft (`0 20px 60px rgba(0,0,0,0.5)`) only on framed screenshots.

### Texture / finish
- Pixel-crisp. Hairline 1px borders, snapped to device pixels. No glow, no neon, no glassmorphism, no liquid-glass.
- Optional: a very faint film grain or 1px dot grid at <4% opacity to match the app's pixel-precise waveform character. Keep it invisible-until-looked-for.

### Motion
- Restrained and exact. Fade + 8–16px rise on scroll-in, 200–300ms, ease-out. No parallax circus, no bounce. One signature moment is enough (see §5, the FX/XY section).
- Respect `prefers-reduced-motion`.

---

## 5. The landing page — section by section

Structure it like a track, not a brochure: intro, build, choruses, the main hook, outro. Marinate before the payoff. Each section pairs a single idea with a single screenshot or snippet. Below, `[SCREENSHOT: name]` = drop the named asset; `[TOOLTIP: "…"]` = real in-app microcopy you should surface as authentic feature copy (these are the actual tooltips from the product — use them, they are honest and precise).

### 5.0 — Top nav (minimal, sticky, thin)
- Left: wordmark `GONE` (mono, tight) + small `PLAYER` muted.
- Right: `Privacy` · `Support` · language toggle `EN / UK` · primary button `Download` (or `Get it on the Mac App Store` badge once live; until then `Download Beta` / `Coming to the Mac App Store`).
- Background `--bg-window` with bottom hairline border on scroll.

### 5.1 — Hero (intro)
- Headline: a single declarative line about the thirty minutes before the set.
- Subline (one sentence, --text-secondary): the one-sentence positioning from §2.
- Primary CTA + a quiet secondary link "What it does ↓".
- `[SCREENSHOT: hero-player]` — the full player window, framed like a floating macOS panel (use `--r-window-outer`, soft deep shadow, on `--bg-page`). This is the only big visual above the fold. Let it sit in negative space. Do not crowd it.
- Beneath, a thin mono caption line: `macOS 13+ · Apple Silicon & Intel · runs on older MacBooks`.

### 5.2 — The concept (the "why", marinate here)
- Short narrative block, prose measure. Use the concept from §2: the moment that matters is judgment; Rekordbox is built for the show, not for the quiet half hour of deciding; GONE protects that half hour. End on: "It does the part nobody else respects."
- No screenshot, or one quiet detail crop. This is a breath.

### 5.3 — Drop a folder → sorted by BPM (first chorus)
- Idea: zero setup. No database, no import ritual. Drag a folder, get instant BPM detection and a sorted list.
- `[SCREENSHOT: playlist-bpm]` — the track list with BPM column.
- Surface real copy:
  - Welcome states from the app (use as flavor): `WELCOME TO GONE PLAYER` / `DRAG AND DROP TRACK HERE` / `OR JUST CLICK, IT'S UP TO YOU`.
  - [TOOLTIP: "BPM Fit — shifts tempo to match a target BPM range"]
  - [TOOLTIP: "Re-analyze BPM"] — note BPM detection is honest and re-runnable, with octave-fold sanity for the dance-floor range.
- One mono detail line on the analysis quality (true): "Multi-window BPM analysis with dance-floor sanity correction. Wrong on the intro is wrong everywhere, so it listens to the body of the track."

### 5.4 — Honest auditioning: tempo + Master Tempo (build)
- Idea: hear the track where it will actually sit. Pitch/tempo with three ranges, key-locked.
- `[SCREENSHOT: pitch-fader]` — the vertical pitch fader + MT button.
- Real copy:
  - [TOOLTIP: "Tempo fader — drag to speed up or slow down. Double-click to reset to 0%"]
  - [TOOLTIP: "Fader range — ±8 fine-tuning, ±16 medium, ±100 extreme"]
  - [TOOLTIP: "Master Tempo — pitch stays locked to original key when you change speed"]
  - [TOOLTIP: "How far the speed has shifted from original. 0.0% = no change"]
  - [TOOLTIP: "BPM after your tempo shift"]

### 5.5 — EQ + the XY effects pad (the main hook)
- This is the centerpiece. Idea: a real 4-band EQ with HPF/LPF so you hear it in the mix, plus an XY pad with 13 effect axes for auditioning a track's character, not just its loudness.
- `[SCREENSHOT: eq-xy]` — the EQ faders + XY pad.
- List the 13 axes (real, from the app) as a tight mono grid — this is the "tool types / hidden features revealed interestingly" the brief asks for. Give each a one-line plain-English gloss:
  ```
  FILTER          one knob from lowpass through highpass
  LOW-PASS        roll off the highs
  HIGH-PASS       roll off the lows
  BAND-PASS       isolate the mids
  RESONANCE       add bite at the cutoff
  LFO             sweep the filter in motion
  BPM CHOP        tempo-synced filter sweeps
  SLICER          tempo-synced gate, 1/4 → 1/32
  REVERB          space and tail
  FILTER + REVERB filter and space together
  DELAY           clean echo
  DUB DELAY       feedback echo with its own low-pass
  LO-FI           decimated, degraded character
  ```
- Caption (true): "Display only where it should be: the spectrum shows the audio's frequency energy as it plays, it is not an EQ." [TOOLTIP: "Frequency energy of the audio as it plays. Display only — not an EQ"]
- **Signature motion moment:** on scroll-in, let one filter sweep animate across the XY pad / spectrum once (CSS only, subtle). This is the single allowed flourish. Reduced-motion: static.

### 5.6 — Hot cues (build)
- Idea: mark phrases on the fly. 4 hot cues per player, keys 1–4, sample-accurate, shown on the waveform.
- `[SCREENSHOT: waveform-cues]` — waveform with colored cue ticks.
- Copy: "Four cues per player. Press 1–4 to set on the fly, press again to jump. Sample-accurate, drawn on the waveform. Session-only, nothing written to your files."

### 5.7 — Clone Mode: compare two tracks (chorus)
- Idea: a second independent player + a visual crossfader between the two windows, for honest A/B.
- `[SCREENSHOT: clone-mode]` — both player windows + crossfader.
- Real copy: [TOOLTIP: "Clone Mode — opens a second player with shared track list for side-by-side comparison"]
- Note equal-power crossfade and per-window output device sync (true) as a quiet detail line.

### 5.8 — Snap to edge: it gets out of the way (the design philosophy made literal)
- Idea: the window slides off-screen when idle and returns on hover. Stays out of your way while your DAW is open.
- `[SCREENSHOT: snap-peek]` — the docked/peek state.
- Real copy: [TOOLTIP: "Snap to edge — slides off, reappears on hover · timing in Settings → Snap"]
- Also mention: always-on-top by default, with an Invisible mode for when you want it gone but alive.

### 5.9 — Numbered export: the bridge back to your gear (strong, unique — give it room)
- Idea: this is the feature that proves GONE knows its place in the workflow. Drag tracks to Finder and they rename to `001_Name`, `002_Name` — locking your set order for any gear that reads filenames. No proprietary export, no lock-in.
- `[SCREENSHOT: numbered-export]` — dragging to Finder / renamed files.
- Real copy: [TOOLTIP: "Numbered export. Drag tracks to Finder and they rename to 001_Name, 002_Name — locks set order for any gear that reads filenames"]
- Plus: [TOOLTIP: "Show in Finder"]. This section reinforces the wedge: GONE hands off cleanly, it does not trap you.

### 5.10 — Built to be quiet about your data (privacy as a feature)
- Idea: 100% Apple-native, no third-party code, no network. Your files never leave the Mac. Nothing collected.
- No screenshot needed; a stark mono statement block on `--bg-page`.
- Copy: "GONE does not connect to the internet. No accounts, no tracking, no analytics, no uploads. Everything happens on your Mac, with your files, and stays there." Link to `/privacy`.

### 5.11 — Formats & system (spec block, mono)
- Mono spec table, calm:
  ```
  FORMATS     MP3 · FLAC · WAV · AIFF · AAC · M4A
  SYSTEM      macOS 13 Ventura or later
  HARDWARE    Apple Silicon & Intel · runs on older MacBooks
  ENGINE      100% Apple-native · no third-party dependencies
  NETWORK     none — fully offline
  ```

### 5.12 — Closing / download (outro)
- Restate the positioning in one line. Primary CTA (Mac App Store badge when live). Quiet line: "A focused tool for the part of the work that deserves focus."

### 5.13 — Footer
- Wordmark, copyright `© 2026 GONE Player`, links: `Privacy` · `Support` · language toggle. Contact email (see §7). Keep it sparse, mono, muted.

---

## 6. Assets — what Robert provides (screenshot slots)

Robert will deliver PNG/screenshots of these states. Name files exactly so they drop into the slots. If a shot is missing, leave the framed container with a thin dashed `--border-strong` placeholder labeled in mono with the slot name — never a stock image.

```
hero-player.png        full player window, default loaded state
playlist-bpm.png       track list showing BPM column + sort
pitch-fader.png        pitch fader rail + Master Tempo button
eq-xy.png              EQ faders + XY effects pad
waveform-cues.png      waveform with hot cue ticks
clone-mode.png         two player windows + crossfader
snap-peek.png          docked / peek state at screen edge
numbered-export.png    drag-to-Finder numbered files
app-icon.png           app icon (for favicon + OG)
```
**Screenshot framing rules:** present each as the floating object it is — rounded `--r-window-outer`, deep soft shadow, on `--bg-page`. Do not add fake browser chrome, fake device mockups, hands, desks, or cafe backgrounds. The app is the hero; show it clean. Provide `@1x` and `@2x` (retina) and use `srcset`. Lazy-load everything below the fold.

---

## 7. /support page

Stable URL, public, App Store-linked. Plain, useful, fast. Structure:

- **Header:** `Support` + one line: "GONE Player is a small, focused macOS app. Here is how to get help and answers."
- **Contact block (top, unmissable):** a real support email. **Robert to confirm the address** — placeholder `support@goneplayer.app` (config it the same way as BASE_URL). Until the domain is live, fall back to his contact email. State a realistic response expectation: "Email is the fastest way to reach us. We read everything and reply within a few business days."
- **FAQ** (write these out, EN + UK):
  1. **What is GONE Player?** — the one-sentence positioning + the wedge (it is for the prep, not the performance).
  2. **What does it cost / where do I get it?** — Mac App Store (link/badge when live).
  3. **What macOS do I need?** — macOS 13 Ventura or later; Apple Silicon and Intel; runs on older MacBooks.
  4. **What audio formats are supported?** — MP3, FLAC, WAV, AIFF, AAC, M4A.
  5. **Does GONE change or move my files?** — No. It reads your files for playback and analysis. The only thing that touches filenames is *Numbered export*, and only when you drag tracks out to Finder. Hot cues, ratings, and analysis are session-only and never written into your audio files.
  6. **Does it sync with Rekordbox / Serato / Spotify?** — No, by design. GONE is for the half hour before you open those. Use Numbered export to carry your set order to any gear that reads filenames.
  7. **Is BPM detection accurate?** — It uses multi-window analysis with dance-floor sanity correction and an octave-fold for the club range. You can re-analyze any track; a deep re-analysis widens the range and corrects half/double tempo.
  8. **Why does the window slide away?** — Snap to edge. It docks off-screen when idle and returns on hover. Timing is in Settings → Snap. Turn it off there if you prefer.
  9. **Does GONE collect any data / connect to the internet?** — No. It is fully offline and collects nothing. See the Privacy page.
  10. **I found a bug / want a feature.** — Email us with your macOS version and what happened. Concrete reports get fixed faster.
- **Footer:** link to Privacy, language toggle.

---

## 8. /privacy page

Stable URL, public, App Store-linked, real text. GONE's privacy story is simple and strong: it collects nothing. Write it plainly and honestly. Draft below (EN; UK mirror in §10). Put a "Last updated" date at top (`Last updated: <build date>`).

```
GONE Player — Privacy Policy

GONE Player is a macOS application made by Robert Vagin (heartbeat).
We designed it to do its job without ever needing your data.

WHAT WE COLLECT
Nothing. GONE Player does not collect, transmit, store on our servers,
or sell any personal information. We have no accounts, no analytics,
no advertising, and no third-party tracking SDKs.

YOUR FILES
GONE reads the audio files and folders you open, on your Mac, to play
and analyze them. These files never leave your device. We never see them,
upload them, or copy them anywhere. Track analysis (BPM, waveform),
hot cues, and ratings exist only during your session and in a local
cache on your own Mac.

NETWORK
GONE Player does not connect to the internet. It is fully offline by design.

PERMISSIONS
GONE asks only for access to the audio files and folders you choose to
open, through the standard macOS file dialog. It does not request access
to your contacts, location, camera, microphone, or any other personal data.

THIRD PARTIES
GONE Player is built entirely with Apple frameworks and includes no
third-party code or services. There is no one for your data to be shared
with, because no data is collected.

CHILDREN
GONE Player is a professional audio tool and is not directed at children.
It collects no data from anyone, including children.

CHANGES
If this policy ever changes, we will update this page and the date above.
Because the app collects nothing, we do not expect material changes.

CONTACT
Questions about privacy: <support email>
```
**Important for App Store:** keep the wording consistent with the App Privacy answers in App Store Connect (which will be "Data Not Collected"). The page text above supports that. Do not add language about data we do not actually handle.

---

## 9. App Store compliance checklist (build to satisfy all)

- [ ] `/privacy` and `/support` are **separate, permanent, public** URLs, HTTPS, no login, real HTML text (not PDF, not image).
- [ ] Links do not change after submit — that is why they live at fixed paths and use `BASE_URL`.
- [ ] Privacy page wording matches "Data Not Collected" in App Store Connect.
- [ ] Support page has a working contact method (email) above the fold.
- [ ] No broken links; cross-page nav works on the deployed host AND from the file system (relative links).
- [ ] Loads fast and works without JS for the core content (JS only enhances: lang toggle, lazyload). Privacy and Support must be fully readable with JS disabled.
- [ ] Accessible: semantic HTML, real headings, alt text on every screenshot, visible focus states, AA contrast (the palette already passes — verify white-on-#141414 and muted greys on copy).
- [ ] Responsive: clean from 375px mobile to 1440px desktop. The mono spec tables and the 13-axis grid must reflow gracefully (stack on mobile).
- [ ] `prefers-reduced-motion` honored.
- [ ] Favicon + OG/Twitter meta from the app mark. `og:url` and canonical from `BASE_URL`.
- [ ] No tracking scripts, no Google Fonts CDN (use system fonts per §4), no external calls — consistent with the privacy claim. The site itself should be as privacy-clean as the app.

---

## 10. Localization — EN + UK (no Russian)

**Approach:** English is the source of truth. Build Ukrainian as a complete mirror. Implement with a simple `data-i18n` key system or twin `en.json`/`uk.json` consumed by the small JS toggle, with `lang` persisted to `localStorage` and reflected on `<html lang>`. The toggle in nav switches without a page reload. Default language: detect `navigator.language` (uk → Ukrainian, else English).

**SEO:** add `<link rel="alternate" hreflang="en">` and `hreflang="uk">` pointing to the language variants (or `?lang=uk`), plus `x-default` = English.

**UK strings for the legally/operationally critical copy** (landing prose UK can be drafted by you in the same calm register; these must be precise):

Nav / UI:
```
Privacy   → Приватність
Support   → Підтримка
Download  → Завантажити
Coming to the Mac App Store → Незабаром у Mac App Store
EN / UK   → EN / UK
```

Privacy page (UK):
```
GONE Player — Політика приватності
Останнє оновлення: <дата>

GONE Player — застосунок для macOS від Роберта Вагіна (heartbeat).
Ми створили його так, щоб він виконував свою роботу, не потребуючи ваших даних.

ЩО МИ ЗБИРАЄМО
Нічого. GONE Player не збирає, не передає, не зберігає на наших серверах
і не продає жодної персональної інформації. Немає облікових записів,
аналітики, реклами чи сторонніх систем відстеження.

ВАШІ ФАЙЛИ
GONE читає аудіофайли та теки, які ви відкриваєте, на вашому Mac, щоб
відтворювати й аналізувати їх. Ці файли ніколи не залишають ваш пристрій.
Аналіз треку (BPM, форма хвилі), гарячі точки та оцінки існують лише під
час сесії та в локальному кеші на вашому Mac.

МЕРЕЖА
GONE Player не підключається до інтернету. Він повністю офлайн за задумом.

ДОЗВОЛИ
GONE запитує лише доступ до аудіофайлів і тек, які ви самі обираєте,
через стандартне вікно вибору файлів macOS. Він не запитує доступ до
контактів, геолокації, камери, мікрофона чи інших персональних даних.

ТРЕТІ СТОРОНИ
GONE Player побудований повністю на фреймворках Apple і не містить
стороннього коду чи сервісів. Ділитися вашими даними нема з ким, бо
жодних даних не збирається.

ДІТИ
GONE Player — професійний аудіоінструмент, не призначений для дітей.
Він не збирає даних ні від кого.

ЗМІНИ
Якщо ця політика колись зміниться, ми оновимо цю сторінку й дату вгорі.

КОНТАКТ
Питання щодо приватності: <support email>
```

Support FAQ (UK) — translate the ten Q&A from §7 into the same calm register; key headers:
```
Support → Підтримка
Contact → Контакт
What is GONE Player? → Що таке GONE Player?
What does it cost / where do I get it? → Скільки коштує і де завантажити?
What macOS do I need? → Яка версія macOS потрібна?
What audio formats are supported? → Які аудіоформати підтримуються?
Does GONE change or move my files? → Чи змінює GONE мої файли?
Does it sync with Rekordbox / Serato / Spotify? → Чи синхронізується з Rekordbox / Serato / Spotify?
Is BPM detection accurate? → Наскільки точне визначення BPM?
Why does the window slide away? → Чому вікно ховається за край?
Does GONE collect any data? → Чи збирає GONE якісь дані?
I found a bug / want a feature. → Я знайшов помилку / хочу функцію.
```

Hero / key landing lines (UK drafts, refine):
```
The thirty minutes before the set. → Тридцять хвилин до сету.
Drop a folder. Know what fits.     → Кинь теку. Зрозумій, що підходить.
It does the part nobody else respects. → Він робить ту частину, яку інші ігнорують.
```

---

## 11. Do / Don't

**Do**
- Treat the page as a continuation of the app: same dark, same mono numbers, same precision.
- Use the real tooltips and labels — they are honest and already in the product's voice.
- Let sections breathe. Marinate before the XY/FX hook.
- Make every screenshot a clean floating object.
- Keep it fast, offline-clean, and accessible.
- Write UK as a true mirror, no Russian anywhere.

**Don't**
- Don't invent features or overstate (no "sync", no "library", no "AI", no "cloud").
- Don't add a brand color, gradients-as-decoration, stock photos, device mockups, emoji, or exclamation marks.
- Don't put questions in headlines.
- Don't load any external script, font CDN, or tracker — it would contradict the privacy story.
- Don't make Privacy/Support depend on JS to be readable.
- Don't change the `/privacy` or `/support` paths once decided.

---

## 12. Open items for Robert (confirm before final)

1. **Support email** — confirm the real address (placeholder `support@goneplayer.app`; fallback to personal contact until domain is live).
2. **Final domain** — `goneplayer.app` assumed as canonical; if different, change one `BASE_URL` line.
3. **Distribution wording** — Mac App Store vs direct beta DMG for the CTA until the App Store listing is live.
4. **Screenshots** — deliver the nine named assets in §6 at @1x and @2x.
```
