# herdr-voice-client-ios: design

Status on 2026-11-23: a first version is installed on an iPhone 16 Pro; pairing and a spoken turn
have been seen working, the rest is untested (see `README.md`). This is a scratch surface:
decisions marked "agent's choice" are open to change.

## What it is

A native iPhone client for the existing herdr-voice server. The server is the brain and is not
changed. The app follows the CardputerZero client's shape (thin client, same endpoints) and the Mac
app's speech arrangement (speech done on the device, server asked for no audio).

Why native when the phone page exists: the page stops working after switching apps and coming back
(herdr-voice `TODO.md`, Bugs), needs the page open and the screen on, and sends every clip to the
Mac and back for speech.

## How one turn works

1. Hold the button: the microphone is recorded as 16 kHz mono samples in memory (two minutes at most).
2. While holding, the clip so far is transcribed on the phone again and again (every 0.7 s at
   first, then a fifth of the clip's length), so words appear as you talk.
3. Release: the whole clip is transcribed on the phone. No `/api/hear`.
4. The words go to the session: `POST /api/say?t=<session>&spoken=1&audio=0`.
5. The reply text is shown and spoken. While the session works: `POST /api/collect?...&audio=0`.
6. A permission prompt shows a card with Allow and Deny (`POST /api/answer`), then collecting goes on.
7. In the background of the app: long-poll `GET /api/announcements?...&audio=0`.

`audio=0` is the server's existing switch for a client that voices replies itself (the Mac app uses
it). With the "Mac's voice" setting the app leaves it off and plays the server's clip.

## Decided

- **Speech-to-text on the phone, Parakeet through FluidAudio 0.18.3** (owner's call, 2026-11-23:
  do speech on the client to make it snappier). Same engine and version as the Mac app.
- **Three voices, a setting** (agent's choice, 2026-11-23): the iPhone's built-in voice (default),
  the Mac's voice as a clip from the server, and Kokoro on the phone marked experimental.
  Reason: FluidAudio 0.18.3 flags Kokoro as crash-prone on iOS 26.4 and later, iOS 27 included
  (its `KokoroAneManager.osAdvisory`, upstream issue 889), and the crash cannot be caught in the app.
- **Pairing by QR, key in the Keychain.** Same one-time code as the phone page; the certificate
  authority is fetched from the server's plain-HTTP side door and pinned in the app, so nothing is
  installed in iOS's trust settings.
- **Runs on the phone directly, no simulator.** The speech models need the real hardware anyway.
- **Talking pauses a reply; answering the session that was speaking drops the rest of it**, as in
  the Mac app. This also keeps the app's own voice out of the microphone.

- **One voice at a time, and an inbox** (owner's call, 2026-11-23: voices from several agents
  talking over each other were confusing; wanted a page showing who said something, where opening
  one plays what was missed). Only the session open on screen speaks. Anything another session says
  is added to its conversation as unread and counted in the inbox. Opening a session plays its
  unread lines in order; a line counts as heard when it starts playing. Leaving a session stops the
  voice, and what had not started stays unread.
- **Play again by tapping a line.** Possible because the voice is made on the phone. With the
  "Mac's voice" setting a replayed line uses the iPhone voice, since the server's clip is not kept.
- **What was missed while the app was closed comes from the server's history, with no server
  change.** History marks an agent speaking up unasked with a `from` field; replies to a turn do not
  have it. So at launch each session's history is read once, and an unasked line newer than the
  last thing played on this phone (a time kept per session on the phone) is unread. Replies to turns
  asked from another device are not counted: they were heard there. A session seen for the first
  time starts with nothing unread.
- **The "agents can speak up" switch is gone**: the inbox replaces it.

## Rejected

- Naming the session before each line ("From <name>. ...") and letting every session speak: that
  was the first build, and it is what the inbox replaced.
- Sending clips to the server for speech (`/api/hear`), as the page and the Cardputer do: the round
  trip is what on-device speech removes.
- Kokoro on the phone as the default voice: see the crash flag above.

## Not built (second version)

- Playing anything once the screen locks (seen 2026-11-23: it goes quiet). iOS suspends the app
  seconds after the lock unless sound is already playing. See open question 4.

- Talking from the Action Button: the app offers a Talk action to assign there. iOS reports a press,
  not a hold and release, so it becomes press to start, then press again or a pause in speech to send.
- Hearing a reply after the app has been closed. That needs push notifications, which free signing
  does not include.
- Apple's own speech-to-text as an alternative to Parakeet (no download, built-in live words).

## Open questions

1. Settled 2026-11-23: the certificate is fetched over a plain socket (Network framework), not a
   web request. The first build used a web request and pairing failed with "can't reach the
   server"; the cause was not pinned down (iOS's plain-HTTP block or the local-network permission
   question), and the socket build paired on the next try.
2. How fast Parakeet is on the phone, and whether re-transcribing the growing clip keeps up.
   One sentence has gone through so far; "From iOS" may have been heard as "Floor IoS".
3. Which voice is the right default once all three have been heard side by side.
4. What happens to a turn in flight when the screen locks. Background audio is switched on, which
   keeps the app alive only while something is playing.
5. Bluetooth headsets: output works through them, the microphone is always the phone's.
6. A reply to a turn asked from this phone, not yet played when the app is closed, is not unread
   at the next launch (only unasked lines are found in history). Whether that matters in use.
7. Lines the Mac said aloud while the phone was away also show as missed here; the server does not
   record which device played a line. Swipe a session to mark it heard.
