# Claude Instructions for Scribe

Scribe is a community-driven open-source macOS menu bar app that provides
on-device inline autocomplete in any text field. It watches Accessibility focus,
monitors global input, generates a local continuation through Apple Intelligence
or llama.cpp, renders ghost text near the caret, and inserts accepted text when
the user presses `Tab`.

This is a production app with real users and external contributors. Treat every
change as shipping to end users, not as an exercise.

## How To Work In This Repo

- Read the relevant subsystem before editing. Scribe is stateful, permission-heavy,
  and tied to macOS Accessibility behavior, so guessing usually creates regressions.
- Talk through architecture before coding when ownership, lifecycle, or async
  cancellation is unclear.
- Diagnose failures step by step before touching code. Many bugs come from stale
  focus snapshots, AX timing, permission state, runtime lifecycle, or cancellation.
- Keep changes narrow. Prefer pure helpers in `Support/` before changing services,
  coordinators, or SwiftUI views.
- Protect the user's worktree. Do not revert unrelated dirty files.

## Project Map

- `Scribe/App/`: app lifecycle, dependency construction, and coordinators.
- `Scribe/UI/`: SwiftUI/AppKit presentation such as settings, onboarding, overlays,
  and menu-facing state.
- `Scribe/Services/`: side-effectful boundaries: Accessibility, input monitoring,
  screenshots/OCR, llama runtime, permissions, downloads, updates, and insertion.
- `Scribe/Models/`: shared value types, settings snapshots, state machines, and
  protocol contracts.
- `Scribe/Support/`: pure rules and low-level helper logic that should be easy to
  test.
- `ScribeTests/`: focused tests for prompt rendering, request building, availability,
  runtime behavior, and pure state transitions.

## Key Subsystems

- App ownership starts in `ScribeAppEnvironment` and `AppDelegate`. These construct
  and retain the long-lived services. SwiftUI views should observe this graph,
  not recreate service objects.
- The suggestion state machine lives in `SuggestionCoordinator` plus its extension
  files: lifecycle, input, prediction, and acceptance. Keep pure rules out of the
  coordinator when they can live in `Support/`.
- Focus comes from `FocusTracker`, `FocusSnapshotResolver`, `AXTextGeometryResolver`,
  and `AXHelper`. Treat AX data as eventually consistent and app-specific.
- Visual context flows through `VisualContextCoordinator`,
  `ScreenshotContextGenerator`, `ScreenTextExtractor`, and `WindowScreenshotService`.
  OCR text is cleaned by the pure `OCRTextHygiene`; there is no model summarization step.
- Runtime generation flows through `SuggestionEngineRouter`,
  `FoundationModelSuggestionEngine`, `LlamaSuggestionEngine`,
  `LlamaRuntimeManager`, and the serialized `LlamaRuntimeCore` actor. The OSS
  (llama.cpp) path drives base models via `BaseCompletionPromptRenderer`; Apple
  Foundation Models stays instruct via `FoundationModelPromptRenderer`.

## Comments

- Comments should explain why, not what. Explain which invariant a design
  protects or which macOS/Swift pitfall it avoids.
- Prefer file-level and type-level `///` comments for new important files/types.
- Add targeted inline comments for tricky lifecycle, `@MainActor`, `Task`,
  cancellation, Accessibility/Core Foundation bridging, unsafe pointer work, and
  llama.cpp runtime state.
- Avoid comments that merely restate the next line of code.

## Contributing Workflow

- External contributors open PRs against `main`. Greptile reviews automatically.
- `Scribe.xcodeproj` is generated from `project.yml` by XcodeGen and committed to the
  repo. `project.yml` is the source of truth. Sources under `Scribe/` and `ScribeTests/`
  are auto-discovered by folder, so a new file (including a new test) needs no project edit.
  Only structural changes (targets, build settings, package dependencies, scheme) require
  editing `project.yml` followed by `xcodegen generate`. The `XcodeGen` CI workflow fails the
  PR if the committed project drifts from `project.yml`.
- Run SwiftLint before pushing: `swiftlint lint --quiet`. The project config is
  in `.swiftlint.yml` (line length 140/200, trailing commas disallowed).
- Wiki lives at https://github.com/bryanbernardo/jot/wiki for contributor onboarding.

## GitHub Automation Rules

- **No Co-Authored-By lines.** Never add `Co-Authored-By` trailers to commits.
- **PRs must use the repo template.** When creating a pull request, read
  `.github/PULL_REQUEST_TEMPLATE.md` and fill in every section (Summary,
  Validation, Linked issues, Risk / rollout notes). Do not invent your own
  format or use a generic body.
- **Issues must use the repo templates.** When opening an issue, read the
  matching template in `.github/ISSUE_TEMPLATE/` (bug_report.md or
  feature_request.md) and fill in every field. Do not invent your own format.

## Swift And macOS Expectations

- UI, AppKit, SwiftUI, and most Accessibility interactions belong on the main actor.
- CPU-heavy work, OCR, screenshots, and llama.cpp generation must not block the UI.
- Keep cancellation and stale-result handling explicit. The focused field can change
  while async work is still running.
- Use protocol contracts in `SuggestionSubsystemContracts.swift` when the coordinator
  only needs a behavior-shaped dependency.
- Do not show dev-only diagnostics as normal user settings unless the feature is
  intentionally productized.

## Debugging & Logs

