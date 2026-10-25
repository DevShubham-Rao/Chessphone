# Controls and feedback update

Named presets, vibration toggles, configurable invalid-move feedback, on-screen input buttons, and volume-control recovery have been added. See [CONTROLS_UPDATE.md](CONTROLS_UPDATE.md) for usage and the validation limits of this update.

# ChessPhone + Ray-Ban Meta Board Scan

ChessPhone is an iOS chess assistant that combines:

- Ray-Ban Meta camera capture through Meta Wearables Device Access Toolkit (DAT) 1.0.0
- iPhone camera fallback for testing
- Gemini Flash vision parsing
- Stockfish through `chesskit-engine`
- Spoken and/or haptic move output
- Existing manual volume-button move entry, takebacks, saves, skill level, and depth controls

## Vision workflow

With **Continuous board watch** enabled and Ray-Ban Meta selected, ChessPhone keeps the glasses preview warm. It reads one starting frame, then compares small local image fingerprints while waiting for a board change. After the image moves and settles, it sends one frame to Gemini for piece recognition, validates the position against legal chess moves, and asks Stockfish for a reply. It does not send every preview frame to Gemini.

The watcher tracks the engine's recommended move separately from the physical board. If the board still shows the position from before that recommendation, it waits for you to play. If it sees the recommendation on the board, it waits for the opponent. If you play a different legal move, it corrects the saved move history to match the board. A **Check board now** button is available for recovery. Volume Up and Volume Down remain available for manual move entry.

The iPhone camera remains a manual testing source. Continuous watch is available only with Ray-Ban Meta because the iPhone fallback currently captures still images rather than publishing a live preview.

This version uses whole-board Gemini recognition after local motion gating. It does not yet draw piece boxes or normalize the board perspective like the video; that would require a dedicated on-device chess-piece detector and board-corner tracker. The glasses preview is configured at 2 FPS, so a real move may take a couple of seconds to register before image recognition and Stockfish search begin.

## Ray-Ban Meta support

This project uses Meta's current iOS Device Access Toolkit instead of trying to expose the glasses as an `AVCaptureDevice`. The glasses camera is not a normal iOS camera input. Registration, camera permission, device session creation, and photo capture all go through Meta's SDK and Meta AI companion app.

The project is pinned to:

- `meta-wearables-dat-ios` **1.0.0**
- `MWDATCore`
- `MWDATCamera`
- iOS deployment target **17.2**

The camera stream is kept warm at medium resolution / 2 FPS. Continuous watch uses those preview frames for local change detection and only requests a still-photo fallback if a fresh preview frame is unavailable.

## First-time setup

### 1. Meta glasses

1. Install/update the Meta AI companion app on the iPhone.
2. Pair the Ray-Ban Meta glasses normally.
3. Enable **Developer Mode** for the glasses in Meta AI.
4. Build and run ChessPhone on a real iPhone.
5. Open **Vibration & Audio Settings → Board scanning**.
6. Choose **Ray-Ban Meta glasses**.
7. Tap **Connect Ray-Ban Meta glasses** and approve the registration/permission flow in Meta AI.
8. Turn on **Continuous board watch**.

For Developer Mode, `project.yml` uses placeholder Meta app credentials (`MetaAppID` / `ClientToken` = `0`). For a release-channel build, replace these with values from the Wearables Developer Center and build with the correct Apple Development Team.

### 2. Gemini key

The Gemini API key is never hard-coded in source. Supported lookup order:

1. **Keychain**: paste it in Board scanning settings and tap **Save key to Keychain**.
2. **Untracked plist**: copy `Resources/Secrets.example.plist` to `Resources/Secrets.plist` and replace the placeholder.
3. **Xcode environment variable**: set `GEMINI_API_KEY` in the run scheme.

`Resources/Secrets.plist` is gitignored.

For an app distributed to other people, do not ship a reusable Gemini key in the app bundle. Put Gemini behind your own server/proxy and issue short-lived authenticated requests from the app.

### 3. Stockfish NNUE files

Both required network files are already present in `Resources/` in this ZIP:

- `nn-1111cefa1111.nnue`
- `nn-37f18f62d772.nnue`

The app checks for both before declaring Stockfish ready.

## Build

This is an XcodeGen project.

```bash
brew install xcodegen
xcodegen generate
open ChessPhone.xcodeproj
```

For current Meta DAT builds, use a current Xcode toolchain compatible with the SDK. Run on a real iPhone for Ray-Ban Meta and volume-button testing.

The included Builder/GitHub workflow can also generate the Xcode project before building.

## Important iPhone Volume Up behavior

Apple does not expose a dedicated public "hardware Volume Up button pressed" callback. This app observes `AVAudioSession.outputVolume` and embeds an `MPVolumeView`, then restores the volume to a midpoint after a press. This works only on a real device and is intentionally isolated in `VolumeButtonHandler.swift` / `MPVolumeSetter.swift`.

Because it is volume-state observation rather than a formal button-event API, test this on every iOS version you plan to use. If you later want a glasses-native trigger, Meta DAT 1.0 also introduced an experimental Inputs module, but this project does not require that experimental capability.

## Main vision files

- `ChessPhone/GlassesCameraSource.swift`: Meta registration/session/camera/photo capture
- `ChessPhone/BoardImageSource.swift`: image-source protocol + iPhone fallback
- `ChessPhone/ImagePreprocessor.swift`: 1024 px JPEG normalization
- `ChessPhone/GeminiKeyProvider.swift`: Keychain/plist/environment key loading
- `ChessPhone/GeminiBoardReader.swift`: structured Gemini board reading
- `ChessPhone/BoardPosition.swift`: orientation, sanity checks, scan-to-move matching, FEN-ready position
- `ChessPhone/VisionCoordinator.swift`: frame capture, Gemini reading, and scan settings
- `ChessPhone/BoardFrameMonitor.swift`: low-resolution local motion fingerprints
- `ChessPhone/GameState.swift`: continuous watch and game-history reconciliation

## Debugging an incorrect move

During a game, tap the ladybug icon in the top bar to open **Chess Debug**. Run a scan or enter the move again, then inspect the latest events or tap **Copy log** to copy them for troubleshooting. The log includes the sanitized Gemini request (with image bytes omitted), full response text, decoded board rows, oriented board, tracked FEN, legal move list, changed squares, and accepted/rejected move details. The API key is redacted; logs are kept in memory and are cleared when you tap **Clear**. If a scan is an unambiguous near match to exactly one legal position, the app can now repair a one-square piece placement error; it still rejects ambiguous or larger differences.

## Testing status

The debug overlay has not been compiled in this editing environment because the Swift compiler and Xcode are unavailable. Build it in Xcode before installing. It also requires a real Apple/Meta environment for:

- Xcode compile/link against the Meta binary SDK
- Meta AI registration callback
- Ray-Ban Meta physical capture
- iPhone hardware Volume Up behavior
- Real Gemini API request with your key

Those cannot be truthfully hardware-verified from a Linux build container.
