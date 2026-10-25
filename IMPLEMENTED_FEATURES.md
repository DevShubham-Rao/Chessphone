# ChessPhone 1.2 — iPhone session update

The supplied Chess Hacker manual was used as a feature reference. Its Mac-specific commands, paths, server, audio devices, and installers were replaced with the existing app's native iPhone components.

## Start here

1. Open **Command Center / Load FEN** on the side-selection screen, or **Command Center** during a game.
2. Use the existing scanning settings to select Ray-Ban Meta glasses or the iPhone still-camera fallback, connect glasses, and save your Gemini key to iOS Keychain.
3. Choose your side. For a game already in progress, enter a complete six-field FEN and tap **Start game**. FEN determines whose turn it is, castling rights, and en passant; the selected color determines who receives advice.
4. Play the suggested move. The command center keeps a confirmed physical board separate from pending engine advice. A scan confirms the move, or tap **I played this move**. You can also enter a different legal move in SAN (`Nf3`, `O-O`) or UCI (`g1f3`, `e7e8q`). Manual notation uses real board coordinates even when Black-seat numbering is enabled.
5. The opponent's legal move triggers a fresh Stockfish recommendation. **Pause**, **Resume**, **Undo**, **Check board now**, **Repeat**, and manual move entry provide recovery.

The existing main board continues to preview the engine's recommended continuation, preserving the original vibration/manual-entry workflow. The command center's **Tracked physical board**, move list, and PGN show confirmed moves. A suggested mating move becomes a completed game only after confirmation.

## What was added or adapted

| Manual feature | Working iPhone implementation |
| --- | --- |
| WhatsApp window capture | Existing direct Meta DAT camera stream; iPhone back camera for manual test scans. |
| OpenAI/Claude vision | Existing Gemini structured board recognition, with bounded requests and diagnostics. No extra service credentials required. |
| Jev paid pre-check | Optional local motion/stability fingerprints. With it off, watch reads roughly every three seconds. Local gating does not recognize hands; Gemini reports a hand/blocked board when readable. |
| Live game loop | Legal move reconciliation, confirmed own moves, alternate own moves, pending advice, lost-track recovery, exponential failure backoff up to ten seconds. |
| Spending cap | A $10 default **estimated allowance**. Each HTTP attempt reserves an editable estimate before it is sent. Exhaustion pauses the session. Resume authorizes another allowance block and retains the tally. This does not enforce the provider's actual invoice. |
| Browser command center / SSE | Native SwiftUI command center and Combine updates inside the app. No listening network server is needed. |
| Controls | Pause/resume, undo, manual SAN/UCI entry, new game/FEN import, repeat, explicit move confirmation, retry engine. Late results are rejected after control changes. |
| Status and evaluation | Turn/pause/lost-track/game-over statuses, side-to-move centipawn or mate evaluation, and a position-evaluation bar. The bar is not recognition confidence. |
| Live overlay | A suggestion arrow on the confirmed digital board, plus a live glasses preview while the command center is visible. Diagnostics are labeled as the last analyzed frame. |
| Overlay recording / ffmpeg | Native iOS screen recording from the command center; stop to finalize and share an MP4 of the displayed session. This replaces a desktop overlay video file. |
| OBS/HTTP video streaming | Native live session view and shareable video/files. No RTMP server, MJPEG endpoint, or desktop OBS integration is added. |
| Event bus | Typed, timestamped events, newest 300 in memory, All/Moves/Problems filters. Snapshots are published without being saved as events. |
| Run folder | Opt-in append-only JSONL, session metadata, confirmed-move PGN, and separately opt-in JPEG frames in **Files → On My iPhone → ChessPhone → ChessPhone Sessions**. |
| Stockfish executable installer | Bundled iOS ChessKitEngine Stockfish with both existing NNUE networks. Package pinned to 0.7.0; no desktop executable download. |
| Engine recovery | Half-second thinking budget, ten-second startup/probe deadlines, independent search hard timeout, fresh engine and one retry on failure, and retired-response isolation. |
| `doctor` | Native **Command Center → Diagnostics** checks engine, NNUE files, key availability, camera authorization, Meta SDK, audio route, and session storage. |
| Mac Keychain / `say` / BlackHole | Existing iOS Keychain, AVSpeechSynthesizer, iOS audio routing, and haptics. Speech goes to the phone's selected output; it is not injected into WhatsApp's microphone. |

## Files and sharing

Turn on **Save events and PGN on this iPhone** before or during a game. Turning it on mid-game saves the available recent history and all subsequent events; earlier events outside the memory limit cannot be recovered. Toggle **Also save key camera frames** separately to include photos. **Share session files** shares the actual saved files.

Screen recording is a separate user action in the command center. iOS handles the recording consent prompt. Recordings go to **ChessPhone Recordings** in the app's Documents folder; microphone recording is disabled. Stop recording before sharing. Recording also stops when the dashboard closes or the app enters the background.

Gemini still requires your own API key. Photos leave the phone only for the existing Gemini board reads. Session exports do not include Keychain items or preferences. No secrets are supplied in this ZIP.

## Build and validation

This is the complete updated **source project**, including the two NNUE networks, XcodeGen configuration, existing Builder workflows, new validation workflow, and unit tests. It is not a signed IPA.

Use **Xcode 26 or newer / Swift 6.2 or newer** for the pinned engine package:

```sh
xcodegen generate
xcodebuild test -project ChessPhone.xcodeproj -scheme ChessPhone \
  -destination 'platform=iOS Simulator,name=<available iPhone simulator>' \
  CODE_SIGNING_ALLOWED=NO
```

The new **Validate ChessPhone** GitHub Actions workflow selects an available simulator and runs the test target. The existing build workflow remains available for device builds. A signed installation still requires your Apple signing configuration; release Meta use still requires your own Meta app credentials.

Local validation on 2026-10-25: all Swift sources and tests were parsed with the tree-sitter Swift grammar, and project/workflow YAML was parsed. See `VALIDATION.md` for the exact final checks. No Xcode compiler, iPhone, Meta glasses, or API key was available in the Windows editing environment. XCTest execution, Apple/Meta SDK compile/link, recording, actual billing, camera, speech routes, hardware buttons, and haptics are therefore **not claimed as verified**.

API references used for compatibility checks: [ChessKitEngine 0.7.0](https://github.com/chesskit-app/chesskit-engine/tree/0.7.0), [Gemini Flash-Lite](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite), [Apple ReplayKit movie output](https://developer.apple.com/documentation/replaykit/rpscreenrecorder/stoprecording(withoutput:completionhandler:)).
