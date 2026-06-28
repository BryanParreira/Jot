<p align="center">
  <img height="120" alt="Scribe logo" src="scribe/Scribe/Assets.xcassets/AppIcon.appiconset/256.png" />
</p>

<h1 align="center">Scribe</h1>

<p align="center"><em>On-device AI autocomplete for macOS. Free. Private. Fast.</em></p>

---

## What it does

Scribe watches wherever you type across macOS — Notes, Mail, Messages, Chrome, VS Code, Slack, and more — and shows AI-powered ghost-text completions inline. Press **Tab** to accept. No cloud. No API key. Runs the model locally via llama.cpp, completely on your machine.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon or Intel Mac
- A GGUF model file (recommended: `gemma-4-E2B-i1-Q4_K_M.gguf`)
- ~4 GB RAM free for the 2B model

## Setup

1. Open `scribe/Scribe.xcodeproj` in Xcode
2. Select the **Scribe Dev** scheme and run (`⌘R`)
3. Grant Accessibility permission when prompted
4. Go to **Settings → AI → Import Model** and select your `.gguf` file
5. Start typing anywhere — ghost text appears after a short pause, press **Tab** to accept

## Model

Scribe is optimized for **Gemma 4 E2B** base models (2B parameters). Recommended quant:

```
gemma-4-E2B-i1-Q4_K_M.gguf
```

Any GGUF base model works — import via Settings and Scribe picks it up automatically.

## Build from source

```bash
git clone https://github.com/BryanParreira/Scribe.git
cd Scribe/scribe

# Create your signing config (replace XXXXXXXXXX with your Apple Team ID)
cat > Config/Signing.local.xcconfig << 'EOF'
DEVELOPMENT_TEAM = XXXXXXXXXX
SCRIBE_DEV_BUNDLE_ID = com.yourname.scribe.dev
EOF

open Scribe.xcodeproj
```

Select **Scribe Dev** scheme → Product → Run.

## Features

| Feature | Description |
|---------|-------------|
| **Ghost text** | Inline suggestion rendered near your cursor in any app |
| **Tab to accept** | Full suggestion inserted instantly |
| **Shift+Tab** | Accept one word at a time |
| **Works everywhere** | Notes, Mail, Chrome, VS Code, Slack, Terminal, and more |
| **Emoji shortcodes** | Type `:roc` → suggests 🚀, Tab to insert |
| **Inline commands** | Trigger rewrite/translate/fix directly in any text field |
| **Macros** | Custom text expansion shortcuts |
| **Clipboard context** | Recent clipboard content influences suggestions |
| **Personalization** | Learns vocabulary and style from accepted completions |
| **Per-app settings** | Different instructions per application |
| **Fast Mode** | Shorter, faster completions for quick typing |
| **Apple Intelligence** | Optional Apple Foundation Models engine |
| **100% local** | llama.cpp runs in-process — no server, no internet required |

## Keyboard shortcuts

| Key | Action |
|-----|--------|
| **Tab** | Accept full suggestion |
| **Shift+Tab** | Accept next word |
| **Escape** | Dismiss suggestion |
| Any other key | Dismiss and re-trigger after pause |

## Privacy

- All inference runs locally via llama.cpp — nothing leaves your machine
- No analytics, no telemetry, no accounts, no API keys
- Accessibility API used read-only except when inserting accepted text
- Writing history stored in `UserDefaults` — clearable in Settings → Personalization

## Architecture

```
scribe/
├── Scribe.xcodeproj
└── Scribe/
    ├── App/            — lifecycle, coordinators, dependency wiring
    ├── Services/
    │   ├── Runtime/    — llama.cpp engine, model loading (LlamaRuntimeCore)
    │   ├── Accessibility/ — AX focus tracking, caret geometry
    │   ├── Visual/     — screenshot capture, OCR context
    │   └── Suggestion/ — prompt routing, post-processing
    ├── Models/         — value types, state machines, settings
    ├── UI/             — Settings, onboarding, ghost-text overlay, menu bar
    └── Support/        — pure helpers, logging, device info
```

## License

AGPL-3.0 — see [LICENSE](scribe/LICENSE).
