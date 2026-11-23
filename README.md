# herdr-voice-client-ios

A hold-to-talk iPhone app for [herdr-voice](https://github.com/TheRealHaoLiu/herdr-voice-server): pick an
agent session, hold the button, talk, hear the reply. It talks to the herdr-voice server the same
way the phone page and the CardputerZero client do, so the server needs no change. Unlike the page,
it turns speech into text on the phone, and by default speaks replies with the phone's own voice.

Status (2026-11-23): first version, built with Xcode 27.2 and installed on an iPhone 16 Pro.
Seen working there: pairing, hold-to-talk with speech turned into text on the phone, and the words
reaching an agent session. Not yet checked by anyone: the three voices side by side, Allow and
Deny, Stop, Send now, announcements, and what happens when the screen locks. Design and reasons:
`DESIGN.md`.

## What it does

- Pairs by scanning the code from the Mac app's "Connect a Phone" window (or a pasted pairing link).
- Lists agent sessions by machine, with each one's state.
- Hold to talk, with the words appearing while you speak.
- Shows the reply and says it. Three voices to choose from in Settings.
- Allow and Deny for permission prompts; Stop; Send now; a line for typing (slash commands too).
- Agents that speak up by themselves are heard, named first.

## What you need

- A running herdr-voice server in `network` mode, reachable from the phone. If the server has an
  `allow` rule, it must admit the phone's address.
- An iPhone on iOS 18 or later. The speech model (Parakeet, through FluidAudio) downloads on first
  launch.
- Xcode 27 and an Apple ID added to it (Xcode, Settings, Accounts). A free Apple ID signs the app
  for 7 days at a time.

## Build and run

Copy `Local.xcconfig.example` to `Local.xcconfig` and put in your team ID and a bundle identifier
of your own (git ignores that file). Then open `HerdrVoice.xcodeproj`, select your iPhone and press
Run. The phone needs Developer Mode on (Settings, Privacy & Security), and the first time you must
trust your developer certificate on it (Settings, General, VPN & Device Management).

Compile check without signing:

    xcodebuild -project HerdrVoice.xcodeproj -scheme HerdrVoice -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

## Layout

- `HerdrVoice/API.swift`: the server calls, pairing, and where the key is kept (Keychain).
- `HerdrVoice/Speech.swift`: speech-to-text, the microphone, and the three ways a reply is spoken.
- `HerdrVoice/Model.swift`: what a hold, a typed line or a tap sets off.
- `HerdrVoice/Views.swift`: the screens.
- `Info.plist`: the two settings Xcode cannot generate (local plain-HTTP for pairing, background audio).
- `Config.xcconfig`, `Local.xcconfig.example`: signing settings (see Build and run).
- `tools/icon.swift`: draws the app icon (`swift tools/icon.swift <out.png>`).

## Licence

Apache-2.0, see `LICENSE`. Copyright 2026 Hao Liu.

The app uses [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) and downloads
its speech models on the phone: Parakeet TDT 0.6B v3 for speech-to-text on first launch, and Kokoro
for text-to-speech only if you choose that voice. The models are not part of this repository and
carry their own licences; see their model cards.
