# Luna brand and UI

The source of truth for the Hermes Lens iPhone UI. Where this document and the code
differ, the code wins.

## Luna, the character

- A soft lime pebble with a small face, drawn in SwiftUI `Canvas`:
  `HermesLensApp/Components/LunaCharacter.swift`. There are no image assets, so she
  stays crisp from 40 pt (tab bar) to 220 pt (Home).
- Nine moods (`LunaMood`), each a distinct pose that reads without colour or motion:
  ready, connecting, listening, thinking, looking, speaking, needs your OK, didn't
  work, offline. Props make them unambiguous: sound arcs (listening), thought dots
  (thinking), a sparkle (looking), a held approval card (needs your OK), a sweat drop
  (didn't work), "z z" (offline).
- Every mood comes from real state (`LunaMood(call:isReconnecting:isOffline:)` in
  `LunaTabBar.swift`), never decoration. A failed or offline state replaces Ready at once.
- Motion: breathing, blinks, lean, wobble, bounce. It stops with Reduce Motion or in
  the background, and every still pose is complete on its own.
- `LunaCharacter.swift` has no UIKit dependency, so it can be rendered on a Mac with
  `ImageRenderer` (pass `previewTime:` for a fixed pose) to review the drawing.
- The app icon (`Luna.png`, `LunaDark.png` and `LunaTinted.png` in
  `Assets.xcassets/AppIcon.appiconset/`) is a separate
  illustration, not rendered from `LunaCharacter`.

## Colour, type, metrics

All of these live in `HermesLensApp/Components/LunaTheme.swift`. Views use roles, never raw colours.

| Role | Light | Dark | Use |
|---|---|---|---|
| background | #F4F4EF | #10120F | screen ground |
| surface | #FFFFFF | #1C201A | cards, rows, tab bar |
| raised | #E9EBE3 | #2A3025 | pucks, secondary pills |
| emphasis | #181C17 | #050705 | "Needs your OK", next reminder, undo |
| text / secondaryText | #181C17 / #5A6254 | #F6F7EF / #AFB8A5 | |
| lime | #D4F53C | #D4F53C | **fill only**: main action, live, highlights |
| onLime | #181C17 | #181C17 | text on lime, **never white** |
| accent | #4B6A00 | #D4F53C | readable accent for text and icons |
| success / warning / danger | #32623C / #735200 / #A43432 | #ACD4AD / #E9C77B / #FFADA5 | meaning, not decoration |

- Type: SF Pro, Dynamic Type styles only. `lunaDisplay` (largeTitle bold) for greetings
  and titles. `lunaLine` (New York serif, title2) only for Luna's own status line.
- Metrics (`LunaMetrics`): 20 pt gutter, 12 pt card gap, 20 pt card padding, 30 pt card
  radius, 22 pt row radius, 56 pt pills.
- The launch screen and `AccentColor` use the same background and accent values.

## Components

All in `HermesLensApp/Components/LunaComponents.swift`:

| Component | What it is |
|---|---|
| `LunaPrimaryButton` | The 56 pt pill with an icon puck; lime or dark |
| `LunaLimeCapsuleStyle` | The one action on a card (Approve, Review & Save) |
| `LunaSecondaryActionStyle` | Raised capsule |
| `LunaQuickActionButton` | 60 pt puck with a short label |
| `LunaStatusPill` | Status capsule, e.g. "Glasses ready · 78%" |
| `LunaErrorBanner` | A plain problem plus its one fix |
| `LunaEmptyState` | Small Luna, a title, a sentence, one action |
| `LunaFilterChips` | Lime-selected pills |
| `lunaCard` / `lunaRow` / `lunaEmphasisCard` / `lunaPageChrome` / `lunaFormChrome` | Surfaces |

## Structure

- Floating pill tab bar: **Home · Library · [Talk] · Tasks · You** (`LunaTabBar.swift`).
  Talk is an action, not a tab. The centre Luna shows the live call's mood and returns to it.
- Home: greeting, the glasses pill (live battery, worn, folded, heat), Luna and her
  line, the Talk pill, a bento (latest photo, things due today, next reminder), five
  quick actions (Look, Photo, Video, Note, Remind) and today's calls and note. When no
  Hermes server is set up, a banner links to it. The call happens on Home: Luna moves up,
  and the call takes the bento's place.
- Library: a photo grid per day, cards for calls and notes, and lime filters. Reminders
  live in Tasks. Everything in the Library is stored only on this iPhone.
- Tasks: Waiting for you · Reminders · Handed off. Waiting for you shows the live call's
  approval card (with the exact action and Hermes's risk flag) or contact card. Handed
  off shows only real data: actions approved or declined in calls. The Hermes agent
  reports results on its own home channel.
- You: Luna's status, the Hermes server (address and token), glasses (model, battery,
  worn, heat, updates, camera permission), privacy and camera, notifications for
  reminders, your data, about. A hidden Developer section (tap the version seven times)
  holds demo modes and hardware diagnostics.

## Rules

- No model, provider, route or harness names in the UI (for example Gemini or a tool
  name). "Hermes" appears only where the user sets up or reads about their own server,
  and on the approval card's risk flag.
- Truthful states only: no "Ready" over a failure, no fake progress, no sample content
  presented as real. Features the server does not provide are left out, not faked.
- Contrast at least 4.5:1, touch targets at least 44 pt, Dynamic Type, VoiceOver labels,
  Reduce Motion and Reduce Transparency.
- Approvals stay explicit: a tap on Approve, or a deliberate glasses double tap while the
  card has been showing for at least 1.5 s. Voice alone never approves.
- Check every UI change with screenshots in light and dark, on a real iPhone for anything
  that touches the glasses.
