# Docent

An art museum companion for iPhone. Photograph an artwork, confirm what it is, then talk with a guide about its history out loud.

1. **Photograph** the piece (or pick a photo), optionally typing its title.
2. **Confirm**: Claude identifies the work and says how sure it is (confident match, likely match, best guess, or not identified) with a short reason and other candidates. You can correct any detail before continuing.
3. **Talk**: tap the mic, ask a question, tap again to send. The answer streams in as text and is read aloud. Typing works too.
4. **Export** the conversation as a Markdown file from the share button.

Docent uses **your own Claude API key**. It is stored in the device Keychain and sent only to `api.anthropic.com`; usage is billed to your Anthropic account. There is no Docent server.

## Build and run

Needs a Mac with Xcode 15.3 or later (iOS 17 SDK). The Xcode project is generated from `project.yml`:

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
