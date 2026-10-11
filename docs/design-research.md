# Vox v3: design research and decisions

The goal was a UI people screenshot and share on X, that never feels heavy. The posts below were read on X on 2026-10-10. Engagement is as shown on each post when it was read.

## What travels on X, and what Vox took from it

| Post | Reach | Takeaway | Applied in Vox |
|---|---|---|---|
| [Edward Luo: an app that runs Claude Code, Codex, Cursor… in the Mac notch ("Agent finishes → notch pops")](https://x.com/edwardluox/status/2078111197212414447) | 928.8K views · 6K likes · 5K bookmarks | The notch is the most-shared Mac UI surface right now. "Pops" means short, purposeful motion tied to an event. | All recording UI lives in a black island that grows out of the notch, with springs at most 0.38 s and no bounce. It pops only on events: start, done, error. It is never animated at rest. |
| [Dhilip Subramanian: 6 months on Wispr Flow (44,414 words, 161 wpm), switched to FluidVoice, which "corrects as I speak"](https://x.com/sdhilip/status/2069140867466797200) | 1.8M views · 6K likes · 16K bookmarks | The viral hook is seeing your words while you speak. Personal stats (words, wpm) are what people post. | Live transcript in the notch: committed text solid, the words still being recognized italic at 45 %. Home shows words, pace, streak and minutes saved, and "Share stats" makes a 1200×630 monochrome card. |
| [Emil Kowalski: "one font size, monochrome colors… limit the amount of design mistakes"](https://x.com/emilkowalski/status/2072301069271552363) | 284.8K views · 2K likes | Restraint reads as premium: monochrome plus content-first. | Pure ink palette (one ink at four opacities), hairlines instead of shadows, SF Pro with engraved mono captions. Red appears only for errors. No orange and green. |
| [Emil Kowalski: Linear intro animation, "a 4px blur, Y transform, and a subtle stagger"](https://x.com/emilkowalski/status/1987892934587412676) | 73.8K views · 1K likes | The entrance recipe people copy. | Onboarding steps and first appearances use opacity, scale 0.96, y +6 pt and a 4 px blur. The blur is used only on these one-time entrances, never on frequent surfaces, because blur costs CPU. |
| [Monologue launch (Every)](https://x.com/danshipper/status/1967968084540453371) | 268.1K views | Pitched on smart formatting per app, a personal dictionary, and local models. | Styles per app group, a dictionary that learns from your corrections, and fully local models. |
| [Aqua Voice for iOS](https://x.com/aquavoice/status/2042105774449795182) | 1.9M views | "Premium voice keyboard": craft and speed sell dictation. | Release-to-text is ≈0.85 s even on a 75 s monologue, and the overlay stays instant. |
| [Kartik: built "betterwispr" because Wispr became unusable](https://x.com/code_kartik/status/2108219601469550720) | 17.6K views | Wispr users churn over price and reliability, and want native, light, free alternatives. | Native SwiftUI, idle at 0.00 % CPU and 65 MB, free, and no account. |

### Second pass: motion principles, notch apps, and dictation competitors (read 2026-10-10, evening)

Frames from the video posts were examined frame by frame.

| Post | Reach | Takeaway | Applied in Vox |
|---|---|---|---|
| [Emil Kowalski: `/apple-design`, 17 design and motion principles distilled from WWDC talks](https://x.com/emilkowalski/status/2075188252877672732) | 2.0M views · 13K likes · 22.7K bookmarks | Critically damped springs by default; enter and exit along the same path; sound and visuals on the same frame; Reduce Motion means a cross-fade, not nothing; size-specific tracking; feedback has four kinds (status, completion, warning, error). | Audited against all of these, see the checklist below. |
| [Emil Kowalski: animating from `scale(0)` feels off, start at 0.93 or higher](https://x.com/emilkowalski/status/1954891053032755560) · [keep animations fast, ease-out](https://x.com/emilkowalski/status/1949870041819730389) | 123K · 102K views | Gentle entrances, snappy user-initiated motion. | Entrances start at scale 0.96. Every UI motion is 0.45 s or less, with ease-out or critically damped springs. |
| [Droppy: "the best Dynamic Island out there"](https://x.com/Droppyformac/status/2107416617940291587) | 742K views | A pure black notch pill with HUDs hanging off it. The launch video gives one short headline per scene ("Drop it in the notch.", "Live Activities.") over the real UI on a wallpaper. | Vox's island is the same pure black pill. The docs renders and share card follow the one-headline-per-feature recipe. |
| [Aside: "100% local" dictation replacing Wispr Flow](https://x.com/dominikmartn/status/2099857235539284362) | 173K views · 2.5K bookmarks | Black capsule states: a dot plus bars (recording), ✕ bars ✓ (hands-free), and the result text with a copy button. | Hands-free (double-tap) now shows engraved keycaps in the island, "esc cancel" and "fn done". The copied-to-clipboard fallback was already there. |
| [Google's free, local dictation app (Gemma 4)](https://x.com/Saboo_Shubham_/status/2061846522397089968) | 367K views · 2.7K bookmarks | Makes the AI's work visible by marking the filler words it removed. | History → **Changes**: a word diff with removed words struck through. It is computed only when opened. |
| [MKBHD: Liquid Glass and recent design elements "have felt sloppy"; wants an update about fine details](https://x.com/MKBHD/status/2064034468005073147) | 966K views · 18.6K likes | People reward polish over effects. | No glass or blur on live surfaces. The island is solid black and the app uses hairlines. Effort went into alignment, tracking and timing. |
| [Meta AI for Mac: "Just hold down fn and yap"](https://x.com/spencerbarnett/status/2090164939105476969) · [Stream: universal push-to-talk dictation](https://x.com/minafahmi/status/2077794603286044840) | 366K · 580K views | Hold fn is now the standard gesture. Dictation is becoming a built-in feature everywhere. | fn is the default trigger. Vox's wedge is free, local and live. |
| [Wispr Flow's creator-ads engine, $0 to $2B](https://x.com/irabukht/status/2108585781581217906) · ["Feature, not a product"](https://x.com/awilkinson/status/2089799535686295762) | 226K views · 5.4K bookmarks · 374K views | Wispr Flow grows through short creator clips, while the category is commoditizing. | The share card and the notch clip are the things worth filming. Free and local is the pitch. |
| [Eli Guerron (ex-Apple): OS micro-interactions](https://x.com/eliguerron/status/2052638041421058160) | 532K views | Small, purposeful details travel. | Numeric-text "+42" on done, and the menu bar glyph changing only on state changes. |

**Apple-principles checklist (from `/apple-design`):**
- **Response.** Recording starts on key-down with no delay. The island appears 0.18 s later, a deliberate trade-off so ⌘-shortcuts never flash it.
- **Springs.** The island opens with response 0.38 and damping 0.86 (≈0.5 % overshoot, only on the event "pop"), and closes critically damped (0.28 / 1.0).
- **Spatial consistency.** The island grows out of the notch and returns into it.
- **Harmony.** The start chime and the island appear in the same run-loop turn.
- **Reduce Motion.** The island cross-fades in 0.15 s, and illustrations show their final frame.
- **Typography.** −0.8 tracking at 34 pt, +0.8 for 10 pt mono captions, and monospaced digits.
- **Four feedback kinds.** Status: dot, ring or stepping dots. Completion: ✓ +N. Warning: hands-free hint. Error: a shake, and red, the only color.
- **Craft.** Renders are checked at 2× in both light and dark (`--render-ui`).

The owner's own taste, from [Tutto](../../XCode/Tutto) and CornerClick, is monochrome, flat, hairlines, no glows, an "instrument" feel, and color only as an event. Vox uses the same tokens and components (`Components.swift`), so the apps read as one family.

## Visual system
- **Ink:** `.primary` at 100 / 80 / 62 / 40 %. Hairline 12 %, wash 5.5 %. The canvas is off-black or off-white, never pure. The notch island is always pure `#000`, so it blends into the hardware.
- **Type:** SF Pro, with 10 pt uppercase SF Mono captions at +0.8 tracking (engraved labels). All numbers use `.monospacedDigit()`.
- **State is shape, not color:** a solid dot means listening, a lock means hands-free, a wand means command, three stepping dots mean finishing, and a check plus "+42" means done. Red is reserved for errors.
- **Icon:** a Liquid Glass Icon Composer icon (`Resources/AppIcon.icon`) on a graphite gradient squircle, with one bright element. Four glass voice bars brighten toward a pure-white text caret: what you say becomes text at your cursor. The same mark (`VoxMark`) heads the share card.

## Performance rules (measured, not assumed)
- **Nothing runs at idle:** no timers, no `TimelineView`, no `repeatForever`. The menu bar icon changes only on state changes. Measured: 0.00 % CPU, 0.1 wakeups/s and 65 MB at idle.
- **Separate models for separate update rates.** The 15 Hz meter has its own model and only redraws when its quantized picture changes. The transcript updates about once a second. So no single change re-renders the whole island.
- **Illustrations play once, then rest.** Click replays them, and Reduce Motion shows the final frame.
- **No blur or glass on surfaces that change.** A 4 px blur is allowed only on one-time entrances.