Scribe ships a structured logging system built for AI-assisted debugging. During development
the app is launched with `-scribe-debug`, which enables on-disk JSONL sinks in addition to
the always-on Console.app stream.

**Verbosity floor.** Every handler's level comes from `ScribeDebugOptions.minimumLogLevel`. The
default is `.info`, which lets swift-log skip per-keystroke `.debug`/`.trace` calls before they
allocate, so they cost nothing in release and do not distort energy measurements. `-scribe-debug`
raises the floor to `.trace`. `SCRIBE_LOG_LEVEL=<trace|debug|info|...>` overrides it explicitly,
e.g. to get Console `.debug` output without the heavier file/screenshot artifacts. A
`Logging initialized` line at startup records the active `debug_mode`, `min_log_level`, and sink paths.

**Log file locations** (only populated when `-scribe-debug` is set):

- `~/Library/Logs/Scribe/scribe.jsonl` — main event stream. One JSON object per line. All
  metadata (request IDs, engine names, token counts, latencies, error reasons) is flattened
  as top-level fields so it can be filtered with `jq`.
- `~/Library/Logs/Scribe/llm-io.jsonl` — full LLM prompts and completions, one record per
  generation. Shares `request_id` with the main log so a single suggestion can be joined
  across files.
- **Dev-identity builds log to `~/Library/Logs/Scribe Dev/` instead** (same file names). The
  `Scribe Dev` scheme — the daily-driver way to run from Xcode — ships a separate app identity,
  and its logs land in the identity's own directory. When debugging a dev-built app, read that
  directory first; an apparently silent `~/Library/Logs/Scribe/` does not mean the flag is off.
- `~/Desktop/scribe-ax-dump.txt` — most recent Chrome AX tree snapshot. Overwritten on each
  Chrome focus change (debounced by focused-element identity).
- Rotated previous logs: `*.jsonl.1` (one-step rotation when a file exceeds 10 MB).

**Correlation IDs.** Every prediction gets a `request_id` like `req_a3f9k2lq`, stamped on
every log line that touches that request (coordinator state transitions, router selection,
engine generation, LLM I/O capture). To pull the complete history of one suggestion:

```bash
jq 'select(.request_id == "req_a3f9k2lq")' ~/Library/Logs/Scribe/scribe.jsonl
jq 'select(.request_id == "req_a3f9k2lq")' ~/Library/Logs/Scribe/llm-io.jsonl
```

**Useful `jq` recipes:**

```bash
# Recent errors across the app
jq 'select(.level == "error")' ~/Library/Logs/Scribe/scribe.jsonl

# Llama generations slower than 500 ms
jq 'select(.engine == "llama" and .latency_ms > 500)' ~/Library/Logs/Scribe/llm-io.jsonl

# Coordinator state transitions
jq 'select(.category == "suggestion" and .stage != null)' ~/Library/Logs/Scribe/scribe.jsonl

# Runtime model load/decode events
jq 'select(.category == "runtime")' ~/Library/Logs/Scribe/scribe.jsonl
```

**Symptom → category map** (jump straight to the right filter):

- Ghost text didn't appear → `suggestion` + `focus`
- Wrong text inserted → look up the request in `llm-io.jsonl`, then walk `suggestion` for
  acceptance
- Model won't load / decode fails → `runtime` + `models`
- Permission dialog loop → `app` (permission state transitions)
- Chrome-specific weirdness → start with `~/Desktop/scribe-ax-dump.txt`, then `focus`
- Wrong backend chosen → `suggestion` router selection log (`engine`, `fallback_engine`)

**Console.app fallback** (when `-scribe-debug` wasn't set or the user hasn't relaunched yet):

```bash
log show --predicate 'subsystem == "com.bryanbernardo.scribe"' --last 10m
log stream --predicate 'subsystem == "com.bryanbernardo.scribe"' --level debug
```

Note the default verbosity floor is `.info`, so Scribe's `.debug`/`.trace` lines are not emitted
unless the app was launched with `-scribe-debug` or `SCRIBE_LOG_LEVEL=debug`. The `--level debug`
flag above controls what `log` *displays*, not what Scribe *emits*. The `.info`, warning, and error
lines (including model-load config and permission transitions) always stream.

**Rule of thumb.** When a user reports a bug, first `tail` / `jq` the relevant file with the
symptom → category map. Do not ask the user to re-explain symptoms before checking the logs.
If `-scribe-debug` clearly isn't on (no JSONL files exist), use the `log show` fallback
first; only ask for a relaunch with the flag if the OSLog stream is genuinely insufficient.

## Validation

Prefer the narrowest useful validation first, then broaden when the change touches
shared behavior:

```bash
xcodebuild -project Scribe.xcodeproj -scheme Scribe -destination 'platform=macOS' build \
  -derivedDataPath build/DerivedData
xcodebuild -project Scribe.xcodeproj -scheme Scribe -destination 'platform=macOS' build-for-testing \
  -derivedDataPath build/DerivedData
```

Always pass `-derivedDataPath build/DerivedData` so output lands in the
repo-scoped `build/` (already gitignored) instead of accumulating under
`~/Library/Developer/Xcode/DerivedData/Scribe-*`, where every build leaves a
fresh multi-GB module cache and SwiftPM checkout that nothing trims. When a
task is done and the build artifacts are no longer needed, `rm -rf
build/DerivedData` before reporting completion.

Run targeted tests when possible. If app-hosted tests fail because of local signing
or Team ID mismatch, report the exact failure and still run `build-for-testing`.
