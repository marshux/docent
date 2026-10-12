# Docent

An art museum companion for iPhone. Photograph an artwork, confirm what it is, then talk with a guide about its history out loud.

1. **Photograph** the piece (or pick a photo), optionally typing its title.
2. **Confirm**: Claude identifies the work and says how sure it is (confident match, likely match, best guess, or not identified) with a short reason and other candidates. You can correct any detail before continuing.
3. **Talk**: tap the mic, ask a question, tap again to send. The answer streams in as text and is read aloud. Typing works too.
4. **Export** the conversation as a Markdown file from the share button.

Docent uses **your own Claude API key**. It is stored in the device Keychain and sent only to `api.anthropic.com`; usage is billed to your Anthropic account. There is no Docent server.

## Status and findings

Early prototype. What has and hasn't been checked so far:

| | iPhone app | Web version |
|---|---|---|
| Compiles | Yes, on GitHub's macOS runners (Xcode 26) | Yes (TypeScript, strict) |
| Automated tests | 12 unit tests pass: response parsing, sentence splitting, request building, transcript export | Full flow run in a headless phone-sized browser against a faked Claude API |
| Real Claude calls | Not yet | Not yet |
| Run on a real phone | Not yet | Not yet |

So the plumbing is verified and the experience is not: nobody has yet pointed it at a real painting with a real API key.

What building it has shown so far:

- **An iPhone app can be built without a Mac.** The whole project was written on Windows/Linux; GitHub Actions' macOS runners compile and test it on every push. Getting it onto a phone still needs either sideloading or TestFlight.
- **Voice is the weak link, not the model.** Claude only handles text, so speech in and out comes from the platform (Apple's speech frameworks, or the browser's Web Speech API). Those are free and need no second key, but sound robotic and are turn-based. Dedicated speech services, or a speech-to-speech model, are the obvious next upgrade.
- **Identification needs an honest "how sure are you".** Asking for a fixed JSON shape with a `high` / `medium` / `low` confidence and a reason, then letting the visitor correct it, is what keeps a wrong guess from turning into a confident wrong history lesson. The guide is also told how sure the identification was.
- **Spoken answers need different writing.** The guide is instructed to answer in a few plain sentences with no lists or formatting, and replies are split into sentences so speech can start before the full answer has arrived.
- **A browser can call Claude directly** with the visitor's own key, so the web version needs no server. That is fine for a personal prototype and not for a public product, where the key would have to move behind a backend.

## Web version

`web/` is the same flow as a web page, for trying the idea on any phone or computer without installing anything: https://marshux.github.io/docent/

It uses the browser's own speech recognition and speech synthesis, and a photo upload (on a phone, the file picker offers the camera). Voice input needs Chrome, Edge or Safari; other browsers fall back to typing. Your API key is kept in that browser's storage. It is a TypeScript + Vite app using the official `@anthropic-ai/sdk`, deployed to GitHub Pages on every push that touches `web/`.

```bash
cd web && npm install && npm run dev
```

## Build and run (iPhone app)

Every push is built and unit-tested on a macOS runner by GitHub Actions (`.github/workflows/build.yml`), so no Mac is needed to check that it compiles.

To build it yourself you need a Mac with Xcode 26 or later. The Xcode project is generated from `project.yml`:

```bash
brew install xcodegen
xcodegen generate
open Docent.xcodeproj
```

In Xcode, pick your team under Signing & Capabilities, then run on an iPhone. The simulator has no camera, so there you can only choose from the photo library. Tests: `Cmd-U`.

On first launch, paste a Claude API key from https://console.anthropic.com.

## How it works

| File | Role |
|---|---|
| `Docent/App/AppModel.swift` | All app state and the capture → confirm → conversation flow |
| `Docent/Services/ClaudeClient.swift` | Claude Messages API over raw HTTPS: image identification with a JSON schema, and streamed chat replies |
| `Docent/Services/Speech.swift` | Speech-to-text (Apple Speech framework) and text-to-speech (AVSpeechSynthesizer), spoken sentence by sentence as the reply streams |
| `Docent/Services/Support.swift` | Keychain storage, photo downscaling, transcript export |
| `Docent/Views/` | SwiftUI screens |

Notes on the Claude calls:

- **Identification** is one request with the photo and a structured-output schema, so the reply is always valid JSON with a `confidence` of `high`, `medium` or `low`.
- **Conversation** resends the photo and history each turn (the API is stateless) with prompt caching on, and tells the guide how certain the identification was so it can hedge when it should.
- Default model is Claude Opus 5.5; Sonnet 5.5 and Haiku 5.5 can be chosen in Settings.
- Voice is Apple's on-device speech, not Claude: Claude only ever sees and returns text.

## Not done yet

- Conversations are not saved between launches; export before starting a new artwork.
- Push-to-talk only (no hands-free "it noticed I stopped speaking").
- English-first: speech uses the device language, but the prompts are written in English.
- The API key lives on the device. Fine for personal use; a public release should move calls behind a server.
