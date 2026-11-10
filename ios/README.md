# Hermes Lens for iPhone

The iPhone companion app for Hermes Lens. It connects Ray-Ban Meta glasses to
your own [Hermes Agent](https://github.com/NousResearch/hermes-agent) server.
You talk to **Luna**, the assistant persona, through the glasses. She can look
through the glasses camera, record a short clip, save a contact from a business
card, and hand tasks to Hermes. Anything that sends a message or takes another
consequential action waits until you tap **Approve** on your phone.

The app talks only to your Hermes server, which needs the `hermes-lens` plugin
from this repository. The server issues a short-lived, locked-down Gemini Live
grant for each call, so no provider API key is ever stored on the phone.

## What the app does

- **Talk to Luna**: a live voice call through the glasses microphone and speakers.
- **Look**: one deliberate picture from the glasses camera per request: a still photo
  when the glasses deliver one within 3 seconds, otherwise the newest frame of the camera
  stream. Luna sees a copy at most 1440 px on its long side. It is never a continuous upload.
- **Record**: a six-second clip saved to the local Library.
- **Save contact**: Luna reads a business card and pre-fills Apple's new-contact sheet. You check it and tap Done.
- **Approvals**: an action Hermes wants to take is shown as a card with Hermes's reason,
  the exact command or action (credentials redacted), and a warning when Hermes's own
  safety check flags it as risky. You approve or decline with a tap, or approve with a
  deliberate double tap on the glasses touchpad once the card has been on screen for at
  least 1.5 seconds. Voice alone never approves anything.
- **Glasses buttons** (on by default, You › Privacy & camera): during a call, press the
  capture button to have Luna look, hold it to record, and double-tap the touchpad to
  mute. This uses the toolkit's input API, which Meta marks experimental. The app also
  answers the toolkit's experimental voice launch ("Hey Meta, start Luna"), which works
  only if voice invocation is turned on for your app in Meta's Wearables Developer Center.
- **Glasses status**: battery, charging, whether the glasses are worn or folded, and
  heat, as the glasses report them. Luna won't try the camera while the glasses are
  folded, off your face or too hot, and says why. The You tab also opens Meta AI's
  update screens and its camera permission.
- **Shortcuts**: Talk to Luna, Look with Luna, End Luna Call and Remember This, for Siri
  and the Action Button.
- **Local Library**: calls, photos, clips, notes and reminders are stored only on this iPhone. Calls and captures are kept for 30 days, notes for a year.

## Requirements

- A Mac with **Xcode 16 or later** (Swift 6, iOS 17.2+ SDK) and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- An iPhone running iOS 17.2 or later. Glasses features do not work in the Simulator.
- **Ray-Ban Meta glasses** paired in the **Meta AI** app, with **Developer Mode**
  turned on: in Meta AI open **Settings › App Info**, tap the **App version** number
  five times, then turn on **Developer Mode**. Developer Mode lets an app you build
  yourself register with your glasses through Meta's Wearables Device Access Toolkit
  without a registered Meta App ID or publishing review. After the first connection
  it is listed under **Settings › App connections › Developer mode apps**. Check that
  your Meta AI app and glasses software meet Meta's
  [version requirements](https://wearables.developer.meta.com/docs/develop/dat/version-dependencies/).
- A **Hermes Agent server with the `hermes-lens` plugin** installed and live voice
  enabled. See the repository root for plugin setup. The phone must be able to
  reach the server over HTTPS.
- An Apple ID signed in to Xcode. A free Personal Team works for building to your own
  phone, but the app then has to be rebuilt every 7 days.

## Build

1. In `project.yml`, set `DEVELOPMENT_TEAM` to your Apple team ID (a 10-character code:
   in Xcode, **Settings › Accounts**, select your team; or the Membership page of your
   Apple Developer account) and
   `HERMES_BUNDLE_ID` to an identifier of your own (for example
   `com.yourname.hermeslens`). This step is required: `com.example.hermeslens`
   is a placeholder that Apple will not sign. Set them here rather than in Xcode's
   Signing tab, because `xcodegen` overwrites the project each time it runs.
2. Generate and open the project:

   ```sh
   cd ios
   xcodegen                      # generates HermesLens.xcodeproj from project.yml
   open HermesLens.xcodeproj
   ```
3. On the iPhone, turn on **Developer Mode** in Settings › Privacy & Security (this is
   iOS's own Developer Mode, separate from the one in Meta AI). Select your phone in
   Xcode and run. The first time, trust your developer certificate on the phone in
   Settings › General › VPN & Device Management.

Settings in `project.yml`:

| Setting | Default | Purpose |
| --- | --- | --- |
| `DEVELOPMENT_TEAM` | empty | Your Apple team ID |
| `HERMES_BUNDLE_ID` | `com.example.hermeslens` | App bundle identifier |
| `HERMES_URL_SCHEME` | `hermeslens` | Return URL scheme for the Meta AI app |
| `META_APP_ID` | `0` | Your Meta App ID, if you registered one. Leave it at `0` when using Developer Mode |
| `HERMES_DEFAULT_BRIDGE_URL` | empty | Optional server address baked into the build |

Command-line checks:

```sh
swift test --package-path Packages/HermesLensCore
xcodebuild -project HermesLens.xcodeproj -scheme HermesLens \
  -destination 'generic/platform=iOS Simulator' build
```

## Pair with your Hermes server

1. On the server, install the `hermes-lens` plugin and set its access token
   (`HERMES_LENS_TOKEN`), following the [plugin's instructions](../README.md#install).
2. Open the app. On the **Pair with Hermes** page, enter the server address (for
   example `https://hermes.example.com`) and the same access token, then tap
   **Save and connect**. You can change both later in **You › Hermes server**.
3. Tap **Set up with Meta AI** to connect the glasses. Meta AI opens, asks you to
   confirm, and returns to the app.
4. Tap **Talk to Luna**.

The token is stored in the iPhone Keychain. Every request sends it as a Bearer
token, together with a per-install `X-Hermes-Device-Id` and an `Idempotency-Key`.
Plain HTTP is accepted only for `localhost` and `127.0.0.1`.
If the server address is a Tailscale name (`…ts.net`), the iPhone must be signed in to the
same tailnet with Tailscale switched on. On the Home screen the app is called **Luna**.

The app uses these plugin routes: `GET health`, `GET v1/lens/config` (live voice
is offered only when `voice.nativeAudioEnabled` is true and
`voice.nativeAudioProtocol` is `luna.native.v2`), `POST`/`DELETE
v1/lens/realtime/calls`, `POST v1/lens/native/tools` and `POST
v1/lens/native/approvals`.

## Demo mode

To try the interface without a server or glasses, tap the version number at the
bottom of the **You** tab seven times. Then turn on **Demo Luna** and **Demo glasses** in the
Developer section.

## Meta Wearables Device Access Toolkit

The glasses integration uses Meta's
[Wearables Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios)
(`MWDATCore`, `MWDATCamera` and `MWDATInputs`, version 1.0.1). Xcode fetches it through Swift
Package Manager when you build. It is **not bundled** in this repository, and
your use of it is governed by Meta's own license and developer terms, not by
this project's MIT license. The app opts out of the toolkit's analytics and
crash reporting in `Info.plist`.

## Privacy

- Photos, clips, notes, reminders and call records stay on the phone unless you
  share them. A frame leaves the phone only when Luna looks during a call. It
  goes to the live model as part of that call.
- What you say is shown on screen during a call. It is never logged, and only
  the conversation text is saved to the local call record.
- The camera runs only when you ask Luna to look or record, or tap Look. Home
  shows **Camera on** while it is active.
- Face recognition is never used.
- The app registers for no remote push. Reminders are local notifications.

## Layout

- `HermesLensApp/`: the SwiftUI app (Home, calls, glasses, Library, Tasks, You, onboarding).
- `docs/LUNA_BRAND.md`: Luna's character, colours, components and UI rules.
- `Packages/HermesLensCore/`: the wire contract, HTTP client and tests.
- `HermesLensTests/`, `HermesLensUITests/`: app unit and UI tests. UI tests run in demo mode.
