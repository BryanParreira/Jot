# Jot

Native macOS menubar app that provides inline AI text completions system-wide, using a local [Ollama](https://ollama.com) model. No cloud, no accounts, no telemetry.

Works in any text field: TextEdit, Safari, Mail, Notes, Slack, VS Code, and more.

## How It Works

1. You type — Jot reads the text before your cursor via the Accessibility API
2. After a brief pause, it sends context to your local Ollama model
3. A ghost text suggestion appears to the right of your cursor
4. Press **Tab** to accept, **Shift+Tab** to accept one word, **Escape** to dismiss

Everything runs on your Mac. No internet required after setup.

## Prerequisites

### 1. Install Ollama

```bash
# Download from https://ollama.com or via Homebrew:
brew install ollama
ollama serve  # Keep this running in the background
```

### 2. Pull a Model

| RAM | Recommended Model | Notes |
|-----|-------------------|-------|
| 8 GB | `qwen2.5:1.5b` | Fast, surprisingly capable |
| 16 GB | `phi3.5:mini` or `qwen2.5:3b` | Best quality/speed balance |
| 32 GB+ | `qwen2.5:7b` or `mistral:7b` | Near-perfect completions |

```bash
ollama pull qwen2.5:1.5b   # Recommended for most Macs
```

### 3. Grant Accessibility Access

On first launch, Jot will prompt you. Go to:
**System Settings → Privacy & Security → Accessibility → Enable Jot**

## Build & Run

### Open in Xcode

```bash
open /path/to/Jot.xcodeproj
```

Set your development team in the target's Signing & Capabilities, then Build & Run (`⌘R`).

### CLI Build

```bash
xcodebuild -scheme Jot -configuration Release -derivedDataPath build
open build/Build/Products/Release/Jot.app
```

Requirements: Xcode 15+, macOS 14+ SDK, Apple Silicon or Intel.

## Features

| Feature | Description |
|---------|-------------|
| **Ghost text** | Inline suggestion rendered near your cursor |
| **Tab to accept** | Full suggestion inserted at cursor |
| **Shift+Tab** | Accept one word at a time |
| **Emoji shortcodes** | Type `:roc` → suggest 🚀, Tab to insert |
| **Typo correction** | Detects misspelled words, suggests fix as ghost text |
| **Mid-line completion** | Fill-in-the-middle when cursor is not at end |
| **Clipboard context** | Recently copied text influences suggestions |
| **Personalization** | Learns your vocabulary and style from accepted completions |
| **Per-app settings** | Different instructions per application |
| **App blocklist** | Password managers and auth prompts are always suppressed |
| **Debug logging** | All prompts/responses logged to `~/Library/Logs/Jot/debug.log` |

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| **Tab** | Accept full suggestion |
| **Shift+Tab** | Accept next word |
| **Escape** | Dismiss suggestion |
| Any other key | Dismiss + re-trigger after delay |

## Privacy

- All inference runs locally via Ollama — no data leaves your machine
- No analytics, no telemetry, no accounts
- Accessibility API is used read-only except when inserting accepted text
- Writing history (for personalization) stored in `UserDefaults` — clearable in Settings → Personalization

## Architecture

```
Jot.app
├── AppDelegate.swift              # Lifecycle, permission flow, wiring
├── Core/
│   ├── AccessibilityManager.swift # AXUIElement: read text, insert text, cursor rect
│   ├── EventTapManager.swift      # CGEventTap: intercept Tab/Escape globally
│   ├── OllamaClient.swift         # HTTP actor for /api/generate + /api/tags
│   ├── ContextBuilder.swift       # Assembles system prompt + user message
│   ├── CompletionEngine.swift     # State machine: idle→debouncing→requesting→shown
│   ├── DebounceTimer.swift        # Cancellable debounce utility
│   └── DebugLogger.swift          # Optional file logging
├── Features/
│   ├── EmojiProvider.swift        # :shortcode: → emoji matching
│   ├── TypoDetector.swift         # NSSpellChecker-based typo detection
│   ├── PersonalizationStore.swift # Rolling history, vocabulary frequency map
│   ├── ClipboardMonitor.swift     # Polls NSPasteboard every 2s
│   └── MidLineCompletion.swift    # Fill-in-the-middle helpers
├── UI/
│   ├── SuggestionOverlay.swift    # Transparent floating NSWindow ghost text
│   ├── MenuBarController.swift    # NSStatusItem + dropdown menu
│   ├── SettingsWindowController.swift # 5-tab preferences window
│   └── OnboardingWindowController.swift # First-launch wizard
├── Settings/
│   ├── AppSettings.swift          # @UserDefault-backed settings model
│   └── SettingsKeys.swift         # UserDefaults key constants
├── Statistics/
│   └── StatsTracker.swift         # Tracks completions, latency, words saved
└── Resources/
    └── emoji-shortcodes.json      # ~300 common emoji shortcodes
```

## Settings

Open via menubar → **Open Settings...**

- **General**: model, Ollama URL, debounce delay, completion length, launch at login
- **Context**: clipboard awareness, context window size, screen-aware mode
- **Personalization**: learning level slider, custom AI instructions, per-app instructions
- **Features**: toggle emoji, typo detection, mid-line completion individually
- **Stats & Debug**: accept/word counts, avg latency, debug log toggle

## Troubleshooting

**Ghost text doesn't appear**
- Check Accessibility permission: System Settings → Privacy & Security → Accessibility
- Verify Ollama is running: `curl http://localhost:11434/api/tags`
- Check menubar icon — warning badge means permission not granted

**Suggestions are slow**
- Use a smaller model (`qwen2.5:1.5b` is fastest)
- Reduce context window (Settings → Context → 500 chars)
- Reduce completion length (Settings → General → Short)

**Wrong model error**
- Menubar → Check Ollama Connection shows current status
- Run `ollama pull <model-name>` to install the configured model

**Suggestions appear in password fields**
- This should never happen — Jot detects `AXSecureTextField` and suppresses all suggestions
- If you see it, file a bug with the app name

## Distribution

Direct `.app` bundle (no App Store). Requires:
- `com.apple.security.app-sandbox = false` (Accessibility API + CGEventTap require it)
- User approval in System Settings on first launch

To notarize for distribution: use `xcrun altool` or `xcrun notarytool` with your Apple Developer account.
